defmodule Lovelace.Workspaces.LocalOwner do
  @moduledoc "Checks the explicit local-owner capability, without coercing string roles."
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "actor is the local owner"

  @impl true
  def match?(%{role: :local_owner}, _context, _opts), do: true
  def match?(_actor, _context, _opts), do: false
end
