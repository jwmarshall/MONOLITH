defmodule Lovelace.Security.Secret do
  @moduledoc false
  @enforce_keys [:value]
  defstruct [:value]
end

defimpl Inspect, for: Lovelace.Security.Secret do
  def inspect(_, _), do: "#Lovelace.Security.Secret<[REDACTED]>"
end
