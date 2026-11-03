defmodule LovelaceWeb.OwnerController do
  use LovelaceWeb, :controller
  alias Lovelace.Owner
  alias Lovelace.Owner.Actions
  alias LovelaceWeb.OwnerReturnPath

  plug :no_cache

  def new(conn, _params), do: unlock_form(conn)

  # Refuse ordinary routed credential handling: it would expose parsed passwords
  # to router telemetry. Only the early endpoint boundary may dispatch this action.
  def create(%{private: %{owner_unlock_boundary: true}} = conn, _params) do
    password = Map.get(conn.body_params, "password", "")
    safe_params = Map.take(conn.body_params, ["_csrf_token"])
    conn = %{conn | params: safe_params, body_params: safe_params}
    unlock(conn, password)
  end

  def create(conn, _params), do: unlock_form(conn, 503, true)

  defp unlock(conn, password) do
    conn = no_cache(conn, [])
    client = conn.remote_ip |> :inet.ntoa() |> to_string()

    case Owner.unlock(password, client) do
      {:ok, token} ->
        # Replacing an authenticated browser session also revokes its old token.
        case revoke_current(conn) do
          {:ok, true} ->
            destination = OwnerReturnPath.safe(get_session(conn, :owner_return_to)) || "/"

            conn
            |> configure_session(renew: true)
            |> clear_session()
            |> put_session(:owner_session_token, token)
            |> put_session(:live_socket_id, Actions.topic(Actions.digest(token)))
            |> redirect(to: destination)

          _ ->
            Owner.logout(token)
            unlock_form(conn, 503, true)
        end

      _ ->
        unlock_form(conn, 401, true)
    end
  end

  def delete(conn, _params) do
    result = revoke_current(conn)
    conn = conn |> configure_session(renew: true) |> clear_session()

    case result do
      {:ok, true} -> redirect(conn, to: "/unlock")
      _ -> unlock_form(conn, 503, true)
    end
  end

  defp no_cache(conn, _opts), do: put_resp_header(conn, "cache-control", "no-store")

  defp revoke_current(conn) do
    case get_session(conn, :owner_session_token) do
      nil -> {:ok, true}
      token -> Owner.logout(token)
    end
  end

  defp unlock_form(conn, status \\ 200, error? \\ false) do
    configured? = match?({:ok, true}, Owner.configured())

    background =
      case Lovelace.StageDesigner.background() do
        {:ok, background} -> background
        {:error, _reason} -> %{url: nil, status: :unavailable}
      end

    conn
    |> put_status(status)
    |> put_layout(false)
    |> render(:unlock,
      configured?: configured?,
      background: background,
      error?: error?,
      csrf_token: get_csrf_token()
    )
  end
end
