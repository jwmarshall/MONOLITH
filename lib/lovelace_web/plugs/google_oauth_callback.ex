defmodule LovelaceWeb.Plugs.GoogleOAuthCallback do
  @moduledoc "Consumes OAuth before Phoenix instrumentation; the documented stock Bandit exception remains."
  import Plug.Conn
  alias Lovelace.Mail
  alias Lovelace.Mail.{ConnectionDiagnostics, Connections, OAuth, Operations}
  alias LovelaceWeb.Plugs.SensitivePath
  @owner %{role: :local_owner}

  def init(opts), do: opts

  def call(conn, _) do
    if SensitivePath.matches?(conn, ["oauth", "google", "callback"]),
      do: callback(conn),
      else: conn
  end

  defp callback(conn) do
    result = complete(conn)
    conn = %{conn | query_string: "", params: %{}, query_params: %{}}

    target =
      case result do
        {:ok, workspace} -> "/?gmail=connected&workspace=" <> workspace
        {:error, failure} -> ConnectionDiagnostics.failure_path(failure)
      end

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("content-security-policy", "default-src 'none'; frame-ancestors 'none'")
    |> put_resp_header("location", target)
    |> send_resp(303, "")
    |> halt()
  end

  defp complete(%{method: "GET", query_string: query} = conn) when byte_size(query) <= 8192 do
    conn = fetch_session(conn)
    session = get_session(conn, :owner_session_token)
    params = URI.decode_query(query)

    with {:ok, _} <- step(:session, fn -> Lovelace.Owner.verify_session(session) end),
         {:ok, state} <- step(:state, fn -> required(params, "state", 128) end),
         {:ok, attempt} <- step(:state, fn -> OAuth.take(state, session) end),
         :ok <- step(:consent, fn -> consent(params) end),
         {:ok, code} <- step(:code, fn -> required(params, "code", 4096) end),
         {:ok, tokens} <-
           step(:token_exchange, fn ->
             Operations.provider().exchange_code(
               code,
               attempt.verifier,
               LovelaceWeb.GoogleOAuthController.redirect_uri()
             )
           end),
         {:ok, identity} <-
           step(:identity, fn -> Operations.provider().identity(tokens.access_token) end),
         :ok <-
           step(:account_binding, fn ->
             same_account(attempt.expected_account_id, identity.subject)
           end),
         {:ok, refresh} <- step(:refresh_token, fn -> refresh_token(tokens, identity.subject) end),
         {:ok, _} <- step(:session, fn -> Lovelace.Owner.verify_session(session) end),
         {:ok, _} <-
           step(:connection, fn -> Connections.accept(attempt.workspace_id, identity, refresh) end) do
      {:ok, attempt.workspace_id}
    end
  rescue
    _ -> ConnectionDiagnostics.failure(:callback, :unexpected)
  catch
    _, _ -> ConnectionDiagnostics.failure(:callback, :unexpected)
  end

  defp complete(_), do: ConnectionDiagnostics.failure(:callback, :invalid_callback)
  defp step(stage, fun), do: ConnectionDiagnostics.step(stage, fun)

  defp consent(params), do: if(is_nil(params["error"]), do: :ok, else: {:error, :denied})

  defp required(params, key, max) do
    case params[key] do
      value when is_binary(value) and byte_size(value) >= 1 and byte_size(value) <= max ->
        {:ok, value}

      _ ->
        {:error, :invalid_callback}
    end
  end

  defp same_account(expected, _) when expected in [nil, ""], do: :ok

  defp same_account(id, subject) do
    case Mail.get_account(id, actor: @owner) do
      {:ok, %{subject: ^subject}} -> :ok
      _ -> {:error, :wrong_account}
    end
  end

  defp refresh_token(%{refresh_token: token}, _) when is_binary(token) and byte_size(token) > 0,
    do: {:ok, token}

  defp refresh_token(_, subject) do
    with {:ok, %{id: id}} <- Mail.find_account(subject, actor: @owner),
         {:ok, token} <- Operations.vault().get(id) do
      {:ok, token}
    else
      _ -> {:error, :reconnect}
    end
  end
end
