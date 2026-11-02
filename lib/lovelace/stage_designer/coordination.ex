defmodule Lovelace.StageDesigner.Coordination do
  @moduledoc """
  Nonexpiring, cross-BEAM exclusion per trusted stage storage root.

  A private Exqlite NIF resource is retained by the calling process throughout
  the callback. No pool, timer, lease, monitor, or other process can revoke it.
  See docs/STORAGE_COORDINATION.md before changing ownership or file lifecycle.
  """

  require Logger

  alias Exqlite.Sqlite3
  alias Lovelace.Repo

  @filename ".stage-coordination.sqlite3"
  @busy_timeout 1_000
  @held_key {__MODULE__, :held}

  def with_lock(settings, fun) when is_function(fun, 0) do
    if Process.get(@held_key, false) or Repo.in_transaction?() do
      {:error, :nested_storage_transaction}
    else
      acquire(settings.storage_dir, fun)
    end
  rescue
    _ -> {:error, :coordination_error}
  end

  # Bootstrap only: trusted configuration supplies the root and this fixed file
  # is never unlinked/replaced. Root permissions protect initial file creation.
  # sobelow_skip ["Traversal.FileModule"]
  defp acquire(directory, fun) do
    path = Path.join(directory, @filename)

    with :ok <- File.mkdir_p(directory),
         :ok <- File.chmod(directory, 0o700),
         :ok <- create_file(path),
         {:ok, %{type: :regular}} <- File.lstat(path),
         :ok <- File.chmod(path, 0o600),
         {:ok, handle} <- Sqlite3.open(path, mode: :readwrite) do
      run_with_handle(handle, fun)
    else
      _ -> {:error, :coordination_error}
    end
  end

  # This is not an application schema: an empty SQLite file suffices for its
  # OS-backed writer lock. Never truncate an existing coordination file. The
  # caller constructs this exact filename under the trusted configured root.
  # sobelow_skip ["Traversal.FileModule"]
  defp create_file(path) do
    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, file} -> File.close(file)
      {:error, :eexist} -> :ok
      _ -> {:error, :coordination_error}
    end
  end

  defp run_with_handle(handle, fun) do
    with :ok <- Sqlite3.set_busy_timeout(handle, @busy_timeout),
         :ok <- Sqlite3.execute(handle, "BEGIN EXCLUSIVE") do
      Process.put(@held_key, true)
      result = fun.()

      case Sqlite3.execute(handle, "ROLLBACK") do
        :ok -> result
        _ -> {:error, :coordination_error}
      end
    else
      _ -> {:error, :coordination_error}
    end
  after
    Process.delete(@held_key)

    # Keep handle live until ALL callback work has finished. Even a main Repo
    # timeout/disconnect cannot release this independent resource's lock.
    case Sqlite3.close(handle) do
      :ok -> :ok
      _ -> Logger.warning("LOVELACE stage storage coordination close failed; no retry")
    end
  end
end
