defmodule Monolith.GitHub.Metrics do
  @moduledoc "Explicit counts within one selected installation snapshot, never inferred totals."

  @failed_conclusions ~w(failure timed_out startup_failure)
  @review_decisions ~w(APPROVED CHANGES_REQUESTED REVIEW_REQUIRED)
  @check_states ~w(SUCCESS PENDING FAILURE ERROR)

  def summary(org, now) do
    runs = runs_snapshot(org, now)

    if org.cache_retained? do
      %{
        prs: count(org.pull_requests, org.truncated),
        review: pr_count(org, &review?(&1, "REVIEW_REQUIRED")),
        changes: pr_count(org, &review?(&1, "CHANGES_REQUESTED")),
        checks: pr_count(org, &checks_failed?/1),
        issues: count(org.issues, org.issues_truncated),
        runs: count(runs.workflow_runs, runs.actions_truncated),
        failed: run_count(runs, &(&1["conclusion"] in @failed_conclusions)),
        running: run_count(runs, &(&1["status"] == "in_progress"))
      }
    else
      Map.new(~w(prs review changes checks issues runs failed running)a, &{&1, nil})
    end
  end

  @doc "Runs created in (now - 24 hours, now]; update time does not extend the window."
  def runs_snapshot(org, now) do
    cutoff = DateTime.add(now, -86_400)

    {runs, unknown?} =
      Enum.reduce(org.workflow_runs, {[], false}, fn run, {rows, unknown?} ->
        case recent_run?(run, cutoff, now) do
          true ->
            {[run | rows], unknown?}

          false ->
            {rows, unknown?}

          :unknown ->
            {rows, true}
        end
      end)

    %{
      org
      | workflow_runs: Enum.reverse(runs),
        actions_truncated: org.actions_truncated || unknown?
    }
  end

  defp recent_run?(run, cutoff, now) do
    case created_at(run) do
      {:ok, created, _} ->
        DateTime.compare(created, cutoff) == :gt && DateTime.compare(created, now) != :gt

      _ ->
        :unknown
    end
  end

  defp created_at(%{"created_at" => at}) when is_binary(at), do: DateTime.from_iso8601(at)
  defp created_at(_), do: :unknown

  defp review?(%{"is_draft" => true}, _decision), do: false

  defp review?(pr, decision) do
    if pr["review_decision"] in @review_decisions,
      do: pr["review_decision"] == decision,
      else: :unknown
  end

  defp checks_failed?(pr) do
    if pr["checks"] in @check_states,
      do: pr["checks"] in ["FAILURE", "ERROR"],
      else: :unknown
  end

  defp pr_count(org, predicate), do: count(org.pull_requests, org.truncated, predicate)
  defp run_count(org, predicate), do: count(org.workflow_runs, org.actions_truncated, predicate)

  defp count(rows, partial?, predicate \\ fn _ -> true end) do
    {value, partial?} =
      Enum.reduce(rows, {0, partial?}, fn row, {value, partial?} ->
        case predicate.(row) do
          true -> {value + 1, partial?}
          false -> {value, partial?}
          :unknown -> {value, true}
        end
      end)

    if value == 0 && partial?, do: nil, else: %{value: value, partial?: partial?}
  end
end
