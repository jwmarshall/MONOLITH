defmodule Mix.Tasks.Lovelace.Owner.Setup do
  @shortdoc "Configure the one local LOVELACE owner password (no web signup)"
  @moduledoc "Initial setup only; refuses to replace an existing owner. Password is read without echo."
  use Mix.Task

  @impl true
  def run([]) do
    Mix.Task.run("compile")
    # Start only the persistence/authentication dependencies, not the web app or integrations.
    {:ok, _} = Application.ensure_all_started(:ash_sqlite)
    {:ok, _} = Application.ensure_all_started(:ash_authentication)
    start_repo()

    case Lovelace.Owner.configured() do
      {:ok, false} -> configure()
      {:ok, true} -> Mix.raise("Local owner is already configured; setup will not replace it.")
      _ -> Mix.raise("Local owner storage is unavailable. Run the owner migrations first.")
    end
  end

  def run(_), do: Mix.raise("Usage: mix lovelace.owner.setup (no password arguments)")

  defp start_repo do
    case Process.whereis(Lovelace.Repo) do
      nil ->
        case Lovelace.Repo.start_link() do
          {:ok, _} -> :ok
          _ -> Mix.raise("Local owner storage is unavailable.")
        end

      _ ->
        :ok
    end
  end

  defp configure do
    password = prompt("New local password (at least 12 characters): ")
    confirmation = prompt("Confirm password: ")

    unless Plug.Crypto.secure_compare(password, confirmation),
      do: Mix.raise("Passwords did not match; no owner was created.")

    case Lovelace.Owner.configure(password, actor: %{role: :owner_setup}) do
      {:ok, _} ->
        Mix.shell().info("LOVELACE local owner configured. Open /unlock in your browser.")

      _ ->
        Mix.raise("Unable to configure owner. Use 12–1024 characters; run migrations first.")
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
