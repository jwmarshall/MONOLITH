defmodule Lovelace.Security.KeychainHelperIOTest do
  use ExUnit.Case, async: false

  alias Lovelace.Security.Keychain

  @moduletag skip:
               not match?({:unix, :darwin}, :os.type()) or is_nil(System.find_executable("xcrun"))
  @moduletag timeout: 120_000
  @database "5bbed47a-8e42-4b3e-a2e8-f81beb0738d5"
  @gmail "01234567-89ab-cdef-0123-456789abcdef"
  @other_gmail "11234567-89ab-cdef-0123-456789abcdef"
  @gemini "b26d050a-0729-4d79-a6bc-407cf660a7ea"
  @oauth "710dd510-61ed-4e6a-975c-78ce13f5d6e2"

  setup_all do
    directory = Path.join(System.tmp_dir!(), "lovelace-helper-io-#{Ash.UUID.generate()}")
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    executable = Path.join(directory, "vault-test-helper")
    source = Path.expand("../../../priv/native/keychain.swift", __DIR__)

    migration_executable = Path.join(directory, "vault-migration-test-helper")
    acl_executable = Path.join(directory, "legacy-acl-owner")
    acl_source = Path.expand("../../support/keychain_legacy_acl_fixture.swift", __DIR__)

    # Both helpers compile out the real login-keychain path. Only the second
    # enables the shared migration algorithm against root/legacy.
    for {input, output, flags} <- [
          {source, executable, ["-DLOVELACE_TEST"]},
          {source, migration_executable, ["-DLOVELACE_TEST", "-DLOVELACE_TEST_MIGRATION"]},
          {acl_source, acl_executable, []}
        ] do
      {_output, status} =
        System.cmd(
          "xcrun",
          ["swiftc"] ++ flags ++ ["-O", "-framework", "Security", input, "-o", output],
          stderr_to_stdout: true
        )

      assert status == 0
    end

    {:ok,
     executable: executable,
     migration_executable: migration_executable,
     acl_executable: acl_executable,
     root: directory}
  end

  test "short newline frames are processed while stdin remains open, before keychain access",
       context do
    for input <- ["{\"operation\":\"invalid\",\"account\":\"not-a-uuid\"}\n", "not-json\n"] do
      assert invoke(context.executable, input) == %{"version" => 1, "error" => "unavailable"}
    end
  end

  test "old protocol and malformed identities cannot create a vault", context do
    root = Path.join(context.root, "invalid")

    for request <- [
          %{operation: "create", directory: root, password: "synthetic"},
          %{version: 0, operation: "vault_create", directory: root, password: "synthetic"},
          %{
            version: 1,
            operation: "vault_get",
            directory: root,
            account: "not-a-uuid",
            service: "LOVELACE Gmail"
          }
        ] do
      assert %{"error" => _} = invoke(context.executable, Jason.encode!(request) <> "\n")
      refute File.exists?(root)
    end
  end

  @tag attended_keychain: true, timeout: 180_000
  test "dedicated synthetic vault preserves independent random database key through ten cycles",
       context do
    root = Path.join(context.root, "synthetic")

    call = fn operation, attributes ->
      request(context.executable, root, operation, attributes)
    end

    on_exit(fn -> call.("lock", %{}) end)
    assert %{"status" => "missing"} = call.("status", %{})
    assert %{"ok" => true} = call.("lock", %{})

    assert %{"error" => "unavailable"} =
             call.("create", %{
               password: "synthetic diagnostic password",
               interrupt_before_marker: true
             })

    refute File.exists?(Path.join(root, ".keychain-pending"))

    assert %{"error" => "unavailable"} =
             call.("create", %{
               password: "synthetic diagnostic password",
               interrupt_after_create: true
             })

    assert File.regular?(Path.join(root, ".keychain-pending"))
    refute File.exists?(Path.join(root, "lovelace.keychain-db"))

    assert %{"ok" => true} =
             call.("create", %{password: "synthetic diagnostic password", setup_interaction: true})

    refute File.exists?(Path.join(root, ".keychain-pending"))
    assert %{"error" => "exists"} = call.("create", %{password: "different synthetic password"})
    assert Bitwise.band(File.stat!(root).mode, 0o077) == 0
    assert Bitwise.band(File.stat!(Path.join(root, "lovelace.keychain-db")).mode, 0o077) == 0

    database = %{account: @database, service: "LOVELACE Database"}
    assert %{"value" => key} = call.("get", database)
    assert key =~ ~r/\A[0-9a-f]{64}\z/
    # A crash after publication but before journal completion must preserve the key
    # and authenticate the original password, never generate a replacement.
    File.write!(Path.join(root, ".keychain-pending"), "LOVELACE keychain creation v1\n")
    File.chmod!(Path.join(root, ".keychain-pending"), 0o600)
    assert %{"error" => "locked"} = call.("create", %{password: "incorrect"})
    assert %{"ok" => true} = call.("create", %{password: "synthetic diagnostic password"})
    assert %{"value" => ^key} = call.("get", database)
    assert %{"error" => "unavailable"} = call.("put", Map.put(database, :value, "replacement"))
    assert %{"error" => "unavailable"} = call.("delete", database)

    identities = [
      %{account: "01234567-89ab-cdef-0123-456789abcdef", service: "LOVELACE Gmail"},
      %{account: "b26d050a-0729-4d79-a6bc-407cf660a7ea", service: "LOVELACE Gemini"},
      %{account: "710dd510-61ed-4e6a-975c-78ce13f5d6e2", service: "LOVELACE Google OAuth"}
    ]

    for identity <- identities do
      assert %{"ok" => true} = call.("put", Map.put(identity, :value, "synthetic value"))
    end

    encrypted = File.read!(Path.join(root, "lovelace.keychain-db"))

    for secret <- [key, "synthetic diagnostic password", "synthetic value"] do
      refute encrypted =~ secret
    end

    # Migration paths are compiled out even with valid framing and an open vault.
    for operation <- ["copy_legacy", "delete_legacy"],
        attributes <- [%{accounts: []}, %{accounts: [], migration_interaction: true}] do
      assert %{"version" => 1, "error" => "unavailable"} == call.(operation, attributes)
    end

    for _ <- 1..10 do
      assert %{"ok" => true} = call.("lock", %{})
      assert %{"status" => "locked"} = call.("status", %{})
      assert %{"error" => "locked"} = call.("get", database)
      assert %{"error" => "locked"} = call.("unlock", %{password: "wrong synthetic password"})
      assert %{"status" => "locked"} = call.("status", %{})
      assert %{"ok" => true} = call.("unlock", %{password: "synthetic diagnostic password"})
      assert %{"status" => "unlocked"} = call.("status", %{})
      assert %{"value" => ^key} = call.("get", database)
    end

    for identity <- identities do
      assert %{"value" => "synthetic value"} = call.("get", identity)
      assert %{"ok" => true} = call.("put", Map.put(identity, :value, "updated synthetic value"))
      assert %{"value" => "updated synthetic value"} = call.("get", identity)
      assert %{"ok" => true} = call.("delete", identity)
      assert %{"ok" => true} = call.("delete", identity)
      assert %{"error" => "not_found"} = call.("get", identity)
    end

    assert %{"ok" => true} = call.("lock", %{})
  end

  @tag attended_keychain: true, timeout: 180_000
  test "synthetic migration preflights conflicts, resumes idempotently and deletes only matching originals",
       context do
    {destination, source} = migration_fixture(context, "migration.vault")
    root = Path.join(context.root, "migration.vault")
    identities = migration_identities()
    accounts = %{accounts: [@gmail], migration_interaction: true}
    database = %{account: @database, service: "LOVELACE Database"}
    assert %{"value" => destination_key} = destination.("get", database)

    assert %{"value" => ^destination_key} =
             destination.("get", Map.put(database, :migration_interaction, true))

    assert %{"value" => source_key} = source.("get", database)
    refute source_key == destination_key

    for identity <- identities do
      assert %{"ok" => true} = source.("put", Map.put(identity, :value, "synthetic original"))
    end

    unselected = %{account: @other_gmail, service: "LOVELACE Gmail"}
    assert %{"ok" => true} = source.("put", Map.put(unselected, :value, "synthetic unselected"))
    oauth = List.last(identities)
    assert %{"ok" => true} = destination.("put", Map.put(oauth, :value, "synthetic conflict"))

    assert {:error, :conflict} ==
             wrapper_request(context.migration_executable, root, "copy_legacy", accounts)

    for identity <- identities do
      assert %{"value" => "synthetic original"} = source.("get", identity)
    end

    for identity <- Enum.drop(identities, -1) do
      assert %{"error" => "not_found"} = destination.("get", identity)
    end

    assert %{"value" => "synthetic conflict"} = destination.("get", oauth)
    assert %{"ok" => true} = destination.("delete", oauth)

    for _ <- 1..2 do
      assert :ok == wrapper_request(context.migration_executable, root, "copy_legacy", accounts)

      for identity <- identities do
        assert %{"value" => "synthetic original"} = destination.("get", identity)
        assert %{"value" => "synthetic original"} = source.("get", identity)
      end
    end

    assert %{"error" => "not_found"} = destination.("get", unselected)
    gmail = hd(identities)
    assert %{"ok" => true} = destination.("delete", gmail)
    assert %{"version" => 1, "error" => "conflict"} == destination.("delete_legacy", accounts)
    assert %{"ok" => true} = destination.("put", Map.put(gmail, :value, "synthetic original"))
    assert %{"ok" => true} = destination.("put", Map.put(oauth, :value, "synthetic changed"))
    assert %{"version" => 1, "error" => "conflict"} == destination.("delete_legacy", accounts)

    for identity <- identities do
      assert %{"value" => "synthetic original"} = source.("get", identity)
    end

    assert %{"value" => "synthetic changed"} = destination.("get", oauth)
    assert %{"ok" => true} = destination.("put", Map.put(oauth, :value, "synthetic original"))

    for _ <- 1..2 do
      assert %{"ok" => true} = destination.("delete_legacy", accounts)
    end

    for identity <- identities do
      assert %{"error" => "not_found"} = source.("get", identity)
      assert %{"value" => "synthetic original"} = destination.("get", identity)
    end

    assert %{"value" => "synthetic unselected"} = source.("get", unselected)
    assert %{"value" => ^source_key} = source.("get", database)
    assert %{"value" => ^destination_key} = destination.("get", database)
  end

  @tag attended_keychain: true, timeout: 180_000
  test "source failure categories preserve both vaults and remain distinct from destination locking",
       context do
    {destination, source} = migration_fixture(context, "migration-failures")
    identities = migration_identities()

    for identity <- identities do
      assert %{"ok" => true} = source.("put", Map.put(identity, :value, "synthetic original"))
    end

    assert %{"ok" => true} = source.("lock", %{})

    assert %{"version" => 1, "error" => "legacy_locked"} ==
             destination.("copy_legacy", %{accounts: [@gmail], migration_interaction: true})

    assert %{"ok" => true} = source.("unlock", %{password: "synthetic diagnostic password"})

    for operation <- ["copy_legacy", "delete_legacy"],
        {failure, category} <- [
          {"authorization", "legacy_authorization_required"},
          {"denied", "legacy_access_denied"},
          {"cancelled", "legacy_access_denied"},
          {"unavailable", "legacy_unavailable"}
        ] do
      # Inject only the Security status at the last source read, after earlier
      # real source reads. The shared preflight/mutation algorithm is unchanged.
      assert %{"version" => 1, "error" => category} ==
               destination.(operation, %{
                 accounts: [@gmail],
                 migration_interaction: true,
                 legacy_failure_account: @oauth,
                 legacy_failure: failure
               })

      for identity <- identities do
        assert %{"value" => "synthetic original"} = source.("get", identity)
        assert %{"error" => "not_found"} = destination.("get", identity)
      end
    end

    assert %{"ok" => true} = destination.("lock", %{})

    assert %{"version" => 1, "error" => "locked"} ==
             destination.("copy_legacy", %{accounts: [@gmail], migration_interaction: true})
  end

  @tag attended_keychain: true, timeout: 180_000
  test "real synthetic source ACL denial preflights before copying and ordinary flags cannot authorize Gmail",
       context do
    {destination, source} = migration_fixture(context, "migration-acl")
    root = Path.join(context.root, "migration-acl")
    first = %{account: @gmail, service: "LOVELACE Gmail"}
    restricted = %{account: @other_gmail, service: "LOVELACE Gmail"}
    assert %{"ok" => true} = source.("put", Map.put(first, :value, "synthetic readable"))

    owner = fn operation ->
      invoke(
        context.acl_executable,
        Jason.encode!(%{directory: root, operation: operation, value: "synthetic ACL original"}) <>
          "\n",
        35_000
      )
    end

    assert %{"ok" => true} = owner.("add")

    for flags <- [%{}, %{setup_interaction: true}] do
      assert %{"version" => 1, "error" => category} =
               destination.("copy_legacy", Map.merge(flags, %{accounts: [@gmail, @other_gmail]}))

      # macOS can report either interaction-not-allowed or authentication failure
      # for an unapproved application; both must stay source-scoped and fail closed.
      assert category in ["legacy_authorization_required", "legacy_access_denied"]

      assert %{"error" => "not_found"} = destination.("get", first)
      assert %{"error" => "not_found"} = destination.("get", restricted)
      assert %{"value" => "synthetic readable"} = source.("get", first)
      assert %{"ok" => true} = owner.("verify")
    end

    for operation <- ["get", "put", "delete"] do
      assert %{"version" => 1, "error" => "locked"} ==
               source.(
                 operation,
                 Map.merge(restricted, %{
                   migration_interaction: true,
                   setup_interaction: true,
                   value: "synthetic replacement"
                 })
               )

      assert %{"ok" => true} = owner.("verify")
    end
  end

  @tag attended_keychain: true, timeout: 180_000
  test "destination item ACL denial remains a destination error before any credential is copied",
       context do
    {destination, source} = migration_fixture(context, "migration-destination-acl")
    root = Path.join(context.root, "migration-destination-acl")
    first = %{account: @gmail, service: "LOVELACE Gmail"}
    restricted = %{account: @other_gmail, service: "LOVELACE Gmail"}

    for identity <- [first, restricted] do
      assert %{"ok" => true} = source.("put", Map.put(identity, :value, "synthetic ACL original"))
    end

    owner = fn operation ->
      invoke(
        context.acl_executable,
        Jason.encode!(%{
          directory: root,
          target: "destination",
          operation: operation,
          value: "synthetic ACL original"
        }) <> "\n",
        35_000
      )
    end

    assert %{"ok" => true} = owner.("add")

    assert %{"version" => 1, "error" => "locked"} ==
             destination.("copy_legacy", %{accounts: [@gmail, @other_gmail]})

    assert %{"error" => "not_found"} = destination.("get", first)
    assert %{"ok" => true} = owner.("verify")

    for identity <- [first, restricted] do
      assert %{"value" => "synthetic ACL original"} = source.("get", identity)
    end
  end

  @tag attended_keychain: true,
       authorization_smoke: true,
       database_authorization_smoke: true,
       skip: System.get_env("LOVELACE_KEYCHAIN_AUTHORIZATION_SMOKE") != "1",
       timeout: 360_000
  test "explicit attended Database ACL approval preserves the existing key for ordinary runtime reads",
       context do
    root = Path.join(context.root, "migration-database-acl")
    database = %{account: @database, service: "LOVELACE Database"}

    previous = fn operation, attributes ->
      request(context.executable, root, operation, attributes)
    end

    destination = fn operation, attributes ->
      request(context.migration_executable, root, operation, attributes)
    end

    on_exit(fn -> destination.("lock", %{}) end)

    # The candidate has never created or read this item: model a helper upgrade,
    # not an ACL edit after the candidate has already been authorized as creator.
    assert %{"ok" => true} =
             previous.("create", %{
               password: "synthetic diagnostic password",
               setup_interaction: true
             })

    assert %{"value" => original} = previous.("get", database)
    assert %{"version" => 1, "error" => "locked"} == destination.("get", database)
    # Choose Always Allow for the replacement helper; transient Allow must not
    # count as successful runtime cutover.
    assert %{"value" => ^original} =
             destination.("get", Map.put(database, :migration_interaction, true))

    assert %{"value" => ^original} = destination.("get", database)
    assert %{"value" => ^original} = previous.("get", database)
  end

  @tag attended_keychain: true,
       authorization_smoke: true,
       skip: System.get_env("LOVELACE_KEYCHAIN_AUTHORIZATION_SMOKE") != "1",
       timeout: 180_000
  test "explicit attended source ACL approval copies the selected original without deleting it",
       context do
    {destination, _source} = migration_fixture(context, "migration-source-approval")
    root = Path.join(context.root, "migration-source-approval")
    restricted = %{account: @other_gmail, service: "LOVELACE Gmail"}

    owner = fn operation ->
      invoke(
        context.acl_executable,
        Jason.encode!(%{
          directory: root,
          operation: operation,
          value: "synthetic ACL original"
        }) <> "\n",
        35_000
      )
    end

    assert %{"ok" => true} = owner.("add")
    # Explicit opt-in only: authorize vault-migration-test-helper at the macOS
    # LOVELACE Gmail item dialog using the synthetic diagnostic password.
    assert %{"ok" => true} =
             destination.("copy_legacy", %{
               accounts: [@other_gmail],
               migration_interaction: true
             })

    assert %{"value" => "synthetic ACL original"} = destination.("get", restricted)
    assert %{"ok" => true} = owner.("verify")
  end

  test "symlink roots and keychain leaves fail closed", context do
    target = Path.join(context.root, "target")
    File.mkdir!(target)
    File.chmod!(target, 0o700)
    link = Path.join(context.root, "link")
    File.ln_s!(target, link)
    assert %{"error" => "invalid_directory"} = request(context.executable, link, "status", %{})
    File.write!(Path.join(context.root, "ordinary"), "synthetic")
    File.ln_s!(Path.join(context.root, "ordinary"), Path.join(target, "lovelace.keychain-db"))
    assert %{"error" => "invalid_directory"} = request(context.executable, target, "status", %{})
  end

  defp migration_identities do
    [
      %{account: @gmail, service: "LOVELACE Gmail"},
      %{account: @gemini, service: "LOVELACE Gemini"},
      %{account: @oauth, service: "LOVELACE Google OAuth"}
    ]
  end

  defp migration_fixture(context, name) do
    root = Path.join(context.root, name)
    legacy = Path.join(root, "legacy")
    executable = context.migration_executable
    destination = fn operation, attributes -> request(executable, root, operation, attributes) end
    source = fn operation, attributes -> request(executable, legacy, operation, attributes) end

    on_exit(fn ->
      source.("lock", %{})
      destination.("lock", %{})
    end)

    for call <- [destination, source] do
      assert %{"ok" => true} =
               call.("create", %{
                 password: "synthetic diagnostic password",
                 setup_interaction: true
               })
    end

    {destination, source}
  end

  defp wrapper_request(executable, root, operation, attributes) do
    previous = Application.fetch_env!(:lovelace, Lovelace.Repo)
    database = String.replace_suffix(root, ".vault", "")
    Application.put_env(:lovelace, Lovelace.Repo, Keyword.put(previous, :database, database))

    try do
      Keychain.with_test_runner(operation, attributes, fn input ->
        {:ok, invoke_raw(executable, input, 125_000)}
      end)
    after
      Application.put_env(:lovelace, Lovelace.Repo, previous)
    end
  end

  defp request(executable, directory, operation, attributes) do
    attributes
    |> Map.merge(%{version: 1, directory: directory, operation: "vault_" <> operation})
    |> Jason.encode!()
    |> then(
      &invoke(
        executable,
        &1 <> "\n",
        if(attributes[:setup_interaction] || attributes[:migration_interaction],
          do: 125_000,
          else: 5_000
        )
      )
    )
  end

  defp invoke(executable, input, timeout \\ 5_000) do
    executable |> invoke_raw(input, timeout) |> Jason.decode!()
  end

  defp invoke_raw(executable, input, timeout) do
    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [:binary, :exit_status, :use_stdio, :stderr_to_stdout, args: []]
      )

    try do
      true = Port.command(port, input)
      collect(port, [], 0, System.monotonic_time(:millisecond) + timeout)
    after
      if Port.info(port), do: Port.close(port)
    end
  end

  defp collect(port, chunks, size, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^port, {:data, chunk}} when byte_size(chunk) + size <= 128 * 1024 ->
        collect(port, [chunk | chunks], size + byte_size(chunk), deadline)

      {^port, {:exit_status, 0}} ->
        chunks |> Enum.reverse() |> IO.iodata_to_binary()

      {^port, {:exit_status, status}} ->
        flunk("helper exited with status #{status} before returning its protocol response")

      {^port, _} ->
        flunk("invalid helper framing or exit status")
    after
      remaining -> flunk("helper did not process a short frame before the deadline")
    end
  end
end
