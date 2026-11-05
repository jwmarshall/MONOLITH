defmodule LovelaceWeb.GeminiConnectionLiveTest do
  use LovelaceWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Lovelace.Integrations.Google.ClientCredentials
  alias Lovelace.TestSupport.{GeminiVault, OnboardingKeychain}

  setup %{conn: conn} do
    start_supervised!(GeminiVault)
    start_supervised!(OnboardingKeychain)
    previous_google = Application.fetch_env(:lovelace, :google_client_keychain)

    Application.put_env(:lovelace, :google_client_keychain, OnboardingKeychain)

    :ok =
      ClientCredentials.save(
        "synthetic-subnav-client",
        "synthetic-subnav-secret"
      )

    previous = Application.get_env(:lovelace, :gemini_vault)
    Application.put_env(:lovelace, :gemini_vault, GeminiVault)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lovelace, :gemini_vault, previous),
        else: Application.delete_env(:lovelace, :gemini_vault)

      case previous_google do
        {:ok, value} -> Application.put_env(:lovelace, :google_client_keychain, value)
        :error -> Application.delete_env(:lovelace, :google_client_keychain)
      end
    end)

    %{conn: authenticate_owner(conn)}
  end

  test "Connections separates app-wide Gemini from Gmail and uses non-LiveView credential forms",
       %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    view |> element("#show-connections") |> render_click()
    view |> element("#open-connection-gmail") |> render_click()
    assert has_element?(view, "#gmail-connections-heading", "Gmail accounts")
    refute has_element?(view, "#gemini-connection")
    assert :sys.get_state(view.pid).socket.assigns.gemini_status == :unknown
    assert has_element?(view, "#connections-gmail[aria-current=page]")
    view |> element("#connections-gemini") |> render_click()
    render_async(view)
    assert has_element?(view, "#gemini-status", "No API key stored")
    refute has_element?(view, "#connections-panel")
    assert has_element?(view, "#connections-gemini[aria-current=page]")
    assert has_element?(view, "#gemini-key-form[method=post][action='/connections/gemini']")
    refute has_element?(view, "#gemini-key-form[phx-submit], #gemini-key-form[phx-change]")
    assert has_element?(view, "#gemini-api-key[type=password][name=api_key][autocomplete=off]")
    refute has_element?(view, "#gemini-api-key[value]")
    assert has_element?(view, "#gemini-connection", "Saving a key does not generate")
    assert has_element?(view, "#gemini-connection", "Startup generation is disabled")

    assert has_element?(
             view,
             "#gemini-generation-help:not([open]) > summary",
             "Scenery & billing"
           )

    assert has_element?(view, "#gemini-generation-help", "Each request may incur API charges")
    assert has_element?(view, "#gemini-generation-help", "No automatic retries")
    assert has_element?(view, "#gemini-generation-help", "cannot cancel an in-progress request")
    refute has_element?(view, "#gemini-generation-help #gemini-status")

    GeminiVault.put("unused", "synthetic-key-never-rendered")
    view |> element("[phx-click='gemini:check']") |> render_click()
    html = render_async(view)
    assert has_element?(view, "#gemini-status", "API key stored · Google access not verified")
    assert has_element?(view, "#gemini-remove-form[method=post]")
    refute html =~ "synthetic-key-never-rendered"
    refute inspect(:sys.get_state(view.pid).socket.assigns) =~ "synthetic-key-never-rendered"
  end

  test "provider subnav rejects invalid/out-of-view events and returns to the global index",
       %{conn: conn} do
    workspace = Lovelace.Workspaces.create_workspace!("Studio", actor: %{role: :local_owner})
    {:ok, view, _} = live(conn, "/")
    render_click(view, "select_connection", %{"provider" => "gemini"})
    assert has_element?(view, "#home-overview")
    refute has_element?(view, "#connections-subnav")

    view |> element("#show-workspaces") |> render_click()
    view |> element("#open-#{workspace.id}") |> render_click()
    view |> element("#show-connections") |> render_click()
    assert_patch(view, "/connections")
    assert :sys.get_state(view.pid).socket.assigns.selected == nil
    assert has_element?(view, "#connections-overview")
    refute has_element?(view, "#connections-subnav, #back-from-connections")
    view |> element("#open-connection-gmail") |> render_click()
    render_click(view, "select_connection", %{"provider" => "unknown"})
    assert has_element?(view, "#connections-gmail[aria-current=page]")
    render_async(view)
    view |> element("#new-gmail-connection") |> render_click()
    # Same-provider selection cannot discard an open form/draft.
    view |> element("#connections-gmail") |> render_click()
    assert has_element?(view, "#gmail-connection-modal")
    view |> element("#gmail-connection-modal button[type=button]") |> render_click()
    view |> element("#connections-gemini") |> render_click()
    render_async(view)
    assert has_element?(view, "#connections-gemini[aria-current=page]")
    view |> element("#show-connections") |> render_click()
    assert_patch(view, "/connections")
    assert has_element?(view, "#connections-overview")
    refute has_element?(view, "#connections-subnav, #gemini-connection, #connections-panel")
    assert :sys.get_state(view.pid).socket.assigns.selected == nil
    view |> element("#open-connection-gmail") |> render_click()
    assert has_element?(view, "#connections-panel")
    refute has_element?(view, "#gemini-connection, #gmail-connection-modal")
    view |> element("#back-to-connections") |> render_click()
    assert_patch(view, "/connections")
    assert has_element?(view, "#connections-overview")
    refute has_element?(view, "#connections-subnav, #back-from-connections")
    render_patch(view, "/workspaces/#{workspace.id}")
    assert has_element?(view, "#directory-heading", "Studio")
    refute has_element?(view, "#connections-subnav")
  end

  test "unavailable is not disconnected, and post return opens Connections with safe feedback", %{
    conn: conn
  } do
    GeminiVault.fail(:locked)
    {:ok, view, _} = live(conn, "/connections/gemini?gemini=saved")
    render_async(view)
    assert has_element?(view, "#directory-heading", "Connections")
    assert has_element?(view, "#connections-gemini[aria-current=page]")
    refute has_element?(view, "#connections-panel")
    assert has_element?(view, "#gemini-status", "Keychain is locked")
    assert render(view) =~ "Gemini API key saved"
    refute has_element?(view, "#gemini-status", "No API key stored")
  end
end
