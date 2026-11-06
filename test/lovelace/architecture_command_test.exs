defmodule Lovelace.ArchitectureCommandTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Lovelace.Architecture.Check

  setup do
    root = Path.join(System.tmp_dir!(), "lovelace-architecture-command-#{Ash.UUID.generate()}")
    File.mkdir_p!(Path.join(root, "lib/nested"))
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(previous_shell)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "the command rejects a forbidden dependency discovered in nested source files", %{
    root: root
  } do
    File.write!(Path.join(root, "lib/nested/boundary.ex"), """
    defmodule Lovelace.Forbidden do
      def callback, do: LovelaceWeb.Endpoint.url()
    end
    """)

    File.cd!(root, fn ->
      assert_raise Mix.Error, ~r/Architecture boundary violations:/, fn -> Check.run([]) end
    end)

    assert_received {:mix_shell, :error, [message]}
    assert message =~ "lib/nested/boundary.ex:2: [core_to_web]"
    assert message =~ "Lovelace.Forbidden"
    assert message =~ "LovelaceWeb.Endpoint"
  end

  test "supported composition passes but invalid source fails closed", %{root: root} do
    source = Path.join(root, "lib/nested/composition.ex")

    File.write!(source, """
    defmodule Lovelace.Application do
      def children, do: [LovelaceWeb.Endpoint, LovelaceWeb.Telemetry]
    end
    """)

    File.cd!(root, fn -> Check.run([]) end)
    assert_received {:mix_shell, :info, ["Architecture boundaries passed"]}

    File.write!(source, "defmodule Lovelace.Broken do\n")
    File.cd!(root, fn -> assert_raise TokenMissingError, fn -> Check.run([]) end end)
    refute_received {:mix_shell, :info, _}
  end
end
