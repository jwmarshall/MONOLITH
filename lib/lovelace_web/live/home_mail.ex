defmodule LovelaceWeb.HomeMail do
  @moduledoc """
  Mail state and callbacks delegated by HomeLive after owner unlock.

  Call `init/1` at mount, `open_workspace/2` or `open_connections/1` on entry
  and `leave_workspace/1` on exit. Subscriptions track attached accounts or the
  global connection list; only updates for the selected account refresh its view.
  Delegate `mail:*` events, `{:mail_changed, id}` messages and async
  names beginning with `:mail`. Render `MailComponents.panel mail={@mail}
  workspace={@selected}`. All state lives in `:mail`; it contains no credentials
  or provider content. `:data_ref` resolves through Mail.ViewData only at render.
  Workers publish payloads there before returning an opaque result to LiveView.
  Lists replace rather than accumulate (at most 20 threads per page).
  """
  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [connected?: 1, start_async: 3, cancel_async: 2]

  alias Lovelace.Mail
  alias Lovelace.Mail.ViewData

  @owner %{role: :local_owner}

  def init(socket), do: assign(socket, :mail, initial())
  def close_connection(socket), do: put(socket, %{connecting: false})

  def open_workspace(socket, %{id: id}) do
    socket
    |> leave_workspace()
    |> put(%{workspace_id: id})
    |> load_accounts()
  end

  def open_home_account(socket, id) do
    socket
    |> leave_workspace()
    |> put(%{scope: :home})
    |> load_accounts()
    |> event_select(id)
  end

  defp event_select(socket, id), do: event("mail:select", %{"id" => id}, socket)

  def open_connections(socket) do
    socket
    |> leave_workspace()
    |> put(%{scope: :connections})
    |> load_accounts()
  end

  def leave_workspace(socket) do
    socket = socket |> cancel_view() |> cancel_credential_check()
    Enum.each(socket.assigns.mail.subscriptions, &unsubscribe/1)
    ViewData.clear()
    assign(socket, :mail, initial())
  end

  def handle_event(event, params, socket) do
    {:noreply, event(event, params, socket)}
  end

  def handle_info({:mail_changed, id}, socket) do
    if id in socket.assigns.mail.subscriptions do
      socket = load_accounts(socket)
      # Metadata updates from another account must never fetch the selected inbox.
      refresh = socket.assigns.mail.account_id == id
      {:noreply, if(refresh, do: request(socket, false), else: socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_, socket), do: {:noreply, socket}

  def handle_async({:mail, :view, workspace, account, generation} = name, result, socket) do
    mail = socket.assigns.mail

    if mail.workspace_id == workspace && mail.account_id == account &&
         mail.generation == generation && mail.task == name do
      socket = load_accounts(socket)

      if socket.assigns.mail.account_id == account do
        {:noreply, apply_result(socket, result)}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_async({:mail, :disconnect, workspace, account, generation}, result, socket) do
    mail = socket.assigns.mail

    if mail.workspace_id == workspace && mail.command == {account, generation} do
      notice = disconnect_notice(result)
      {:noreply, socket |> put(%{command: nil, notice: notice}) |> load_accounts()}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:mail, :credential_check, id, generation, request_id}, result, socket) do
    mail = socket.assigns.mail

    if mail.scope == :connections && mail.credential_check == {id, generation, request_id} do
      socket = load_accounts(socket)
      current = Enum.find(socket.assigns.mail.accounts, &(&1.id == id))

      checks =
        if current && current.generation == generation && current.status != :disconnected do
          Map.put(socket.assigns.mail.credential_checks, id, %{
            generation: generation,
            status: credential_result(result),
            checked_at: DateTime.utc_now()
          })
        else
          Map.delete(socket.assigns.mail.credential_checks, id)
        end

      {:noreply, put(socket, %{credential_check: nil, credential_checks: checks})}
    else
      {:noreply, socket}
    end
  end

  def handle_async(_, _, socket), do: {:noreply, socket}

  defp initial do
    %{
      workspace_id: nil,
      scope: :workspace,
      subscriptions: [],
      adding: false,
      connecting: false,
      account_id: nil,
      accounts: [],
      memberships: [],
      directory_error: false,
      generation: System.unique_integer([:positive, :monotonic]),
      task: nil,
      command: nil,
      credential_check: nil,
      credential_checks: %{},
      loading: false,
      query: nil,
      page_token: nil,
      list_key: System.unique_integer([:positive, :monotonic]),
      next_page_token: nil,
      thread_id: nil,
      data_ref: nil,
      data_loaded: false,
      fetched_at: nil,
      cached: false,
      stale: false,
      error: nil,
      notice: nil,
      search_form: to_form(%{"query" => ""}, as: :mail_search)
    }
  end

  defp event("mail:select", %{"id" => id}, socket) do
    socket = load_accounts(socket)

    if member?(socket.assigns.mail, id) && !socket.assigns.mail.command do
      socket |> clear_view(id) |> request(false)
    else
      socket
    end
  end

  defp event("mail:add", _, socket),
    do: socket |> put(%{adding: true}) |> load_accounts()

  defp event("mail:close_add", _, socket), do: put(socket, %{adding: false})

  defp event("mail:new_connection", _, socket) do
    mail = socket.assigns.mail

    if mail.scope == :connections && !mail.command && !mail.directory_error,
      do: put(socket, %{connecting: true}),
      else: socket
  end

  defp event("mail:close_connection", _, socket), do: close_connection(socket)

  defp event("mail:accounts", _, socket), do: socket |> clear_view(nil) |> load_accounts()

  defp event("mail:reload_accounts", _, socket), do: load_accounts(socket)

  defp event("mail:search", %{"mail_search" => %{"query" => query}}, socket)
       when is_binary(query) and byte_size(query) <= 4096 do
    if active?(socket) && String.length(query) <= 1024 do
      query =
        case String.trim(query) do
          "" -> nil
          value -> value
        end

      socket
      |> reset_content()
      |> put(%{
        query: query,
        list_key: System.unique_integer([:positive, :monotonic]),
        page_token: nil,
        thread_id: nil,
        search_form: to_form(%{"query" => query || ""}, as: :mail_search)
      })
      |> request(false)
    else
      socket
    end
  end

  defp event("mail:next", _, socket) do
    mail = socket.assigns.mail

    if active?(socket) && !mail.loading && is_binary(mail.next_page_token) do
      token = mail.next_page_token

      socket
      |> reset_content()
      |> put(%{
        page_token: token,
        thread_id: nil,
        list_key: System.unique_integer([:positive, :monotonic])
      })
      |> request(false)
    else
      socket
    end
  end

  defp event("mail:first", _, socket) do
    if active?(socket) do
      socket
      |> reset_content()
      |> put(%{
        page_token: nil,
        thread_id: nil,
        list_key: System.unique_integer([:positive, :monotonic])
      })
      |> request(false)
    else
      socket
    end
  end

  defp event("mail:thread", %{"id" => id}, socket) do
    data = ViewData.get(socket.assigns.mail.data_ref) || %{}
    threads = Enum.take(Map.get(data, "threads", []), 20)

    if active?(socket) && Enum.any?(threads, &(&1["id"] == id)) do
      socket |> reset_content() |> put(%{thread_id: id}) |> request(false)
    else
      socket
    end
  end

  defp event("mail:back", _, socket) do
    if active?(socket) do
      socket |> reset_content() |> put(%{thread_id: nil}) |> request(false)
    else
      socket
    end
  end

  defp event("mail:refresh", _, socket) do
    if active?(socket), do: request(socket, true), else: socket
  end

  defp event("mail:attach", %{"id" => id}, socket) do
    socket = load_accounts(socket)
    mail = socket.assigns.mail

    if mail.workspace_id && !mail.command &&
         Enum.any?(mail.accounts, &(&1.id == id && &1.status == :ready)) do
      case Mail.link(mail.workspace_id, id, actor: @owner) do
        {:ok, true} ->
          socket
          |> put(%{adding: false, notice: "Account attached to this workspace."})
          |> load_accounts()

        _ ->
          put(socket, %{notice: "The account could not be attached. Try again."})
      end
    else
      socket
    end
  end

  defp event("mail:detach", %{"id" => id}, socket) do
    socket = load_accounts(socket)
    mail = socket.assigns.mail

    if member?(mail, id) && !mail.command do
      socket = if mail.account_id == id, do: clear_view(socket, nil), else: socket

      case Mail.unlink(mail.workspace_id, id, actor: @owner) do
        {:ok, true} ->
          socket
          |> put(%{notice: "Detached here. The account remains available in other workspaces."})
          |> load_accounts()

        _ ->
          socket
          |> put(%{notice: "The account could not be detached. Try again."})
          |> load_accounts()
      end
    else
      socket
    end
  end

  defp event("mail:check_credentials", %{"id" => id}, socket) do
    socket = load_accounts(socket)
    mail = socket.assigns.mail
    account = Enum.find(mail.accounts, &(&1.id == id && &1.status != :disconnected))

    if mail.scope == :connections && socket.assigns.connection_view == :gmail &&
         !mail.command && !mail.credential_check && account && connected?(socket) do
      generation = account.generation
      request_id = System.unique_integer([:positive, :monotonic])
      name = {:mail, :credential_check, id, generation, request_id}

      socket
      |> put(%{credential_check: {id, generation, request_id}})
      |> start_async(name, fn -> Mail.check_credentials(id, generation, actor: @owner) end)
    else
      socket
    end
  end

  defp event("mail:disconnect", %{"id" => id}, socket) do
    socket = load_accounts(socket)
    mail = socket.assigns.mail

    if mail.scope == :connections && !mail.command && !mail.credential_check &&
         Enum.any?(mail.accounts, &(&1.id == id)) && connected?(socket) do
      socket = clear_view(socket, nil)
      mail = socket.assigns.mail
      name = {:mail, :disconnect, mail.workspace_id, id, mail.generation}

      socket
      |> put(%{command: {id, mail.generation}, notice: "Disconnecting account everywhere…"})
      |> start_async(name, fn -> Mail.disconnect(id, actor: @owner) end)
    else
      socket
    end
  end

  defp event(_, _, socket), do: socket

  defp request(socket, force) do
    socket = cancel_view(socket)
    mail = socket.assigns.mail

    if active?(socket) && connected?(socket) do
      generation = System.unique_integer([:positive, :monotonic])
      name = {:mail, :view, mail.workspace_id, mail.account_id, generation}
      workspace = mail.workspace_id
      account = mail.account_id
      thread = mail.thread_id
      options = %{query: mail.query, page_token: mail.page_token, force: force}
      scope = mail.scope
      owner = self()

      socket
      |> put(%{generation: generation, task: name, loading: true, error: nil})
      |> start_async(name, fn ->
        protect_result(fetch_mail(scope, workspace, account, thread, options), owner)
      end)
    else
      put(socket, %{loading: false})
    end
  end

  defp fetch_mail(:home, _workspace, account, nil, options),
    do: Mail.account_page(account, options, actor: @owner)

  defp fetch_mail(:home, _workspace, account, thread, options),
    do: Mail.account_thread(account, thread, Map.take(options, [:force]), actor: @owner)

  defp fetch_mail(_scope, workspace, account, nil, options),
    do: Mail.mail_page(workspace, account, options, actor: @owner)

  defp fetch_mail(_scope, workspace, account, thread, options),
    do: Mail.thread(workspace, account, thread, Map.take(options, [:force]), actor: @owner)

  # Never return payloads to LiveView: callback/render telemetry receives its socket.
  defp protect_result({:ok, %{data: data} = result}, owner) when is_map(data) do
    {:ok, result |> Map.put(:data, nil) |> Map.put(:data_ref, ViewData.put(data, owner))}
  end

  defp protect_result(result, _owner), do: result

  defp apply_result(socket, {:ok, {:ok, %{data_ref: ref} = result}}) when not is_nil(ref) do
    case ViewData.get(ref) do
      data when is_map(data) ->
        put(socket, %{
          loading: false,
          task: nil,
          data_loaded: true,
          data_ref: ref,
          fetched_at: Map.get(result, :fetched_at),
          cached: Map.get(result, :cached, false),
          stale: Map.get(result, :stale, false),
          error: Map.get(result, :error),
          next_page_token: Map.get(data, "next_page_token")
        })

      _ ->
        apply_result(socket, {:exit, :expired})
    end
  end

  defp apply_result(socket, {:ok, {:ok, %{error: error}}}) do
    put(socket, %{
      loading: false,
      task: nil,
      error: error || :unavailable,
      stale: socket.assigns.mail.data_loaded
    })
  end

  defp apply_result(socket, _) do
    put(socket, %{
      loading: false,
      task: nil,
      error: :unavailable,
      stale: socket.assigns.mail.data_loaded
    })
  end

  defp load_accounts(%{assigns: %{mail: %{workspace_id: nil, scope: :workspace}}} = socket),
    do: socket

  defp load_accounts(socket) do
    mail = socket.assigns.mail

    with {:ok, accounts} <- Mail.list_accounts(actor: @owner),
         {:ok, memberships} <- workspace_memberships(mail) do
      accounts =
        Enum.reject(accounts, &(&1.status == :disconnected && &1.last_error != :keychain))

      ids =
        if mail.scope == :home,
          do: accounts |> Enum.reject(&(&1.status == :disconnected)) |> Enum.map(& &1.id),
          else: Enum.map(memberships, & &1.account_id)

      ids = Enum.filter(ids, fn id -> Enum.any?(accounts, &(&1.id == id)) end)

      socket =
        socket
        |> put(%{
          accounts: accounts,
          memberships: ids,
          directory_error: false,
          credential_checks: current_credential_checks(mail.credential_checks, accounts)
        })
        |> subscribe_accounts(
          if(mail.scope == :connections, do: Enum.map(accounts, & &1.id), else: ids)
        )

      if mail.account_id && mail.account_id not in ids do
        socket
        |> clear_view(nil)
        |> put(%{notice: "This account is no longer available in this view."})
      else
        socket
      end
    else
      _ ->
        socket
        |> clear_view(nil)
        |> put(%{accounts: [], memberships: [], directory_error: true})
        |> subscribe_accounts([])
    end
  end

  defp clear_view(socket, account_id) do
    socket = cancel_view(socket)
    old = socket.assigns.mail
    ViewData.clear()
    fresh = initial()

    put(
      socket,
      Map.merge(
        fresh,
        Map.take(old, [
          :workspace_id,
          :scope,
          :subscriptions,
          :accounts,
          :memberships,
          :directory_error,
          :command
        ])
      )
      |> Map.put(:account_id, account_id)
    )
  end

  defp reset_content(socket) do
    socket = cancel_view(socket)
    ViewData.clear()

    put(socket, %{
      data_ref: nil,
      data_loaded: false,
      fetched_at: nil,
      next_page_token: nil,
      cached: false,
      stale: false,
      error: nil
    })
  end

  defp cancel_view(socket) do
    case socket.assigns.mail.task do
      nil -> socket
      name -> socket |> cancel_async(name) |> put(%{task: nil, loading: false})
    end
  end

  defp cancel_credential_check(socket) do
    case socket.assigns.mail.credential_check do
      nil ->
        socket

      {id, generation, request_id} ->
        cancel_async(socket, {:mail, :credential_check, id, generation, request_id})
    end
  end

  defp current_credential_checks(checks, accounts) do
    Map.filter(checks, fn {id, check} ->
      Enum.any?(
        accounts,
        &(&1.id == id && &1.generation == check.generation && &1.status != :disconnected)
      )
    end)
  end

  defp credential_result({:ok, {:ok, %{status: status}}})
       when status in [
              :accessible,
              :not_found,
              :locked,
              :timeout,
              :unavailable,
              :invalid_account,
              :invalid_value,
              :changed
            ],
       do: status

  defp credential_result(_), do: :unavailable

  defp workspace_memberships(%{scope: scope}) when scope in [:connections, :home], do: {:ok, []}
  defp workspace_memberships(mail), do: Mail.workspace_accounts(mail.workspace_id, actor: @owner)

  defp subscribe_accounts(socket, ids) do
    old = socket.assigns.mail.subscriptions

    if connected?(socket) do
      Enum.each(old -- ids, &unsubscribe/1)
      Enum.each(ids -- old, &Phoenix.PubSub.subscribe(Lovelace.PubSub, topic(&1)))
    end

    put(socket, %{subscriptions: ids})
  end

  defp member?(mail, id),
    do: (mail.workspace_id != nil || mail.scope == :home) && id in mail.memberships

  defp active?(socket), do: member?(socket.assigns.mail, socket.assigns.mail.account_id)
  defp put(socket, values), do: assign(socket, :mail, Map.merge(socket.assigns.mail, values))
  defp topic(id), do: "mail:#{id}"
  defp unsubscribe(nil), do: :ok
  defp unsubscribe(id), do: Phoenix.PubSub.unsubscribe(Lovelace.PubSub, topic(id))

  defp disconnect_notice(
         {:ok, {:ok, %{local_removed: true, credentials_removed: true, revoked: true}}}
       ),
       do:
         "Disconnected everywhere. Local mail cache and credentials removed; Google access revoked."

  defp disconnect_notice(
         {:ok, {:ok, %{local_removed: true, credentials_removed: credentials, revoked: revoked}}}
       ) do
    "Local mail cache and workspace connections removed." <>
      if(credentials,
        do: " Local credentials removed.",
        else: " Local credentials could not be removed; review the system keychain."
      ) <>
      if(revoked,
        do: " Google access revoked.",
        else:
          " Google revocation could not be confirmed. Remove LOVELACE access in your Google account settings."
      )
  end

  defp disconnect_notice(_),
    do:
      "Disconnect could not be confirmed. Reload accounts to check local state; Google access may still need removal in your Google account settings."
end
