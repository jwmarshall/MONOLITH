defmodule MonolithWeb.SceneConfirmation do
  @moduledoc "Web signing adapter for the application-owned scenery confirmation capability."
  @behaviour Monolith.StageDesigner.Confirmation

  @salt "scene-generation-v1"

  @impl true
  def sign(snapshot, _options) do
    {:ok, Phoenix.Token.sign(MonolithWeb.Endpoint, @salt, snapshot)}
  rescue
    _ -> {:error, :unavailable}
  end

  @impl true
  def verify(token, _options) do
    case Phoenix.Token.verify(MonolithWeb.Endpoint, @salt, token, max_age: 600) do
      {:ok, snapshot} when is_map(snapshot) -> {:ok, snapshot}
      _ -> {:error, :invalid_confirmation}
    end
  rescue
    _ -> {:error, :invalid_confirmation}
  end
end
