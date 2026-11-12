defmodule Monolith.MixProject do
  use Mix.Project

  def project do
    [
      app: :monolith,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      test_coverage: [summary: [threshold: 90]],
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      usage_rules: usage_rules(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      consolidate_protocols: Mix.env() != :dev
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Monolith.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [
        check: :test,
        lint: :test,
        credo: :test,
        precommit: :test,
        "test.ui": :test
      ]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:sourceror, "~> 1.8", only: [:dev, :test]},
      {:ash, "~> 3.37"},
      # Pure-Elixir SAT solver required by Ash policies; no additional native build.
      {:simple_sat, "~> 0.1"},
      {:ash_sqlite, "~> 0.3.1"},
      {:ash_phoenix, "~> 2.3"},
      {:ash_authentication, "~> 4.15.1"},
      # AshAuthentication 4.x still caps Assent below its CVE-2026-117656 fix.
      # Its Assent calls retain their APIs in 0.3; owner auth uses only passwords.
      {:assent, "~> 0.3.2", override: true},
      {:ash_authentication_phoenix, "~> 2.17"},
      {:req, "~> 0.7"},
      {:oban, "~> 2.24.2"},
      # Private Gemini adapter avoids credential-bearing Finch instrumentation.
      {:mint, "~> 1.11.0"},
      # SQLCipher binding and non-pooled cross-BEAM filesystem exclusion handles.
      {:exqlite, "~> 0.43.0"},
      # Strict, fully evaluated JPEG decoding; preserve provider bytes for storage.
      {:vix, "~> 0.42.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ash_credo, "~> 0.19.2", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.18.1", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:igniter, "~> 0.8", only: [:dev, :test], runtime: false},
      {:usage_rules, "~> 1.3", only: :dev, runtime: false},
      {:tidewave, "~> 0.9", only: :dev},
      {:phoenix, "~> 1.8.9"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, "~> 0.26.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.5.20",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"}
    ]
  end

  # Keep third-party guidance linked, rather than inflating the repository root prompt.
  defp usage_rules do
    [
      file: "DEPENDENCY_RULES.md",
      usage_rules: [
        {:ash, link: :markdown},
        {~r/^ash_/, link: :markdown},
        {"phoenix:all", link: :markdown},
        {:igniter, link: :markdown},
        {:usage_rules, link: :markdown}
      ]
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp test_js(_args) do
    {_, status} =
      System.cmd("node", ["--test" | Path.wildcard("test/js/*_test.mjs")],
        into: IO.stream(:stdio, :line)
      )

    if status != 0, do: Mix.raise("JavaScript tests failed")
  end

  defp aliases do
    [
      setup: [
        "deps.get",
        "deps.clean --build exqlite",
        "deps.compile exqlite --include-children",
        "monolith.developer.setup",
        "assets.setup",
        "assets.build"
      ],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind monolith", "esbuild monolith"],
      "assets.deploy": [
        "tailwind monolith --minify",
        "esbuild monolith --minify",
        "phx.digest"
      ],
      lint: ["compile --warnings-as-errors", "credo --strict"],
      security: ["sobelow --private --exit low --skip"],
      audit: ["deps.audit", "hex.audit"],
      "test.js": &test_js/1,
      "test.ui": ["assets.deploy", "run --no-start test/support/ui_browser.exs"],
      check: [
        "format --check-formatted",
        "lint",
        "monolith.architecture.check",
        "security",
        "ash.codegen --check",
        "test --cover",
        "test.js",
        "assets.build"
      ],
      precommit: ["check"]
    ]
  end
end
