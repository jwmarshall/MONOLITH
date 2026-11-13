defmodule Monolith.StageDesigner.Directions do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  alias Monolith.StageDesigner
  alias Monolith.StageDesigner.{DirectionOptions, Settings}

  @impl true
  def run(input, opts, context) do
    case Keyword.fetch!(opts, :operation) do
      :read ->
        read(Settings.get(), context.actor)

      :save ->
        with {:ok, direction} <-
               StageDesigner.persist_direction(input.arguments, actor: context.actor) do
          {:ok, saved(direction)}
        end
    end
  end

  def effective_settings(settings) do
    with {:ok, direction} <- read(settings, %{role: :stage_designer}) do
      {:ok, %{settings | prompt: direction.prompt}}
    end
  end

  defp read(settings, actor) do
    case StageDesigner.get_direction(1, actor: actor) do
      {:ok, nil} ->
        {:ok, %{values: DirectionOptions.defaults(), prompt: settings.prompt, saved?: false}}

      {:ok, direction} ->
        {:ok, saved(direction)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp saved(direction) do
    values = Map.take(direction, Enum.map(DirectionOptions.fields(), & &1.key))
    %{values: values, prompt: DirectionOptions.compose(values), saved?: true}
  end
end
