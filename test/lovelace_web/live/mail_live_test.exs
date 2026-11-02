defmodule LovelaceWeb.MailLiveTest do
  # Exercise the delegated callbacks without HomeLive wiring, live Google, or Keychain.
  use LovelaceWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Lovelace.Mail
  alias Lovelace.Mail.{CacheEntry, PollWorker, ViewData}
  alias LovelaceWeb.{HomeMail, MailComponents}

  defmodule Harness do
    @moduledoc false
    use LovelaceWeb, :live_view

    @impl true
    def mount(_, %{"workspace_id" => id}, socket) do
      workspace = Lovelace.Workspaces.get_workspace!(id, actor: %{role: :local_owner})
      socket = Phoenix.Component.assign(socket, :workspace, workspace)
      {:ok, socket |> HomeMail.init() |> HomeMail.open_workspace(workspace)}
    end

    @impl true
    def handle_event(event, params, socket), do: HomeMail.handle_event(event, params, socket)
    @impl true
    def handle_info(message, socket), do: HomeMail.handle_info(message, socket)
    @impl true
    def handle_async(name, result, socket), do: HomeMail.handle_async(name, result, socket)
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
    def refresh("fake-refresh"), do: {:ok, %{access_token: "fake-access"}}

    def inbox("fake-access", token),
      do: page(if(token, do: "Next page", else: "Private inbox subject"))

    def search("fake-access", "everywhere", _), do: page("Account-wide match")

    def thread("fake-access", "t1") do
      {:ok,
       %{
         "id" => "t1",
         "messages" => [
           %{
             "id" => "m1",
             "subject" => "Private conversation subject",
             "from" => "sender@example.test",
             "to" => "first@example.test",
             "date" => "Yesterday",
             "text" => "Private body <img src=\"https://remote.test/pixel\">"
           }
         ]
       }}
    end

    defp page(subject),
      do:
        {:ok,
         %{
           "threads" => [
             %{
               "id" => "t1",
               "subject" => subject,
               "from" => "sender@example.test",
               "snippet" => "Private snippet",
               "date" => "Yesterday",
               "unread" => true
             }
           ],
           "next_page_token" => "next"
         }}
  end

  @owner %{role: :local_owner}

  setup do
    workspace = Lovelace.Workspaces.create_workspace!("Mail test", actor: @owner)
    other_workspace = Lovelace.Workspaces.create_workspace!("Other mail test", actor: @owner)
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
    assert {:noreply, socket} = HomeMail.handle_event("mail:add", %{}, context.socket)
    html = panel(socket, context.workspace)
    assert html =~ context.first.email
    assert html =~ context.second.email
    refute html =~ "Separate accounts"
    assert html =~ ~s(action="/oauth/google/start")
    assert html =~ ~s(method="post")
    assert html =~ ~s(name="_csrf_token")
    assert html =~ ~s(name="workspace_id" value="#{context.workspace.id}")
    refute html =~ "Disconnect everywhere"
    assert html =~ "Remove from workspace"
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
        task: {:mail, :view, context.workspace.id, context.first.id, 100}
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

  test "late account, workspace and generation results cannot cross boundaries", context do
    socket = select(context.socket, context.second.id)
    current_task = {:mail, :view, context.workspace.id, context.second.id, 300}
    socket = change(socket, %{generation: 300, loading: true, task: current_task})

    for name <- [
          {:mail, :view, context.workspace.id, context.first.id, 300},
          {:mail, :view, context.other_workspace.id, context.second.id, 300},
          {:mail, :view, context.workspace.id, context.second.id, 299}
        ] do
      assert {:noreply, ^socket} = HomeMail.handle_async(name, result(), socket)
    end

    assert {:noreply, accepted} = HomeMail.handle_async(current_task, result(), socket)
    refute accepted.assigns.mail.loading
  end

  test "completion rechecks membership, discarding results detached while in flight", context do
    socket = pending(context.socket, context.first.id)
    name = socket.assigns.mail.task
    assert {:ok, true} = Mail.unlink(context.workspace.id, context.first.id, actor: @owner)
    assert {:noreply, socket} = HomeMail.handle_async(name, result(), socket)
    assert socket.assigns.mail.account_id == nil
    assert socket.assigns.mail.data_ref == nil
    refute socket.assigns.mail.loading
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
             LazyHTML.query(document, "#mail-loading .mail-loading-track[aria-hidden=true]")
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

  test "successful page replaces the bounded list and retains truthful cache metadata", context do
    socket = pending(context.socket, context.first.id)
    threads = for n <- 1..25, do: %{"id" => "thread#{n}", "subject" => "Subject #{n}"}
    time = ~U[2026-11-01 12:00:00Z]
    ref = ViewData.put(%{"threads" => threads, "next_page_token" => "next"})

    reply =
      {:ok,
       {:ok,
        %{
          data: nil,
          data_ref: ref,
          fetched_at: time,
          cached: true,
          stale: true,
          error: :rate_limited
        }}}

    assert {:noreply, socket} = HomeMail.handle_async(socket.assigns.mail.task, reply, socket)
    assert socket.assigns.mail.data_ref == ref
    refute inspect(socket.assigns) =~ "Subject"
    assert socket.assigns.mail.next_page_token == "next"
    refute socket.assigns.mail.loading
    html = panel(socket, context.workspace)
    assert html =~ "rate limit"
    assert html =~ "stale local mail"
    assert html =~ "2026-11-01 12:00:00 UTC"
    assert html =~ "Local copy"
    refute html =~ "Subject 25"
  end

  test "empty and offline are distinct, and refresh failure preserves an existing copy",
       context do
    socket = pending(context.socket, context.first.id)
    assert {:noreply, socket} = HomeMail.handle_async(socket.assigns.mail.task, result(), socket)
    assert panel(socket, context.workspace) =~ "Your inbox is empty"

    socket =
      change(socket, %{
        task: {:mail, :view, context.workspace.id, context.first.id, 400},
        generation: 400,
        loading: true
      })

    reply = {:ok, {:ok, %{data: nil, error: :unavailable, fetched_at: nil, stale: true}}}
    assert {:noreply, socket} = HomeMail.handle_async(socket.assigns.mail.task, reply, socket)
    assert socket.assigns.mail.fetched_at == ~U[2026-11-01 12:00:00Z]
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
            "Reply #{n}\n\n> Quoted history\nSignature <img src='https://remote.test/pixel'>"
        }
      end

    socket = select(context.socket, context.first.id)
    ref = ViewData.put(%{"messages" => messages})
    socket = change(socket, %{thread_id: "t1", data_loaded: true, data_ref: ref})

    html = panel(socket, context.workspace)
    document = LazyHTML.from_fragment(html)
    assert ViewData.get(ref) == %{"messages" => messages}
    assert html =~ "Conversation title"

    assert LazyHTML.query(document, "#mail-conversation-heading") |> LazyHTML.text() ==
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

    assert LazyHTML.query(document, "#mail-threads, img, script, a") |> LazyHTML.to_tree() == []
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
    assert {:noreply, ^socket} = HomeMail.handle_async(name, result(), socket)
    assert {:noreply, ^socket} = HomeMail.handle_info({:mail_changed, context.first.id}, socket)
    assert {:noreply, ^socket} = HomeMail.handle_event("mail:unknown", %{}, socket)
    assert {:noreply, ^socket} = HomeMail.handle_async({:mail, :unknown}, {:exit, :bad}, socket)
  end

  test "global disconnect reports partial credential or revocation outcomes truthfully",
       context do
    socket = change(context.socket, %{command: {context.first.id, 700}})
    name = {:mail, :disconnect, context.workspace.id, context.first.id, 700}
    result = {:ok, {:ok, %{local_removed: true, credentials_removed: false, revoked: false}}}
    assert {:noreply, socket} = HomeMail.handle_async(name, result, socket)
    assert socket.assigns.mail.command == nil
    assert socket.assigns.mail.notice =~ "credentials could not be removed"
    assert socket.assigns.mail.notice =~ "revocation could not be confirmed"
  end

  test "real async delegation paginates, searches and renders bodies without socket payloads",
       context do
    previous_provider = Application.fetch_env(:lovelace, :gmail_provider)
    previous_vault = Application.fetch_env(:lovelace, :gmail_vault)
    Application.put_env(:lovelace, :gmail_provider, FakeProvider)
    Application.put_env(:lovelace, :gmail_vault, FakeVault)
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

    view |> element("#mail-account-#{context.first.id} .mail-account-open") |> render_click()
    assert render_async(view) =~ "Private inbox subject"

    assert has_element?(
             view,
             ".mail-inbox-heading #mail-search input[type=search][aria-label='Search Gmail']"
           )

    assert has_element?(view, "#mail-search button[type=submit]", "Search")
    assert has_element?(view, ".mail-toolbar button", "All accounts")
    refute has_element?(view, "#mail-panel button", "Home")
    refute render(view) =~ "Search this entire Gmail account"
    refute inspect(:sys.get_state(view.pid).socket.assigns) =~ "Private inbox subject"
    view |> element("button", "Next page") |> render_click()
    assert render_async(view) =~ "Next page"
    view |> form("#mail-search", mail_search: %{query: "everywhere"}) |> render_submit()
    assert render_async(view) =~ "Account-wide match"
    view |> element("#mail-thread-t1") |> render_click()
    html = render_async(view)
    assert html =~ "Private body &lt;img"
    assigns = :sys.get_state(view.pid).socket.assigns
    refute inspect(assigns) =~ "Private body"
    refute inspect(assigns) =~ "Private snippet"
    refute inspect(assigns) =~ "Private conversation subject"
    assert assigns.mail.thread_id == "t1"
    assert has_element?(view, "#mail-message-m1[open]")
    refute has_element?(view, "#mail-threads")
    view |> element("#mail-back") |> render_click()
    assert render_async(view) =~ "Account-wide match"
    assert :sys.get_state(view.pid).socket.assigns.mail.query == "everywhere"
    assert has_element?(view, "#mail-thread-t1[data-mail-open-thread]")

    Phoenix.PubSub.broadcast(
      Lovelace.PubSub,
      "mail:#{context.second.id}",
      {:mail_changed, context.second.id}
    )

    assert :sys.get_state(view.pid).socket.assigns.mail.account_id == context.first.id
    view |> element("button", "All accounts") |> render_click()
    assert ViewData.get(assigns.mail.data_ref) == nil
    rendered_sockets = drain_render_sockets([])
    assert rendered_sockets != []
    refute inspect(rendered_sockets) =~ "Private body"
    refute inspect(rendered_sockets) =~ "Private snippet"
    refute inspect(rendered_sockets) =~ "Private inbox subject"
    refute inspect(rendered_sockets) =~ "Private conversation subject"
  end

  test "429 PubSub updates and manual Refresh cannot start another provider call", context do
    {:ok, _} = Lovelace.TestMail.start()
    Lovelace.TestMailVault.put(context.first.id, "synthetic-ui-cooldown")
    previous_provider = Application.fetch_env(:lovelace, :gmail_provider)
    previous_vault = Application.fetch_env(:lovelace, :gmail_vault)
    Application.put_env(:lovelace, :gmail_provider, Lovelace.TestGoogle)
    Application.put_env(:lovelace, :gmail_vault, Lovelace.TestMailVault)

    on_exit(fn ->
      restore(:gmail_provider, previous_provider)
      restore(:gmail_vault, previous_vault)
    end)

    {:ok, view, _} =
      live_isolated(context.conn, Harness, session: %{"workspace_id" => context.workspace.id})

    view |> element("#mail-account-#{context.first.id} .mail-account-open") |> render_click()
    assert render_async(view) =~ "synthetic-ui-cooldown"

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

    Lovelace.TestMail.response({:error, :rate_limited})

    assert :ok =
             PollWorker.perform(%Oban.Job{
               args: %{"account_id" => context.first.id, "generation" => context.first.generation}
             })

    calls = Lovelace.TestMail.calls()
    render(view)
    assert render_async(view) =~ "rate limit"
    assert Lovelace.TestMail.calls() == calls
    view |> element("#mail-account-view button", "Refresh") |> render_click()
    assert render_async(view) =~ "rate limit"
    assert Lovelace.TestMail.calls() == calls
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

  defp restore(key, {:ok, value}), do: Application.put_env(:lovelace, key, value)
  defp restore(key, :error), do: Application.delete_env(:lovelace, key)

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

  defp pending(socket, id) do
    socket = select(socket, id)
    generation = socket.assigns.mail.generation

    change(socket, %{
      task: {:mail, :view, socket.assigns.mail.workspace_id, id, generation},
      loading: true
    })
  end

  defp change(socket, values),
    do: Phoenix.Component.assign(socket, :mail, Map.merge(socket.assigns.mail, values))

  defp panel(socket, workspace),
    do: render_component(&MailComponents.panel/1, mail: socket.assigns.mail, workspace: workspace)

  defp result,
    do:
      {:ok,
       {:ok,
        %{
          data: nil,
          data_ref: ViewData.put(%{"threads" => []}),
          fetched_at: ~U[2026-11-01 12:00:00Z],
          cached: false,
          stale: false,
          error: nil
        }}}
end
