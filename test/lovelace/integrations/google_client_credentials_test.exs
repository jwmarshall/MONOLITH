defmodule Lovelace.Integrations.Google.ClientCredentialsTest do
  use ExUnit.Case, async: false

  alias Lovelace.Integrations.Google.ClientCredentials

  defmodule FakeKeychain do
    def get(account, service) do
      send(self(), {:read, account, service})
      Process.get(:google_client_value, {:error, :not_found})
    end

    def put(account, value, service) do
      send(self(), {:write, account, value, service})
      Process.put(:google_client_value, {:ok, value})
      :ok
    end

    def delete(account, service) do
      send(self(), {:delete, account, service})
      Process.delete(:google_client_value)
      :ok
    end
  end

  setup do
    previous = Application.fetch_env(:lovelace, :google_client_keychain)
    Application.put_env(:lovelace, :google_client_keychain, FakeKeychain)

    on_exit(fn ->
      case previous do
        {:ok, adapter} -> Application.put_env(:lovelace, :google_client_keychain, adapter)
        :error -> Application.delete_env(:lovelace, :google_client_keychain)
      end
    end)

    :ok
  end

  test "bounded client pair roundtrips in the dedicated namespace" do
    assert :ok = ClientCredentials.save("synthetic-client", "synthetic-secret")

    assert_received {:write, "710dd510-61ed-4e6a-975c-78ce13f5d6e2", json,
                     "LOVELACE Google OAuth"}

    assert Jason.decode!(json) == %{
             "client_id" => "synthetic-client",
             "client_secret" => "synthetic-secret"
           }

    assert {:ok, %{client_id: "synthetic-client", client_secret: "synthetic-secret"}} =
             ClientCredentials.read()

    assert :ok = ClientCredentials.delete()
    assert {:error, :invalid_configuration} = ClientCredentials.read()
  end

  test "invalid values do not reach the keychain" do
    for value <- [nil, "", "has space", "line\nfeed", "nul\0byte", String.duplicate("x", 8193)] do
      assert {:error, :invalid_configuration} = ClientCredentials.save(value, "synthetic-secret")
      assert {:error, :invalid_configuration} = ClientCredentials.save("synthetic-client", value)
    end

    refute_received {:write, _, _, _}
  end

  test "malformed stored values and native failures expose only safe categories" do
    for value <- [
          "not json",
          "{}",
          Jason.encode!(%{client_id: "id", client_secret: "has space"}),
          String.duplicate("x", 20_001)
        ] do
      Process.put(:google_client_value, {:ok, value})
      assert {:error, :invalid_configuration} = ClientCredentials.read()
    end

    Process.put(:google_client_value, {:error, :locked})
    assert {:error, :locked} = ClientCredentials.read()
    Process.put(:google_client_value, {:error, "synthetic private native error"})
    assert {:error, :unavailable} = ClientCredentials.read()
  end
end
