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

        # A persisted reservation is not proof a task is still alive (possibly in
        # another BEAM). Never announce active preparation from durable state alone.
        status = if settings.enabled, do: public_status(state.status), else: :disabled
        {:ok, %{url: url, status: status}}

      {:ok, nil} ->
        {:ok, %{url: nil, status: :idle}}

      {:error, _} ->
        {:ok, %{url: nil, status: :unavailable}}
    end
  rescue
    _ -> {:ok, %{url: nil, status: :unavailable}}
  end

  defp public_status(:generating), do: :uncertain
  defp public_status(status), do: status

  defp image_url(settings, digest) do
    case Storage.read(settings, digest) do
      {:ok, bytes} -> Storage.url(digest, Image.format(bytes))
      _ -> nil
    end
  end
end
