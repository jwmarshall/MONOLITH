defmodule LovelaceWeb.HomeLive do
  @moduledoc "The local owner's daily orientation, workspaces and separate Gmail accounts."
  use LovelaceWeb, :live_view

  alias Lovelace.Mail
  alias Lovelace.Mail.ConnectionDiagnostics
  alias Lovelace.Workspaces
  alias Lovelace.Workspaces.Workspace

  alias LovelaceWeb.{
    CalendarComponents,
    GeminiComponents,
    HomeCalendar,
    HomeComponents,
    HomeGemini,
    HomeMail,
    HomeNavigation,
    HomeScenes,
    MailComponents,
    SceneComponents,
    WorkspaceComponents
  }

  # Capability minted only behind the HTTP and LiveView owner-session boundaries.
  @owner %{role: :local_owner}

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Lovelace.PubSub, "stage_designer")

    background =
      case Lovelace.StageDesigner.background() do
        {:ok, background} -> background
        {:error, _reason} -> %{url: nil, status: :unavailable}
      end

    socket =
      socket
      |> assign(
        page_title: "Home",
        home: true,
        navigation_ready: false,
        navigation_path: nil,
        home_accounts: [],
        home_error: false,
        background: background,
        selected: nil,
        connections: false,
        connection_view: :index,
        workspace_options: [],
        workspace_health: %{},
        directory_subscriptions: [],
        editor: nil,
        form: nil,
        form_failed: false,
        workspaces_error: false,
        loading: not connected?(socket),
        save_status: ""
      )
      |> stream(:workspaces, [])
      |> HomeMail.init()
      |> HomeCalendar.init()
      |> HomeGemini.init()
      |> HomeScenes.init()

    socket = if connected?(socket), do: load_workspaces(socket), else: socket
    socket = resume_connection(socket, params)
    {:ok, socket}
  end

  @impl true
  def handle_info({:stage_background, %{url: _url, status: _status} = background}, socket) do
    socket = assign(socket, :background, background)
    {:noreply, if(socket.assigns.scenes, do: HomeScenes.refresh(socket), else: socket)}
  end

  def handle_info({:mail_changed, id} = message, socket) do
    socket = HomeCalendar.reload(socket)

    if id in socket.assigns.directory_subscriptions do
      {:noreply, load_workspaces(socket)}
    else
      reconcile_mail_navigation(socket, HomeMail.handle_info(message, socket))
    end
  end

  def handle_info({:calendar_changed, id}, socket) do
    if id in socket.assigns.directory_subscriptions || id in socket.assigns.mail.subscriptions do
      {:noreply, HomeCalendar.changed(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_async(name, result, socket) when name in [:scene_gallery, :scene_request],
    do: HomeScenes.handle_async(name, result, socket)

  def handle_async(:gemini_status, result, socket), do: HomeGemini.handle_async(result, socket)

  def handle_async(name, result, socket),
    do: reconcile_mail_navigation(socket, HomeMail.handle_async(name, result, socket))

  @impl true
  def handle_event(name, params, socket) do
    {:noreply, socket} = event(name, params, socket)
    path = HomeNavigation.current(socket)

    {:noreply,
     if(path == socket.assigns.navigation_path, do: socket, else: push_patch(socket, to: path))}
  end

  defp event("calendar:" <> _ = event, params, socket),
    do: HomeCalendar.handle_event(event, params, socket)

  defp event("mail:accounts", _params, %{assigns: %{mail: %{scope: :home}}} = socket),
    do: event("show_home", %{}, socket)

  defp event("mail:" <> _ = event, params, socket),
    do: HomeMail.handle_event(event, params, socket)

  defp event("scenes:" <> _ = event, params, %{assigns: %{scenes: true}} = socket),
    do: HomeScenes.handle_event(event, params, socket)

  defp event("scenes:" <> _, _params, socket), do: {:noreply, socket}

  defp event("show_scenes", _params, socket) do
    {:noreply,
     socket
     |> HomeMail.leave_workspace()
     |> directory_subscriptions([])
     |> assign(
       home: false,
       selected: nil,
       connections: false,
       editor: nil,
       form: nil,
       page_title: "Scenes"
     )
     |> HomeScenes.open()
     |> focus_heading()}
  end

  defp event("show_home", _params, socket) do
    {:noreply,
     socket
     |> HomeScenes.leave()
     |> HomeMail.leave_workspace()
     |> assign(
       home: true,
       scenes: false,
       scene_confirmation: false,
       selected: nil,
       connections: false,
       editor: nil,
       form: nil,
       page_title: "Home"
     )
     |> load_workspaces()
     |> focus_heading()}
  end

  defp event("open_home_account", %{"id" => id}, socket) do
    socket = load_workspaces(socket)

    if Enum.any?(socket.assigns.home_accounts, &(&1.id == id)) do
      {:noreply,
       socket
       |> HomeScenes.leave()
       |> directory_subscriptions([])
       |> assign(
         home: false,
         scenes: false,
         scene_confirmation: false,
         selected: nil,
         connections: false,
         editor: nil,
         form: nil,
         page_title: "Inbox"
       )
       |> HomeMail.open_home_account(id)
       |> focus_heading()}
    else
      {:noreply, put_flash(socket, :error, "This account is unavailable. Check Connections.")}
    end
  end

  defp event(
         "gemini:check",
         _params,
         %{assigns: %{connections: true, connection_view: :gemini}} = socket
       ),
       do: {:noreply, HomeGemini.open(socket)}

  defp event("gemini:check", _params, socket), do: {:noreply, socket}

  defp event(
         "select_connection",
         %{"provider" => provider},
         %{assigns: %{connections: true}} = socket
       )
       when provider in ["gemini", "gmail", "calendar"] do
    view =
      Map.fetch!(%{"gemini" => :gemini, "gmail" => :gmail, "calendar" => :calendar}, provider)

    if view == socket.assigns.connection_view do
      {:noreply, socket}
    else
      socket =
        if socket.assigns.connection_view == :index, do: focus_heading(socket), else: socket

      socket = socket |> HomeMail.close_connection() |> assign(:connection_view, view)
      {:noreply, if(view == :gemini, do: HomeGemini.open(socket), else: socket)}
    end
  end

  defp event("select_connection", _params, socket), do: {:noreply, socket}

  defp event(
         "show_connections",
         _params,
         %{assigns: %{connections: true, connection_view: :index}} = socket
       ),
       do: {:noreply, socket}

  defp event("show_connections", _params, socket) do
    {:noreply,
     socket
     |> HomeScenes.leave()
     |> directory_subscriptions([])
     |> assign(
       home: false,
       connections: true,
       selected: nil,
       scenes: false,
       scene_confirmation: false,
       connection_view: :index,
       editor: nil,
       form: nil,
       page_title: "Connections"
     )
     |> HomeMail.open_connections()
     |> focus_heading()}
  end

  defp event("retry_workspaces", _params, socket) do
    {:noreply, load_workspaces(socket)}
  end

  defp event("new_workspace", _params, socket) do
    form =
      Workspace
      |> AshPhoenix.Form.for_create(:create, as: "workspace", actor: @owner)
      |> to_form()

    {:noreply, assign(socket, editor: :new, form: form, form_failed: false, save_status: "")}
  end

  defp event("rename_workspace", %{"id" => id}, socket) do
    case Workspaces.get_workspace(id, actor: @owner) do
      {:ok, %Workspace{} = workspace} ->
        form =
          workspace
          |> AshPhoenix.Form.for_update(:rename, as: "workspace", actor: @owner)
          |> to_form()

        {:noreply,
         assign(socket, editor: :rename, form: form, form_failed: false, save_status: "")}

      _ ->
        {:noreply, put_flash(socket, :error, "This workspace is unavailable. Try again.")}
    end
  end

  defp event("cancel_workspace", _params, socket) do
    {:noreply, assign(socket, editor: nil, form: nil)}
  end

  defp event("validate_workspace", %{"workspace" => params}, socket) do
    if socket.assigns.form do
      form = AshPhoenix.Form.validate(socket.assigns.form, params)
      {:noreply, assign(socket, form: to_form(form), form_failed: false)}
    else
      {:noreply, socket}
    end
  end

  defp event("save_workspace", %{"workspace" => params}, socket) do
    if socket.assigns.form do
      save_workspace(socket, params)
    else
      {:noreply, socket}
    end
  end

  defp event("open_workspace", %{"id" => id}, socket) do
    case Workspaces.get_workspace(id, actor: @owner) do
      {:ok, %Workspace{} = workspace} ->
        {:noreply,
         socket
         |> HomeScenes.leave()
         |> directory_subscriptions([])
         |> assign(
           home: false,
           selected: workspace,
           scenes: false,
           scene_confirmation: false,
           connections: false,
           editor: nil,
           form: nil,
           page_title: workspace.name
         )
         |> HomeMail.open_workspace(workspace)
         |> focus_heading()}

      _ ->
        {:noreply, put_flash(socket, :error, "This workspace is unavailable. Try again.")}
    end
  end

  defp event("show_workspaces", _params, socket) do
    {:noreply,
     socket
     |> HomeScenes.leave()
     |> HomeMail.leave_workspace()
     |> assign(
       home: false,
       scenes: false,
       scene_confirmation: false,
       selected: nil,
       connections: false,
       editor: nil,
       form: nil,
       page_title: "Workspaces"
     )
     |> load_workspaces()
     |> focus_heading()}
  end

  @impl true
  def handle_params(params, uri, socket) do
    {:noreply, if(connected?(socket), do: navigate_params(socket, params, uri), else: socket)}
  end

  defp navigate_params(socket, params, uri) do
    %{path: path, query: query} = URI.parse(uri)
    path = if query, do: path <> "?" <> query, else: path

    socket =
      if socket.assigns.navigation_ready && HomeNavigation.current(socket) == path,
        do: socket,
        else: visit(socket, params)

    canonical = HomeNavigation.current(socket)
    socket = assign(socket, navigation_ready: true, navigation_path: canonical)
    if path == canonical, do: socket, else: push_patch(socket, to: canonical, replace: true)
  end

  # Account removal can arrive through PubSub or a delayed completion. Leave the
  # invalid route completely, rather than keeping an account-shaped empty shell.
  defp reconcile_mail_navigation(previous, {:noreply, socket}) do
    if previous.assigns.mail.account_id && is_nil(socket.assigns.mail.account_id) do
      socket =
        unavailable_destination(
          socket,
          "This account is no longer available in this view. Check Connections."
        )

      {:noreply, push_patch(socket, to: HomeNavigation.current(socket), replace: true)}
    else
      {:noreply, socket}
    end
  end

  defp visit(socket, params) do
    case HomeNavigation.destination(socket.assigns.live_action, params) do
      {:ok, destination} -> visit_destination(socket, destination)
      _ -> unavailable_destination(socket, "This link is invalid. Choose a view from navigation.")
    end
  end

  defp visit_destination(socket, %{action: :index}), do: transition(socket, "show_home")

  defp visit_destination(socket, %{action: :workspaces}),
    do: transition(socket, "show_workspaces")

  defp visit_destination(socket, %{action: :connections}),
    do: transition(socket, "show_connections")

  defp visit_destination(socket, %{action: :connection, provider: provider}) do
    socket =
      if socket.assigns.connections, do: socket, else: transition(socket, "show_connections")

    transition(socket, "select_connection", %{"provider" => to_string(provider)})
  end

  defp visit_destination(socket, %{action: :scenes, page: page}) do
    socket = if socket.assigns.scenes, do: socket, else: transition(socket, "show_scenes")

    if socket.assigns.scene_page == page,
      do: socket,
      else: socket |> assign(:scene_page, page) |> HomeScenes.refresh()
  end

  defp visit_destination(socket, %{action: action} = destination)
       when action in [:workspace, :integration_add, :workspace_inbox, :workspace_thread] do
    socket = select_workspace(socket, destination.workspace_id)

    if socket.assigns.selected && socket.assigns.selected.id == destination.workspace_id do
      visit_workspace(socket, destination)
    else
      unavailable_destination(socket, "This workspace is unavailable. Choose another workspace.")
    end
  end

  defp visit_destination(socket, %{action: action} = destination)
       when action in [:inbox, :thread] do
    socket =
      if socket.assigns.mail.scope == :home do
        socket
      else
        socket
        |> HomeScenes.leave()
        |> directory_subscriptions([])
        |> assign(
          home: false,
          selected: nil,
          connections: false,
          editor: nil,
          form: nil,
          page_title: "Inbox"
        )
        |> HomeMail.open_home()
        |> focus_heading()
      end

    visit_mail(socket, destination)
  end

  defp visit_workspace(socket, destination) do
    socket =
      if socket.assigns.connections ||
           (socket.assigns.mail.account_id && is_nil(destination.account_id)),
         do: transition(socket, "open_workspace", %{"id" => destination.workspace_id}),
         else: socket

    cond do
      destination.account_id -> visit_mail(socket, destination)
      destination.action == :integration_add -> transition(socket, "mail:add")
      socket.assigns.mail.adding -> transition(socket, "mail:close_add")
      true -> socket
    end
  end

  defp visit_mail(socket, destination) do
    socket = HomeMail.navigate(socket, destination)

    if socket.assigns.mail.account_id == destination.account_id,
      do: socket,
      else:
        unavailable_destination(
          socket,
          "This account is unavailable in this view. Check Connections."
        )
  end

  defp select_workspace(socket, id) do
    if socket.assigns.selected && socket.assigns.selected.id == id,
      do: socket,
      else: transition(socket, "open_workspace", %{"id" => id})
  end

  defp unavailable_destination(socket, message) do
    socket |> transition("show_workspaces") |> put_flash(:error, message)
  end

  defp transition(socket, name, params \\ %{}) do
    {:noreply, socket} = event(name, params, socket)
    socket
  end

  defp save_workspace(socket, params) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, workspace} ->
        selected = socket.assigns.selected
        selected = if selected && selected.id == workspace.id, do: workspace, else: selected

        {:noreply,
         socket
         |> assign(
           selected: selected,
           editor: nil,
           form: nil,
           page_title: if(selected, do: selected.name, else: "Workspaces"),
           save_status: "Workspace saved."
         )
         |> load_workspaces()}

      {:error, form} ->
        {:noreply, assign(socket, form: to_form(form), form_failed: true)}
    end
  end

  defp load_workspaces(socket) do
    with {:ok, _personal} <- Workspaces.initialize_personal(actor: @owner),
         {:ok, workspaces} <- Workspaces.list_workspaces(actor: @owner) do
      socket
      |> assign(
        workspaces_error: false,
        loading: false,
        workspace_options: Enum.map(workspaces, &{&1.name, &1.id})
      )
      |> load_workspace_health(workspaces)
      |> HomeCalendar.reload()
      |> stream(:workspaces, workspaces, reset: true)
    else
      _ -> assign(socket, workspaces_error: true, home_error: true, loading: false)
    end
  end

  # Read persisted metadata only. Rendering never fetches mail or provider counts.
  defp load_workspace_health(socket, workspaces) do
    with {:ok, accounts} <- Mail.list_accounts(actor: @owner),
         {:ok, memberships} <- Mail.list_workspace_accounts(actor: @owner) do
      by_id = Map.new(accounts, &{&1.id, &1})
      grouped = Enum.group_by(memberships, & &1.workspace_id, & &1.account_id)

      health =
        Map.new(workspaces, fn workspace ->
          attached =
            grouped
            |> Map.get(workspace.id, [])
            |> Enum.map(&Map.get(by_id, &1))
            |> Enum.reject(&is_nil/1)

          problems =
            attached
            |> Enum.filter(&(&1.status != :ready || not is_nil(&1.last_error)))
            |> Enum.map(&Map.take(&1, [:id, :email, :status, :last_error]))

          {workspace.id, %{total: length(attached), problems: problems}}
        end)

      names = Map.new(workspaces, &{&1.id, &1.name})

      summaries =
        accounts
        |> Enum.reject(&(&1.status == :disconnected))
        |> Enum.map(fn account ->
          labels =
            memberships
            |> Enum.filter(&(&1.account_id == account.id))
            |> Enum.map(&Map.get(names, &1.workspace_id))
            |> Enum.reject(&is_nil/1)
            |> Enum.sort()

          account
          |> Map.take([
            :id,
            :email,
            :status,
            :last_error,
            :inbox_unread_count,
            :inbox_unread_at,
            :inbox_unread_error
          ])
          |> Map.put(:workspaces, labels)
        end)

      ids = Enum.map(accounts, & &1.id)

      browsing =
        socket.assigns.scenes || socket.assigns.selected || socket.assigns.connections ||
          socket.assigns.mail.scope == :home

      ids = if browsing, do: [], else: ids

      socket
      |> assign(workspace_health: health, home_accounts: summaries, home_error: false)
      |> directory_subscriptions(ids)
    else
      _ ->
        socket
        |> assign(workspace_health: %{}, home_accounts: [], home_error: true)
        |> directory_subscriptions([])
    end
  end

  defp directory_subscriptions(socket, ids) do
    old = socket.assigns.directory_subscriptions

    if connected?(socket) do
      Enum.each(old -- ids, &Phoenix.PubSub.unsubscribe(Lovelace.PubSub, "mail:#{&1}"))
      Enum.each(ids -- old, &Phoenix.PubSub.subscribe(Lovelace.PubSub, "mail:#{&1}"))
    end

    assign(socket, :directory_subscriptions, ids)
  end

  defp resume_connection(socket, params) do
    socket =
      case params["gmail"] do
        "connected" ->
          put_flash(socket, :info, "Gmail connected. Mail access is read-only.")

        "failed" ->
          put_flash(
            socket,
            :error,
            ConnectionDiagnostics.message(params["stage"], params["reason"])
          )

        _ ->
          socket
      end

    socket
    |> resume_calendar(params)
    |> resume_gemini(params)
  end

  defp resume_calendar(socket, %{"calendar" => "connected"}) do
    socket
    |> put_flash(:info, "Calendar connected. Event access is read-only.")
    |> HomeCalendar.reload()
  end

  defp resume_calendar(socket, _params), do: socket

  defp resume_gemini(socket, params) do
    if connected?(socket) && (params["connections"] == "gemini" || params["provider"] == "gemini") do
      message =
        case params["gemini"] do
          "saved" ->
            {:info, "Gemini API key saved in Keychain. No generation was started."}

          "removed" ->
            {:info, "Gemini API key removed. Existing scenery is unchanged."}

          "failed" ->
            {:error,
             "Gemini key could not be updated. Check the key format and Keychain access, then try again."}

          _ ->
            nil
        end

      if message, do: put_flash(socket, elem(message, 0), elem(message, 1)), else: socket
    else
      socket
    end
  end

  defp focus_heading(socket), do: push_event(socket, "workspace:focus-heading", %{})

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} background={@background}>
      <h1 id="workspace-title" class="sr-only">LOVELACE</h1>
      <div
        id="workspace-brand"
        class="workspace-brand"
        aria-hidden="true"
        phx-hook="BrandReveal"
        phx-update="ignore"
      >
        <Layouts.monogram
          id="lovelace-monogram"
          class="workspace-monogram"
          stroke_id="lovelace-monogram-stroke"
        />
        <p class="workspace-wordmark" aria-label="LOVELACE">
          <span
            :for={{letter, index} <- Enum.with_index(String.graphemes("LOVELACE"))}
            id={"lovelace-letter-#{index}"}
            class="workspace-letter"
          >{letter}</span>
        </p>
      </div>

      <div id="workspace-content" class="workspace-content" inert>
        <span id="calendar-context" phx-hook="CalendarDay" class="hidden" aria-hidden="true"></span>
        <p id="workspace-save-status" class="sr-only" role="status">{@save_status}</p>
        <div class="workspace-topline">
          <nav id="center-nav" class="center-nav" aria-label="Main navigation">
            <.link
              id="home-link"
              patch="/"
              class="workspace-nav-link"
              aria-label="Home"
              aria-current={if @home, do: "page"}
              aria-disabled={if @editor, do: "true"}
            >Home</.link>
            <.link
              id="show-workspaces"
              patch="/workspaces"
              class="workspace-nav-link"
              aria-current={
                if !@home && !@connections && !@scenes && @mail.scope != :home, do: "page"
              }
              aria-disabled={if @editor, do: "true"}
            >Workspaces</.link>
            <.link
              id="show-connections"
              patch="/connections"
              class="workspace-nav-link"
              aria-current={if @connections, do: "page"}
              aria-disabled={if @editor, do: "true"}
            >Connections</.link>
            <.link
              id="show-scenes"
              patch="/scenes"
              class="workspace-nav-link"
              aria-current={if @scenes, do: "page"}
              aria-disabled={if @editor, do: "true"}
            >Scenes</.link>
          </nav>
        </div>

        <section
          class={["workspace-directory", @home && "workspace-directory-home"]}
          aria-labelledby="directory-heading"
        >
          <.link
            :if={@selected && !@connections}
            id="back-to-workspaces"
            patch="/workspaces"
            class="workspace-back workspace-action"
          >
            <span aria-hidden="true">←</span> All workspaces
          </.link>

          <.link
            :if={@connections && @connection_view != :index}
            id="back-to-connections"
            patch="/connections"
            class="workspace-back workspace-action"
          >
            <.icon name="hero-arrow-left" class="size-4" /> All connections
          </.link>

          <HomeComponents.daily_heading :if={@home} />

          <div :if={!@home} class="workspace-directory-heading">
            <div>
              <h2 id="directory-heading" tabindex="-1" data-workspace-heading>
                {cond do
                  @scenes -> "Scenes"
                  @connections -> "Connections"
                  @selected -> @selected.name
                  @mail.scope == :home -> "Inbox"
                  true -> "Workspaces"
                end}
              </h2>
            </div>
            <nav
              :if={@connections && @connection_view != :index}
              id="connections-subnav"
              class="connections-subnav"
              aria-label="Connection providers"
            >
              <.link
                id="connections-gemini"
                patch={HomeNavigation.connections_path(:gemini)}
                class="workspace-nav-link"
                aria-current={if @connection_view == :gemini, do: "page"}
              >Gemini</.link>
              <.link
                id="connections-gmail"
                patch={HomeNavigation.connections_path(:gmail)}
                class="workspace-nav-link"
                aria-current={if @connection_view == :gmail, do: "page"}
              >Gmail</.link>
              <.link
                id="connections-calendar"
                patch={HomeNavigation.connections_path(:calendar)}
                class="workspace-nav-link"
                aria-current={if @connection_view == :calendar, do: "page"}
              >Calendar</.link>
            </nav>
            <button
              :if={!@selected && !@connections && !@scenes && @mail.scope != :home && !@editor}
              id="new-workspace"
              type="button"
              class="workspace-action"
              phx-click="new_workspace"
              disabled={@loading || @workspaces_error}
            >
              <.icon name="hero-plus" class="size-4" /> New workspace
            </button>
            <WorkspaceComponents.workspace_menu
              :if={@selected && !@connections && !@editor}
              workspace={@selected}
              current
            />
          </div>

          <LovelaceWeb.ModalComponents.modal
            :if={@editor}
            id="workspace-modal"
            title={if @editor == :new, do: "New workspace", else: "Rename workspace"}
            on_cancel="cancel_workspace"
            initial_focus="#workspace-name"
            return_focus={
              if @editor == :new,
                do: "#new-workspace",
                else: "#workspace-menu-#{@form.source.data.id} summary"
            }
          >
            <.form
              for={@form}
              id="workspace-form"
              class="workspace-modal-form"
              phx-change="validate_workspace"
              phx-submit="save_workspace"
            >
              <.input
                field={@form[:name]}
                id="workspace-name"
                label="Name"
                class="workspace-name-input"
                maxlength="64"
                required
                autocomplete="off"
                aria-invalid={if @form[:name].errors != [], do: "true", else: "false"}
                aria-describedby="workspace-name-hint workspace-form-feedback"
              />
              <p id="workspace-name-hint" class="workspace-form-hint">
                Use a name of 1–64 characters.
              </p>
              <p id="workspace-form-feedback" class="workspace-form-feedback" role="alert">
                {if @form_failed,
                  do: "The workspace couldn’t be saved. Check the name and try again."}
              </p>
              <div class="workspace-editor-actions">
                <button
                  type="submit"
                  class="workspace-action workspace-action-primary"
                  phx-disable-with="Saving…"
                >
                  {if @editor == :new, do: "Create workspace", else: "Save name"}
                </button>
                <button type="button" class="workspace-action" phx-click="cancel_workspace">Cancel</button>
              </div>
            </.form>
          </LovelaceWeb.ModalComponents.modal>

          <div
            :if={!@home && !@selected && !@connections && !@scenes && @mail.scope != :home}
            class="workspace-list"
            id="workspace-list"
            phx-update="stream"
          >
            <WorkspaceComponents.card
              :for={{dom_id, workspace} <- @streams.workspaces}
              id={dom_id}
              workspace={workspace}
              health={Map.get(@workspace_health, workspace.id)}
            />
          </div>

          <div :if={@home} id="home-readouts" class="home-readouts">
            <HomeComponents.overview
              accounts={@home_accounts}
              loading={@loading}
              error={@home_error}
            />

            <CalendarComponents.agenda
              home
              accounts={Enum.filter(@calendar_accounts, & &1.calendar_enabled)}
              window={@calendar_window}
              refresh={@calendar_revision}
            />
          </div>

          <div
            :if={!@home && !@connections && @mail.scope == :home}
            id="home-inbox"
            class="workspace-landing"
          >
            <MailComponents.panel mail={@mail} />
          </div>

          <p
            :if={@loading && !@home && !@scenes}
            id="workspaces-loading"
            class="workspace-notice"
            role="status"
          >
            <.status_signal
              id="workspaces-loading-signal"
              state={:active}
              label="Opening your spaces…"
            />
          </p>
          <div
            :if={@workspaces_error && !@home && !@scenes}
            id="workspaces-error"
            class="workspace-notice"
            role="alert"
          >
            <p>Your workspaces couldn’t be loaded. Your saved spaces have not been changed.</p>
            <button type="button" class="workspace-action" phx-click="retry_workspaces">Try again</button>
          </div>

          <SceneComponents.gallery
            :if={@scenes}
            data={@scene_data}
            loading={@scene_loading}
            error={@scene_error}
            pending={@scene_request_pending}
            notice={@scene_notice}
            confirmation={@scene_confirmation}
          />

          <LovelaceWeb.ConnectionComponents.overview :if={@connections && @connection_view == :index} />

          <GeminiComponents.connection
            :if={@connections && @connection_view == :gemini}
            status={@gemini_status}
          />

          <MailComponents.connections
            :if={@connections && @connection_view == :gmail}
            mail={@mail}
            workspace_options={@workspace_options}
          />

          <CalendarComponents.connections
            :if={@connections && @connection_view == :calendar}
            accounts={@calendar_accounts}
            workspace_options={@workspace_options}
            window={@calendar_window}
            refresh={@calendar_revision}
          />

          <div
            :if={@selected && !@connections && !@editor}
            id="workspace-landing"
            class="workspace-landing"
          >
            <MailComponents.panel mail={@mail} workspace={@selected} />
            <CalendarComponents.agenda
              :if={!@mail.account_id && !@mail.adding}
              accounts={
                Enum.filter(@calendar_accounts, &(&1.calendar_enabled && &1.id in @mail.memberships))
              }
              window={@calendar_window}
              refresh={@calendar_revision}
            />
          </div>
        </section>
      </div>
      <div id="workspace-controls" class="workspace-controls" inert>
        <.form for={%{}} action="/lock" method="post" id="owner-lock-form">
          <button type="submit" class="workspace-action">Lock</button>
        </.form>
        <footer class="workspace-footer">
          <span><kbd>esc</kbd> Landscape</span>
        </footer>
      </div>
    </Layouts.app>
    """
  end
end
