defmodule Lovelace.StageDesigner.Scenes do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  alias Lovelace.StageDesigner
  alias Lovelace.StageDesigner.{ReadBackground, Scene, Settings, Startup, Storage}

  @actor %{role: :stage_designer}

  @impl true
  def run(input, opts, _context) do
    case Keyword.fetch!(opts, :operation) do
      :list ->
        list(Settings.get(), input.arguments.page)

      :select ->
        select(Settings.get(), input.arguments.digest)
    end
  end

  defp list(settings, page) do
    with {:ok, state} <- StageDesigner.get_state(1, actor: @actor),
         {:ok, scenes, has_next} <- Scene.page(page) do
      # Resolve the actual background once, even if selected outside this page or
      # the recent fallback manifest. Never mark an arbitrary page item active.
      active = ReadBackground.active_scene(state, settings)

      {:ok,
       %{
         scenes: Enum.map(scenes, &scene(&1, active, settings)),
         status: if(state, do: ReadBackground.public_status(state.status), else: :idle),
         last_attempt_at: if(state, do: state.last_attempt_at),
         next_attempt_at: Startup.next_attempt_at(state, settings),
         eligible: Startup.manual_eligible?(state),
         page: page,
         page_size: Scene.page_size(),
         has_previous: page > 1,
         has_next: has_next
       }}
    else
      {:error, _} -> {:error, :unavailable}
    end
  end

  defp scene(scene, active, settings) do
    url = ReadBackground.image_url(settings, scene.digest)

    %{
      digest: scene.digest,
      url: url,
      generated_at: scene.generated_at,
      active: not is_nil(active) and scene.digest == active.digest,
      available: not is_nil(url)
    }
  end

  defp select(settings, digest) do
    case Storage.select(settings, digest) do
      {:ok, :selected} = result ->
        Startup.notify()
        result

      {:error, _} ->
        {:error, :unavailable_scene}
    end
  end
end
