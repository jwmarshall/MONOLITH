defmodule Monolith.Security.LauncherTest do
  use ExUnit.Case, async: true

  @project_root Path.expand("../../..", __DIR__)
  @launcher Path.join(@project_root, "bin/monolith")

  setup do
    root =
      Path.join(System.tmp_dir!(), "monolith launcher #{System.unique_integer([:positive])}")

    bin = Path.join(root, "fake executables")
    starting_directory = Path.join(root, "unrelated working directory")
    File.mkdir_p!(bin)
    File.mkdir_p!(starting_directory)
    on_exit(fn -> File.rm_rf!(root) end)

    context = %{
      root: root,
      bin: bin,
      starting_directory: starting_directory,
      capture: Path.join(root, "dispatch"),
      pkg_calls: Path.join(root, "pkg-config calls"),
      brew_calls: Path.join(root, "brew calls")
    }

    # PATH contains only these scripts. Even a broken dispatch cannot invoke the
    # developer's Mix, IEx, Homebrew, or pkg-config installation.
    executable(context, "dirname", """
    [ "$#" -eq 1 ] || exit 98
    printf '%s\\n' "${1%/*}"
    """)

    executable(context, "cat", """
    [ "$#" -eq 0 ] || exit 98
    while IFS= read -r line; do printf '%s\\n' "$line"; done
    """)

    for command <- ["mix", "iex"] do
      executable(context, command, """
      printf '%s\\000' "${0##*/}" "$PWD" "$EXQLITE_USE_SYSTEM" \
        "$EXQLITE_SYSTEM_CFLAGS" "$EXQLITE_SYSTEM_LDFLAGS" \
        "${PKG_CONFIG_PATH-}" "$@" > "$LAUNCHER_CAPTURE"
      exit "${LAUNCHER_COMMAND_STATUS:-0}"
      """)
    end

    executable(context, "pkg-config", """
    printf '%s\\000' "$PWD" "${PKG_CONFIG_PATH-}" "$#" "$@" >> "$LAUNCHER_PKG_CALLS"
    case "$#:${1-}:${2-}" in
      2:--exists:sqlcipher) exit "${LAUNCHER_SQLCIPHER_STATUS:-0}" ;;
      2:--cflags:sqlcipher) printf '%s\\n' '-I/synthetic sqlcipher/include -DSQLITE_HAS_CODEC' ;;
      2:--libs:sqlcipher) printf '%s\\n' '-L/synthetic sqlcipher/lib -lsqlcipher' ;;
      *) exit 98 ;;
    esac
    """)

    {:ok, context}
  end

  test "dispatches every action from the project root without changing arguments", context do
    arguments = [
      "two words",
      "",
      "semi;colon",
      "$(not-a-command)",
      "*?[abc]",
      "\"double\" 'single'",
      "line one\nline two",
      "--option=value with spaces"
    ]

    for {action, command, prefix} <- [
          {"server", "mix", ["phx.server"]},
          {"console", "iex", ["-S", "mix", "phx.server"]},
          {"mix", "mix", []},
          {"setup", "mix", ["setup"]},
          {"check", "mix", ["check"]},
          {"test", "mix", ["test"]},
          {"audit", "mix", ["audit"]}
        ] do
      assert {"", 0} = launch(context, [action | arguments])
      assert_dispatch(context, command, prefix ++ arguments, "")
      assert_pkg_calls(context, ["--exists", "--cflags", "--libs"])
      refute File.exists?(context.brew_calls)
    end
  end

  test "prepends the Homebrew SQLCipher prefix and retains an existing pkg-config path",
       context do
    install_brew(context)
    prefix = Path.join(context.root, "Homebrew SQLCipher")
    existing = "/existing pkgconfig:/another/pkgconfig"

    assert {"", 0} =
             launch(context, ["mix", "compile"],
               LAUNCHER_BREW_PREFIX: prefix,
               PKG_CONFIG_PATH: existing
             )

    assert_dispatch(context, "mix", ["compile"], "#{prefix}/lib/pkgconfig:#{existing}")
    assert read_fields(context.brew_calls) == ["2", "--prefix", "sqlcipher"]

    assert_pkg_calls(
      context,
      ["--exists", "--cflags", "--libs"],
      "#{prefix}/lib/pkgconfig:#{existing}"
    )
  end

  test "Homebrew omits trailing separators for unset or empty pkg-config paths", context do
    install_brew(context)
    prefix = Path.join(context.root, "Homebrew SQLCipher")

    for existing <- [nil, ""] do
      assert {"", 0} =
               launch(context, ["server"],
                 LAUNCHER_BREW_PREFIX: prefix,
                 PKG_CONFIG_PATH: existing
               )

      assert_dispatch(context, "mix", ["phx.server"], "#{prefix}/lib/pkgconfig")
      assert_pkg_calls(context, ["--exists", "--cflags", "--libs"], "#{prefix}/lib/pkgconfig")
    end
  end

  test "without Homebrew the supplied pkg-config search path is preserved", context do
    existing = "/standalone sqlcipher/lib/pkgconfig"

    assert {"", 0} = launch(context, ["test"], PKG_CONFIG_PATH: existing)
    assert_dispatch(context, "mix", ["test"], existing)
    assert_pkg_calls(context, ["--exists", "--cflags", "--libs"], existing)
    refute File.exists?(context.brew_calls)
  end

  test "propagates both Mix and console failure statuses", context do
    for {action, command, prefix, status} <- [
          {"mix", "mix", ["synthetic.task"], 37},
          {"console", "iex", ["-S", "mix", "phx.server"], 23}
        ] do
      arguments = if action == "mix", do: prefix, else: []

      assert {"", ^status} =
               launch(context, [action | arguments], LAUNCHER_COMMAND_STATUS: status)

      assert_dispatch(context, command, prefix, "")
    end
  end

  test "missing pkg-config fails before dispatch", context do
    File.rm!(Path.join(context.bin, "pkg-config"))

    assert {"pkg-config is required\n", 1} = launch(context, ["server"])
    refute File.exists?(context.capture)
    refute File.exists?(context.pkg_calls)
  end

  test "missing SQLCipher fails before querying flags or dispatching", context do
    assert {"SQLCipher is required\n", 1} =
             launch(context, ["setup"], LAUNCHER_SQLCIPHER_STATUS: 9)

    assert_pkg_calls(context, ["--exists"])
    refute File.exists?(context.capture)
  end

  test "a failing Homebrew prefix lookup propagates failure before pkg-config or dispatch",
       context do
    install_brew(context)

    assert {"", 27} = launch(context, ["server"], LAUNCHER_BREW_STATUS: 27)
    assert read_fields(context.brew_calls) == ["2", "--prefix", "sqlcipher"]
    refute File.exists?(context.pkg_calls)
    refute File.exists?(context.capture)
  end

  test "help and unknown actions do not require build prerequisites", context do
    File.rm!(Path.join(context.bin, "pkg-config"))

    for arguments <- [[], ["help"], ["-h"], ["--help"]] do
      assert {output, 0} = launch(context, arguments)
      assert output =~ "Usage: bin/monolith <action> [arguments]"
      refute File.exists?(context.capture)
      refute File.exists?(context.pkg_calls)
    end

    assert {output, 2} = launch(context, ["unknown action"])
    assert output =~ "Unknown action: unknown action\n"
    assert output =~ "Usage: bin/monolith <action> [arguments]"
    refute File.exists?(context.capture)
    refute File.exists?(context.pkg_calls)
  end

  defp executable(context, name, body) do
    path = Path.join(context.bin, name)
    File.write!(path, "#!/bin/sh\nset -eu\n" <> body)
    File.chmod!(path, 0o755)
  end

  defp install_brew(context) do
    executable(context, "brew", """
    printf '%s\\000' "$#" "$@" >> "$LAUNCHER_BREW_CALLS"
    [ "$#:${1-}:${2-}" = '2:--prefix:sqlcipher' ] || exit 98
    [ "${LAUNCHER_BREW_STATUS:-0}" -eq 0 ] || exit "$LAUNCHER_BREW_STATUS"
    printf '%s\\n' "$LAUNCHER_BREW_PREFIX"
    """)
  end

  defp launch(context, arguments, overrides \\ []) do
    for path <- [context.capture, context.pkg_calls, context.brew_calls], do: File.rm(path)

    env = [
      {"PATH", context.bin},
      {"CDPATH", nil},
      {"ENV", nil},
      {"BASH_ENV", nil},
      {"PKG_CONFIG_PATH", nil},
      {"EXQLITE_USE_SYSTEM", "inherited value must be replaced"},
      {"EXQLITE_SYSTEM_CFLAGS", "inherited flags must be replaced"},
      {"EXQLITE_SYSTEM_LDFLAGS", "inherited flags must be replaced"},
      {"LAUNCHER_CAPTURE", context.capture},
      {"LAUNCHER_PKG_CALLS", context.pkg_calls},
      {"LAUNCHER_BREW_CALLS", context.brew_calls},
      {"LAUNCHER_COMMAND_STATUS", "0"},
      {"LAUNCHER_SQLCIPHER_STATUS", "0"},
      {"LAUNCHER_BREW_STATUS", "0"},
      {"LAUNCHER_BREW_PREFIX", "/synthetic/sqlcipher"}
    ]

    overrides =
      Map.new(overrides, fn {key, value} ->
        {Atom.to_string(key), if(is_nil(value), do: nil, else: to_string(value))}
      end)

    System.cmd(@launcher, arguments,
      cd: context.starting_directory,
      env: Map.to_list(Map.merge(Map.new(env), overrides)),
      stderr_to_stdout: true
    )
  end

  defp assert_dispatch(context, command, arguments, pkg_config_path) do
    assert read_fields(context.capture) ==
             [
               command,
               @project_root,
               "1",
               "-I/synthetic sqlcipher/include -DSQLITE_HAS_CODEC",
               "-L/synthetic sqlcipher/lib -lsqlcipher",
               pkg_config_path
             ] ++ arguments
  end

  defp assert_pkg_calls(context, flags, pkg_config_path \\ "") do
    expected = Enum.flat_map(flags, &[@project_root, pkg_config_path, "2", &1, "sqlcipher"])

    assert read_fields(context.pkg_calls) == expected
  end

  defp read_fields(path) do
    path
    |> File.read!()
    |> :binary.split(<<0>>, [:global])
    |> Enum.drop(-1)
  end
end
