defmodule Lovelace.StageDesigner.ServiceActor do
  @moduledoc false
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "actor is the stage designer service"

  @impl true
  def match?(%{role: :stage_designer}, _context, _opts), do: true
  def match?(_actor, _context, _opts), do: false
end
