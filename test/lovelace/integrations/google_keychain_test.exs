defmodule Lovelace.Security.KeychainTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Lovelace.Integrations.GitHub.Keychain, as: GitHubKeychain
  alias Lovelace.Integrations.Google.Keychain, as: GoogleKeychain
  alias Lovelace.Security.Keychain

  @account "01234567-89AB-CDEF-0123-456789ABCDEF"
  @gemini "b26d050a-0729-4d79-a6bc-407cf660a7ea"
  @oauth "710dd510-61ed-4e6a-975c-78ce13f5d6e2"
  @database "5bbed47a-8e42-4b3e-a2e8-f81beb0738d5"
  @gmail "LOVELACE Gmail"

  defmodule FakeStore do
    @behaviour GoogleKeychain
    @impl true
    def get(_), do: {:ok, "fake-refresh-token"}
    @impl true
    def put(_, _), do: :ok
    @impl true
    def delete(_), do: :ok
  end

  defp response(payload), do: {:ok, Jason.encode!(Map.put(payload, :version, 1)) <> "\n"}

  defp attributes(account \\ @account, service \\ @gmail),
    do: %{account: account, service: service}

  test "provider fake contract remains separate and test builds cannot invoke native secrets" do
    assert {:ok, "fake-refresh-token"} = FakeStore.get(@account)
    assert :ok = FakeStore.put(@account, "value")
    assert :ok = FakeStore.delete(@account)
    assert {:error, :unavailable} = GoogleKeychain.get(@account)
    assert {:error, :unavailable} = GoogleKeychain.put(@account, "fake-token")
    assert {:error, :unavailable} = GoogleKeychain.delete(@account)
    assert {:error, :unavailable} = GitHubKeychain.get(@account)
    assert {:error, :unavailable} = GitHubKeychain.put(@account, "synthetic-github-token")
    assert {:error, :unavailable} = GitHubKeychain.delete(@account)
    assert {:error, :unavailable} = Keychain.create("synthetic password")
    assert {:error, :unavailable} = Keychain.unlock("synthetic password")
    assert {:error, :unavailable} = Keychain.status()
    assert {:error, :unavailable} = Keychain.lock()
    assert {:error, :unavailable} = Keychain.database_key()
    assert {:error, :unavailable} = Keychain.copy_legacy([])
    assert {:error, :unavailable} = Keychain.delete_legacy([])
  end

  test "directory uses trusted application database configuration without invoking Repo" do
    config = Application.fetch_env!(:lovelace, Lovelace.Repo)
    directory = Path.expand(Keyword.fetch!(config, :database) <> ".vault")
    assert Keychain.directory() == directory
    assert Keychain.path() == Path.join(directory, "lovelace.keychain-db")
  end

  test "versioned stdin frame includes fixed directory, explicit service and lowercase UUID" do
    owner = self()
    token = "fake-secret\nwith \"quotes\""

    runner = fn input ->
      send(owner, {:stdin, input})
      response(%{ok: true})
    end

    assert :ok = Keychain.with_test_runner("put", Map.put(attributes(), :value, token), runner)
    assert_receive {:stdin, input}
    assert [line, ""] = String.split(input, "\n")

    assert Jason.decode!(line) == %{
             "version" => 1,
             "directory" => Keychain.directory(),
             "operation" => "vault_put",
             "service" => @gmail,
             "account" => String.downcase(@account),
             "value" => token
           }

    assert {:ok, ^token} =
             Keychain.with_test_runner("get", attributes(), fn _ ->
               response(%{ok: true, value: token})
             end)

    assert :ok = Keychain.with_test_runner("delete", attributes(), runner)
  end

  test "GitHub credentials are isolated by organization UUID and service through synthetic transport" do
    {:ok, store} = Agent.start_link(fn -> %{} end)
    on_exit(fn -> if Process.alive?(store), do: Agent.stop(store) end)
    other = "11234567-89ab-cdef-0123-456789abcdef"
    service = "LOVELACE GitHub"

    runner = fn input ->
      request = Jason.decode!(input)
      identity = {request["account"], request["service"]}

      case request["operation"] do
        "vault_put" ->
          Agent.update(store, &Map.put(&1, identity, request["value"]))
          response(%{ok: true})

        "vault_get" ->
          case Agent.get(store, &Map.fetch(&1, identity)) do
            {:ok, value} -> response(%{ok: true, value: value})
            :error -> response(%{error: "not_found"})
          end

        "vault_delete" ->
          Agent.update(store, &Map.delete(&1, identity))
          response(%{ok: true})
      end
    end

    for {account, credential_service, token} <- [
          {@account, service, "synthetic-github-first"},
          {other, service, "synthetic-github-second"},
          {@account, @gmail, "synthetic-gmail"}
        ] do
      assert :ok =
               Keychain.with_test_runner(
                 "put",
                 Map.put(attributes(account, credential_service), :value, token),
                 runner
               )
    end

    assert {:ok, "synthetic-github-first"} =
             Keychain.with_test_runner(
               "get",
               attributes(String.downcase(@account), service),
               runner
             )

    assert :ok = Keychain.with_test_runner("delete", attributes(@account, service), runner)

    assert {:error, :not_found} =
             Keychain.with_test_runner("get", attributes(@account, service), runner)

    assert {:ok, "synthetic-github-second"} =
             Keychain.with_test_runner("get", attributes(other, service), runner)

    assert {:ok, "synthetic-gmail"} =
             Keychain.with_test_runner("get", attributes(), runner)

    never = fn _ -> flunk("invalid GitHub credential invoked runner") end

    assert {:error, :invalid_account} =
             Keychain.with_test_runner("get", attributes("organization-login", service), never)

    assert {:error, :invalid_value} =
             Keychain.with_test_runner(
               "put",
               Map.put(
                 attributes(@account, service),
                 :value,
                 String.duplicate("x", 16 * 1024 + 1)
               ),
               never
             )
  end

  test "all services are explicit and singleton services cannot address another account" do
    for {account, service} <- [
          {@account, @gmail},
          {@account, "LOVELACE GitHub"},
          {@gemini, "LOVELACE Gemini"},
          {@oauth, "LOVELACE Google OAuth"},
          {@database, "LOVELACE Database"}
        ] do
      assert {:ok, "synthetic"} =
               Keychain.with_test_runner("get", attributes(account, service), fn input ->
                 request = Jason.decode!(input)
                 assert request["service"] == service
                 assert request["account"] == String.downcase(account)
                 response(%{ok: true, value: "synthetic"})
               end)
    end

    never = fn _ -> flunk("invalid identity invoked runner") end

    for service <- ["LOVELACE Gemini", "LOVELACE Google OAuth", "LOVELACE Database"] do
      assert {:error, :invalid_account} =
               Keychain.with_test_runner("get", attributes(@account, service), never)
    end

    for service <- [nil, "", "arbitrary service", "LOVELACE Gmail\n", :gemini] do
      assert {:error, :unavailable} =
               Keychain.with_test_runner("get", attributes(@account, service), never)
    end

    assert {:error, :unavailable} =
             Keychain.with_test_runner(
               "put",
               Map.put(attributes(@database, "LOVELACE Database"), :value, "replacement"),
               never
             )

    assert {:error, :unavailable} =
             Keychain.with_test_runner(
               "delete",
               attributes(@database, "LOVELACE Database"),
               never
             )
  end

  test "unversioned or wrong-version helpers and obsolete operations fail closed" do
    for output <- [
          "{\"ok\":true}\n",
          "{\"version\":0,\"ok\":true}\n",
          "{\"version\":2,\"ok\":true}\n"
        ] do
      assert {:error, :unavailable} =
               Keychain.with_test_runner("delete", attributes(), fn _ -> {:ok, output} end)
    end

    for operation <- ["gemini_get", "vault_get", "invalid"] do
      assert {:error, :unavailable} =
               Keychain.with_test_runner(operation, attributes(), fn _ ->
                 flunk("obsolete operation")
               end)
    end
  end

  test "passwords are bounded UTF-8 and carried only inside the versioned stdin request" do
    for operation <- ["create", "unlock"] do
      assert :ok =
               Keychain.with_test_runner(
                 operation,
                 %{password: "synthetic\npassword"},
                 fn input ->
                   assert %{"password" => "synthetic\npassword", "operation" => wire} =
                            Jason.decode!(input)

                   assert wire == "vault_" <> operation
                   response(%{ok: true})
                 end
               )

      for password <- [nil, "", <<255>>, String.duplicate("x", 4097)] do
        assert {:error, :invalid_password} =
                 Keychain.with_test_runner(operation, %{password: password}, fn _ ->
                   flunk("invalid password")
                 end)
      end
    end
  end

  test "invalid account and value fail before runner invocation" do
    never = fn _ -> flunk("invalid input invoked runner") end

    for account <- ["not-a-uuid", "../path", nil, @account <> "\n"] do
      assert {:error, :invalid_account} =
               Keychain.with_test_runner("get", attributes(account), never)
    end

    for value <- [nil, "", <<255>>, String.duplicate("x", 16 * 1024 + 1)] do
      assert {:error, :invalid_value} =
               Keychain.with_test_runner("put", Map.put(attributes(), :value, value), never)
    end
  end

  test "status and migration APIs expose only safe results with explicit account lists" do
    for {status, expected} <- [
          {"locked", :locked},
          {"unlocked", :unlocked},
          {"missing", :missing}
        ] do
      assert {:ok, ^expected} =
               Keychain.with_test_runner("status", %{}, fn _ ->
                 response(%{ok: true, status: status})
               end)
    end

    assert {:error, :unavailable} =
             Keychain.with_test_runner("status", %{}, fn _ ->
               response(%{ok: true, status: "private"})
             end)

    for operation <- ["copy_legacy", "delete_legacy"] do
      assert :ok =
               Keychain.with_test_runner(
                 operation,
                 %{accounts: [@account, String.downcase(@account)]},
                 fn input ->
                   request = Jason.decode!(input)
                   assert request["accounts"] == [String.downcase(@account)]
                   refute Map.has_key?(request, "password")
                   response(%{ok: true})
                 end
               )

      for accounts <- [nil, ["not-a-uuid"], List.duplicate(@account, 513)] do
        assert {:error, :invalid_account} =
                 Keychain.with_test_runner(operation, %{accounts: accounts}, fn _ ->
                   flunk("invalid migration input")
                 end)
      end
    end
  end

  test "safe errors are allowlisted and malformed output is hidden without logging secrets" do
    for reason <-
          ~w(locked missing exists conflict not_found unavailable timeout invalid_directory) do
      expected = String.to_existing_atom(reason)

      assert {:error, ^expected} =
               Keychain.with_test_runner("get", attributes(), fn _ ->
                 response(%{error: reason})
               end)
    end

    for output <- [
          "private diagnostic",
          "{\"version\":1,\"ok\":true}\nextra\n",
          "{}\n",
          "{\"version\":1,\"error\":\"private-secret\"}\n",
          String.duplicate("x", 128 * 1024 + 1)
        ] do
      assert {:error, :unavailable} =
               Keychain.with_test_runner("get", attributes(), fn _ -> {:ok, output} end)
    end

    assert capture_log(fn ->
             assert {:error, :unavailable} =
                      Keychain.with_test_runner(
                        "put",
                        Map.put(attributes(), :value, "fake-secret"),
                        fn _ -> raise "fake-secret" end
                      )
           end) == ""
  end

  @tag timeout: 7_000
  test "deadline bounds injected hanging runner" do
    assert {:error, :timeout} =
             Keychain.with_test_runner("get", attributes(), fn _ -> Process.sleep(:infinity) end)
  end
end
