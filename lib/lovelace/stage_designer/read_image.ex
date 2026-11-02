defmodule Lovelace.StageDesigner.ReadImage do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  alias Lovelace.StageDesigner
  alias Lovelace.StageDesigner.{Settings, Storage}

  @impl true
  def run(input, _opts, _context) do
    digest = input.arguments.digest

    with {:ok, state} when not is_nil(state) <-
           StageDesigner.get_state(1, actor: %{role: :stage_designer}),
         true <- digest in state.history,
         {:ok, bytes} <- Storage.read(Settings.get(), digest) do
      {:ok, bytes}
    else
      _ -> {:error, "Background unavailable"}
    end
  rescue
    _ -> {:error, "Background unavailable"}
  end
end
