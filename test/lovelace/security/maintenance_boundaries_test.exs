defmodule Lovelace.Security.MaintenanceBoundariesTest do
  use ExUnit.Case, async: false

  alias Lovelace.TestSupport.SubprocessCoverage

  for scenario <-
        ~w(owner_mismatch owner_short owner_cancel google_cancel migration_cancel migration_auth journal_invalid journal_identity journal_symlink) do
    @tag timeout: 60_000
    test "terminal refusal preserves storage: #{scenario}" do
      root = Path.expand("tmp/maintenance-boundary-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(root) end)

      {output, status} =
        SubprocessCoverage.cmd(
          System.find_executable("elixir"),
          [
            "-r",
            "test/support/maintenance_boundaries.exs",
            "-S",
            "mix",
            "lovelace.synthetic_boundaries",
            unquote(scenario),
            root
          ],
          env: [
            {"MIX_ENV", "prod"},
            {"ERL_FLAGS", "+S 2:2"},
            {"DATABASE_PATH", Path.join(root, "original.db")},
            {"SECRET_KEY_BASE", String.duplicate("synthetic-production-cookie-key-", 3)},
            {"LOVELACE_STAGE_ENABLED", "false"},
            {"LOVELACE_STAGE_STORAGE_DIR", Path.join(root, "scenery")}
          ],
          stderr_to_stdout: true
        )

      assert status == 0, output
    end
  end

  test "maintenance commands reject credential-bearing arguments before accessing storage" do
    for task <- [
          Mix.Tasks.Lovelace.Owner.Setup,
          Mix.Tasks.Lovelace.Google.Configure,
          Mix.Tasks.Lovelace.Vault.Migrate
        ] do
      assert_raise Mix.Error, ~r/Usage:/, fn ->
        task.run(["synthetic-secret-never-an-argument"])
      end
    end
  end
end
