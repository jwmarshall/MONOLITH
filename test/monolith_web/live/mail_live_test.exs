defmodule MonolithWeb.MailLiveTest do
  # Exercise the delegated callbacks without HomeLive wiring, live Google, or Keychain.
  use MonolithWeb.ConnCase, async: false
  use Oban.Testing, repo: Monolith.Repo, engine: Oban.Engines.Lite

  import Phoenix.LiveViewTest
  import Monolith.TestSupport.BackgroundWork, only: [complete: 1]

  alias Monolith.Mail
  alias Monolith.Mail.{CacheEntry, DisconnectWorker, PollWorker, ReadWorker, ViewData}
  alias MonolithWeb.{HomeMail, MailComponents}

  defmodule Harness do
    @moduledoc false
    use MonolithWeb, :live_view

    @impl true
    def mount(_, %{"workspace_id" => id}, socket) do
      workspace = Monolith.Workspaces.get_workspace!(id, actor: %{role: :local_owner})
      socket = Phoenix.Component.assign(socket, :workspace, workspace)
      {:ok, socket |> HomeMail.init() |> HomeMail.open_workspace(workspace)}
    end

    @impl true
    def handle_event(event, params, socket), do: HomeMail.handle_event(event, params, socket)
    @impl true
    def handle_info(message, socket), do: HomeMail.handle_info(message, socket)
    @impl true
    def render(assigns), do: ~H"<MailComponents.panel mail={@mail} workspace={@workspace} />"
  end

  defmodule FakeVault do
    @moduledoc false
    def get(_), do: {:ok, "fake-refresh"}
    def put(_, _), do: :ok
    def delete(_), do: :ok
  end

  defmodule FakeProvider do
    @moduledoc false
    @spec refresh(binary()) :: {:ok, Monolith.Google.OAuthProvider.tokens()}
    def refresh("fake-refresh"), do: {:ok, %{access_token: "fake-access", expires_in: 3600}}

    @spec inbox(binary(), Monolith.Mail.Provider.page_token()) ::
            {:ok, Monolith.Mail.Provider.page()}
    def inbox("fake-access", token),
      do: page(if(token, do: "Next page", else: "Private inbox subject"))

    @spec search(binary(), binary(), Monolith.Mail.Provider.page_token()) ::
            {:ok, Monolith.Mail.Provider.page()}
    def search("fake-access", "everywhere", _), do: page("Account-wide match")

    @spec thread(binary(), binary()) :: {:ok, Monolith.Mail.Provider.thread()}
    def thread("fake-access", "t1") do
      {:ok,
       %{
         id: "t1",
         messages: [
           %{
             id: "m1",
             subject: "Private conversation subject",
             from: "sender@example.test",
             to: "first@example.test",
             date: "Yesterday",
             text: "Private body <img src=\"https://remote.test/pixel\">",
             attachments: []
           }
         ]
       }}
    end

    defp page(subject),
      do:
        {:ok,
         %{
           threads: [
             %{
               id: "t1",
               subject: subject,
               from: "sender@example.test",
               snippet: "Private snippet",
               date: "Yesterday",
               unread: true
             }
           ],
           next_page_token: "next"
         }}
  end

  defmodule EmptyProvider do
    @moduledoc false
    defdelegate refresh(token), to: FakeProvider
    def inbox(_token, _page), do: {:ok, %{threads: [], next_page_token: nil}}
  end

  defmodule OfflineProvider do
    @moduledoc false
    defdelegate refresh(token), to: FakeProvider
    def inbox(_token, _page), do: {:error, :transport_error}
  end

  defmodule FailedCleanupVault do
    @moduledoc false
    defdelegate get(id), to: FakeVault
    def delete(_id), do: {:error, :unavailable}
  end

  defmodule UncertainRevocationProvider do
    @moduledoc false
    def revoke(_token), do: {:error, :transport_error}
  end

  @owner %{role: :local_owner}

  setup do
    previous_provider = Application.fetch_env(:monolith, :gmail_provider)
    previous_vault = Application.fetch_env(:monolith, :gmail_vault)
    Application.put_env(:monolith, :gmail_provider, FakeProvider)
    Application.put_env(:monolith, :gmail_vault, FakeVault)

    on_exit(fn ->
      restore(:gmail_provider, previous_provider)
      restore(:gmail_vault, previous_vault)
    end)

    workspace = Monolith.Workspaces.create_workspace!("Mail test", actor: @owner)
    other_workspace = Monolith.Workspaces.create_workspace!("Other mail test", actor: @owner)
    first = account("first")
    second = account("second")
    assert {:ok, true} = Mail.link(workspace.id, first.id, actor: @owner)
    assert {:ok, true} = Mail.link(workspace.id, second.id, actor: @owner)
    socket = HomeMail.init(%Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}})
    socket = HomeMail.open_workspace(socket, workspace)

    %{
      workspace: workspace,
      other_workspace: other_workspace,
      first: first,
      second: second,
      socket: socket
    }
  end

  test "landing lists attached accounts separately and uses CSRF-protected POST connect",
       context do
    html = panel(context.socket, context.workspace)
    assert html =~ context.first.email
    assert html =~ context.second.email
    assert {:noreply, socket} = HomeMail.handle_event("mail:add", %{}, context.socket)
    html = panel(socket, context.workspace)
    assert html =~ ~s(action="/oauth/google/start")
    assert html =~ ~s(method="post")
    assert html =~ ~s(name="_csrf_token")
    assert html =~ ~s(name="workspace_id" value="#{context.workspace.id}")
    refute html =~ "Disconnect everywhere"
    refute html =~ "mail-search"
    refute html =~ "Send"
  end

  test "switching accounts immediately clears content, search, page, loading and timestamp",
       context do
    socket = select(context.socket, context.first.id)
    ref = ViewData.put(%{"threads" => [%{"id" => "old", "subject" => "Private first account"}]})

    socket =
      change(socket, %{
        data_ref: ref,
        query: "secret",
        page_token: "old-page",
        fetched_at: DateTime.utc_now(),
        loading: true,
        task: Ash.UUID.generate()
      })

    socket = select(socket, context.second.id)
    mail = socket.assigns.mail
    assert mail.account_id == context.second.id
    assert mail.data_ref == nil
    assert ViewData.get(ref) == nil
    assert mail.query == nil
    assert mail.page_token == nil
    assert mail.fetched_at == nil
    refute mail.loading
    refute panel(socket, context.workspace) =~ "Private first account"
  end

  test "late operations cannot populate a different account or reopened workspace", context do
    old = pending(context.socket, context.first.id)
    operation = old.assigns.mail.task
    socket = select(old, context.second.id)
    assert {:noreply, ^socket} = HomeMail.handle_info({:mail_operation, operation}, socket)
    assert socket.assigns.mail.data_ref == nil

    socket = HomeMail.open_workspace(socket, context.other_workspace)
    assert {:noreply, ^socket} = HomeMail.handle_info({:mail_operation, operation}, socket)
    assert socket.assigns.mail.account_id == nil

    socket = HomeMail.open_workspace(socket, context.workspace)
    socket = pending(socket, context.first.id)
    refute socket.assigns.mail.task == operation
    assert {:noreply, ^socket} = HomeMail.handle_info({:mail_operation, operation}, socket)
    socket = settle(socket)
    assert panel(socket, context.workspace) =~ "Private inbox subject"
    refute inspect(socket.assigns) =~ "Private inbox subject"
  end

  test "completion rechecks membership, discarding results detached while in flight", context do
    socket = pending(context.socket, context.first.id)
    operation = socket.assigns.mail.task
    assert {:ok, true} = Mail.unlink(context.workspace.id, context.first.id, actor: @owner)
    assert :ok = perform_job(ReadWorker, %{operation_id: operation})
    assert {:noreply, socket} = HomeMail.handle_info({:mail_changed, context.first.id}, socket)
    assert {:noreply, socket} = HomeMail.handle_info({:mail_operation, operation}, socket)
    assert socket.assigns.mail.account_id == nil
    assert socket.assigns.mail.data_ref == nil
    refute socket.assigns.mail.loading
  end

  test "an operation from an old connection generation cannot publish a conversation", context do
    socket = pending(context.socket, context.first.id)

    Mail.save_connection!(
      %{
        id: context.first.id,
        subject: context.first.subject,
        email: context.first.email,
        generation: Ash.UUID.generate()
      },
      actor: @owner
    )

    socket = settle(socket)
    assert socket.assigns.mail.error == :unavailable
    assert socket.assigns.mail.data_ref == nil
    refute panel(socket, context.workspace) =~ "Private inbox subject"
  end

  test "loading is an announced indeterminate status, distinct from actionable warnings",
       context do
    socket = pending(context.socket, context.first.id)
    document = socket |> panel(context.workspace) |> LazyHTML.from_fragment()

    assert Enum.any?(
             LazyHTML.query(
               document,
               "#mail-status[role=status][aria-live=polite][aria-atomic=true]"
             )
           )

    assert LazyHTML.query(document, "#mail-loading") |> LazyHTML.text() =~ "Loading messages"

    assert Enum.any?(
             LazyHTML.query(document, "#mail-loading [data-state=active] svg[aria-hidden=true]")
           )

    assert Enum.empty?(LazyHTML.query(document, ".mail-warning, [role=progressbar]"))

    socket =
      change(socket, %{thread_id: "t1", error: :rate_limited, stale: true, data_loaded: true})

    document = socket |> panel(context.workspace) |> LazyHTML.from_fragment()
    assert LazyHTML.query(document, "#mail-loading") |> LazyHTML.text() =~ "Loading conversation"
    assert LazyHTML.query(document, ".mail-warning") |> LazyHTML.text() =~ "rate limit"
    assert LazyHTML.query(document, ".mail-warning") |> LazyHTML.text() =~ "stale local mail"

    document =
      socket |> change(%{loading: false}) |> panel(context.workspace) |> LazyHTML.from_fragment()

    assert Enum.empty?(LazyHTML.query(document, "#mail-loading"))
    assert Enum.any?(LazyHTML.query(document, ".mail-warning"))
  end

  test "completed reads expose only an opaque render reference and truthful cache metadata",
       context do
    socket = context.socket |> pending(context.first.id) |> settle()
    ref = socket.assigns.mail.data_ref
    assert is_reference(ref)
    assert %DateTime{} = socket.assigns.mail.fetched_at
    assert socket.assigns.mail.next_page_token == "next"
    refute socket.assigns.mail.loading
    refute socket.assigns.mail.cached
    refute socket.assigns.mail.stale
    assert panel(socket, context.workspace) =~ "Private inbox subject"
    refute inspect(socket.assigns) =~ "Private inbox subject"

    socket = socket |> pending(context.first.id) |> settle()
    assert socket.assigns.mail.cached
    assert panel(socket, context.workspace) =~ "Local copy"
    refute inspect(socket.assigns) =~ "Private snippet"
  end

  test "rendered lists stay bounded and expose stale-copy metadata without socket payloads",
       context do
    socket = select(context.socket, context.first.id)
    threads = for n <- 1..25, do: %{"id" => "thread#{n}", "subject" => "Subject #{n}"}
    ref = ViewData.put(%{"threads" => threads, "next_page_token" => "next"})

    socket =
      socket
      |> change(%{
        data_ref: ref,
        data_loaded: true,
        fetched_at: ~U[2026-11-01 12:00:00Z],
        cached: true,
        stale: true,
        error: :rate_limited,
        next_page_token: "next"
      })

    html = panel(socket, context.workspace)
    assert html =~ "Subject 1"
    refute html =~ "Subject 25"
    assert html =~ "rate limit"
    assert html =~ "stale local mail"
    assert html =~ "2026-11-01 12:00:00 UTC"
    assert html =~ "Local copy"
    refute inspect(socket.assigns) =~ "Subject"
  end

  test "empty and offline are distinct, and refresh failure preserves an existing copy",
       context do
    Application.put_env(:monolith, :gmail_provider, EmptyProvider)
    socket = context.socket |> pending(context.first.id) |> settle()
    assert panel(socket, context.workspace) =~ "Your inbox is empty"
    fetched_at = socket.assigns.mail.fetched_at

    Application.put_env(:monolith, :gmail_provider, OfflineProvider)
    socket = socket |> pending(context.first.id, %{force: true}) |> settle()
    assert socket.assigns.mail.fetched_at == fetched_at
    assert panel(socket, context.workspace) =~ "Offline or Gmail unavailable"
    assert socket.assigns.mail.stale
    assert socket.assigns.mail.data_loaded
  end

  test "conversation text is escaped, without remote links, images or raw HTML", context do
    socket = select(context.socket, context.first.id)

    ref =
      ViewData.put(%{
        "messages" => [
          %{
            "id" => "m1",
            "from" => "sender@example.test",
            "to" => "first@example.test",
            "date" => "Yesterday",
            "subject" => "<script>bad()</script>",
            "text" => "<img src=\"https://remote.test/pixel\">\nhttps://remote.test/"
          }
        ]
      })

    socket = change(socket, %{thread_id: "t1", data_loaded: true, data_ref: ref})
    refute inspect(socket.assigns) =~ "remote.test"
    html = panel(socket, context.workspace)
    assert html =~ "&lt;script&gt;"
    assert html =~ "&lt;img"
    assert html =~ "mail-message-text"
    refute html =~ "<script>"
    refute html =~ "<img"
    refute html =~ "href=\"https://"
  end

  test "reader has one title, native message disclosures and full metadata without hiding body text",
       context do
    messages =
      for n <- 1..3 do
        %{
          "id" => "m#{n}",
          "subject" => if(n == 2, do: "A different subject", else: "Conversation title"),
          "from" => "Sender <sender@example.test>",
          "to" => "first@example.test, colleague@example.test",
          "date" => "Mon, 2 Nov 2026 09:15:00 +0000",
          "text" =>
            "Reply #{n}\n\n> Quoted history\nSignature <img src='https://remote.test/pixel'>",
          "attachments" =>
            if(n == 3,
              do: [
                %{
                  "attachment_id" => "photo-1",
                  "filename" => "photo.png",
                  "mime_type" => "image/png",
                  "size" => 2048
                }
              ],
              else: []
            )
        }
      end

    socket = select(context.socket, context.first.id)
    ref = ViewData.put(%{"messages" => messages})
    socket = change(socket, %{thread_id: "t1", data_loaded: true, data_ref: ref})

    html = panel(socket, context.workspace)
    document = LazyHTML.from_fragment(html)
    assert ViewData.get(ref) == %{"messages" => messages}
    assert html =~ "Conversation title"

    assert LazyHTML.query(document, "#mail-conversation-heading")
           |> LazyHTML.text()
           |> String.trim() ==
             "Conversation title"

    assert length(LazyHTML.query(document, ".mail-message[open]") |> LazyHTML.to_tree()) == 1

    assert LazyHTML.query(document, "#mail-message-m3[open][data-mail-latest=true]")
           |> LazyHTML.to_tree() != []

    assert LazyHTML.query(document, "#mail-message-m1[open], #mail-message-m2[open]")
           |> LazyHTML.to_tree() == []

    assert LazyHTML.query(document, ".mail-message-subject") |> LazyHTML.text() |> String.trim() ==
             "A different subject"

    assert LazyHTML.query(document, "#mail-message-details-m3 dd") |> LazyHTML.text() =~
             "colleague@example.test"

    assert LazyHTML.query(document, "#mail-message-m3 .mail-message-text") |> LazyHTML.text() =~
             "> Quoted history\nSignature <img"

    assert LazyHTML.query(document, ".mail-attachment img, .mail-attachment [src]")
           |> LazyHTML.to_tree() == []

    assert LazyHTML.query(
             document,
             ".mail-attachment a[href$='photo-1'][target='_blank'][rel='noopener noreferrer']"
           )
           |> LazyHTML.text() =~ "Preview image"

    assert LazyHTML.query(document, ".mail-attachment a[href*='photo-1?download=1']")
           |> LazyHTML.text() == "Download"

    assert LazyHTML.query(document, "#mail-threads, script, .mail-message-text a")
           |> LazyHTML.to_tree() == []

    refute inspect(socket.assigns) =~ "Quoted history"
    assert html =~ "ignore_attrs"
  end

  test "reader return retains query and page while new list intents rotate client context",
       context do
    socket = select(context.socket, context.first.id)
    initial_key = socket.assigns.mail.list_key

    {:noreply, socket} =
      HomeMail.handle_event("mail:search", %{"mail_search" => %{"query" => "everywhere"}}, socket)

    refute socket.assigns.mail.list_key == initial_key

    socket = change(socket, %{next_page_token: "second-page"})
    search_key = socket.assigns.mail.list_key
    {:noreply, socket} = HomeMail.handle_event("mail:next", %{}, socket)
    page_key = socket.assigns.mail.list_key
    refute page_key == search_key

    ref = ViewData.put(%{"threads" => [%{"id" => "t1"}]})
    socket = change(socket, %{data_loaded: true, data_ref: ref})
    {:noreply, socket} = HomeMail.handle_event("mail:thread", %{"id" => "t1"}, socket)
    assert socket.assigns.mail.list_key == page_key
    assert socket.assigns.mail.thread_id == "t1"
    assert ViewData.get(ref) == nil

    {:noreply, socket} = HomeMail.handle_event("mail:back", %{}, socket)
    assert socket.assigns.mail.list_key == page_key
    assert socket.assigns.mail.thread_id == nil
    assert socket.assigns.mail.query == "everywhere"
    assert socket.assigns.mail.page_token == "second-page"
    refute socket.assigns.mail.data_loaded

    {:noreply, socket} = HomeMail.handle_event("mail:first", %{}, socket)
    refute socket.assigns.mail.list_key == page_key
    assert socket.assigns.mail.page_token == nil
    page_key = socket.assigns.mail.list_key
    socket = select(socket, context.second.id)
    refute socket.assigns.mail.list_key == page_key
    assert socket.assigns.mail.query == nil
  end

  test "reconnect binds the exact expected identity", context do
    socket = select(context.socket, context.first.id) |> change(%{error: :reconnect})
    html = panel(socket, context.workspace)
    assert html =~ "Reconnect Google"
    assert html =~ ~s(name="expected_account_id" value="#{context.first.id}")
    assert html =~ "Google access expired"
  end

  test "detach is workspace-local; account remains reusable", context do
    assert {:noreply, socket} =
             HomeMail.handle_event("mail:detach", %{"id" => context.first.id}, context.socket)

    refute context.first.id in socket.assigns.mail.memberships
    assert Enum.any?(socket.assigns.mail.accounts, &(&1.id == context.first.id))

    assert {:noreply, socket} =
             HomeMail.handle_event("mail:attach", %{"id" => context.first.id}, socket)

    assert context.first.id in socket.assigns.mail.memberships
  end

  test "leaving drops all mail and ignores late results, PubSub and unknown callbacks", context do
    socket = pending(context.socket, context.first.id)
    name = socket.assigns.mail.task
    socket = HomeMail.leave_workspace(socket)
    assert socket.assigns.mail.workspace_id == nil
    assert socket.assigns.mail.account_id == nil
    assert socket.assigns.mail.accounts == []
    assert {:noreply, ^socket} = HomeMail.handle_info({:mail_operation, name}, socket)
    assert {:noreply, ^socket} = HomeMail.handle_info({:mail_changed, context.first.id}, socket)
    assert {:noreply, ^socket} = HomeMail.handle_event("mail:unknown", %{}, socket)

    assert {:noreply, ^socket} =
             HomeMail.handle_info({:mail_operation, Ash.UUID.generate()}, socket)
  end

  test "global disconnect reports partial credential or revocation outcomes truthfully",
       context do
    Application.put_env(:monolith, :gmail_provider, UncertainRevocationProvider)
    Application.put_env(:monolith, :gmail_vault, FailedCleanupVault)

    assert {:ok, %{operation_id: operation, state: :pending}} =
             Mail.disconnect(context.first.id, actor: @owner)

    socket = change(context.socket, %{command: {context.first.id, operation}})
    assert :ok = perform_job(DisconnectWorker, %{operation_id: operation})
    assert {:noreply, socket} = HomeMail.handle_info({:mail_operation, operation}, socket)
    assert socket.assigns.mail.command == nil
    assert socket.assigns.mail.notice =~ "credentials could not be removed"
    assert socket.assigns.mail.notice =~ "revocation could not be confirmed"
  end

  test "Oban-owned reads paginate, search and render bodies without socket payloads",
       context do
    previous_provider = Application.fetch_env(:monolith, :gmail_provider)
    previous_vault = Application.fetch_env(:monolith, :gmail_vault)
    Application.put_env(:monolith, :gmail_provider, FakeProvider)
    Application.put_env(:monolith, :gmail_vault, FakeVault)
    telemetry_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:phoenix, :live_view, :render, :start],
        &__MODULE__.capture_render/4,
        self()
      )

    on_exit(fn ->
      :telemetry.detach(telemetry_id)
      restore(:gmail_provider, previous_provider)
      restore(:gmail_vault, previous_vault)
    end)

    {:ok, view, _} =
      live_isolated(context.conn, Harness, session: %{"workspace_id" => context.workspace.id})

    assert has_element?(
             view,
             "#mail-account-#{context.first.id} a[href='/workspaces/#{context.workspace.id}/accounts/#{context.first.id}/mail'][data-phx-link=patch]"
           )

    render_click(view, "mail:select", %{"id" => context.first.id})
    assert complete(view) =~ "Private inbox subject"

    assert has_element?(
             view,
             ".mail-inbox-heading #mail-search input[type=search][aria-label='Search Gmail']"
           )

    assert has_element?(view, "#mail-search button[type=submit]", "Search")

    assert has_element?(
             view,
             ".mail-register-row a[href='/workspaces/#{context.workspace.id}'][data-phx-link=patch]",
             "All accounts"
           )

    refute has_element?(view, "#mail-panel button", "Home")
    refute render(view) =~ "Search this entire Gmail account"
    refute inspect(:sys.get_state(view.pid).socket.assigns) =~ "Private inbox subject"

    assert has_element?(
             view,
             ".mail-pagination a[href='/workspaces/#{context.workspace.id}/accounts/#{context.first.id}/mail?page_token=next'][data-phx-link=patch]",
             "Next page"
           )

    render_click(view, "mail:next", %{})
    assert complete(view) =~ "Next page"
    view |> form("#mail-search", mail_search: %{query: "everywhere"}) |> render_submit()
    assert complete(view) =~ "Account-wide match"

    assert has_element?(
             view,
             "a#mail-thread-t1[href='/workspaces/#{context.workspace.id}/accounts/#{context.first.id}/mail/threads/t1?q=everywhere'][data-phx-link=patch]"
           )

    render_click(view, "mail:thread", %{"id" => "t1"})
    html = complete(view)
    assert html =~ "Private body &lt;img"
    assigns = :sys.get_state(view.pid).socket.assigns
    refute inspect(assigns) =~ "Private body"
    refute inspect(assigns) =~ "Private snippet"
    refute inspect(assigns) =~ "Private conversation subject"
    assert assigns.mail.thread_id == "t1"
    assert has_element?(view, "#mail-message-m1[open]")
    refute has_element?(view, "#mail-threads")

    assert has_element?(
             view,
             "a#mail-back[href='/workspaces/#{context.workspace.id}/accounts/#{context.first.id}/mail?q=everywhere'][data-phx-link=patch]"
           )

    render_click(view, "mail:back", %{})
    assert complete(view) =~ "Account-wide match"
    assert :sys.get_state(view.pid).socket.assigns.mail.query == "everywhere"
    assert has_element?(view, "#mail-thread-t1[data-mail-open-thread]")

    Phoenix.PubSub.broadcast(
      Monolith.PubSub,
      "mail:#{context.second.id}",
      {:mail_changed, context.second.id}
    )

    assert :sys.get_state(view.pid).socket.assigns.mail.account_id == context.first.id
    render_click(view, "mail:accounts", %{})
    assert ViewData.get(assigns.mail.data_ref) == nil
    rendered_sockets = drain_render_sockets([])
    assert rendered_sockets != []
    refute inspect(rendered_sockets) =~ "Private body"
    refute inspect(rendered_sockets) =~ "Private snippet"
    refute inspect(rendered_sockets) =~ "Private inbox subject"
    refute inspect(rendered_sockets) =~ "Private conversation subject"
  end

  test "429 PubSub updates and manual Refresh cannot start another provider call", context do
    {:ok, _} = Monolith.TestMail.start()
    Monolith.TestMailVault.put(context.first.id, "synthetic-ui-cooldown")
    previous_provider = Application.fetch_env(:monolith, :gmail_provider)
    previous_vault = Application.fetch_env(:monolith, :gmail_vault)
    Application.put_env(:monolith, :gmail_provider, Monolith.TestGoogle)
    Application.put_env(:monolith, :gmail_vault, Monolith.TestMailVault)

    on_exit(fn ->
      restore(:gmail_provider, previous_provider)
      restore(:gmail_vault, previous_vault)
    end)

    {:ok, view, _} =
      live_isolated(context.conn, Harness, session: %{"workspace_id" => context.workspace.id})

    render_click(view, "mail:select", %{"id" => context.first.id})
    assert complete(view) =~ "synthetic-ui-cooldown"

    entry =
      CacheEntry
      |> Ash.Query.for_read(:read, %{account_id: context.first.id}, actor: @owner)
      |> Ash.read_one!()

    CacheEntry
    |> Ash.Changeset.for_create(
      :store,
      %{
        account_id: entry.account_id,
        key: entry.key,
        generation: entry.generation,
        payload: entry.payload,
        bytes: entry.bytes,
        fetched_at: DateTime.add(DateTime.utc_now(), -181),
        expires_at: entry.expires_at
      },
      actor: @owner
    )
    |> Ash.create!()

    Monolith.TestMail.response({:error, :rate_limited})

    assert :ok =
             PollWorker.perform(%Oban.Job{
               args: %{"account_id" => context.first.id, "generation" => context.first.generation}
             })

    calls = Monolith.TestMail.calls()
    render(view)
    assert complete(view) =~ "rate limit"
    assert Monolith.TestMail.calls() == calls
    view |> element("#mail-account-view button", "Refresh") |> render_click()
    assert complete(view) =~ "rate limit"
    assert Monolith.TestMail.calls() == calls
  end

  def capture_render(_, _, %{socket: socket}, recipient),
    do: send(recipient, {:mail_render_socket, socket.assigns})

  defp drain_render_sockets(acc) do
    receive do
      {:mail_render_socket, assigns} -> drain_render_sockets([assigns | acc])
    after
      0 -> acc
    end
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:monolith, key, value)
  defp restore(key, :error), do: Application.delete_env(:monolith, key)

  defp account(name) do
    Mail.save_connection!(
      %{
        id: Ash.UUID.generate(),
        subject: "fake-#{name}",
        email: "#{name}@example.test",
        generation: Ash.UUID.generate()
      },
      actor: @owner
    )
  end

  defp select(socket, id) do
    {:noreply, socket} = HomeMail.handle_event("mail:select", %{"id" => id}, socket)
    socket
  end

  defp pending(socket, id, options \\ %{}) do
    socket = if socket.assigns.mail.account_id == id, do: socket, else: select(socket, id)

    args =
      Map.merge(
        %{
          account_id: id,
          workspace_id: socket.assigns.mail.workspace_id,
          owner: self(),
          kind: :page,
          query: nil,
          page_token: nil,
          thread_id: nil,
          force: false
        },
        options
      )

    assert {:ok, %{operation_id: operation}} = Mail.request_read(args, actor: @owner)
    change(socket, %{task: operation, loading: true})
  end

  defp settle(socket) do
    operation = socket.assigns.mail.task
    assert :ok = perform_job(ReadWorker, %{operation_id: operation})
    assert {:noreply, socket} = HomeMail.handle_info({:mail_operation, operation}, socket)
    socket
  end

  defp change(socket, values),
    do: Phoenix.Component.assign(socket, :mail, Map.merge(socket.assigns.mail, values))

  defp panel(socket, workspace),
    do: render_component(&MailComponents.panel/1, mail: socket.assigns.mail, workspace: workspace)
end
