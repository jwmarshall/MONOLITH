defmodule Monolith.Security.Secret do
  @moduledoc false
  @enforce_keys [:value]
  defstruct [:value]
end

defimpl Inspect, for: Monolith.Security.Secret do
  def inspect(_, _), do: "#Monolith.Security.Secret<[REDACTED]>"
end
