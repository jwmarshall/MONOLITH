defmodule Monolith.StageDesigner.ReadBackground do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  alias Monolith.StageDesigner
  alias Monolith.StageDesigner.{Generation, Image, Scene, Settings, Storage}

  @impl true
  def run(_input, _opts, _context) do
    settings = Settings.get()

    case StageDesigner.get_state(1, actor: %{role: :stage_designer}) do
      {:ok, state} when not is_nil(state) ->
        active = active_scene(state, settings)
        url = if active, do: active.url

        attempt = Generation.current(state)

        status =
          cond do
            attempt ->
              Generation.status(attempt)

            settings.enabled or state.status in [:failed, :generating] ->
              public_status(state.status)

            true ->
              :disabled
          end

        {:ok, %{url: url, status: status, attempt: Generation.public(attempt)}}

      {:ok, nil} ->
        {:ok, %{url: nil, status: :idle}}

      {:error, _} ->
        {:ok, %{url: nil, status: :unavailable}}
    end
  rescue
    _ -> {:ok, %{url: nil, status: :unavailable}}
  end

  def public_status(:generating), do: :uncertain
  def public_status(status), do: status

  def active_scene(nil, _settings), do: nil

  def active_scene(state, settings) do
    [state.selected_digest | state.history]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.find_value(fn digest ->
      with {:ok, true} <- Scene.registered(digest),
           url when is_binary(url) <- image_url(settings, digest) do
        %{digest: digest, url: url}
      else
        _ -> nil
      end
    end)
  end

  def image_url(settings, digest) do
    case Storage.read(settings, digest) do
      {:ok, bytes} -> Storage.url(digest, Image.format(bytes))
      _ -> nil
    end
  end
end
