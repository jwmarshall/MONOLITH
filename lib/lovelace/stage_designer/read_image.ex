defmodule Lovelace.StageDesigner.ReadImage do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  alias Lovelace.StageDesigner.{Scene, Settings, Storage}

  @impl true
  def run(input, _opts, _context) do
    digest = input.arguments.digest

    with {:ok, true} <- Scene.registered(digest),
         {:ok, bytes} <- Storage.read(Settings.get(), digest) do
      {:ok, bytes}
    else
      _ -> {:error, "Background unavailable"}
    end
  rescue
    _ -> {:error, "Background unavailable"}
  end
end
