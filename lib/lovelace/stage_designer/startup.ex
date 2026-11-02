defmodule Lovelace.StageDesigner.Startup do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  require Logger

  alias Lovelace.StageDesigner
  alias Lovelace.StageDesigner.{Diagnostics, Gemini, Settings, Storage}

  @actor %{role: :stage_designer}

  @impl true
  def run(input, opts, _context) do
    settings = Settings.get()

    result =
      if settings.enabled do
        attempt(
          settings,
          input.arguments.now,
          Map.get(input.context, :provider_options, []),
          Keyword.get(opts, :retry_failed?, false)
        )
      else
        :disabled
      end

    {:ok, result}
  rescue
    _ ->
      Logger.warning("LOVELACE stage designer unavailable; keeping local scenery")
      {:ok, :unavailable}
  end

  defp attempt(settings, now, provider_options, retry_failed?) do
    with {:ok, _} <- StageDesigner.initialize_state(%{}, actor: @actor),
         {:ok, state} when not is_nil(state) <- StageDesigner.get_state(1, actor: @actor) do
      Storage.reconcile(settings, state.history, DateTime.to_unix(now))

      if eligible?(state, settings, now, retry_failed?) do
        reserve_and_generate(state, settings, now, provider_options)
      else
        :cached
      end
    else
      _ -> :unavailable
    end
  end

  defp eligible?(state, _settings, _now, true), do: state.status == :failed
  defp eligible?(state, settings, now, false), do: due?(state, settings, now)

  defp due?(state, settings, now) do
    cutoff = DateTime.add(now, -settings.min_refresh_hours * 3600, :second)

    Enum.all?([state.last_attempt_at, state.generated_at], fn
      nil -> true
      timestamp -> DateTime.compare(timestamp, cutoff) != :gt
    end)
  end

  defp reserve_and_generate(state, settings, now, provider_options) do
    # Optimistic version check is performed in SQLite. Only the winning reservation
    # may contact Google; the timestamp commits before the network call starts.
    case StageDesigner.reserve_state(state, %{last_attempt_at: now}, actor: @actor) do
      {:ok, reserved} ->
        notify()
        generate(reserved, settings, now, provider_options)

      {:error, _} ->
        :cached
    end
  end

  defp generate(reserved, settings, now, provider_options) do
    with {:provider, {:ok, bytes}} <- {:provider, Gemini.generate(settings, provider_options)},
         {:storage, {:ok, digest}} <- {:storage, Storage.store(settings, bytes)},
         history = Enum.take(Enum.uniq([digest | reserved.history]), settings.retain_count),
         {:publication, {:ok, _}} <-
           {:publication,
            StageDesigner.publish_state(reserved, %{history: history, generated_at: now},
              actor: @actor
            )} do
      Storage.prune(settings, history)
      notify()
      :generated
    else
      {:publication, {:error, _error}} ->
        fail(reserved, :publication, :publication_error)

      {stage, {:error, reason}} ->
        fail(reserved, stage, reason)

      _ ->
        fail(reserved, :startup, :unexpected_error)
    end
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

  defp notify do
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
  end
end
