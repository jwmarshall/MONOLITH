defmodule LovelaceWeb.HomeLive do
  @moduledoc "The glass entrance and local owner's saved workspaces."
  use LovelaceWeb, :live_view

  alias Lovelace.Mail.ConnectionDiagnostics
  alias Lovelace.Workspaces
  alias Lovelace.Workspaces.Workspace
  alias LovelaceWeb.{HomeMail, MailComponents}

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
        page_title: "Workspaces",
        background: background,
        selected: nil,
        editor: nil,
        form: nil,
        form_failed: false,
        workspaces_error: false,
        loading: not connected?(socket),
        save_status: ""
      )
      |> stream(:workspaces, [])
      |> HomeMail.init()

    socket = if connected?(socket), do: load_workspaces(socket), else: socket
    socket = resume_connection(socket, params)
    {:ok, socket}
  end

  @impl true
  def handle_info({:stage_background, %{url: _url, status: _status} = background}, socket) do
    {:noreply, assign(socket, :background, background)}
  end

  def handle_info({:mail_changed, _} = message, socket), do: HomeMail.handle_info(message, socket)
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_async(name, result, socket), do: HomeMail.handle_async(name, result, socket)

  @impl true
  def handle_event("mail:" <> _ = event, params, socket),
    do: HomeMail.handle_event(event, params, socket)

  def handle_event("retry_workspaces", _params, socket) do
    {:noreply, load_workspaces(socket)}
  end

  def handle_event("new_workspace", _params, socket) do
    form =
      Workspace
      |> AshPhoenix.Form.for_create(:create, as: "workspace", actor: @owner)
      |> to_form()

    {:noreply, assign(socket, editor: :new, form: form, form_failed: false, save_status: "")}
  end

  def handle_event("rename_workspace", %{"id" => id}, socket) do
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

  def handle_event("cancel_workspace", _params, socket) do
    {:noreply, socket |> assign(editor: nil, form: nil) |> focus_heading()}
  end

  def handle_event("validate_workspace", %{"workspace" => params}, socket) do
    if socket.assigns.form do
      form = AshPhoenix.Form.validate(socket.assigns.form, params)
      {:noreply, assign(socket, form: to_form(form), form_failed: false)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("save_workspace", %{"workspace" => params}, socket) do
    if socket.assigns.form do
      save_workspace(socket, params)
    else
      {:noreply, socket}
    end
  end

  def handle_event("open_workspace", %{"id" => id}, socket) do
    case Workspaces.get_workspace(id, actor: @owner) do
      {:ok, %Workspace{} = workspace} ->
        {:noreply,
         socket
         |> assign(selected: workspace, editor: nil, form: nil, page_title: workspace.name)
         |> HomeMail.open_workspace(workspace)
         |> focus_heading()}

      _ ->
        {:noreply, put_flash(socket, :error, "This workspace is unavailable. Try again.")}
    end
  end

  def handle_event("show_workspaces", _params, socket) do
    {:noreply,
     socket
     |> HomeMail.leave_workspace()
     |> assign(selected: nil, editor: nil, form: nil, page_title: "Workspaces")
     |> load_workspaces()
     |> focus_heading()}
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
         |> load_workspaces()
         |> focus_heading()}

      {:error, form} ->
        {:noreply, assign(socket, form: to_form(form), form_failed: true)}
    end
  end

  defp load_workspaces(socket) do
    with {:ok, _personal} <- Workspaces.initialize_personal(actor: @owner),
         {:ok, workspaces} <- Workspaces.list_workspaces(actor: @owner) do
      socket
      |> assign(workspaces_error: false, loading: false)
      |> stream(:workspaces, workspaces, reset: true)
    else
      _ -> assign(socket, workspaces_error: true, loading: false)
    end
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

    if connected?(socket) && is_binary(params["workspace"]) do
      case Workspaces.get_workspace(params["workspace"], actor: @owner) do
        {:ok, workspace} ->
          socket
          |> assign(selected: workspace, page_title: workspace.name)
          |> HomeMail.open_workspace(workspace)

        _ ->
          socket
      end
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
        <svg
          id="lovelace-monogram"
          class="workspace-monogram"
          viewBox="0 0 104 104"
          fill="none"
          xmlns="http://www.w3.org/2000/svg"
          aria-hidden="true"
          focusable="false"
        >
          <path
            id="lovelace-monogram-stroke"
            d="M16 82C34 65 64 23 56 12C48 1 33 37 29 63C24 94 41 88 57 70C73 51 89 18 80 12C70 3 56 42 52 66C47 91 62 90 88 71"
            stroke="currentColor"
            stroke-width="1.8"
            stroke-linecap="round"
            stroke-linejoin="round"
          />
        </svg>
        <p class="workspace-wordmark" aria-label="LOVELACE">
          <span
            :for={{letter, index} <- Enum.with_index(String.graphemes("LOVELACE"))}
            id={"lovelace-letter-#{index}"}
            class="workspace-letter"
          >{letter}</span>
        </p>
      </div>

      <div id="workspace-content" class="workspace-content" inert>
        <p id="workspace-save-status" class="sr-only" role="status">{@save_status}</p>
        <div class="workspace-topline">
          <span class="workspace-signature">LOVELACE</span>
          <.form for={%{}} action="/lock" method="post" id="owner-lock-form">
            <button type="submit" class="workspace-action">Lock</button>
          </.form>
        </div>

        <section class="workspace-directory" aria-labelledby="directory-heading">
          <button
            :if={@selected}
            id="back-to-workspaces"
            type="button"
            class="workspace-back workspace-action"
            phx-click="show_workspaces"
          >
            <span aria-hidden="true">←</span> All workspaces
          </button>

          <div class="workspace-directory-heading">
            <div>
              <h2 id="directory-heading" tabindex="-1" data-workspace-heading>
                {if @selected, do: @selected.name, else: "Workspaces"}
              </h2>
            </div>
            <button
              :if={!@selected && !@editor}
              id="new-workspace"
              type="button"
              class="workspace-action"
              phx-click="new_workspace"
              disabled={@loading || @workspaces_error}
            >
              New workspace
            </button>
            <button
              :if={@selected && !@editor}
              id="rename-current-workspace"
              type="button"
              class="workspace-action"
              phx-click="rename_workspace"
              phx-value-id={@selected.id}
            >
              Rename workspace
            </button>
          </div>

          <.form
            :if={@editor}
            for={@form}
            id="workspace-form"
            class="workspace-editor"
            phx-change="validate_workspace"
            phx-submit="save_workspace"
          >
            <h3 class="workspace-editor-title">
              {if @editor == :new, do: "New workspace", else: "Rename workspace"}
            </h3>
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
              phx-mounted={JS.focus()}
            />
            <p id="workspace-name-hint" class="workspace-form-hint">Use a name of 1–64 characters.</p>
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

          <div :if={!@selected} class="workspace-list" id="workspace-list" phx-update="stream">
            <div :for={{dom_id, workspace} <- @streams.workspaces} id={dom_id} class="workspace-row">
              <button
                id={"open-#{workspace.id}"}
                type="button"
                class="workspace-open"
                phx-click="open_workspace"
                phx-value-id={workspace.id}
                aria-label={"Open #{workspace.name}"}
              >
                <span class="workspace-row-name">{workspace.name}</span>
                <span class="workspace-row-enter" aria-hidden="true">Open</span>
              </button>
              <button
                id={"rename-#{workspace.id}"}
                type="button"
                class="workspace-row-rename workspace-action"
                phx-click="rename_workspace"
                phx-value-id={workspace.id}
                aria-label={"Rename #{workspace.name}"}
              >
                Rename
              </button>
            </div>
          </div>

          <p :if={@loading} id="workspaces-loading" class="workspace-notice" role="status">
            Opening your spaces…
          </p>
          <div :if={@workspaces_error} id="workspaces-error" class="workspace-notice" role="alert">
            <p>Your workspaces couldn’t be loaded. Your saved spaces have not been changed.</p>
            <button type="button" class="workspace-action" phx-click="retry_workspaces">Try again</button>
          </div>

          <div :if={@selected && !@editor} id="workspace-landing" class="workspace-landing">
            <MailComponents.panel mail={@mail} workspace={@selected} />
          </div>
        </section>

        <footer class="workspace-footer">
          <span><kbd>esc</kbd> Landscape</span>
        </footer>
      </div>
    </Layouts.app>
    """
  end
end
