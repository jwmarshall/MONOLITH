defmodule Lovelace.StageDesigner.Startup do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  alias Lovelace.StageDesigner
  alias Lovelace.StageDesigner.{Coordination, Generation, Settings, Storage}

  @impl true
  def run(input, opts, _context) do
    settings = Settings.get()

    result =
      if settings.enabled or opts[:retry_failed?] do
        now = input.arguments.now
        reconcile_storage(settings, now)
        Generation.startup(settings, now, Keyword.get(opts, :retry_failed?, false))
      else
        :disabled
      end

    {:ok, result}
  rescue
    _ -> {:ok, :unavailable}
  end

  defp reconcile_storage(settings, now) do
    case StageDesigner.get_state(1, actor: %{role: :stage_designer}) do
      {:ok, state} when not is_nil(state) ->
        Storage.reconcile(settings, state.history, DateTime.to_unix(now))

      _ ->
        :ok
    end
  end

  def manual_eligible?(nil), do: true
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

  def notify do
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
