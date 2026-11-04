defmodule Lovelace.Repo do
  use AshSqlite.Repo, otp_app: :lovelace
  alias Lovelace.Security.{CipherKey, Database}

  @impl Ecto.Repo
  def init(:runtime, config), do: {:ok, config}

  if Mix.env() == :test do
    @impl Ecto.Repo
    def init(_type, config) do
      if Database.managed?(), do: protected_config(config), else: {:ok, config}
    end
  else
    @impl Ecto.Repo
    def init(_type, config), do: protected_config(config)
  end

  defp protected_config(config) do
    unless match?(%CipherKey{}, config[:key]) do
      raise "Protected database requires vault unlock; stock Ecto tasks are unavailable"
    end

    if Database.migration_pending?() do
      raise "Vault migration is incomplete; resume mix lovelace.vault.migrate"
    end

    unless Database.available?() do
      raise "SQLCipher 4.20.0 is required; rebuild Exqlite with bin/lovelace setup"
    end

    {:ok,
     Keyword.merge(config,
       temp_store: :memory,
       secure_delete: :on,
       synchronous: :full,
       log: false,
       telemetry_event: nil,
       custom_pragmas: [cipher_plaintext_header_size: 0, cipher_memory_security: "ON"]
     )}
  end

  # Ecto query telemetry includes raw bound parameters AND returned rows. A mail
  # cache read is therefore sensitive too. Disable that payload-bearing channel
  # and SQL logging for this private Repo; keep higher-level numeric telemetry.
  if Mix.env() == :test do
    @impl Ecto.Repo
    def default_options(_operation) do
      # Explicit synthetic scenery interleavings use query-event barriers. This
      # process-local seam is absent from production and never enabled for mail.
      event = if Process.get(:lovelace_synthetic_sql_barriers), do: [:lovelace, :repo, :query]
      [log: false, telemetry_event: event]
    end
  else
    @impl Ecto.Repo
    def default_options(_operation), do: [log: false, telemetry_event: nil]
  end

  @impl AshSqlite.Repo
  def write_transactions?, do: true

  # AshSqlite's baseline; raise deliberately if a feature needs newer SQLite syntax.
  @impl AshSqlite.Repo
  def min_sqlite_version, do: %Version{major: 3, minor: 38, patch: 0}
end
