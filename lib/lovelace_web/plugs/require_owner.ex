defmodule LovelaceWeb.Plugs.RequireOwner do
  @moduledoc "Fail-closed HTTP boundary for private local-owner routes. Run after fetch_session."
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    case Lovelace.Owner.verify_session(get_session(conn, :owner_session_token)) do
      {:ok, _session} ->
        assign(conn, :current_actor, %{role: :local_owner})

      _ ->
        conn
        |> configure_session(renew: true)
        |> clear_session()
        |> redirect(to: "/unlock")
        |> halt()
    end
  end
end
