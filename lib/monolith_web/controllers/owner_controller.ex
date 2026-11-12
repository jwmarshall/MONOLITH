defmodule MonolithWeb.OwnerController do
  use MonolithWeb, :controller
  alias Monolith.Owner
  alias Monolith.Owner.Actions
  alias Monolith.Security.Vault
  alias MonolithWeb.OwnerReturnPath

  plug :no_cache

  def new(conn, _params) do
    if configuration_status() in [:new, :setup_incomplete],
      do: redirect(conn, to: "/setup"),
      else: unlock_form(conn)
  end

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
            destination =
              OwnerReturnPath.safe(get_session(conn, :owner_return_to)) ||
                Monolith.Onboarding.entry_path()

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
    result =
      case Owner.verify_session(get_session(conn, :owner_session_token)) do
        {:ok, _} -> Owner.lock_all(actor: %{role: :local_owner})
        _ -> {:ok, true}
      end

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
    setup_state = configuration_status()

    background =
      if Vault.open?() do
        case Monolith.StageDesigner.background() do
          {:ok, background} -> background
          {:error, _reason} -> %{url: nil, status: :unavailable}
        end
      else
        %{url: nil, status: :unavailable}
      end

    conn
    |> put_status(status)
    |> put_layout(false)
    |> render(:unlock,
      configured?: setup_state == :configured,
      setup_state: setup_state,
      background: background,
      error?: error?,
      csrf_token: get_csrf_token()
    )
  end

  if Mix.env() == :test do
    defp configuration_status do
      if Vault.enabled?(),
        do: Vault.configuration_status(),
        else: if(match?({:ok, true}, Owner.configured()), do: :configured, else: :new)
    end
  else
    defp configuration_status, do: Vault.configuration_status()
  end
end
