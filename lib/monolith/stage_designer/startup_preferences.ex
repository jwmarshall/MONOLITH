defmodule Monolith.StageDesigner.StartupPreferences do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  alias Monolith.StageDesigner
  alias Monolith.StageDesigner.Settings

  @impl true
  def run(input, opts, context) do
    case Keyword.fetch!(opts, :operation) do
      :read ->
        with {:ok, preference} <- StageDesigner.get_startup_preference(1, actor: context.actor) do
          {:ok, observed(preference)}
        end

      :save ->
        with {:ok, preference} <-
               StageDesigner.persist_startup_preference(input.arguments, actor: context.actor) do
          {:ok, observed(preference)}
        end
    end
  end

  # This is only admission for new automatic/operator attempts. Known durable jobs
  # recover independently; saving this preference never admits or cancels work.
  def authorize_startup(%{enabled: true}) do
    case StageDesigner.get_startup_preference(1, actor: %{role: :stage_designer}) do
      {:ok, %{enabled: true}} -> :ok
      {:ok, _} -> :disabled
      _ -> :unavailable
    end
  rescue
    _ -> :unavailable
  end

  def authorize_startup(_settings), do: :disabled

  defp observed(preference) do
    %{
      enabled: not is_nil(preference) and preference.enabled == true,
      environment_enabled: Settings.get().enabled == true
    }
  end
end
