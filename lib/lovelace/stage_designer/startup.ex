defmodule Lovelace.StageDesigner.Startup do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  require Logger

  alias Lovelace.StageDesigner
  alias Lovelace.StageDesigner.{Coordination, Diagnostics, Directions, Gemini, Settings, Storage}

  @actor %{role: :stage_designer}

  @impl true
  def run(input, opts, _context) do
    settings = Settings.get()
    manual? = Keyword.get(opts, :manual?, false)

    result =
      if settings.enabled or manual? do
        resolve_and_attempt(input, opts, settings, manual?)
      else
        :disabled
      end

    {:ok, result}
  rescue
    _ ->
      Logger.warning("LOVELACE stage designer unavailable; keeping local scenery")
      {:ok, :unavailable}
  end

  defp resolve_and_attempt(input, opts, settings, manual?) do
    # Capture one effective configuration before reservation/task dispatch. An
    # unreadable saved direction is not permission to use the environment brief.
    case Directions.effective_settings(settings) do
      {:ok, resolved} ->
        expected = Map.get(input.arguments, :expected_prompt)

        if not is_nil(expected) and expected != resolved.prompt do
          :direction_changed
        else
          attempt(
            resolved,
            Map.get(input.arguments, :now) || Map.get(input.context, :now, DateTime.utc_now()),
            Map.get(input.context, :provider_options, []),
            Keyword.get(opts, :retry_failed?, false),
            manual?
          )
        end

      {:error, _} ->
        :unavailable
    end
  end

  defp attempt(settings, now, provider_options, retry_failed?, manual?) do
    with {:ok, _} <- StageDesigner.initialize_state(%{}, actor: @actor),
         {:ok, state} when not is_nil(state) <- StageDesigner.get_state(1, actor: @actor) do
      unless manual?,
        do: report_cleanup(Storage.reconcile(settings, state.history, DateTime.to_unix(now)))

      eligible? =
        if manual?,
          do: manual_eligible?(state),
          else: eligible?(state, settings, now, retry_failed?)

      cond do
        eligible? -> reserve_and_generate(state, settings, now, provider_options, manual?)
        manual? -> :busy
        true -> :cached
      end
    else
      _ -> :unavailable
    end
  end

  defp eligible?(state, _settings, _now, true), do: state.status == :failed
  defp eligible?(state, settings, now, false), do: due?(state, settings, now)

  def manual_eligible?(nil), do: true
  # A persisted reservation has an unknown outcome, regardless of its age.
  def manual_eligible?(state), do: state.status != :generating

  def due?(state, settings, now) do
    case next_attempt_at(state, settings) do
      nil -> true
      timestamp -> DateTime.compare(now, timestamp) != :lt
    end
  end

  def next_attempt_at(nil, _settings), do: nil

  def next_attempt_at(state, settings) do
    [state.last_attempt_at, state.generated_at]
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
    |> case do
      nil -> nil
      timestamp -> DateTime.add(timestamp, settings.min_refresh_hours * 3600, :second)
    end
  end

  defp reserve_and_generate(state, settings, now, provider_options, manual?) do
    # Optimistic version check is performed in SQLite. Only the winning reservation
    # may contact Google; the timestamp commits before the network call starts.
    case StageDesigner.reserve_state(state, %{last_attempt_at: now}, actor: @actor) do
      {:ok, reserved} ->
        notify()
        dispatch(reserved, settings, now, provider_options, manual?)

      {:error, _} ->
        if manual?, do: :busy, else: :cached
    end
  end

  defp dispatch(reserved, settings, now, provider_options, false),
    do: generate(reserved, settings, now, provider_options)

  defp dispatch(reserved, settings, now, provider_options, true) do
    case Task.Supervisor.start_child(Lovelace.StageDesigner.TaskSupervisor, fn ->
           # An unexpected task exit leaves the durable outcome uncertain. Never
           # restart it or retry a provider request with an unknown outcome.
           try do
             generate(reserved, settings, now, provider_options)
           rescue
             _ -> Logger.warning("LOVELACE stage generation outcome uncertain; no retry")
           end
         end) do
      {:ok, _pid} -> :started
      {:error, _} -> :unavailable
    end
  end

  defp generate(reserved, settings, now, provider_options) do
    case Gemini.generate(settings, provider_options) do
      {:ok, bytes} -> publish(reserved, settings, now, bytes)
      {:error, reason} -> fail(reserved, :provider, reason)
    end
  end

  defp publish(reserved, settings, now, bytes) do
    case Storage.store_and_publish(settings, bytes, reserved, now) do
      {:ok, published} ->
        # This is intentionally a separate transaction after publication COMMIT.
        report_cleanup(Storage.prune(settings, published.history))
        notify()
        :generated

      {:error, {stage, reason}} ->
        fail(reserved, stage, reason)
    end
  end

  defp report_cleanup(:ok), do: :ok

  defp report_cleanup({:error, _}) do
    Logger.warning(
      "LOVELACE stage storage cleanup incomplete; keeping published scenery; " <>
        "check local storage and database availability (no generation retry)"
    )
  end

  defp fail(reserved, stage, reason) do
    StageDesigner.fail_state(reserved, %{}, actor: @actor)

    Logger.warning(
      "LOVELACE background generation failed (#{Diagnostics.describe(stage, reason)}); " <>
        "keeping local scenery (no retry)"
    )

    notify()
    :failed
  end

  def notify do
    # Keep the snapshot and synchronous local dispatch under the same exclusion
    # as selection/publication. A delayed notifier cannot broadcast old imagery
    # after a newer scene commits and notifies. Never fall back to an unlocked read.
    Coordination.with_lock(Settings.get(), fn ->
      case StageDesigner.background() do
        {:ok, background} ->
          Phoenix.PubSub.broadcast(
            Lovelace.PubSub,
            "stage_designer",
            {:stage_background, background}
          )

        _ ->
          :ok
      end
    end)
  end
end
