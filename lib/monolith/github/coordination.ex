defmodule Monolith.GitHub.Coordination do
  @moduledoc """
  The single coordination owner for client replacement, account/installation state and
  rotating credentials. State sections never hold provider HTTP. Per-connection refresh
  exclusion spans reservation, HTTP and fenced completion; state is always acquired
  inside that exclusion, never the reverse.
  """

  def state(fun), do: serial(:state, fun)
  def credential(connection_id, fun), do: serial({:refresh, connection_id}, fun)

  defp serial(key, fun), do: :global.trans({{__MODULE__, key}, self()}, fun, [node()])
end
