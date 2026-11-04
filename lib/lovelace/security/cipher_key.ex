defmodule Lovelace.Security.CipherKey do
  @moduledoc false
  @enforce_keys [:value]
  defstruct [:value]

  def new!(value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, value) do
      %__MODULE__{value: value}
    else
      raise ArgumentError, "Invalid database key"
    end
  end
end

defimpl Inspect, for: Lovelace.Security.CipherKey do
  def inspect(_, _), do: "#Lovelace.Security.CipherKey<[REDACTED]>"
end

defimpl String.Chars, for: Lovelace.Security.CipherKey do
  def to_string(%{value: value}), do: "\"x'" <> value <> "'\""
end
