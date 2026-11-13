defmodule Monolith.Security.MaintenanceTaskTest do
  use ExUnit.Case, async: false

  alias Monolith.TestSupport.SubprocessCoverage

  @tag timeout: 300_000
  test "production maintenance uses runtime storage without starting protected work or replacing originals" do
    root = Path.expand("tmp/vault-maintenance-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    for mode <- ["owner", "migration", "google"] do
      directory = Path.join(root, mode)

      {output, status} =
        SubprocessCoverage.cmd(
          System.find_executable("elixir"),
          [
            "-r",
            "test/support/vault_maintenance.exs",
            "-S",
            "mix",
            "monolith.synthetic_maintenance",
            mode,
            directory
          ],
          env: [
            {"MIX_ENV", "prod"},
            {"ERL_FLAGS", "+S 2:2"},
            {"DATABASE_PATH", Path.join(directory, "original.db")},
            {"SECRET_KEY_BASE", String.duplicate("synthetic-production-cookie-key-", 3)},
            {"MONOLITH_STAGE_ENABLED", "false"},
            {"MONOLITH_STAGE_MIN_REFRESH_HOURS", "24"},
            {"MONOLITH_STAGE_TIMEOUT_SECONDS", "120"},
            {"MONOLITH_STAGE_REFRESH", "on_startup"},
            {"MONOLITH_STAGE_MAX_ATTEMPTS_PER_STARTUP", "1"},
            {"MONOLITH_STAGE_MAX_RETRIES", "0"},
            {"MONOLITH_STAGE_MODEL", "gemini-nano-banana-2.1"},
            {"MONOLITH_STAGE_ASPECT_RATIO", "16:9"},
            {"MONOLITH_STAGE_IMAGE_SIZE", "1K"},
            {"MONOLITH_STAGE_PROMPT", "synthetic"},
            {"MONOLITH_STAGE_STORAGE_DIR", Path.join(directory, "scenery")},
            {"MONOLITH_WORKSPACE_IDLE_MINUTES", "3"}
          ],
          stderr_to_stdout: true
        )

      assert status == 0, "#{mode} maintenance failed:\n#{output}"

      assert output =~
               "Production maintenance #{mode}: configured path, retained original, no protected runtime"
    end
  end
end
