defmodule Mix.Tasks.Lovelace.Developer.Setup do
  @shortdoc "Verify SQLCipher and prepare the local native helper without initializing storage"
  @moduledoc """
  Run through `bin/lovelace setup`. That alias first fetches
  dependencies and discards cached Exqlite builds, including ordinary-SQLite
  builds, before compiling the binding against the installed SQLCipher library.

  This task compiles project code, verifies the actual Exqlite binding using an
  in-memory database, and builds the macOS helper only if it is absent. It does
  not load runtime configuration, start LOVELACE, create or migrate application
  storage, run the helper, access a keychain, or initialize an owner. Existing
  storage migration remains the separate `lovelace.vault.migrate` operation.
  """
  use Mix.Task

  alias Lovelace.Security.Database
  alias Mix.Tasks.Lovelace.Keychain.Build

  @requirements ["compile"]

  @impl Mix.Task
  def run([]) do
    unless :os.type() == {:unix, :darwin}, do: Mix.raise("Developer setup requires macOS")

    unless Database.available?() do
      Mix.raise("""
      Exqlite is not bound to SQLCipher 4.20.0. Ordinary SQLite is not supported.
      Install SQLCipher 4.20.0 and pkg-config, then rerun:
        bin/lovelace setup
      This check uses only an in-memory database; no application storage was initialized.
      """)
    end

    Mix.shell().info("Verified Exqlite binding to SQLCipher 4.20.0")
    Build.run(["--if-missing"])

    Mix.shell().info(
      "Developer prerequisites ready; no database, owner, or keychain was initialized"
    )
  end

  def run(_), do: Mix.raise("Usage: bin/lovelace mix lovelace.developer.setup")
end
