defmodule Lovelace.Integrations.Google.KeychainTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Lovelace.Integrations.Google.Keychain

  @account "01234567-89AB-CDEF-0123-456789ABCDEF"

  defmodule FakeStore do
    @behaviour Keychain
    @impl true
    def get(_account), do: {:ok, "fake-refresh-token"}
    @impl true
    def put(_account, _value), do: :ok
    @impl true
    def delete(_account), do: :ok
  end

  test "fake vault contract is separate from native boundary" do
    assert {:ok, "fake-refresh-token"} = FakeStore.get(@account)
    assert :ok = FakeStore.put(@account, "value")
    assert :ok = FakeStore.delete(@account)
    # Even an installed helper cannot perform real Keychain operations in tests.
    assert {:error, :unavailable} = Keychain.get(@account)
    assert {:error, :unavailable} = Keychain.put(@account, "fake-token")
    assert {:error, :unavailable} = Keychain.delete(@account)
  end

  test "stdin framing carries the value and lowercase UUID, never command arguments" do
    owner = self()
    token = "fake-secret\nwith \"quotes\""

    runner = fn input ->
      send(owner, {:stdin, input})
      {:ok, "{\"ok\":true}\n"}
    end

    assert :ok = Keychain.with_test_runner("put", @account, token, runner)
    assert_receive {:stdin, input}
    assert [line, ""] = String.split(input, "\n")

    assert Jason.decode!(line) == %{
             "operation" => "put",
             "account" => String.downcase(@account),
             "value" => token
           }

    assert {:ok, ^token} =
             Keychain.with_test_runner("get", @account, nil, fn _ ->
               {:ok, Jason.encode!(%{ok: true, value: token}) <> "\n"}
             end)

    assert :ok = Keychain.with_test_runner("delete", @account, nil, runner)
  end

  test "Gemini service is allowlisted and isolated without changing the legacy Gmail envelope" do
    owner = self()

    runner = fn input ->
      send(owner, {:input, Jason.decode!(input)})
      {:ok, "{\"ok\":true}\n"}
    end

    for service <- ["LOVELACE Gmail", "LOVELACE Gemini"] do
      assert :ok = Keychain.with_test_runner("put", @account, "fake-key", runner, service)
      assert_receive {:input, payload}
      assert payload["account"] == String.downcase(@account)
      assert payload["value"] == "fake-key"

      if service == "LOVELACE Gmail" do
        refute Map.has_key?(payload, "service")
        assert payload["operation"] == "put"
      else
        assert payload["service"] == "LOVELACE Gemini"
        assert payload["operation"] == "gemini_put"
      end
    end

    for service <- [nil, "", "arbitrary service", "LOVELACE Gemini\n", :gemini] do
      assert {:error, :unavailable} =
               Keychain.with_test_runner("put", @account, "fake-key", runner, service)
    end

    refute_received {:input, _}

    assert {:error, :invalid_account} =
             Keychain.with_test_runner("get", "not-a-uuid", nil, runner, "LOVELACE Gemini")
  end

  test "all Gemini operations fail closed on legacy helpers before touching Gmail" do
    owner = self()

    legacy_runner = fn input ->
      request = Jason.decode!(input)

      if request["operation"] in ["get", "put", "delete"] do
        send(owner, :gmail_touched)
        {:ok, "{\"ok\":true}\n"}
      else
        {:ok, "{\"error\":\"unavailable\"}\n"}
      end
    end

    for {operation, value} <- [{"get", nil}, {"put", "fake-key"}, {"delete", nil}] do
      assert {:error, :unavailable} =
               Keychain.with_test_runner(
                 operation,
                 @account,
                 value,
                 legacy_runner,
                 "LOVELACE Gemini"
               )
    end

    refute_received :gmail_touched
  end

  test "invalid account and value fail before runner is invoked" do
    runner = fn _ -> flunk("runner invoked for invalid input") end

    for account <- ["not-a-uuid", "../path", nil, @account <> "\n"] do
      assert {:error, :invalid_account} = Keychain.with_test_runner("get", account, nil, runner)
    end

    for value <- [nil, "", <<255>>, String.duplicate("x", 16 * 1024 + 1)] do
      assert {:error, :invalid_value} = Keychain.with_test_runner("put", @account, value, runner)
    end
  end

  test "locked, missing and unavailable errors are allowlisted; malformed output is hidden" do
    for {string, atom} <- [
          {"locked", :locked},
          {"not_found", :not_found},
          {"unavailable", :unavailable},
          {"timeout", :timeout}
        ] do
      assert {:error, ^atom} =
               Keychain.with_test_runner("get", @account, nil, fn _ ->
                 {:ok, Jason.encode!(%{error: string}) <> "\n"}
               end)
    end

    for output <- [
          "private diagnostic",
          "{\"ok\":true}\nextra\n",
          "{}\n",
          "{\"error\":\"private-secret\"}\n",
          String.duplicate("x", 128 * 1024 + 1)
        ] do
      assert {:error, :unavailable} =
               Keychain.with_test_runner("get", @account, nil, fn _ -> {:ok, output} end)
    end

    assert capture_log(fn ->
             assert {:error, :unavailable} =
                      Keychain.with_test_runner("put", @account, "fake-secret", fn _ ->
                        raise "fake-secret"
                      end)
           end) == ""
  end

  @tag timeout: 7_000
  test "helper deadline also bounds an injected hanging runner" do
    assert {:error, :timeout} =
             Keychain.with_test_runner("get", @account, nil, fn _ -> Process.sleep(:infinity) end)
  end
end
