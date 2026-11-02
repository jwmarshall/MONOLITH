defmodule Lovelace.StageDesigner.Storage do
  @moduledoc "Bounded, content-addressed local PNG/JPEG storage. No provider URLs are served."
  alias Lovelace.StageDesigner.Image

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

  # Only the local configuration selects the root; filenames are content hashes.
  # sobelow_skip ["Traversal.FileModule"]
  def store(settings, bytes) do
    with :ok <- Image.validate(bytes),
         :ok <- File.mkdir_p(settings.storage_dir),
         :ok <- File.chmod(settings.storage_dir, 0o700) do
      digest = hash(bytes)
      write_image(settings.storage_dir, digest, Image.extension(Image.format(bytes)), bytes)
    else
      _ -> {:error, :storage_error}
    end
  end

  def prune(settings, retained), do: cleanup(settings, retained, nil)

  # Recover interrupted writes independently of successful provider responses.
  # The grace period exceeds the hard request deadline, protecting concurrent startup.
  def reconcile(settings, retained, now), do: cleanup(settings, retained, now - 300)

  defp cleanup(settings, retained, cutoff) do
    case File.ls(settings.storage_dir) do
      {:ok, names} -> Enum.each(names, &prune_file(settings, &1, retained, cutoff))
      _ -> :ok
    end
  end

  # Only exact generated digest/UUID filenames under the configured root are removable.
  # sobelow_skip ["Traversal.FileModule"]
  defp prune_file(settings, name, retained, cutoff) do
    digest = Path.rootname(name)

    generated? =
      Path.extname(name) in [".png", ".jpg"] and valid_digest?(digest) and digest not in retained

    temporary? = not is_nil(cutoff) and Regex.match?(~r/\A\.stage-[0-9a-f-]{36}\.tmp\z/, name)
    path = Path.join(settings.storage_dir, name)

    if (generated? or temporary?) and old_file?(path, cutoff), do: File.rm(path)
  end

  defp old_file?(_path, nil), do: true

  defp old_file?(path, cutoff) do
    case File.lstat(path, time: :posix) do
      {:ok, %{type: :regular, mtime: mtime}} -> mtime <= cutoff
      _ -> false
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
      File.rm(temporary)
    end
  end

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp valid_digest?(digest), do: is_binary(digest) and Regex.match?(@digest, digest)
end
