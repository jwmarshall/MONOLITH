defmodule Mix.Tasks.Lovelace.Owner.Setup do
  @shortdoc "Configure the one local LOVELACE owner password (no web signup)"
  @moduledoc "Terminal-only owner setup, resumable with the original password; never replaces an owner."
  use Mix.Task

  alias Lovelace.Owner.Actions
  alias Lovelace.Security.{Keychain, Vault}

  @impl true
  def run([]) do
    Mix.Task.run("app.config")

    if Vault.configuration_status() not in [:new, :setup_incomplete],
      do:
        Mix.raise(
          "Existing local storage will not be replaced. Use the explicit vault migration procedure."
        )

    configure()
  end

  def run(_), do: Mix.raise("Usage: mix lovelace.owner.setup (no password arguments)")

  defp configure do
    password = setup_password!()

    case Vault.start_maintenance() do
      {:ok, supervisor} ->
        try do
          configure_owner!(password)
        after
          Vault.lock()
          Supervisor.stop(supervisor)
        end

      _ ->
        Mix.raise(
          "Vault unavailable. Stop the server and check the native SQLCipher/helper prerequisites."
        )
    end
  end

  defp setup_password! do
    password = prompt("New local password (at least 12 characters): ")
    confirmation = prompt("Confirm password: ")

    unless Plug.Crypto.secure_compare(password, confirmation),
      do: Mix.raise("Passwords did not match; no owner was created.")

    unless String.length(password) in 12..1024 and byte_size(password) <= 1024,
      do: Mix.raise("Use 12–1024 characters and at most 1024 UTF-8 bytes.")

    password
  end

  defp configure_owner!(password) do
    unless Vault.configuration_status() in [:new, :setup_incomplete],
      do: Mix.raise("Storage changed; existing owner and files will not be replaced.")

    :ok = Keychain.begin_setup()

    case Vault.setup(password, fn -> Actions.configure_or_authenticate(password) end) do
      {:ok, _} ->
        {:ok, true} = Vault.lock()
        :ok = Keychain.finish_setup()

        Mix.shell().info(
          "LOVELACE owner and encrypted vault configured. Preserve your password; there is no recovery."
        )

      _ ->
        Mix.raise(
          "Setup incomplete; files preserved. Rerun this task with the same password; do not reset storage."
        )
    end
  end

  defp prompt(label) do
    unless :io.setopts(:standard_io, echo: false) == :ok,
      do: Mix.raise("A local terminal supporting hidden input is required.")

    try do
      case IO.gets(:stdio, label) do
        value when is_binary(value) ->
          String.trim_trailing(value, "\n") |> String.trim_trailing("\r")

        _ ->
          Mix.raise("Password input cancelled.")
      end
    after
      :io.setopts(:standard_io, echo: true)
      IO.puts("")
    end
  end
end
