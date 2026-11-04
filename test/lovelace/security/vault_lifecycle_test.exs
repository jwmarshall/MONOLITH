defmodule Lovelace.Security.VaultLifecycleTest do
  use ExUnit.Case, async: false

  @tag timeout: 180_000
  test "managed vault fences real consumers, queued intent, schema failures and shutdown lifetimes" do
    root = Path.expand("tmp/vault-lifecycle-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    {output, status} =
      System.cmd(
        System.find_executable("mix"),
        [
          "run",
          "--no-start",
          "--no-compile",
          "--no-deps-check",
          "test/support/vault_lifecycle.exs",
          root
        ],
        env: [{"MIX_ENV", "test"}, {"ERL_FLAGS", "+S 2:2"}, {"LOVELACE_STAGE_ENABLED", "false"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end
end
