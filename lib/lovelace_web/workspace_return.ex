defmodule LovelaceWeb.WorkspaceReturn do
  @moduledoc false
  @behaviour Plug

  import Plug.Conn
  alias LovelaceWeb.OwnerReturnPath

  @session_key :workspace_return
  @lifetime_seconds 60

  @impl true
  def init(operation), do: operation

  @impl true
  def call(conn, :capture) do
    conn = fetch_session(conn)
    token = get_session(conn, :owner_session_token)
    register_before_send(conn, &record(&1, token))
  end

  def call(conn, :consume) do
    if conn.method == "GET" and Map.get(conn.private, :owner_request_method, "GET") == "GET" do
      marker = get_session(conn, @session_key)
      destination = OwnerReturnPath.from_request(conn)
      token = get_session(conn, :owner_session_token)

      conn
      |> delete_session(@session_key)
      |> put_private(:workspace_return_consumed, not is_nil(marker))
      |> assign(:workspace_return, matches?(marker, destination, token))
    else
      assign(conn, :workspace_return, false)
    end
  end

  def live_session(conn), do: %{"workspace_return" => conn.assigns[:workspace_return] == true}

  defp record(conn, token) do
    if conn.status in [302, 303] do
      conn = delete_session(conn, @session_key)

      # An already-consumed return must not follow a static onboarding redirect onward.
      with false <- conn.private[:workspace_return_consumed] == true,
           true <- is_binary(token) and byte_size(token) > 0,
           ^token <- get_session(conn, :owner_session_token),
           [location] <- get_resp_header(conn, "location"),
           destination when is_binary(destination) <- OwnerReturnPath.safe(location) do
        put_session(conn, @session_key, %{
          "destination" => destination,
          "owner_digest" => digest(token),
          "expires_at" => System.system_time(:second) + @lifetime_seconds
        })
      else
        _ -> conn
      end
    else
      conn
    end
  end

  defp matches?(
         %{
           "destination" => destination,
           "owner_digest" => owner_digest,
           "expires_at" => expires_at
         },
         destination,
         token
       )
       when is_binary(destination) and is_binary(token) and byte_size(token) > 0 and
              is_integer(expires_at) do
    now = System.system_time(:second)
    expires_at > now and expires_at <= now + @lifetime_seconds and owner_digest == digest(token)
  end

  defp matches?(_, _, _), do: false

  defp digest(token), do: :crypto.hash(:sha256, token) |> Base.url_encode64(padding: false)
end
