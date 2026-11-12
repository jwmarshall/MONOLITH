defmodule Monolith.TestSupport.SceneGeneration do
  @moduledoc "Explicit fake-provider execution for manually queued scenery jobs."

  import ExUnit.Assertions

  alias Monolith.StageDesigner
  alias Monolith.StageDesigner.{Attempt, Generation, Image, Models}

  @service %{role: :stage_designer}
  @owner %{role: :local_owner}

  def prepare do
    StageDesigner.prepare_scene_generation(Models.defaults(), actor: @owner)
  end

  def manual do
    with {:ok, snapshot} <- prepare() do
      StageDesigner.request_scene_generation(%{confirmation: snapshot.confirmation},
        actor: @owner
      )
    end
  end

  def current do
    state = StageDesigner.get_state!(1, actor: @service)
    {:ok, attempt} = Attempt.get(state.active_attempt_id)
    attempt
  end

  def submit(module), do: perform(module, :submit)
  def poll(module), do: perform(module, :poll)

  defp perform(module, operation) do
    attempt = current()
    assert :ok = Generation.perform(attempt.id, operation, options(module))
    current()
  end

  def finish({:ok, :started}, module) do
    case submit(module).status do
      :completed -> {:ok, :generated}
      :failed -> {:ok, :failed}
      :unknown -> {:ok, :uncertain}
      status -> {:ok, status}
    end
  end

  def finish(result, _module), do: result

  def options(module), do: [api_key: "fake-stage-key", plug: {Req.Test, module}]

  def rendering(request) do
    Req.Test.json(request, %{
      id: "interaction-#{Ash.UUID.generate()}",
      status: "in_progress",
      steps: []
    })
  end

  def respond(request, bytes) do
    id =
      if request.method == "GET",
        do: List.last(request.path_info),
        else: "interaction-#{Ash.UUID.generate()}"

    Req.Test.json(request, %{
      id: id,
      status: "completed",
      steps: [
        %{
          type: "model_output",
          content: [
            %{
              type: "image",
              mime_type: Image.mime_type(Image.format(bytes)),
              data: Base.encode64(bytes)
            }
          ]
        }
      ]
    })
  end
end
