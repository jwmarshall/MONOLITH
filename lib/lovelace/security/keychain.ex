defmodule Lovelace.Security.Keychain do
  @moduledoc """
  Raw infrastructure access to LOVELACE's dedicated macOS file keychain.

  The root is derived only from trusted Repo application configuration, never
  `Repo.config/0` or HTTP input. The fixed helper uses explicit keychain references
  and does not change the user's default keychain/search list. macOS file-keychain
  APIs are deprecated; this deliberately does not fall back to login or Data
  Protection Keychain storage. Build with `mix lovelace.keychain.build`.

  Credential adapters must use `Vault.with_access/1`; this module is deliberately
  ungated because Vault needs it while opening. Passwords/values travel only over
  bounded stdin/stdout, never argv or temporary files. Native execution is disabled
  in test builds. Legacy access is restricted to explicit migration operations.
  """

  alias Lovelace.Security.Database

  @version 1
  @database_account "5bbed47a-8e42-4b3e-a2e8-f81beb0738d5"
  @gemini_account "b26d050a-0729-4d79-a6bc-407cf660a7ea"
  @oauth_account "710dd510-61ed-4e6a-975c-78ce13f5d6e2"
  @services [
    "LOVELACE Gmail",
    "LOVELACE GitHub",
    "LOVELACE Gemini",
    "LOVELACE Database",
    "LOVELACE Google OAuth"
  ]
  @max_value 16 * 1024
  @max_output 128 * 1024
  @timeout 5_000
  @errors [
    :not_found,
    :locked,
    :missing,
    :exists,
    :conflict,
    :unavailable,
    :legacy_locked,
    :legacy_authorization_required,
    :legacy_access_denied,
    :legacy_unavailable,
    :timeout,
    :invalid_account,
    :invalid_value,
    :invalid_password,
    :invalid_directory
  ]
  @operations ~w(create unlock lock status get put delete copy_legacy delete_legacy)

  def directory do
    database = Application.fetch_env!(:lovelace, Lovelace.Repo) |> Keyword.fetch!(:database)
    Path.expand(database <> ".vault")
  end

  def path, do: Path.join(directory(), "lovelace.keychain-db")
  def initializing?, do: pending?(".keychain-pending")
  def setup_pending?, do: pending?(".setup-pending")

  def begin_setup do
    with :ok <- Database.private_directory(directory()) do
      Database.create_private_file(Path.join(directory(), ".setup-pending"))
    end
  end

  # The task clears its own non-secret journal only after confirmed vault locking.
  # sobelow_skip ["Traversal.FileModule"]
  def finish_setup, do: File.rm(Path.join(directory(), ".setup-pending"))

  defp pending?(name), do: File.lstat(Path.join(directory(), name)) != {:error, :enoent}

  @doc "Checks the fixed file only; does not open the keychain or read any secret."
  def configured? do
    match?({:ok, %File.Stat{type: :regular}}, File.lstat(path()))
  rescue
    _ -> false
  end

  def create(password), do: operation("create", %{password: password, setup_interaction: true})
  def unlock(password), do: operation("unlock", %{password: password})
  def lock, do: operation("lock", %{})
  def status, do: operation("status", %{})

  def database_key, do: validate_database_key(get(@database_account, "LOVELACE Database"))

  @doc "Explicit terminal migration only: permits attended approval of the existing database-key item."
  def database_key_for_migration do
    operation("get", %{
      account: @database_account,
      service: "LOVELACE Database",
      migration_interaction: true
    })
    |> validate_database_key()
  end

  defp validate_database_key(result) do
    case result do
      {:ok, key} when byte_size(key) == 64 ->
        if Regex.match?(~r/\A[0-9a-f]{64}\z/, key), do: {:ok, key}, else: {:error, :unavailable}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :unavailable}
    end
  end

  def get(account, service), do: operation("get", %{account: account, service: service})

  def put(account, value, service),
    do: operation("put", %{account: account, value: value, service: service})

  def delete(account, service), do: operation("delete", %{account: account, service: service})

  @doc "Copies explicit Gmail UUIDs and optional singleton credentials; never overwrites conflicts."
  def copy_legacy(accounts),
    do: operation("copy_legacy", %{accounts: accounts, migration_interaction: true})

  @doc "Explicit migration cleanup only; deletes a legacy item only after matching its vault copy."
  def delete_legacy(accounts),
    do: operation("delete_legacy", %{accounts: accounts, migration_interaction: true})

  defp operation(operation, attributes),
    do: guarded(operation, attributes, &native(&1, timeout(operation, attributes)))

  if Mix.env() == :test do
    @doc false
    def with_test_runner(operation, attributes, runner) when is_function(runner, 1),
      do: guarded(operation, attributes, runner)
  end

  defp guarded(operation, attributes, runner) do
    with {:ok, attributes} <- validate(operation, attributes) do
      input =
        attributes
        |> Map.merge(%{
          version: @version,
          operation: "vault_" <> operation,
          directory: directory()
        })
        |> Jason.encode!()

      if byte_size(input) + 1 > @max_output do
        {:error, :invalid_value}
      else
        run(input <> "\n", operation, runner, timeout(operation, attributes))
      end
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp run(input, operation, runner, timeout) do
    # Catch inside the worker: a crash report must not contain captured secrets.
    task =
      Task.async(fn ->
        try do
          case runner.(input) do
            {:ok, output} when is_binary(output) and byte_size(output) <= @max_output ->
              decode(output, operation)

            {:error, reason} when reason in @errors ->
              {:error, reason}

            _ ->
              {:error, :unavailable}
          end
        rescue
          _ -> {:error, :unavailable}
        catch
          _, _ -> {:error, :unavailable}
        end
      end)

    case Task.yield(task, timeout) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, :timeout}
    end
  end

  defp validate(operation, %{password: password} = attributes)
       when operation in ["create", "unlock"] do
    if is_binary(password) and byte_size(password) in 1..4096 and String.valid?(password) do
      payload = %{password: password}

      {:ok,
       if(operation == "create",
         do:
           Map.put(
             payload,
             :setup_interaction,
             Map.get(attributes, :setup_interaction, false) == true
           ),
         else: payload
       )}
    else
      {:error, :invalid_password}
    end
  end

  defp validate(operation, attributes) when operation in ["get", "put", "delete"] do
    with %{account: account, service: service} <- attributes,
         :ok <- valid_identity(account, service),
         :ok <- writable(operation, service),
         :ok <- valid_value(operation, Map.get(attributes, :value)) do
      payload = %{account: String.downcase(account), service: service}

      payload =
        if operation == "get" and service == "LOVELACE Database",
          do:
            Map.put(payload, :migration_interaction, attributes[:migration_interaction] == true),
          else: payload

      {:ok, if(operation == "put", do: Map.put(payload, :value, attributes.value), else: payload)}
    else
      {:error, _} = error -> error
      _ -> {:error, :unavailable}
    end
  end

  defp validate(operation, %{accounts: accounts} = attributes)
       when operation in ["copy_legacy", "delete_legacy"] do
    if is_list(accounts) and length(accounts) <= 512 and Enum.all?(accounts, &valid_uuid?/1) do
      {:ok,
       %{
         accounts: accounts |> Enum.map(&String.downcase/1) |> Enum.uniq() |> Enum.sort(),
         migration_interaction: Map.get(attributes, :migration_interaction, false) == true
       }}
    else
      {:error, :invalid_account}
    end
  end

  defp validate(operation, %{}) when operation in ["lock", "status"], do: {:ok, %{}}
  defp validate(operation, _) when operation in @operations, do: {:error, :invalid_value}
  defp validate(_, _), do: {:error, :unavailable}

  defp valid_identity(account, service) when service in @services do
    if valid_uuid?(account) do
      valid_service_identity(account, service)
    else
      {:error, :invalid_account}
    end
  end

  defp valid_identity(_, _), do: {:error, :unavailable}

  defp valid_service_identity(account, service) do
    cond do
      service in ["LOVELACE Gmail", "LOVELACE GitHub"] -> :ok
      service == "LOVELACE Gemini" and String.downcase(account) == @gemini_account -> :ok
      service == "LOVELACE Database" and String.downcase(account) == @database_account -> :ok
      service == "LOVELACE Google OAuth" and String.downcase(account) == @oauth_account -> :ok
      true -> {:error, :invalid_account}
    end
  end

  defp valid_uuid?(account) when is_binary(account),
    do:
      Regex.match?(
        ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/,
        account
      )

  defp valid_uuid?(_), do: false

  defp writable(operation, "LOVELACE Database") when operation != "get",
    do: {:error, :unavailable}

  defp writable(_, _), do: :ok

  defp valid_value("put", value) when is_binary(value) and byte_size(value) in 1..@max_value do
    if String.valid?(value), do: :ok, else: {:error, :invalid_value}
  end

  defp valid_value(operation, nil) when operation in ["get", "delete"], do: :ok
  defp valid_value(_, _), do: {:error, :invalid_value}

  defp decode(output, operation) do
    with [line, ""] <- String.split(output, "\n"),
         {:ok, %{"version" => @version} = result} <- Jason.decode(line) do
      decode_result(result, operation)
    else
      _ -> {:error, :unavailable}
    end
  end

  defp decode_result(%{"ok" => true, "value" => value}, "get") do
    if valid_value("put", value) == :ok, do: {:ok, value}, else: {:error, :unavailable}
  end

  defp decode_result(%{"ok" => true, "status" => "missing"}, "status"), do: {:ok, :missing}
  defp decode_result(%{"ok" => true, "status" => "locked"}, "status"), do: {:ok, :locked}
  defp decode_result(%{"ok" => true, "status" => "unlocked"}, "status"), do: {:ok, :unlocked}

  defp decode_result(%{"ok" => true}, operation)
       when operation in @operations and operation not in ["get", "status"], do: :ok

  defp decode_result(%{"error" => reason}, _) when is_binary(reason) do
    case Enum.find(@errors, &(Atom.to_string(&1) == reason)) do
      nil -> {:error, :unavailable}
      safe -> {:error, safe}
    end
  end

  defp decode_result(_, _), do: {:error, :unavailable}
  defp timeout("get", %{service: "LOVELACE Database", migration_interaction: true}), do: 125_000

  defp timeout(operation, _) when operation in ["create", "copy_legacy", "delete_legacy"],
    do: 125_000

  defp timeout(_, _), do: @timeout

  if Mix.env() == :test do
    defp native(_, _timeout), do: {:error, :unavailable}
  else
    defp native(input, timeout) do
      executable = Application.app_dir(:lovelace, "priv/native/lovelace-vault")

      if :os.type() == {:unix, :darwin} and File.regular?(executable) do
        port =
          Port.open(
            {:spawn_executable, String.to_charlist(executable)},
            [:binary, :exit_status, :use_stdio, :stderr_to_stdout, :hide, args: []]
          )

        try do
          true = Port.command(port, input)
          collect(port, [], 0, System.monotonic_time(:millisecond) + timeout - 100)
        after
          if Port.info(port), do: Port.close(port)
        end
      else
        {:error, :unavailable}
      end
    end

    defp collect(port, chunks, size, deadline) do
      remaining = max(0, deadline - System.monotonic_time(:millisecond))

      receive do
        {^port, {:data, data}} when byte_size(data) + size <= @max_output ->
          collect(port, [data | chunks], size + byte_size(data), deadline)

        {^port, {:data, _}} ->
          {:error, :unavailable}

        {^port, {:exit_status, 124}} ->
          {:error, :timeout}

        {^port, {:exit_status, 0}} ->
          {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

        {^port, {:exit_status, _}} ->
          {:error, :unavailable}
      after
        remaining -> {:error, :timeout}
      end
    end
  end
end
