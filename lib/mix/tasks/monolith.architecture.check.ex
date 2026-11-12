defmodule Mix.Tasks.Monolith.Architecture.Check do
  use Mix.Task

  alias Monolith.Architecture.Check

  @shortdoc "Checks parsed application dependency boundaries without starting the app"
  @moduledoc """
  Runs the deterministic architecture rules against current `lib/**/*.ex` sources.
  Does not start MONOLITH, a Repo, queues, credentials or providers. Syntax errors
  and forbidden dependencies fail the task. No cycle-count target is imposed.

  See `Monolith.Architecture.Check` for the exact static-analysis limits.
  """

  @impl Mix.Task
  def run([]) do
    violations = Check.sources() |> Check.check()

    if violations == [] do
      Mix.shell().info("Architecture boundaries passed")
    else
      Enum.each(violations, &Mix.shell().error(Check.format(&1)))
      Mix.raise("Architecture boundary violations: #{length(violations)}")
    end
  end

  def run(_args), do: Mix.raise("Usage: mix monolith.architecture.check")
end
