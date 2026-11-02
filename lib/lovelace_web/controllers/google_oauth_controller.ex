defmodule LovelaceWeb.GoogleOAuthController do
  @moduledoc "Explicit, CSRF-protected connection intent; callback bypasses request instrumentation."
  use LovelaceWeb, :controller
  alias Lovelace.Mail
  alias Lovelace.Mail.{OAuth, Operations}

  def create(conn, _params) do
    workspace = conn.body_params["workspace_id"]
    expected = conn.body_params["expected_account_id"]
    session = get_session(conn, :owner_session_token)

    with {:ok, _} <-
           Lovelace.Workspaces.get_workspace(workspace, actor: conn.assigns.current_actor),
         :ok <- expected_account(expected, conn.assigns.current_actor),
         {:ok, state, verifier} <- OAuth.begin(workspace, session, expected),
         {:ok, url} <-
           Operations.provider().authorization_url(%{
             state: state,
             verifier: verifier,
             redirect_uri: redirect_uri()
           }),
         %URI{scheme: "https", host: "accounts.google.com", userinfo: nil} <- URI.parse(url) do
      conn |> put_resp_header("location", url) |> send_resp(303, "")
    else
      _ ->
        conn
        |> put_flash(
          :error,
          "Gmail connection is unavailable. Complete the local Google setup first."
        )
        |> redirect(to: "/")
    end
  end

  defp expected_account(value, _) when value in [nil, ""], do: :ok

  defp expected_account(id, actor) do
    case Mail.get_account(id, actor: actor) do
      {:ok, _} -> :ok
      _ -> {:error, :unavailable}
    end
  end

  def redirect_uri do
    Application.get_env(:lovelace, :gmail, [])
    |> Keyword.get(:redirect_uri, "http://localhost:4000/oauth/google/callback")
  end
end
