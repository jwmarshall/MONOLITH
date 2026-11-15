defmodule Monolith.Caching.PolicyReader do
  @moduledoc false
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "actor reads application cache policy"

  @impl true
  def match?(%{role: :cache_policy}, _context, _opts), do: true
  def match?(_actor, _context, _opts), do: false
end
