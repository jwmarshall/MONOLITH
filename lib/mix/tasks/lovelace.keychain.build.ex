defmodule Mix.Tasks.Lovelace.Keychain.Build do
  @shortdoc "Explicitly compile LOVELACE's local macOS Keychain helper"
  @moduledoc """
  Compiles `priv/native/keychain.swift` to `priv/native/lovelace-vault` using
  Apple's local Swift compiler and Security framework. Does not start LOVELACE,
  read/write Keychain items, download dependencies, or handle credentials.
  Build on the target Mac before running/releasing; no automatic runtime build.
  With `--if-missing`, used by developer setup, an existing helper is never
  replaced. Stale or unsafe helpers require an explicit rebuild without that flag.
  Rebuilding can change the helper's Keychain ACL identity.
  The obsolete `lovelace-keychain` executable is never overwritten or removed.
  Dedicated file-keychain APIs are deprecated on macOS; no login-keychain fallback.
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) when args in [[], ["--if-missing"]] do
    unless :os.type() == {:unix, :darwin}, do: Mix.raise("Keychain helper requires macOS")
    source = Path.expand("priv/native/keychain.swift")
    output = Path.expand("priv/native/lovelace-vault")

    if args == ["--if-missing"] do
      ensure_missing!(source, output, &compile_helper!/2)
    else
      build!(source, output, :replace, &compile_helper!/2)
    end
  end

  def run(_), do: Mix.raise("Usage: mix lovelace.keychain.build [--if-missing]")

  if Mix.env() == :test do
    @doc false
    def with_test_builder(source, output, builder),
      do: ensure_missing!(source, output, builder)
  end

  defp ensure_missing!(source, output, builder) do
    case File.lstat(output, time: :posix) do
      {:error, :enoent} ->
        build!(source, output, :create, builder)

      {:ok, %File.Stat{type: :regular, mode: mode, mtime: built_at}} ->
        source_stat = File.stat!(source, time: :posix)

        if Bitwise.band(mode, 0o111) == 0 or built_at < source_stat.mtime do
          explicit_rebuild!()
        end

        Mix.shell().info("Preserved existing priv/native/lovelace-vault (not rebuilt)")

      _ ->
        explicit_rebuild!()
    end
  end

  # Compile away from the destination. Exclusive publication prevents a concurrent
  # setup from replacing a helper that has acquired a Keychain ACL identity.
  # sobelow_skip ["Traversal.FileModule"]
  defp build!(source, output, mode, builder) do
    directory =
      Path.join(
        Path.dirname(output),
        ".lovelace-vault-build-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(directory)
    staged = Path.join(directory, "lovelace-vault")

    try do
      builder.(source, staged)

      result =
        case mode do
          :create -> File.ln(staged, output)
          :replace -> File.rename(staged, output)
        end

      case result do
        :ok ->
          Mix.shell().info("Built priv/native/lovelace-vault")

        {:error, :eexist} ->
          explicit_rebuild!()

        {:error, _} ->
          Mix.raise("Could not install native helper; existing helper was not changed")
      end
    after
      File.rm_rf!(directory)
    end
  end

  defp compile_helper!(source, output) do
    compiler = System.find_executable("xcrun") || Mix.raise("Apple developer tools unavailable")

    # Only public source/output paths are argv. This never invokes credential operations.
    case System.cmd(compiler, ["swiftc", "-O", "-framework", "Security", source, "-o", output],
           stderr_to_stdout: true
         ) do
      {_text, 0} -> :ok
      {_text, _} -> Mix.raise("Keychain helper compilation failed; check Apple developer tools")
    end
  end

  defp explicit_rebuild! do
    Mix.raise("""
    Existing native helper was not changed. Automatic setup never replaces an existing helper.
    A current, executable regular file is required; stale or unsafe paths need explicit attention.
    Stop LOVELACE, inspect priv/native/lovelace-vault, then explicitly rebuild with:
      bin/lovelace mix lovelace.keychain.build
    Rebuilding can change its Keychain ACL identity; see docs/DEVELOPMENT.md before authorizing access.
    """)
  end
end
