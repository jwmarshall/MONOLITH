defmodule MonolithWeb.ConnectionsLiveTest do
  use MonolithWeb.ConnCase, async: false
  use Oban.Testing, repo: Monolith.Repo, engine: Oban.Engines.Lite

  import Phoenix.LiveViewTest
  import Monolith.TestSupport.BackgroundWork, only: [complete: 1]

  alias Ash.Resource.Info
  alias Monolith.Integrations.Google.ClientCredentials
  alias Monolith.Mail
  alias Monolith.Mail.{Account, ViewData}
  alias Monolith.TestSupport.{GeminiVault, OnboardingKeychain}
  alias Monolith.Workspaces

  @owner %{role: :local_owner}

  defmodule ObservedGoogleKeychain do
    @moduledoc false

    def get(account, service) do
      OnboardingKeychain.record(:client_read)
      OnboardingKeychain.get(account, service)
    end

    defdelegate put(account, value, service), to: OnboardingKeychain
    defdelegate delete(account, service), to: OnboardingKeychain
  end

  defmodule FakeIO do
    @moduledoc false

    def start_link(owner) do
      Agent.start_link(fn -> %{owner: owner, calls: [], blocked: [], get_results: %{}} end,
        name: __MODULE__
      )
    end

    def child_spec(owner), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [owner]}}

    def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))
    def block(operation), do: Agent.update(__MODULE__, &%{&1 | blocked: [operation]})
    def unblock, do: Agent.update(__MODULE__, &%{&1 | blocked: []})

    def get_result(id, result),
      do: Agent.update(__MODULE__, &put_in(&1, [:get_results, id], result))

    def get(id) do
      result = Agent.get(__MODULE__, &Map.get(&1.get_results, id, {:ok, "refresh:" <> id}))
      result = record({:get, id}, result)

      case result do
        {:raise, message} -> raise message
        {:throw, value} -> throw(value)
        _ -> result
      end
    end

    def put(id, _token), do: record({:put, id}, :ok)
    def delete(id), do: record({:delete, id}, :ok)

    @spec refresh(binary()) :: {:ok, Monolith.Google.OAuthProvider.tokens()}
    def refresh("refresh:" <> id),
      do: record({:refresh, id}, {:ok, %{access_token: "access:" <> id, expires_in: 3600}})

    def revoke("refresh:" <> id), do: record({:revoke, id}, :ok)

    @spec inbox(binary(), Monolith.Mail.Provider.page_token()) ::
            {:ok, Monolith.Mail.Provider.page()}
    def inbox("access:" <> id, token),
      do: record({:inbox, id, token}, page(id))

    @spec search(binary(), binary(), Monolith.Mail.Provider.page_token()) ::
            {:ok, Monolith.Mail.Provider.page()}
    def search("access:" <> id, query, token),
      do: record({:search, id, query, token}, page(id))

    @spec thread(binary(), binary()) :: {:ok, Monolith.Mail.Provider.thread()}
    def thread("access:" <> id, thread_id),
      do:
        record(
          {:thread, id, thread_id},
          {:ok,
           %{
             id: thread_id,
             messages: [
               %{
                 id: "synthetic-message",
                 from: "sender@example.test",
                 to: "owner@example.test",
                 date: "Yesterday",
                 subject: "Synthetic conversation",
                 text: "Synthetic message",
                 attachments: []
               }
             ]
           }}
        )

    defp page(id) do
      {:ok,
       %{
         threads: [
           %{
             id: "shared-thread",
             subject: "Synthetic inbox #{id}",
             from: "sender@example.test",
             snippet: "Synthetic snippet",
             date: "Yesterday",
             unread: false
           }
         ],
         next_page_token: nil
       }}
    end

    defp record(call, result) do
      {owner, blocked} =
        Agent.get_and_update(__MODULE__, fn state ->
          {{state.owner, elem(call, 0) in state.blocked}, %{state | calls: [call | state.calls]}}
        end)

      if blocked do
        send(owner, {:fake_blocked, self(), call})

        receive do
          :release -> result
        after
          5_000 -> {:error, :provider_error}
        end
      else
        result
      end
    end
  end

  setup %{conn: conn} do
    start_supervised!({FakeIO, self()})
    fake_gemini_vault()
    start_supervised!(OnboardingKeychain)
    previous_google = Application.fetch_env(:monolith, :google_client_keychain)

    Application.put_env(:monolith, :google_client_keychain, OnboardingKeychain)

    :ok =
      ClientCredentials.save(
        "synthetic-connection-client",
        "synthetic-connection-secret"
      )

    previous_provider = Application.fetch_env(:monolith, :gmail_provider)
    previous_vault = Application.fetch_env(:monolith, :gmail_vault)
    Application.put_env(:monolith, :gmail_provider, FakeIO)
    Application.put_env(:monolith, :gmail_vault, FakeIO)

    on_exit(fn ->
      restore(:gmail_provider, previous_provider)
      restore(:gmail_vault, previous_vault)
      restore(:google_client_keychain, previous_google)
    end)

    workspace = Workspaces.create_workspace!("Alpha workspace", actor: @owner)
    other = Workspaces.create_workspace!("Beta workspace", actor: @owner)
    healthy = account("alpha-healthy")

    reconnect =
      account("alpha-reconnect") |> status(%{status: :reconnect, last_error: :reconnect})

    limited = account("beta-limited") |> status(%{last_error: :rate_limited})
    available = account("unattached")

    for {space, connection} <- [
          {workspace, healthy},
          {workspace, reconnect},
          {other, healthy},
          {other, limited}
        ] do
      # Reconnect fixtures represent links established before access expired.
      Mail.attach_account!(%{workspace_id: space.id, account_id: connection.id}, actor: @owner)
    end

    %{
      conn: authenticate_owner(conn),
      workspace: workspace,
      other: other,
      healthy: healthy,
      reconnect: reconnect,
      limited: limited,
      available: available
    }
  end

  test "adding Gmail requires available Google client settings even with existing accounts",
       ctx do
    for failure <- [:not_found, :locked, :unavailable] do
      OnboardingKeychain.fail(failure)
      {:ok, view, _} = live(ctx.conn, ~p"/connections/gmail")
      complete(view)
      assert has_element?(view, "#new-gmail-connection[disabled]")
      assert has_element?(view, "#gmail-google-prerequisite a[href='/connections/google']")
      render_click(view, "mail:new_connection")
      refute has_element?(view, "#gmail-connection-modal")

      OnboardingKeychain.fail(nil)
      view |> element("#gmail-google-prerequisite a") |> render_click()
      complete(view)
      view |> element("#connections-gmail") |> render_click()
      complete(view)
      assert has_element?(view, "#new-gmail-connection:not([disabled])")
      view |> element("#new-gmail-connection") |> render_click()
      assert has_element?(view, "#gmail-connection-modal #mail-workspace-new")
      view |> element("#gmail-connection-modal button[type=button]") |> render_click()
      assert FakeIO.calls() == []
    end
  end

  test "Google panel recovers local client failures without changing retained account access",
       ctx do
    accounts = account_state()
    memberships = membership_state(ctx)

    for {failure, expected, signal, label} <- [
          {:not_found, :not_connected, "offline", "No client settings"},
          {:locked, :locked, "warning", "locked"},
          {:unavailable, :unavailable, "warning", "unavailable"},
          {:invalid, :invalid, "warning", "invalid"}
        ] do
      case failure do
        :not_found ->
          assert :ok = ClientCredentials.delete()

        :invalid ->
          Agent.update(OnboardingKeychain, fn state ->
            %{
              state
              | items: Map.new(state.items, fn {key, _} -> {key, "invalid-client-json"} end)
            }
          end)

        reason ->
          OnboardingKeychain.fail(reason)
      end

      {:ok, view, _} = live(ctx.conn, ~p"/connections/google")
      html = complete(view)
      assert {:ok, ^expected} = Monolith.Google.client_status(actor: @owner)
      assert has_element?(view, "#google-credential-signal[data-state='#{signal}']")
      assert has_element?(view, "#google-status", label)
      assert has_element?(view, "#google-client-form button[type=submit]")

      assert has_element?(
               view,
               "#google-connection button[phx-click='google:check']:not([disabled])"
             )

      refute has_element?(view, "#google-connection a[href='/connections/gmail']")
      refute html =~ "invalid-client-json"
      assert account_state() == accounts
      assert membership_state(ctx) == memberships

      OnboardingKeychain.fail(nil)

      if failure in [:not_found, :invalid] do
        assert {:ok, true} =
                 Monolith.Google.save_client_credentials(
                   "synthetic-recovered-client",
                   "synthetic-recovered-secret",
                   actor: @owner
                 )
      end

      view |> element("#google-connection button[phx-click='google:check']") |> render_click()
      html = complete(view)
      assert has_element?(view, "#google-credential-signal[data-state=ready]")
      assert has_element?(view, "#google-connection a[href='/connections/gmail']")

      for private <- [
            "synthetic-connection-client",
            "synthetic-connection-secret",
            "synthetic-recovered-client",
            "synthetic-recovered-secret"
          ] do
        refute html =~ private
        refute inspect(socket(view).assigns) =~ private
      end

      view |> element("#google-connection a[href='/connections/gmail']") |> render_click()
      complete(view)
      assert has_element?(view, "#new-gmail-connection:not([disabled])")
      view |> element("#new-gmail-connection") |> render_click()
      assert has_element?(view, "#gmail-connection-modal #mail-workspace-new")
      assert has_element?(view, "#connection-account-#{ctx.reconnect.id}")
      assert account_state() == accounts
      assert membership_state(ctx) == memberships
      assert FakeIO.calls() == []
    end
  end

  test "Google saved POST return rechecks credentials instead of trusting its success query",
       ctx do
    accounts = account_state()
    memberships = membership_state(ctx)
    client = "synthetic-post-client"
    secret = "synthetic-post-secret"

    response =
      submit_credentials(ctx.conn, "/connections/google", %{
        "client_id" => client,
        "client_secret" => secret
      })

    target = redirected_to(response, 303)
    assert target == "/connections/google?google=saved"
    assert {:ok, %{client_id: ^client, client_secret: ^secret}} = ClientCredentials.read()
    OnboardingKeychain.fail(:not_found)
    {:ok, view, _} = live(recycle(response), target)
    html = complete(view)
    assert has_element?(view, "#google-credential-signal[data-state=offline]")
    refute has_element?(view, "#google-connection a[href='/connections/gmail']")
    view |> element("#connections-gmail") |> render_click()
    complete(view)
    assert has_element?(view, "#new-gmail-connection[disabled]")
    render_click(view, "mail:new_connection")
    refute has_element?(view, "#gmail-connection-modal")

    for private <- [client, secret] do
      refute html =~ private
      refute inspect(socket(view).assigns) =~ private
      refute inspect(get_session(response)) =~ private
    end

    OnboardingKeychain.fail(nil)
    view |> element("#connections-google") |> render_click()
    complete(view)
    view |> element("#google-connection button[phx-click='google:check']") |> render_click()
    complete(view)
    assert has_element?(view, "#google-credential-signal[data-state=ready]")
    assert account_state() == accounts
    assert membership_state(ctx) == memberships
    assert FakeIO.calls() == []
  end

  test "failed Google replacement returns to usable stored settings without granting access",
       ctx do
    accounts = account_state()
    memberships = membership_state(ctx)
    private = "synthetic-invalid-post-secret with spaces"

    response =
      submit_credentials(ctx.conn, "/connections/google", %{
        "client_id" => "synthetic-rejected-client",
        "client_secret" => private
      })

    target = redirected_to(response, 303)
    assert target == "/connections/google?google=failed"
    {:ok, view, _} = live(recycle(response), target)
    html = complete(view)
    assert {:ok, :stored} = Monolith.Google.client_status(actor: @owner)

    assert {:ok,
            %{
              client_id: "synthetic-connection-client",
              client_secret: "synthetic-connection-secret"
            }} = ClientCredentials.read()

    assert OnboardingKeychain.writes() == 1
    assert has_element?(view, "#google-credential-signal[data-state=ready]")
    assert has_element?(view, "#google-client-form button[type=submit]")
    refute has_element?(view, "#google-client-form input[value]:not([type=hidden])")
    refute html =~ private
    refute inspect(socket(view).assigns) =~ private
    view |> element("#google-connection a[href='/connections/gmail']") |> render_click()
    complete(view)
    view |> element("#new-gmail-connection") |> render_click()
    assert has_element?(view, "#gmail-connection-modal #mail-workspace-new")
    assert account_state() == accounts
    assert membership_state(ctx) == memberships
    assert FakeIO.calls() == []
  end

  test "failed Gemini POST preserves the previous key and admits only a local recovery check",
       ctx do
    old_key = "synthetic-retained-gemini-key"
    new_key = "synthetic-rejected-gemini-key"
    assert {:ok, true} = Monolith.StageDesigner.save_gemini_key(old_key, actor: @owner)
    scenes = Monolith.StageDesigner.list_scenes!(%{}, actor: @owner)
    preference = Monolith.StageDesigner.startup_preference!(actor: @owner)
    GeminiVault.fail(:unavailable)

    response =
      submit_credentials(ctx.conn, "/connections/gemini", %{
        "operation" => "save",
        "api_key" => new_key
      })

    target = redirected_to(response, 303)
    assert target == "/connections/gemini?gemini=failed"
    {:ok, view, _} = live(recycle(response), target)
    html = complete(view)
    assert {:ok, :unavailable} = Monolith.StageDesigner.gemini_connection_status(actor: @owner)
    assert has_element?(view, "#gemini-credential-signal[data-state=warning]")

    assert has_element?(
             view,
             "#gemini-connection button[phx-click='gemini:check']:not([disabled])"
           )

    refute has_element?(view, "#gemini-remove-form, #scene-generation-modal")
    refute has_element?(view, "#gemini-api-key[value]")

    for private <- [old_key, new_key] do
      refute html =~ private
      refute inspect(socket(view).assigns) =~ private
      refute inspect(get_session(response)) =~ private
    end

    GeminiVault.fail(nil)
    view |> element("#gemini-connection button[phx-click='gemini:check']") |> render_click()
    complete(view)
    assert has_element?(view, "#gemini-credential-signal[data-state=ready]")
    assert has_element?(view, "#gemini-remove-form button[data-confirm]")
    assert {:ok, ^old_key} = GeminiVault.get("unused")
    assert Monolith.StageDesigner.list_scenes!(%{}, actor: @owner) == scenes
    assert Monolith.StageDesigner.startup_preference!(actor: @owner) == preference
    assert all_enqueued(queue: :gemini) == []
    assert FakeIO.calls() == []
  end

  test "out-of-view Google key checks cannot read credentials even with forged payloads", ctx do
    Application.put_env(:monolith, :google_client_keychain, ObservedGoogleKeychain)
    {:ok, view, _} = live(ctx.conn, ~p"/")
    complete(view)
    before = OnboardingKeychain.calls()

    for path <- ["/", "/workspaces/#{ctx.workspace.id}", "/connections", "/connections/gemini"] do
      render_patch(view, path)
      complete(view)
      reads = OnboardingKeychain.calls()

      for params <- [
            %{},
            %{"provider" => "google"},
            %{"id" => ctx.healthy.id, "provider" => %{"google" => true}}
          ] do
        render_click(view, "google:check", params)
      end

      complete(view)
      assert OnboardingKeychain.calls() == reads
      refute has_element?(view, "#google-connection")
    end

    assert OnboardingKeychain.calls() == before

    render_patch(view, "/connections/google")
    complete(view)
    assert has_element?(view, "#google-credential-signal[data-state=ready]")
    assert :client_read in OnboardingKeychain.calls()
    assert FakeIO.calls() == []
  end

  test "quiet health distinguishes unknown from last-known success without hiding recovery",
       ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/connections/gmail")
    complete(view)
    signal = "#connection-signal-#{ctx.healthy.id}"

    assert has_element?(
             view,
             "#{signal}[data-state=unknown] .status-label",
             "no successful Gmail check yet"
           )

    status(ctx.healthy, %{last_success_at: ~U[2026-11-01 12:00:00Z]})
    broadcast(ctx.healthy.id)
    assert has_element?(view, "#{signal}[data-state=ready]")
    assert has_element?(view, "#{signal} .status-label", "2026-11-01 12:00 UTC")

    status(ctx.healthy, %{last_error: :keychain})
    broadcast(ctx.healthy.id)
    assert has_element?(view, "#{signal}[data-state=warning] .status-label", "Keychain")

    assert has_element?(
             view,
             "#connection-signal-#{ctx.reconnect.id} .status-label",
             "reconnecting"
           )

    assert FakeIO.calls() == []
  end

  test "workspace cards expose their own problem metadata and a separate visible Rename", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    view |> element("#show-workspaces") |> render_click()
    alpha = "#workspaces-#{ctx.workspace.id}"
    beta = "#workspaces-#{ctx.other.id}"

    assert has_element?(
             view,
             "#{alpha}.workspace-card > a#open-#{ctx.workspace.id}[href='/workspaces/#{ctx.workspace.id}'][data-phx-link=patch]"
           )

    assert has_element?(
             view,
             "#{alpha} button#rename-#{ctx.workspace.id}[aria-label='Rename #{ctx.workspace.name}']",
             "Rename"
           )

    refute has_element?(view, "#{alpha} > a details, #{alpha} > a button")

    assert has_element?(
             view,
             "#open-#{ctx.workspace.id}[aria-describedby='workspace-health-#{ctx.workspace.id}']"
           )

    assert has_element?(view, "#{alpha} .workspace-card-problem", ctx.reconnect.email)
    assert has_element?(view, "#{alpha} .workspace-card-problem", "Reconnect required")
    assert has_element?(view, "#{beta} .workspace-card-problem", ctx.limited.email)
    assert has_element?(view, "#{beta} .workspace-card-problem", "Rate limited")
    refute has_element?(view, alpha, ctx.limited.email)
    refute has_element?(view, beta, ctx.reconnect.email)
    refute has_element?(view, "#workspace-list", ctx.healthy.email)
    refute has_element?(view, "#workspace-list", ctx.available.email)
    assert FakeIO.calls() == []

    view |> element("#rename-#{ctx.workspace.id}") |> render_click()
    assert has_element?(view, "#workspace-modal-title", "Rename workspace")
    refute has_element?(view, "#workspace-landing")
    assert socket(view).assigns.selected == nil
  end

  test "account PubSub updates refresh card problems without healthy or cross-workspace leakage",
       ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    view |> element("#show-workspaces") |> render_click()
    status(ctx.reconnect, %{status: :ready, last_error: nil})
    broadcast(ctx.reconnect.id)

    refute has_element?(view, "#workspace-health-#{ctx.workspace.id} .workspace-card-problem")
    refute has_element?(view, "#workspace-list", ctx.reconnect.email)
    assert has_element?(view, "#workspace-health-#{ctx.other.id}", ctx.limited.email)

    status(ctx.healthy, %{last_error: :keychain})
    broadcast(ctx.healthy.id)

    for space <- [ctx.workspace, ctx.other] do
      assert has_element?(view, "#workspace-health-#{space.id}", ctx.healthy.email)
      assert has_element?(view, "#workspace-health-#{space.id}", "Check credentials")
    end

    refute has_element?(view, "#workspace-health-#{ctx.workspace.id}", ctx.limited.email)
    status(ctx.available, %{last_error: :provider})
    broadcast(ctx.available.id)
    refute has_element?(view, "#workspace-list", ctx.available.email)
    assert FakeIO.calls() == []
  end

  test "workspace landing separates account management from the explicit add panel", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    open_workspace(view, ctx.workspace)

    assert has_element?(view, "#mail-account-#{ctx.healthy.id}", ctx.healthy.email)
    assert has_element?(view, "#mail-account-#{ctx.reconnect.id}", ctx.reconnect.email)
    refute has_element?(view, "#mail-account-#{ctx.limited.id}")
    refute has_element?(view, "#mail-account-#{ctx.available.id}")
    refute has_element?(view, "#integration-add-panel, #mail-search, #mail-threads")

    refute has_element?(view, ".integration-tile-open details, .integration-tile-open button")
    assert has_element?(view, "#detach-#{ctx.healthy.id}", "Remove from workspace")
    refute has_element?(view, "[phx-click='mail:disconnect']")

    reconnect_form = "#mail-connect-#{ctx.reconnect.id}"

    assert has_element?(
             view,
             "#{reconnect_form} input[name=workspace_id][type=hidden][value='#{ctx.workspace.id}']"
           )

    assert has_element?(
             view,
             "#{reconnect_form} input[name=expected_account_id][value='#{ctx.reconnect.id}']"
           )

    view |> element("#add-integration") |> render_click()
    assert has_element?(view, "#integration-add-panel")
    assert has_element?(view, "#mail-available-#{ctx.available.id} #attach-#{ctx.available.id}")
    assert has_element?(view, "#mail-available-#{ctx.limited.id}", ctx.limited.email)
    refute has_element?(view, "#mail-available-#{ctx.healthy.id}")

    assert has_element?(
             view,
             "#mail-connect-new input[name=workspace_id][type=hidden][value='#{ctx.workspace.id}']"
           )

    refute has_element?(view, "#mail-connect-new select[name=workspace_id]")
    view |> element("#close-add-integration") |> render_click()
    refute has_element?(view, "#integration-add-panel")
    assert FakeIO.calls() == []
  end

  test "attachment is explicit and removal is local, never a local disconnect", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    open_workspace(view, ctx.workspace)
    render_click(view, "mail:disconnect", %{"id" => ctx.healthy.id})
    assert Mail.get_account!(ctx.healthy.id, actor: @owner).status == :ready
    assert member?(ctx.workspace, ctx.healthy)
    assert member?(ctx.other, ctx.healthy)
    assert FakeIO.calls() == []

    view |> element("#add-integration") |> render_click()
    view |> element("#attach-#{ctx.available.id}") |> render_click()
    assert has_element?(view, "#mail-account-#{ctx.available.id}")
    assert has_element?(view, "#mail-notice", "Account attached to this workspace.")
    refute has_element?(view, "#integration-add-panel")
    assert member?(ctx.workspace, ctx.available)
    refute member?(ctx.other, ctx.available)

    view |> element("#detach-#{ctx.healthy.id}") |> render_click()
    refute has_element?(view, "#mail-account-#{ctx.healthy.id}")

    assert has_element?(
             view,
             "#mail-notice",
             "The account remains available in other workspaces."
           )

    refute member?(ctx.workspace, ctx.healthy)
    assert member?(ctx.other, ctx.healthy)
    assert Mail.get_account!(ctx.healthy.id, actor: @owner).status == :ready

    view |> element("#add-integration") |> render_click()
    assert has_element?(view, "#attach-#{ctx.healthy.id}")
    assert FakeIO.calls() == []
  end

  test "expired available connections require reconnect rather than attachment", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    open_workspace(view, ctx.other)
    view |> element("#add-integration") |> render_click()
    assert has_element?(view, "#mail-available-#{ctx.reconnect.id}")
    refute has_element?(view, "#attach-#{ctx.reconnect.id}")

    assert has_element?(
             view,
             "#mail-connect-#{ctx.reconnect.id} input[name=expected_account_id]" <>
               "[value='#{ctx.reconnect.id}']"
           )

    render_click(view, "mail:attach", %{"id" => ctx.reconnect.id})
    refute member?(ctx.other, ctx.reconnect)
    refute has_element?(view, "#mail-account-#{ctx.reconnect.id}")
    assert FakeIO.calls() == []
  end

  test "global Connections has no workspace or inbox, and forged mail events never read providers",
       ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    open_gmail_connections(view)
    mail = socket(view).assigns.mail
    assert mail.scope == :connections
    assert mail.workspace_id == nil
    assert mail.account_id == nil
    assert mail.memberships == []
    assert mail.data_ref == nil
    assert mail.task == nil
    refute mail.loading
    assert socket(view).assigns.selected == nil
    assert socket(view).redirected == nil
    refute has_element?(view, "#workspace-list, #workspace-landing, #mail-search, #mail-threads")

    for connection <- [ctx.healthy, ctx.reconnect, ctx.limited, ctx.available] do
      assert has_element?(view, "#connection-account-#{connection.id}", connection.email)

      assert has_element?(
               view,
               "#connection-account-#{connection.id} button[phx-click='mail:disconnect']" <>
                 "[phx-value-id='#{connection.id}'][data-confirm]",
               "Disconnect everywhere"
             )
    end

    refute has_element?(view, ".home-account-open, [id^='attach-'], [id^='detach-']")

    for {event, params} <- [
          {"mail:select", %{"id" => ctx.healthy.id}},
          {"mail:search", %{"mail_search" => %{"query" => "synthetic"}}},
          {"mail:refresh", %{}},
          {"mail:thread", %{"id" => "shared-thread"}},
          {"mail:next", %{}},
          {"mail:first", %{}},
          {"mail:back", %{}},
          {"mail:attach", %{"id" => ctx.available.id}},
          {"mail:detach", %{"id" => ctx.healthy.id}}
        ] do
      render_click(view, event, params)
    end

    complete(view)
    status(ctx.healthy, %{last_error: :provider})
    broadcast(ctx.healthy.id)

    assert has_element?(
             view,
             "#connection-account-#{ctx.healthy.id}",
             "Last check could not reach Gmail."
           )

    assert socket(view).assigns.mail.account_id == nil
    assert socket(view).assigns.mail.task == nil
    assert member?(ctx.workspace, ctx.healthy)
    refute member?(ctx.workspace, ctx.available)
    assert FakeIO.calls() == []
  end

  test "global OAuth forms require an unselected workspace and bind reconnect identity", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    open_workspace(view, ctx.workspace)
    open_gmail_connections(view)
    refute has_element?(view, "#mail-connect-new")
    view |> element("#new-gmail-connection") |> render_click()

    assert has_element?(
             view,
             "dialog#gmail-connection-modal[phx-hook=NativeModal][data-cancel-event='mail:close_connection'][data-return-focus='#new-gmail-connection']"
           )

    assert has_element?(view, "#gmail-connection-modal-title", "Add Gmail account")
    assert has_element?(view, "#gmail-connection-modal #mail-connect-new")

    for suffix <- ["new", ctx.reconnect.id] do
      form = "#mail-connect-#{suffix}"
      assert has_element?(view, "#{form}[action='/oauth/google/start'][method=post]")
      assert has_element?(view, "#{form} input[type=hidden][name=_csrf_token]")
      assert has_element?(view, "#{form} select[name=workspace_id][required]:not([disabled])")
      assert has_element?(view, "#{form} select option[value='']", "Choose workspace")
      refute has_element?(view, "#{form} select option[selected]")
      refute has_element?(view, "#{form} input[type=hidden][name=workspace_id]")

      for space <- [ctx.workspace, ctx.other] do
        assert has_element?(view, "#{form} option[value='#{space.id}']", space.name)
      end
    end

    assert has_element?(view, "#mail-connect-new", "Connect and add to")
    refute has_element?(view, "#mail-connect-new input[name=expected_account_id]")
    assert has_element?(view, "#mail-connect-#{ctx.reconnect.id}", "Reconnect and add to")

    assert has_element?(
             view,
             "#mail-connect-#{ctx.reconnect.id} input[type=hidden][name=expected_account_id]" <>
               "[value='#{ctx.reconnect.id}']"
           )

    assert FakeIO.calls() == []
  end

  test "new Gmail modal closes locally, survives metadata updates, and cannot open outside Connections",
       ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    render_click(view, "mail:new_connection")
    refute socket(view).assigns.mail.connecting
    open_workspace(view, ctx.workspace)
    render_click(view, "mail:new_connection")
    refute socket(view).assigns.mail.connecting

    open_gmail_connections(view)
    view |> element("#new-gmail-connection") |> render_click()
    status(ctx.healthy, %{last_error: :provider})
    broadcast(ctx.healthy.id)
    assert has_element?(view, "#gmail-connection-modal #mail-workspace-new")

    assert has_element?(
             view,
             "#connection-account-#{ctx.healthy.id}",
             "Last check could not reach Gmail"
           )

    view |> element("#gmail-connection-modal button[type=button]") |> render_click()
    refute has_element?(view, "#gmail-connection-modal, #mail-connect-new")
    assert socket(view).assigns.mail.scope == :connections
    assert FakeIO.calls() == []

    view |> element("#new-gmail-connection") |> render_click()
    view |> element("#home-link") |> render_click()
    open_gmail_connections(view)
    refute has_element?(view, "#gmail-connection-modal")
  end

  test "Connections is global and browser history restores a workspace without inbox content",
       ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    view |> element("#show-connections") |> render_click()
    refute has_element?(view, "#back-from-connections")
    view |> element("#home-link") |> render_click()
    assert has_element?(view, "#home-overview")
    refute has_element?(view, "#workspace-list")
    assert socket(view).assigns.mail.scope == :workspace
    assert socket(view).assigns.mail.accounts == []

    open_workspace(view, ctx.workspace)
    view |> element("#add-integration") |> render_click()
    view |> element("#show-connections") |> render_click()
    assert_patch(view, "/connections")
    assert socket(view).assigns.selected == nil
    assert has_element?(view, "#connections-overview")
    refute has_element?(view, "#back-from-connections, #connections-subnav")
    render_patch(view, "/workspaces/#{ctx.workspace.id}")
    refute has_element?(view, "#integration-add-panel")
    assert FakeIO.calls() == []

    view |> element("#mail-account-#{ctx.healthy.id} .home-account-open") |> render_click()
    assert complete(view) =~ "Synthetic inbox #{ctx.healthy.id}"
    ref = socket(view).assigns.mail.data_ref
    calls = FakeIO.calls()

    view |> element("#show-connections") |> render_click()
    assert_patch(view, "/connections")
    assert has_element?(view, "#connections-overview")
    refute has_element?(view, "#back-from-connections, #connections-subnav")
    assert socket(view).assigns.selected == nil
    assert socket(view).assigns.mail.workspace_id == nil
    assert socket(view).assigns.mail.scope == :connections
    assert ViewData.get(ref) == nil
    refute render(view) =~ "Synthetic inbox"

    view |> element("#open-connection-gmail") |> render_click()
    assert has_element?(view, "#back-to-connections[href='/connections']")
    view |> element("#back-to-connections") |> render_click()
    assert has_element?(view, "#connections-overview")
    assert socket(view).assigns.selected == nil
    render_patch(view, "/workspaces/#{ctx.workspace.id}")
    assert has_element?(view, "#directory-heading", ctx.workspace.name)
    assert socket(view).assigns.mail.workspace_id == ctx.workspace.id
    assert socket(view).assigns.mail.scope == :workspace
    assert socket(view).assigns.mail.account_id == nil
    refute has_element?(view, "#mail-search, #integration-add-panel")
    assert FakeIO.calls() == calls
    assert socket(view).redirected == nil

    view |> element("#back-to-workspaces") |> render_click()
    assert has_element?(view, "#workspace-list")
    assert socket(view).assigns.selected == nil
    assert socket(view).assigns.mail.workspace_id == nil
    assert socket(view).assigns.mail.subscriptions == []
  end

  test "disconnect everywhere fences locally before queued cleanup and preserves other accounts",
       ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    open_gmail_connections(view)
    disconnect(view, ctx.healthy)

    assert {:ok,
            %{
              operation_id: operation_id,
              state: :pending,
              local_removed: true,
              credentials_removed: false,
              revoked: false
            }} =
             Mail.disconnect_status(ctx.healthy.id, actor: @owner)

    assert is_binary(operation_id)
    assert FakeIO.calls() == []
    assert has_element?(view, "#mail-notice", "cleanup queued")
    assert has_element?(view, "#gmail-account-operation", ctx.healthy.email)

    assert has_element?(
             view,
             "#connection-account-#{ctx.reconnect.id} button[disabled]" <>
               "[aria-describedby='gmail-account-operation']"
           )

    assert has_element?(
             view,
             "#connection-account-#{ctx.healthy.id} [role=status]",
             "Credential cleanup and Google revocation are pending"
           )

    refute has_element?(view, "#check-credentials-#{ctx.healthy.id}")
    assert has_element?(view, "#connection-account-#{ctx.reconnect.id}")
    assert has_element?(view, "#connection-account-#{ctx.limited.id}")
    assert Mail.get_account!(ctx.healthy.id, actor: @owner).status == :disconnected
    refute member?(ctx.workspace, ctx.healthy)
    refute member?(ctx.other, ctx.healthy)
    assert member?(ctx.workspace, ctx.reconnect)
    assert member?(ctx.other, ctx.limited)

    assert complete(view) =~
             "Disconnected everywhere. Local mail cache and credentials removed; Google access revoked."

    assert {:ok,
            %{
              operation_id: ^operation_id,
              state: :complete,
              credentials_removed: true,
              revoked: true
            }} =
             Mail.disconnect_status(ctx.healthy.id, actor: @owner)

    refute has_element?(view, "#connection-account-#{ctx.healthy.id}")
    refute has_element?(view, "#gmail-account-operation")

    assert FakeIO.calls() == [
             {:get, ctx.healthy.id},
             {:revoke, ctx.healthy.id},
             {:delete, ctx.healthy.id}
           ]
  end

  test "late operation observations cannot populate Connections, another workspace, account, or reopened inbox",
       ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    open_workspace(view, ctx.workspace)
    view |> element("#mail-account-#{ctx.healthy.id} .home-account-open") |> render_click()
    old_operation = socket(view).assigns.mail.task
    assert is_binary(old_operation)
    assert socket(view).assigns.mail.loading
    assert FakeIO.calls() == []

    view |> element("#show-connections") |> render_click()
    complete(view)
    assert_late_operation_ignored(view, old_operation)
    refute render(view) =~ "Synthetic inbox"

    render_patch(view, "/workspaces/#{ctx.other.id}")
    assert_late_operation_ignored(view, old_operation)
    refute has_element?(view, "#mail-threads")
    view |> element("#mail-account-#{ctx.limited.id} .home-account-open") |> render_click()
    assert_late_operation_ignored(view, old_operation)
    assert complete(view) =~ "Synthetic inbox #{ctx.limited.id}"
    refute render(view) =~ "Synthetic inbox #{ctx.healthy.id}"

    view |> element("#show-workspaces") |> render_click()
    assert_late_operation_ignored(view, old_operation)
    open_workspace(view, ctx.workspace)
    view |> element("#mail-account-#{ctx.healthy.id} .home-account-open") |> render_click()
    refute socket(view).assigns.mail.task == old_operation
    assert_late_operation_ignored(view, old_operation)
    assert complete(view) =~ "Synthetic inbox #{ctx.healthy.id}"
    assert_late_operation_ignored(view, old_operation)
    refute render(view) =~ "Synthetic inbox #{ctx.limited.id}"
  end

  test "switching providers preserves an accepted Gmail disconnect without showing Gmail on Gemini",
       ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    open_gmail_connections(view)
    disconnect(view, ctx.healthy)

    assert {:ok, %{operation_id: operation_id, state: :pending}} =
             Mail.disconnect_status(ctx.healthy.id, actor: @owner)

    command = socket(view).assigns.mail.command
    assert command != nil
    assert FakeIO.calls() == []
    view |> element("#connections-gemini") |> render_click()
    assert socket(view).assigns.mail.command == command
    refute has_element?(view, "#connections-panel")
    complete(view)
    assert has_element?(view, "#gemini-connection")
    refute has_element?(view, "#connection-account-#{ctx.available.id}")
    assert socket(view).assigns.mail.command == nil

    assert {:ok, %{operation_id: ^operation_id, state: :complete, revoked: true}} =
             Mail.disconnect_status(ctx.healthy.id, actor: @owner)

    view |> element("#connections-gmail") |> render_click()
    refute has_element?(view, "#connection-account-#{ctx.healthy.id}")
    assert has_element?(view, "#connection-account-#{ctx.available.id}")
    assert has_element?(view, "#mail-notice", "Disconnected everywhere")
  end

  test "accepted disconnect survives navigation without applying a late notice after reopening",
       ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    open_workspace(view, ctx.workspace)
    open_gmail_connections(view)
    disconnect(view, ctx.healthy)

    assert {:ok, %{operation_id: operation_id, state: :pending}} =
             Mail.disconnect_status(ctx.healthy.id, actor: @owner)

    assert FakeIO.calls() == []

    assert has_element?(view, "#new-gmail-connection[disabled]")
    refute has_element?(view, "#gmail-connection-modal, #mail-connect-new")
    render_click(view, "mail:new_connection")
    refute has_element?(view, "#gmail-connection-modal")
    render_patch(view, "/workspaces/#{ctx.workspace.id}")
    assert has_element?(view, "#directory-heading", ctx.workspace.name)
    assert_late_operation_ignored(view, operation_id)

    open_gmail_connections(view)
    assert socket(view).assigns.mail.command == nil
    assert has_element?(view, "#new-gmail-connection:not([disabled])")
    view |> element("#new-gmail-connection") |> render_click()
    assert has_element?(view, "#gmail-connection-modal #mail-connect-new select:not([disabled])")
    view |> element("#gmail-connection-modal button[type=button]") |> render_click()
    complete(view)
    assert_late_operation_ignored(view, operation_id)

    assert {:ok,
            %{
              operation_id: ^operation_id,
              state: :complete,
              credentials_removed: true,
              revoked: true
            }} =
             Mail.disconnect_status(ctx.healthy.id, actor: @owner)

    assert has_element?(view, "#connections-panel")
    assert socket(view).assigns.mail.scope == :connections
    assert socket(view).assigns.mail.workspace_id == nil
    assert socket(view).assigns.mail.command == nil
    refute has_element?(view, "#mail-notice")
    refute has_element?(view, "#connection-account-#{ctx.healthy.id}")

    assert FakeIO.calls() == [
             {:get, ctx.healthy.id},
             {:revoke, ctx.healthy.id},
             {:delete, ctx.healthy.id}
           ]
  end

  test "local credential checks expose distinct safe observations without changing sync state",
       ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    open_gmail_connections(view)
    before = account_state()
    private = "synthetic-private-refresh-token"

    for connection <- [ctx.healthy, ctx.reconnect, ctx.limited, ctx.available] do
      assert has_element?(
               view,
               "#check-credentials-#{connection.id}[phx-click='mail:check_credentials']" <>
                 "[phx-value-id='#{connection.id}']:not([disabled])"
             )
    end

    cases = [
      {{:ok, private}, :accessible, "readable"},
      {{:error, :locked}, :locked, "locked"},
      {{:error, :timeout}, :timeout, "timeout"},
      {{:error, :not_found}, :not_found, "not found"},
      {{:error, :unavailable}, :unavailable, "unavailable"},
      {{:error, :invalid_account}, :invalid_account, "invalid"},
      {{:error, :invalid_value}, :invalid_value, "invalid"}
    ]

    for {response, expected, label} <- cases do
      FakeIO.get_result(ctx.reconnect.id, response)
      check_credentials(view, ctx.reconnect)
      html = complete(view)
      result = socket(view).assigns.mail.credential_checks[ctx.reconnect.id]
      assert result.generation == ctx.reconnect.generation
      assert result.status == expected
      assert %DateTime{} = result.checked_at
      assert socket(view).assigns.mail.credential_check == nil
      selector = "#credential-check-#{ctx.reconnect.id}[role=status]"
      assert has_element?(view, selector, label)

      assert has_element?(
               view,
               "#{selector} time[datetime='#{DateTime.to_iso8601(result.checked_at)}']"
             )

      assert render(element(view, selector)) =~ ~r/\d{2}:\d{2}/
      refute has_element?(view, "#credential-check-#{ctx.healthy.id}")
      refute html =~ private
      refute inspect(socket(view).assigns) =~ private
      assert account_state() == before
    end

    FakeIO.get_result(ctx.healthy.id, {:ok, private})
    check_credentials(view, ctx.healthy)
    complete(view)
    assert socket(view).assigns.mail.credential_checks[ctx.healthy.id].status == :accessible
    assert socket(view).assigns.mail.credential_checks[ctx.reconnect.id].status == :invalid_value

    assert Map.keys(socket(view).assigns.mail.credential_checks) |> Enum.sort() ==
             Enum.sort([ctx.healthy.id, ctx.reconnect.id])

    assert FakeIO.calls() ==
             List.duplicate({:get, ctx.reconnect.id}, length(cases)) ++ [{:get, ctx.healthy.id}]
  end

  test "credential diagnostic failures never expose raw vault errors or exceptions", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    open_gmail_connections(view)
    private = "synthetic-private-vault-error"
    before = account_state()
    responses = [{:error, %{private: private}}, {:raise, private}, {:throw, private}]

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        for response <- responses do
          FakeIO.get_result(ctx.healthy.id, response)
          check_credentials(view, ctx.healthy)
          html = complete(view)

          assert has_element?(
                   view,
                   "#credential-check-#{ctx.healthy.id}[role=status]",
                   "unavailable"
                 )

          assert socket(view).assigns.mail.credential_checks[ctx.healthy.id].status ==
                   :unavailable

          refute html =~ private
          refute inspect(socket(view).assigns) =~ private
        end
      end)

    refute log =~ private
    assert account_state() == before
    assert FakeIO.calls() == List.duplicate({:get, ctx.healthy.id}, length(responses))
  end

  test "credential checks reject forged scope, provider, missing and disconnected account events",
       ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    render_click(view, "mail:check_credentials", %{"id" => ctx.healthy.id})
    refute has_element?(view, "[id^='check-credentials-']")
    open_workspace(view, ctx.workspace)
    render_click(view, "mail:check_credentials", %{"id" => ctx.healthy.id})
    assert FakeIO.calls() == []

    status(ctx.available, %{status: :disconnected})
    open_gmail_connections(view)

    for params <- [
          %{"id" => Ash.UUID.generate()},
          %{"id" => "not-an-account"},
          %{"id" => ctx.available.id},
          %{}
        ] do
      render_click(view, "mail:check_credentials", params)
    end

    refute has_element?(view, "#check-credentials-#{ctx.available.id}")
    view |> element("#connections-gemini") |> render_click()
    complete(view)
    refute has_element?(view, "[id^='check-credentials-']")
    render_click(view, "mail:check_credentials", %{"id" => ctx.healthy.id})
    assert socket(view).assigns.mail.credential_check == nil
    assert socket(view).assigns.mail.credential_checks == %{}
    assert FakeIO.calls() == []
    assert Mail.get_account!(ctx.healthy.id, actor: @owner).status == :ready
  end

  test "one accepted credential check disables every account and ignores unrelated observations",
       ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    open_gmail_connections(view)
    check_credentials(view, ctx.healthy)
    active = socket(view).assigns.mail.credential_check
    assert active != nil
    assert is_binary(pending_read_operation())

    for connection <- [ctx.healthy, ctx.reconnect, ctx.limited, ctx.available] do
      assert has_element?(
               view,
               "#check-credentials-#{connection.id}[disabled]" <>
                 "[aria-describedby='gmail-account-operation']"
             )
    end

    assert has_element?(view, "#gmail-account-operation", ctx.healthy.email)

    assert has_element?(
             view,
             "#mail-connect-#{ctx.reconnect.id} select[disabled]" <>
               "[aria-describedby='gmail-account-operation']"
           )

    assert has_element?(
             view,
             "#mail-connect-#{ctx.reconnect.id} button[disabled]" <>
               "[aria-describedby='gmail-account-operation']"
           )

    assert has_element?(
             view,
             "#connection-account-#{ctx.limited.id} button[phx-click='mail:disconnect'][disabled]" <>
               "[aria-describedby='gmail-account-operation']"
           )

    assert has_element?(view, "#credential-check-#{ctx.healthy.id}[role=status]", "Checking")
    render_click(view, "mail:check_credentials", %{"id" => ctx.limited.id})
    render_click(view, "mail:check_credentials", %{"id" => ctx.healthy.id})
    assert socket(view).assigns.mail.credential_check == active
    assert FakeIO.calls() == []
    assert_late_operation_ignored(view, Ash.UUID.generate())

    complete(view)
    assert socket(view).assigns.mail.credential_checks[ctx.healthy.id].status == :accessible
    assert socket(view).assigns.mail.credential_check == nil
    assert has_element?(view, "#check-credentials-#{ctx.limited.id}:not([disabled])")
    refute has_element?(view, "#gmail-account-operation")
    refute has_element?(view, "#check-credentials-#{ctx.limited.id}[aria-describedby]")
    assert FakeIO.calls() == [{:get, ctx.healthy.id}]
  end

  test "leaving and reentering Connections rejects a pending observation even during a new check",
       ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    open_gmail_connections(view)
    check_credentials(view, ctx.healthy)
    old_operation = pending_read_operation()
    assert is_binary(old_operation)
    assert FakeIO.calls() == []
    view |> element("#home-link") |> render_click()
    assert_late_operation_ignored(view, old_operation)

    open_gmail_connections(view)
    assert socket(view).assigns.mail.credential_checks == %{}
    assert socket(view).assigns.mail.credential_check == nil
    assert_late_operation_ignored(view, old_operation)
    check_credentials(view, ctx.healthy)
    refute pending_read_operation() == old_operation
    assert_late_operation_ignored(view, old_operation)
    complete(view)
    assert_late_operation_ignored(view, old_operation)
    assert socket(view).assigns.mail.credential_checks[ctx.healthy.id].status == :accessible
    assert FakeIO.calls() == [{:get, ctx.healthy.id}]
  end

  test "reconnect during a pending check discards the old generation result", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    open_gmail_connections(view)
    check_credentials(view, ctx.healthy)
    old_operation = pending_read_operation()
    assert FakeIO.calls() == []
    reconnected = reconnect_generation(ctx.healthy)
    broadcast(ctx.healthy.id)
    complete(view)
    assert_late_operation_ignored(view, old_operation)
    refute has_element?(view, "#credential-check-#{ctx.healthy.id}")
    refute Map.has_key?(socket(view).assigns.mail.credential_checks, ctx.healthy.id)
    assert socket(view).assigns.mail.credential_check == nil

    check_credentials(view, reconnected)
    complete(view)

    assert socket(view).assigns.mail.credential_checks[ctx.healthy.id].generation ==
             reconnected.generation

    assert socket(view).assigns.mail.credential_checks[ctx.healthy.id].status == :accessible
    assert FakeIO.calls() == [{:get, ctx.healthy.id}]
  end

  test "metadata changes invalidate only the changed account's credential observation", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    open_gmail_connections(view)
    check_credentials(view, ctx.healthy)
    complete(view)
    FakeIO.get_result(ctx.limited.id, {:error, :locked})
    check_credentials(view, ctx.limited)
    complete(view)
    limited_check = socket(view).assigns.mail.credential_checks[ctx.limited.id]
    reconnect_generation(ctx.healthy)
    broadcast(ctx.healthy.id)
    refute has_element?(view, "#credential-check-#{ctx.healthy.id}")
    assert socket(view).assigns.mail.credential_checks[ctx.limited.id] == limited_check
    assert has_element?(view, "#credential-check-#{ctx.limited.id}", "locked")

    status(ctx.limited, %{status: :disconnected})
    broadcast(ctx.limited.id)
    refute has_element?(view, "#credential-check-#{ctx.limited.id}")
    assert socket(view).assigns.mail.credential_checks == %{}
    assert FakeIO.calls() == [{:get, ctx.healthy.id}, {:get, ctx.limited.id}]
  end

  defp open_gmail_connections(view) do
    view |> element("#show-connections") |> render_click()
    view |> element("#open-connection-gmail") |> render_click()
    complete(view)
  end

  defp check_credentials(view, account) do
    view |> element("#check-credentials-#{account.id}") |> render_click()
  end

  defp pending_read_operation do
    assert [%{args: %{"operation_id" => operation_id}}] =
             all_enqueued(worker: Monolith.Mail.ReadWorker)

    operation_id
  end

  defp account_state do
    Enum.map(Mail.list_accounts!(actor: @owner), fn account ->
      Map.take(account, Enum.map(Info.attributes(Account), & &1.name))
    end)
  end

  defp membership_state(ctx) do
    for workspace <- [ctx.workspace, ctx.other], into: %{} do
      ids =
        workspace.id
        |> Mail.workspace_accounts!(actor: @owner)
        |> Enum.map(& &1.account_id)
        |> Enum.sort()

      {workspace.id, ids}
    end
  end

  defp submit_credentials(conn, path, params) do
    page = conn |> put_private(:plug_skip_csrf_protection, false) |> get(path)

    [csrf] =
      page
      |> html_response(200)
      |> LazyHTML.from_document()
      |> LazyHTML.query("#owner-lock-form input[name=_csrf_token]")
      |> LazyHTML.attribute("value")
      |> Enum.uniq()

    page
    |> recycle()
    |> put_private(:plug_skip_csrf_protection, false)
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> post(path, URI.encode_query(Map.put(params, "_csrf_token", csrf)))
  end

  defp reconnect_generation(account) do
    Mail.save_connection!(
      %{
        id: account.id,
        subject: account.subject,
        email: account.email,
        generation: Ash.UUID.generate()
      },
      actor: @owner
    )
  end

  defp fake_gemini_vault do
    start_supervised!(GeminiVault)
    previous = Application.fetch_env(:monolith, :gemini_vault)
    Application.put_env(:monolith, :gemini_vault, GeminiVault)
    on_exit(fn -> restore(:gemini_vault, previous) end)
  end

  defp assert_late_operation_ignored(view, operation_id) do
    current = socket(view).assigns.mail
    send(view.pid, {:mail_operation, operation_id})
    render(view)
    assert socket(view).assigns.mail == current
  end

  defp open_workspace(view, workspace) do
    view |> element("#show-workspaces") |> render_click()
    view |> element("#open-#{workspace.id}") |> render_click()
  end

  defp disconnect(view, connection) do
    view
    |> element("#connection-account-#{connection.id} button[phx-click='mail:disconnect']")
    |> render_click()
  end

  defp socket(view), do: :sys.get_state(view.pid).socket

  defp member?(workspace, connection) do
    workspace.id
    |> Mail.workspace_accounts!(actor: @owner)
    |> Enum.any?(&(&1.account_id == connection.id))
  end

  defp account(name) do
    Mail.save_connection!(
      %{
        id: Ash.UUID.generate(),
        subject: "synthetic-#{name}",
        email: "#{name}@example.test",
        generation: Ash.UUID.generate()
      },
      actor: @owner
    )
  end

  defp status(connection, fields) do
    Mail.update_account!(
      connection,
      Map.put(fields, :expected_generation, connection.generation),
      actor: @owner
    )
  end

  defp broadcast(id),
    do: Phoenix.PubSub.broadcast(Monolith.PubSub, "mail:#{id}", {:mail_changed, id})

  defp restore(key, {:ok, value}), do: Application.put_env(:monolith, key, value)
  defp restore(key, :error), do: Application.delete_env(:monolith, key)
end
