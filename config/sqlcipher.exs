import Config

# SQLCipher is mandatory even for synthetic plaintext test databases. Set this
# before Exqlite's project is evaluated, disabling downloaded stock-SQLite NIFs.
System.put_env("EXQLITE_USE_SYSTEM", "1")

pkg_config = System.find_executable("pkg-config")

query = fn flag ->
  if pkg_config do
    case System.cmd(pkg_config, [flag, "sqlcipher"], stderr_to_stdout: true) do
      {value, 0} -> String.trim(value)
      _ -> nil
    end
  end
end

# Missing SQLCipher must fail at native link time, never fall back to sqlite3.c.
# The wrapper sets PKG_CONFIG_PATH for Homebrew's keg-only SQLCipher installation.
config :exqlite,
  force_build: true,
  make_env: %{
    "EXQLITE_USE_SYSTEM" => "1",
    "EXQLITE_SYSTEM_CFLAGS" => query.("--cflags") || "-DSQLITE_HAS_CODEC",
    "EXQLITE_SYSTEM_LDFLAGS" => query.("--libs") || "-lsqlcipher"
  }
