defmodule MonolithWeb.OwnerAuth do
  @moduledoc "Verifies owner sessions on mount and before LiveView callbacks, without credential assigns."
  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3]
  alias Monolith.Owner
  alias Monolith.Owner.Actions
  alias Monolith.Security.Vault
  @service [actor: %{role: :owner_auth_service}]

  def on_mount(:require_owner, _params, session, socket) do
    with {:ok, %{digest: digest, expires_at: expires_at}} <-
           Owner.verify_session(session["owner_session_token"]),
         :ok <- track(socket),
         :ok <- subscribe(socket, digest),
         {:ok, _} <- Owner.verify_digest(digest, @service) do
      if connected?(socket) do
        delay = max(DateTime.diff(expires_at, DateTime.utc_now(), :millisecond), 0)
        Process.send_after(self(), {:owner_session_expired, digest}, delay)
      end

      socket =
        socket
        |> assign(:current_actor, %{role: :local_owner})
        |> attach_hook(:owner_session_event, :handle_event, fn _event, _params, socket ->
          recheck(socket, digest)
        end)
        |> attach_hook(:owner_session_params, :handle_params, fn _params, _uri, socket ->
          recheck(socket, digest)
        end)
        |> attach_hook(:owner_session_async, :handle_async, fn _name, _result, socket ->
          recheck(socket, digest)
        end)
        |> attach_hook(:owner_session_info, :handle_info, fn
          {:owner_session_expired, ^digest}, socket -> locked(socket)
          %Phoenix.Socket.Broadcast{event: "disconnect"}, socket -> locked(socket)
          _message, socket -> recheck(socket, digest)
        end)

      {:cont, socket}
    else
      _ -> locked(socket)
    end
  end

  defp track(socket) do
    if connected?(socket) do
      case Vault.track() do
        {:ok, _lease} -> :ok
        _ -> {:error, :locked}
      end
    else
      :ok
    end
  end

  defp subscribe(socket, digest) do
    if connected?(socket),
      do: Phoenix.PubSub.subscribe(Monolith.PubSub, Actions.topic(digest)),
      else: :ok
  end

  defp recheck(socket, digest) do
    case Owner.verify_digest(digest, @service) do
      {:ok, _} -> {:cont, socket}
      _ -> locked(socket)
    end
  end

  defp locked(socket), do: {:halt, redirect(socket, to: "/unlock")}
end
