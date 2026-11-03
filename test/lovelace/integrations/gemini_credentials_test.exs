defmodule Lovelace.Integrations.Gemini.CredentialsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Ash.Resource.Info
  alias Lovelace.Integrations.Gemini.{Credentials, Keychain}
  alias Lovelace.StageDesigner
  alias Lovelace.StageDesigner.Designer

  @key "fake-gemini-key-not-a-real-credential"
  @owner [actor: %{role: :local_owner}]

  defmodule Vault do
    @behaviour Lovelace.Integrations.Google.Keychain

    @impl true
    def get(account), do: invoke(:get, account, nil)
    @impl true
    def put(account, value), do: invoke(:put, account, value)
    @impl true
    def delete(account), do: invoke(:delete, account, nil)

    defp invoke(operation, account, value) do
      send(self(), {:vault_call, operation, account, value})

      case Process.get({__MODULE__, operation}, {:error, :not_found}) do
        :raise -> raise "fake-gemini-key-not-a-real-credential"
        :throw -> throw("fake-gemini-key-not-a-real-credential")
        :exit -> exit("fake-gemini-key-not-a-real-credential")
        response -> response
      end
    end
  end

  setup do
    previous = Application.fetch_env(:lovelace, :gemini_vault)
    Application.put_env(:lovelace, :gemini_vault, Vault)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:lovelace, :gemini_vault, value)
        :error -> Application.delete_env(:lovelace, :gemini_vault)
      end
    end)
  end

  test "status exposes safe local storage states, never the stored key" do
    for {response, expected} <- [
          {{:ok, @key}, :stored},
          {{:error, :not_found}, :not_connected},
          {{:error, :locked}, :locked},
          {{:error, :timeout}, :unavailable},
          {{:error, :unavailable}, :unavailable},
          {{:error, @key}, :unavailable},
          {{:ok, ""}, :invalid},
          {{:ok, "with whitespace"}, :invalid},
          {{:ok, nil}, :invalid},
          {{:ok, <<255>>}, :invalid},
          {{:ok, String.duplicate("x", 4097)}, :invalid},
          {nil, :unavailable}
        ] do
      Process.put({Vault, :get}, response)
      assert Credentials.status() == expected
      assert {:ok, ^expected} = StageDesigner.gemini_connection_status(@owner)
    end
  end

  test "read_key distinguishes missing/invalid credentials from Keychain failures" do
    Process.put({Vault, :get}, {:ok, @key})
    assert {:ok, @key} = Credentials.read_key()

    for response <- [{:error, :not_found}, {:ok, "bad key"}, {:ok, nil}] do
      Process.put({Vault, :get}, response)
      assert {:error, :missing_api_key} = Credentials.read_key()
    end

    for response <- [{:error, :locked}, {:error, :timeout}, {:error, @key}, nil] do
      Process.put({Vault, :get}, response)
      assert {:error, :keychain_unavailable} = Credentials.read_key()
    end
  end

  test "validation is byte-bounded, UTF-8 and rejects whitespace without trimming or echoing" do
    for key <- [
          nil,
          123,
          "",
          " ",
          " leading",
          "trailing ",
          "a b",
          "a\tb",
          "a\rb",
          "a\nb",
          "a\u00A0b",
          "a\u2003b",
          <<255>>,
          String.duplicate("x", 4097),
          String.duplicate("é", 2049)
        ] do
      assert {:error, :invalid_api_key} = Credentials.save(key)
    end

    refute_received {:vault_call, _, _, _}
    Process.put({Vault, :put}, :ok)

    for key <- [@key, "x", String.duplicate("x", 4096), String.duplicate("é", 2048)] do
      assert {:ok, true} = Credentials.save(key)
      account = Keychain.account()
      assert_received {:vault_call, :put, ^account, ^key}
    end
  end

  test "save/remove use only the Gemini singleton and report success only on safe success" do
    account = Keychain.account()
    Process.put({Vault, :put}, :ok)
    Process.put({Vault, :delete}, :ok)

    assert {:ok, true} = StageDesigner.save_gemini_key(@key, @owner)
    assert_received {:vault_call, :put, ^account, @key}
    assert {:ok, true} = StageDesigner.remove_gemini_key(@owner)
    assert_received {:vault_call, :delete, ^account, nil}
    refute_received {:vault_call, _, _, _}

    Process.put({Vault, :delete}, {:error, :not_found})
    assert {:ok, true} = Credentials.delete()

    for {response, expected} <- [
          {{:error, :locked}, :locked},
          {{:error, :timeout}, :unavailable},
          {{:error, @key}, :unavailable},
          {true, :unavailable}
        ] do
      Process.put({Vault, :put}, response)
      Process.put({Vault, :delete}, response)
      assert {:error, ^expected} = Credentials.save(@key)
      assert {:error, ^expected} = Credentials.delete()
    end
  end

  test "Ash credential actions reject anonymous, service, string-role and unrelated actors" do
    for actor <- [
          nil,
          %{},
          %{role: :stage_designer},
          %{role: :mail_service},
          %{role: :owner_auth_service},
          %{role: "local_owner"}
        ] do
      assert {:error, %Ash.Error.Forbidden{}} =
               StageDesigner.gemini_connection_status(actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} = StageDesigner.save_gemini_key(@key, actor: actor)
      assert {:error, %Ash.Error.Forbidden{}} = StageDesigner.remove_gemini_key(actor: actor)
    end

    refute_received {:vault_call, _, _, _}
  end

  test "Ash marks the key sensitive and never trims invalid whitespace into a valid key" do
    action = Info.action(Designer, :save_gemini_key)
    [argument] = action.arguments
    assert argument.sensitive?
    assert argument.constraints[:trim?] == false
    Process.put({Vault, :put}, :ok)

    log =
      capture_log(fn ->
        for key <- [
              " " <> @key,
              @key <> " ",
              @key <> "\n",
              @key <> <<255>>,
              @key <> String.duplicate("x", 4096),
              ""
            ] do
          assert {:error, error} = StageDesigner.save_gemini_key(key, @owner)
          refute inspect(error) =~ @key
          refute Exception.message(error) =~ @key
        end
      end)

    refute log =~ @key
    refute_received {:vault_call, _, _, _}
  end

  test "vault exceptions, throws, exits and unexpected responses never escape or log keys" do
    log =
      capture_log(fn ->
        for response <- [:raise, :throw, :exit, {:error, %{private: @key}}] do
          for operation <- [:get, :put, :delete], do: Process.put({Vault, operation}, response)
          assert Credentials.status() == :unavailable
          assert {:error, :keychain_unavailable} = Credentials.read_key()
          assert {:error, :unavailable} = Credentials.save(@key)
          assert {:error, :unavailable} = Credentials.delete()
          assert {:error, error} = StageDesigner.save_gemini_key(@key, @owner)
          refute inspect(error) =~ @key
          refute Exception.message(error) =~ @key
        end
      end)

    refute log =~ @key
  end

  test "native Gemini operations stay disabled in test builds and reject non-singleton UUIDs" do
    assert {:error, :unavailable} = Keychain.get(Keychain.account())
    assert {:error, :unavailable} = Keychain.put(Keychain.account(), @key)
    assert {:error, :unavailable} = Keychain.delete(Keychain.account())

    for account <- [Ash.UUID.generate(), nil, "not-a-uuid"] do
      assert {:error, :invalid_account} = Keychain.get(account)
      assert {:error, :invalid_account} = Keychain.put(account, @key)
      assert {:error, :invalid_account} = Keychain.delete(account)
    end
  end
end
