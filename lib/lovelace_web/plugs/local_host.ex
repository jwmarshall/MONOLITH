defmodule LovelaceWeb.Plugs.LocalHost do
  @moduledoc "Reject DNS-rebinding Host values; loopback listeners alone do not authenticate HTTP hosts."
  import Plug.Conn
  def init(opts), do: opts
  def call(%{host: "localhost"} = conn, _), do: conn

  def call(%{method: "GET", host: host} = conn, _) when host in ["127.0.0.1", "[::1]", "::1"] do
    port = LovelaceWeb.Endpoint.config(:http) |> Keyword.fetch!(:port)

    conn
    |> put_resp_header("location", "http://localhost:#{port}/")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(303, "")
    |> halt()
  end

  def call(conn, _), do: conn |> send_resp(400, "Invalid local host") |> halt()
end
