defmodule Wallace.Repo do
  use AshSqlite.Repo, otp_app: :wallace

  @impl AshSqlite.Repo
  def write_transactions?, do: true

  # AshSqlite's baseline; raise deliberately if a feature needs newer SQLite syntax.
  @impl AshSqlite.Repo
  def min_sqlite_version, do: %Version{major: 3, minor: 38, patch: 0}
end
