defmodule Mix.Tasks.Monolith.Google.Configure do
  @shortdoc "Store Google OAuth client credentials in the local MONOLITH vault"
  @moduledoc "Terminal-only configuration. No credential arguments or provider requests."
  use Mix.Task

  alias Monolith.Integrations.Google.ClientCredentials
  alias Monolith.Security.Vault

  @impl true
  def run([]) do
    Mix.Task.run("app.config")
    password = prompt("Local owner password: ")

    case Vault.start_maintenance() do
      {:ok, supervisor} ->
        try do
          configure(password)
        after
          try do
            Vault.lock()
          after
            Supervisor.stop(supervisor)
          end
        end

      _ ->
        Mix.raise(
          "Local vault unavailable. Stop the server before configuring Google credentials."
        )
    end
  end

  def run(_), do: Mix.raise("Usage: mix monolith.google.configure (no credential arguments)")

  defp configure(password) do
    case Monolith.Owner.unlock_for_maintenance(password, actor: %{role: :owner_setup}) do
      {:ok, _token} ->
        client_id = prompt("Google OAuth client ID: ")
        client_secret = prompt("Google OAuth client secret: ")

        case ClientCredentials.save(client_id, client_secret) do
          :ok ->
            Mix.shell().info(
              "Google OAuth client credentials stored locally. Vault locked on exit."
            )

          _ ->
            Mix.raise(
              "Unable to store Google credentials. Supply nonempty, bounded values without whitespace."
            )
        end

      _ ->
        Mix.raise("Unable to unlock the local owner vault.")
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
          Mix.raise("Credential input cancelled.")
      end
    after
      :io.setopts(:standard_io, echo: true)
      IO.puts("")
    end
  end
end
