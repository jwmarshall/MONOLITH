defmodule MonolithWeb.Plugs.RequireOwner do
  @moduledoc "Fail-closed HTTP boundary for private local-owner routes. Run after fetch_session."
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]
  alias Monolith.Owner
  alias Monolith.Security.Vault
  alias MonolithWeb.OwnerReturnPath
  alias MonolithWeb.Plugs.OwnerRequest

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    token = get_session(conn, :owner_session_token)

    with {:ok, _session} <- Owner.verify_session(token),
         {:ok, lease} <- Vault.track(),
         :ok <- OwnerRequest.retain(lease) do
      conn
      |> assign(:current_actor, %{role: :local_owner})
      |> register_before_send(&recheck(&1, token))
    else
      _ ->
        destination = OwnerReturnPath.from_request(conn)

        conn
        |> configure_session(renew: true)
        |> clear_session()
        |> put_session(:owner_return_to, destination)
        |> redirect(to: "/unlock")
        |> halt()
    end
  end

  defp recheck(response, token) do
    case Owner.verify_session(token) do
      {:ok, _} -> response
      _ -> locked_response(response)
    end
  end

  defp locked_response(conn) do
    conn =
      conn
      |> configure_session(renew: true)
      |> clear_session()
      |> delete_resp_header("content-length")
      |> delete_resp_header("content-disposition")
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("location", "/unlock")

    %{conn | status: 302, resp_body: ""}
  end
end
