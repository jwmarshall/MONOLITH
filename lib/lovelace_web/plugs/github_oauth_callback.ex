defmodule LovelaceWeb.Plugs.GitHubOAuthCallback do
  @moduledoc "Consumes GitHub callback secrets before logging, telemetry and parsers."
  import Plug.Conn
  alias Lovelace.GitHub.Auth
  alias Lovelace.Security.Vault
  alias LovelaceWeb.Plugs.SensitivePath

  def init(opts), do: opts

  def call(conn, _) do
    if SensitivePath.matches?(conn, ["auth", "github", "callback"]),
      do: callback(conn),
      else: conn
  end

  defp callback(conn) do
    result = complete(conn)
    notice = if match?({:ok, _}, result), do: "authorized", else: "access_failed"

    %{conn | query_string: "", params: %{}, query_params: %{}, body_params: %{}}
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("content-security-policy", "default-src 'none'; frame-ancestors 'none'")
    |> put_resp_header("location", "/connections/github?github=" <> notice)
    |> send_resp(303, "")
    |> halt()
  end

  defp complete(%{method: "GET", query_string: query} = conn) when byte_size(query) <= 8192 do
    pairs = Enum.to_list(URI.query_decoder(query))
    params = Map.new(pairs)

    with true <- length(pairs) == map_size(params),
         true <-
           Enum.all?(
             Map.keys(params),
             &(&1 in ["state", "code", "error", "error_description", "error_uri"])
           ),
         state when is_binary(state) and byte_size(state) == 43 <- params["state"],
         true <- valid_response?(params) do
      conn = fetch_session(conn)
      Vault.with_access(fn -> Auth.complete(get_session(conn, :owner_session_token), params) end)
    else
      _ -> {:error, :invalid_callback}
    end
  rescue
    _ -> {:error, :invalid_callback}
  catch
    _, _ -> {:error, :invalid_callback}
  end

  defp complete(_), do: {:error, :invalid_callback}

  defp valid_response?(%{"error" => error} = params),
    do: is_binary(error) and byte_size(error) in 1..256 and not Map.has_key?(params, "code")

  defp valid_response?(%{"code" => code} = params),
    do: is_binary(code) and byte_size(code) in 1..1024 and map_size(params) == 2

  defp valid_response?(_), do: false
end
