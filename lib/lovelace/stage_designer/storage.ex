defmodule Lovelace.StageDesigner.Storage do
  @moduledoc "Content-addressed local PNG/JPEG storage with bounded image reads and orphan cleanup."

  require Logger
  alias Lovelace.Repo
  alias Lovelace.StageDesigner
  alias Lovelace.StageDesigner.{Attempt, Coordination, Image, Scene}

  @actor %{role: :stage_designer}

  @max_bytes 10 * 1024 * 1024
  @digest ~r/\A[0-9a-f]{64}\z/

  def url(digest, format \\ :png) do
    extension = Image.extension(format)

    if valid_digest?(digest) and extension,
      do: "/stage/background/#{digest}.#{extension}",
      else: nil
  end

  def read(settings, digest) do
    if valid_digest?(digest) do
      Enum.find_value(
        ["png", "jpg"],
        {:error, :unavailable_image},
        &available_file(settings, digest, &1)
      )
    else
      {:error, :unavailable_image}
    end
  end

  defp available_file(settings, digest, extension) do
    case read_file(settings, digest, extension) do
      {:ok, bytes} -> {:ok, bytes}
      _ -> nil
    end
  end

  # Reviewed Sobelow false positive: the root is privileged local configuration;
  # read/2 admits only 64 lowercase hex characters and fixed png/jpg extensions.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_file(settings, digest, extension) do
    path = Path.join(settings.storage_dir, digest <> "." <> extension)

    with {:ok, %{type: :regular, size: size}} when size <= @max_bytes <- File.lstat(path),
         {:ok, bytes} when byte_size(bytes) <= @max_bytes <- read_bounded(path),
         true <- hash(bytes) == digest,
         true <- Image.extension(Image.format(bytes)) == extension,
         :ok <- Image.validate(bytes) do
      {:ok, bytes}
    else
      _ -> {:error, :unavailable_image}
    end
  end

  def select(settings, digest) do
    Coordination.with_lock(settings, fn ->
      with {:ok, state} when not is_nil(state) <- StageDesigner.get_state(1, actor: @actor),
           {:ok, true} <- Scene.registered(digest),
           {:ok, _bytes} <- read(settings, digest),
           {:ok, _state} <-
             StageDesigner.select_state_scene(state, %{selected_digest: digest}, actor: @actor) do
        {:ok, :selected}
      else
        _ -> {:error, :unavailable_scene}
      end
    end)
  end

  # Older manifests know only their most recent successful timestamp. Do not
  # fabricate dates for the rest of their history.
  def scene_dates(state) do
    case {state.history, state.generated_at} do
      {[latest | _], %DateTime{} = date} ->
        Map.put_new(state.scene_dates, latest, DateTime.to_iso8601(date))

      _ ->
        state.scene_dates
    end
  end

  def store(settings, bytes) do
    case Coordination.with_lock(settings, fn -> store_locked(settings, bytes) end) do
      {:ok, digest} -> {:ok, digest}
      {:error, _} -> {:error, :storage_error}
    end
  end

  # Store and publish without exposing an unprotected in-flight file. No deletion
  # is allowed here: rollback could restore a manifest referring to older files.
  def store_and_publish(settings, bytes, reserved, now) do
    result =
      Coordination.with_lock(settings, fn ->
        publish_transaction(settings, bytes, reserved, now)
      end)

    case result do
      {:ok, published} -> {:ok, published}
      {:error, {stage, reason}} -> {:error, {stage, reason}}
      {:error, _} -> {:error, {:storage, :storage_error}}
    end
  end

  def store_and_publish_attempt(settings, bytes, attempt, now) do
    result =
      Coordination.with_lock(settings, fn ->
        Repo.transaction(fn -> publish_attempt_transaction(settings, bytes, attempt, now) end)
      end)

    case result do
      {:ok, completed} -> {:ok, completed}
      {:error, :stale_attempt} -> {:error, :stale_attempt}
      {:error, {stage, reason}} -> {:error, {stage, reason}}
      _ -> {:error, {:storage, :storage_error}}
    end
  end

  defp publish_attempt_transaction(settings, bytes, attempt, now) do
    with {:ok, %Attempt{} = fresh} <- Attempt.get(attempt.id),
         true <- fresh.status == :rendering,
         {:ok, current} when not is_nil(current) <- StageDesigner.get_state(1, actor: @actor),
         true <-
           current.active_attempt_id == fresh.id and
             current.version == fresh.reservation_version and current.status == :generating,
         {:ok, published} <- publish_locked(settings, bytes, current, now),
         {:ok, completed} <-
           Attempt.record(fresh, %{
             status: :completed,
             completed_at: now,
             last_checked_at: now,
             digest: published.selected_digest,
             cleanup: :pending,
             failure: nil
           }) do
      completed
    else
      false -> Repo.rollback(:stale_attempt)
      {:error, {stage, reason}} -> Repo.rollback({stage, reason})
      _ -> Repo.rollback({:publication, :publication_error})
    end
  end

  defp publish_transaction(settings, bytes, reserved, now) do
    Repo.transaction(fn ->
      with {:ok, current} when not is_nil(current) <- StageDesigner.get_state(1, actor: @actor),
           true <- current.version == reserved.version and current.status == :generating,
           # Selection does not bump the reservation version. Use the current
           # record so Ash doesn't suppress a digest equal to the old baseline.
           {:ok, published} <- publish_locked(settings, bytes, current, now) do
        published
      else
        {:error, {stage, reason}} -> Repo.rollback({stage, reason})
        _ -> Repo.rollback({:publication, :publication_error})
      end
    end)
  end

  defp publish_locked(settings, bytes, reserved, now) do
    case store_locked(settings, bytes) do
      {:ok, digest} ->
        # Seven recent fallback candidates bound background work, not stored scenes.
        history = Enum.take(Enum.uniq([digest | reserved.history]), 7)

        dates =
          reserved
          |> scene_dates()
          |> Map.put(digest, DateTime.to_iso8601(now))
          |> Map.take(history)

        case Scene.publish(digest, now) do
          {:ok, _scene} -> publish_manifest(reserved, digest, history, dates, now)
          _ -> {:error, {:publication, :publication_error}}
        end

      {:error, _} ->
        {:error, {:storage, :storage_error}}
    end
  end

  defp publish_manifest(reserved, digest, history, dates, now) do
    case StageDesigner.publish_state(
           reserved,
           %{history: history, generated_at: now, selected_digest: digest, scene_dates: dates},
           actor: @actor
         ) do
      {:ok, published} -> {:ok, published}
      {:error, _} -> {:error, {:publication, :publication_error}}
    end
  end

  # Only the local configuration selects the root; filenames are content hashes.
  # sobelow_skip ["Traversal.FileModule"]
  defp store_locked(settings, bytes) do
    with :ok <- Image.validate(bytes),
         :ok <- File.mkdir_p(settings.storage_dir),
         :ok <- File.chmod(settings.storage_dir, 0o700) do
      digest = hash(bytes)
      write_image(settings.storage_dir, digest, Image.extension(Image.format(bytes)), bytes)
    else
      _ -> {:error, :storage_error}
    end
  end

  # Compatibility arguments are not authority. Always reread under a fresh writer
  # lock, after the publication transaction has committed.
  def prune(settings, _retained),
    do: authoritative_cleanup(settings, System.system_time(:second) - 300)

  # Keep five minutes of orphan/temp grace for interrupted or standalone stores.
  def reconcile(settings, _retained, now), do: authoritative_cleanup(settings, now - 300)

  defp authoritative_cleanup(settings, cutoff) do
    Coordination.with_lock(settings, fn ->
      case StageDesigner.get_state(1, actor: @actor) do
        {:ok, state} when not is_nil(state) -> cleanup(settings, cutoff)
        _ -> {:error, :manifest_unavailable}
      end
    end)
  end

  defp cleanup(settings, cutoff) do
    case File.ls(settings.storage_dir) do
      {:ok, names} ->
        prune_files(settings, names, cutoff)

      {:error, :enoent} ->
        :ok

      {:error, _} ->
        {:error, :cleanup_error}
    end
  end

  defp prune_files(settings, names, cutoff) do
    Enum.reduce_while(names, :ok, fn name, :ok ->
      case prune_file(settings, name, cutoff) do
        :ok -> {:cont, :ok}
        {:error, _} -> {:halt, {:error, :cleanup_error}}
      end
    end)
  end

  # Only exact generated digest/UUID filenames under the configured root are removable.
  defp prune_file(settings, name, cutoff) do
    digest = Path.rootname(name)

    generated? =
      Path.extname(name) in [".png", ".jpg"] and valid_digest?(digest)

    temporary? = not is_nil(cutoff) and Regex.match?(~r/\A\.stage-[0-9a-f-]{36}\.tmp\z/, name)
    path = Path.join(settings.storage_dir, name)

    cond do
      generated? ->
        # Catalog authority is unbounded, but each indexed lookup is bounded.
        # A missing/unavailable catalog never grants permission to delete.
        case Scene.registered(digest) do
          {:ok, true} -> :ok
          {:ok, false} -> remove_if_old(path, cutoff)
          {:error, _} -> {:error, :cleanup_error}
        end

      temporary? ->
        remove_if_old(path, cutoff)

      true ->
        :ok
    end
  end

  # The caller admits only generated digest/UUID paths under the trusted root.
  # sobelow_skip ["Traversal.FileModule"]
  defp remove_if_old(path, cutoff) do
    case File.lstat(path, time: :posix) do
      {:ok, %{type: :regular, mtime: mtime}} when is_nil(cutoff) or mtime <= cutoff ->
        # Raw deletion runs in this owner process, not a file-server request
        # that could execute after owner death has released the SQLite resource.
        case :file.delete(path, [:raw]) do
          {:error, :enoent} -> :ok
          result -> result
        end

      {:ok, _} ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, _} ->
        {:error, :cleanup_error}
    end
  end

  # Open only the previously validated generated path; read at most one byte over
  # the cap, even if a local process replaces/grows the file after lstat.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_bounded(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, @max_bytes + 1)) do
      {:ok, bytes} when is_binary(bytes) -> {:ok, bytes}
      _ -> {:error, :unavailable_image}
    end
  end

  # Both paths are internal: a UUID temporary file and SHA-256 destination under
  # the trusted storage root. Exclusive creation precedes writing private bytes.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_image(directory, digest, extension, bytes) do
    temporary = Path.join(directory, ".stage-#{Ash.UUID.generate()}.tmp")
    destination = Path.join(directory, digest <> "." <> extension)

    try do
      with {:ok, :ok} <-
             File.open(temporary, [:write, :binary, :exclusive], fn file ->
               with :ok <- File.chmod(temporary, 0o600),
                    :ok <- IO.binwrite(file, bytes) do
                 :file.sync(file)
               end
             end),
           :ok <- File.rename(temporary, destination) do
        {:ok, digest}
      else
        _ -> {:error, :storage_error}
      end
    after
      cleanup_temporary(temporary)
    end
  end

  # Only an internally generated UUID path reaches this helper. Keep deletion
  # in the lock-owning process, including failed/interrupted atomic writes.
  defp cleanup_temporary(path) do
    case :file.delete(path, [:raw]) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      _ -> Logger.warning("LOVELACE stage temporary-file cleanup incomplete; no retry")
    end
  end

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp valid_digest?(digest), do: is_binary(digest) and Regex.match?(@digest, digest)
end
