defmodule LovelaceWeb.OwnerReturnPath do
  @moduledoc false

  # Only server-observed GET navigation may supply a destination, never unlock params.
  def from_request(%{method: "GET", request_path: path, query_string: query} = conn) do
    if Map.get(conn.private, :owner_request_method, "GET") == "GET" do
      safe(if(query == "", do: path, else: path <> "?" <> query))
    end
  end

  def from_request(_conn), do: nil

  def safe(destination) when is_binary(destination) and byte_size(destination) <= 2048 do
    with true <- String.valid?(destination),
         false <- unsafe_characters?(destination),
         [path | _] <- String.split(destination, "?", parts: 2),
         true <- Regex.match?(~r{\A/(?:[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*)?\z}, path),
         %URI{scheme: nil, host: nil, fragment: nil} <- URI.parse(destination),
         %{phoenix_live_view: {LovelaceWeb.HomeLive, _, _, %{name: :owner}}, pipe_through: pipes} <-
           Phoenix.Router.route_info(LovelaceWeb.Router, "GET", path, "localhost"),
         true <- :owner in pipes do
      destination
    else
      _ -> nil
    end
  end

  def safe(_destination), do: nil

  # Check encoded characters too; route matching alone is not redirect validation.
  defp unsafe_characters?(destination) do
    decoded = URI.decode(destination)

    not String.valid?(decoded) or String.contains?(destination, " ") or
      Regex.match?(~r/[\\\p{Cc}]/u, decoded)
  end
end
