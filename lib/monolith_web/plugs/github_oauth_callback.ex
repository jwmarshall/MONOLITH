defmodule MonolithWeb.Plugs.GitHubOAuthCallback do
  @moduledoc "Consumes GitHub callback secrets before logging, telemetry and parsers."
  import Plug.Conn
  alias Monolith.GitHub.Auth
  alias Monolith.Security.Vault
  alias MonolithWeb.Plugs.SensitivePath

  @issuer "https://github.com/login/oauth"

  def init(opts), do: opts

  def call(conn, _) do
    if SensitivePath.matches?(conn, ["auth", "github", "callback"]),
      do: callback(conn),
      else: conn
  end

  defp callback(conn) do
    result = complete(conn)
    notice = result_notice(result)
    conn = fetch_session(conn)

    conn =
      if notice == "authorized",
        do: delete_session(conn, :github_authorization_result),
        else: put_session(conn, :github_authorization_result, notice)

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
             &(&1 in ["state", "code", "iss", "error", "error_description", "error_uri"])
           ),
         true <- Map.get(params, "iss", @issuer) == @issuer,
         true <- valid_response?(params),
         state when is_binary(state) and byte_size(state) == 43 <- params["state"] do
      conn = fetch_session(conn)
      Vault.with_access(fn -> Auth.complete(get_session(conn, :owner_session_token), params) end)
    else
      nil -> {:error, :unlinked}
      _ -> {:error, :invalid_callback}
    end
  rescue
    _ -> {:error, :invalid_callback}
  catch
    _, _ -> {:error, :invalid_callback}
  end

  defp complete(_), do: {:error, :invalid_callback}

  defp result_notice({:ok, _}), do: "authorized"
  defp result_notice({:error, :unlinked}), do: "authorization_unlinked"
  defp result_notice({:error, :expired}), do: "authorization_unmatched"
  defp result_notice({:error, :denied}), do: "authorization_denied"
  defp result_notice({:error, :invalid_callback}), do: "callback_invalid"
  defp result_notice({:error, :keychain}), do: "keychain_failed"
  defp result_notice({:error, :locked}), do: "locked"
  defp result_notice(_), do: "authorization_failed"

  defp valid_response?(%{"error" => error} = params),
    do: is_binary(error) and byte_size(error) in 1..256 and not Map.has_key?(params, "code")

  defp valid_response?(%{"code" => code} = params),
    do:
      is_binary(code) and byte_size(code) in 1..1024 and
        Enum.all?(Map.keys(params), &(&1 in ["code", "state", "iss"]))

  defp valid_response?(_), do: false
end
