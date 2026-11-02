defmodule Mix.Tasks.Lovelace.Keychain.Build do
  @shortdoc "Explicitly compile LOVELACE's local macOS Keychain helper"
  @moduledoc """
  Compiles `priv/native/keychain.swift` to `priv/native/lovelace-keychain` using
  Apple's local Swift compiler and Security framework. Does not start LOVELACE,
  read/write Keychain items, download dependencies, or handle credentials.
  Build on the target Mac before running/releasing; no automatic runtime build.
  """
  use Mix.Task

  @impl Mix.Task
  def run([]) do
    unless :os.type() == {:unix, :darwin}, do: Mix.raise("Keychain helper requires macOS")
    compiler = System.find_executable("xcrun") || Mix.raise("Apple developer tools unavailable")
    source = Path.expand("priv/native/keychain.swift")
    output = Path.expand("priv/native/lovelace-keychain")

    # Only public source/output paths are argv. This never invokes credential operations.
    case System.cmd(compiler, ["swiftc", "-O", "-framework", "Security", source, "-o", output],
           stderr_to_stdout: true
         ) do
      {_text, 0} -> Mix.shell().info("Built priv/native/lovelace-keychain")
      {_text, _} -> Mix.raise("Keychain helper compilation failed; check Apple developer tools")
    end
  end

  def run(_), do: Mix.raise("Usage: mix lovelace.keychain.build")
end
