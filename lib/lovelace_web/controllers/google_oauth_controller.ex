defmodule LovelaceWeb.GoogleOAuthController do
  @moduledoc "Explicit, CSRF-protected connection intent; callback bypasses request instrumentation."
  use LovelaceWeb, :controller
  alias Lovelace.Mail
  alias Lovelace.Mail.{OAuth, Operations}

  def create(conn, _params) do
    workspace = conn.body_params["workspace_id"]
    expected = conn.body_params["expected_account_id"]
    session = get_session(conn, :owner_session_token)

    with {:ok, capability} <- capability(conn.body_params["capability"]),
         {:ok, %{id: ^workspace}} <-
           Lovelace.Workspaces.get_workspace(workspace, actor: conn.assigns.current_actor),
         {:ok, generation} <- expected_account(expected, conn.assigns.current_actor, capability),
         {:ok, state, verifier} <-
           OAuth.begin(workspace, session, expected, capability, generation),
         {:ok, url} <-
           Operations.provider().authorization_url(%{
             state: state,
             verifier: verifier,
             redirect_uri: redirect_uri(),
             capability: capability
           }),
         %URI{scheme: "https", host: "accounts.google.com", userinfo: nil} <- URI.parse(url) do
      conn |> put_resp_header("location", url) |> send_resp(303, "")
    else
      _ ->
        conn
        |> put_flash(
          :error,
          "Google connection is unavailable. Complete the local Google setup first."
        )
        |> redirect(
          to:
            if(conn.body_params["capability"] == "calendar",
              do: "/connections/calendar",
              else: "/connections/gmail"
            )
        )
    end
  end

  defp capability(nil), do: {:ok, :gmail}
  defp capability("gmail"), do: {:ok, :gmail}
  defp capability("calendar"), do: {:ok, :calendar}
  defp capability(_), do: {:error, :invalid_request}

  defp expected_account(value, _, :gmail) when value in [nil, ""], do: {:ok, nil}
  defp expected_account(value, _, :calendar) when value in [nil, ""], do: {:error, :unavailable}

  defp expected_account(id, actor, capability) do
    case Mail.get_account(id, actor: actor) do
      {:ok, %{status: :disconnected}} when capability == :calendar -> {:error, :unavailable}
      {:ok, %{generation: generation}} -> {:ok, generation}
      _ -> {:error, :unavailable}
    end
  end

  def redirect_uri do
    Application.get_env(:lovelace, :gmail, [])
    |> Keyword.get(:redirect_uri, "http://localhost:4000/oauth/google/callback")
  end
end
