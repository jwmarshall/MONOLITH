defmodule Lovelace.StageDesigner.ReadBackground do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  alias Lovelace.StageDesigner
  alias Lovelace.StageDesigner.{Image, Settings, Storage}

  @impl true
  def run(_input, _opts, _context) do
    settings = Settings.get()

    case StageDesigner.get_state(1, actor: %{role: :stage_designer}) do
      {:ok, state} when not is_nil(state) ->
        url = Enum.find_value(state.history, &image_url(settings, &1))

        status = if settings.enabled, do: state.status, else: :disabled
        {:ok, %{url: url, status: status}}

      {:ok, nil} ->
        {:ok, %{url: nil, status: :idle}}

      {:error, _} ->
        {:ok, %{url: nil, status: :unavailable}}
    end
  rescue
    _ -> {:ok, %{url: nil, status: :unavailable}}
  end

  defp image_url(settings, digest) do
    case Storage.read(settings, digest) do
      {:ok, bytes} -> Storage.url(digest, Image.format(bytes))
      _ -> nil
    end
  end
end
