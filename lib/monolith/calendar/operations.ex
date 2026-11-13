defmodule Monolith.Calendar.Operations do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  alias Monolith.Calendar.{Catalog, Payload, PollWorker, Snapshot, State, Window}
  alias Monolith.Google.Access
  alias Monolith.Mail
  alias Monolith.Security.Vault
  @owner %{role: :local_owner}
  @fields [
    :account_id,
    :generation,
    :revision,
    :calendars,
    :selected_ids,
    :explicit_selection,
    :events,
    :from_at,
    :to_at,
    :local_date,
    :timezone,
    :context_at,
    :fetched_at,
    :catalog_at,
    :error,
    :next_poll_at,
    :cooldown_until,
    :loading,
    :truncated,
    :selection_truncated
  ]

  @impl true
  def run(input, _, context) do
    Vault.with_access(fn ->
      execute(input.action.name, input.arguments, context.actor)
    end)
  rescue
    _ -> failure(input.action.name)
  catch
    _, _ -> failure(input.action.name)
  end

  defp failure(:snapshot), do: {:ok, Snapshot.failure()}
  defp failure(:catalog), do: {:ok, Catalog.failure()}
  defp failure(_), do: {:ok, Snapshot.metadata(nil, false, :unavailable)}

  defp execute(:catalog, args, _) do
    Access.serial(args.account_id, fn ->
      cached =
        State
        |> Ash.Query.for_read(:read, %{account_id: args.account_id}, actor: @owner)
        |> Ash.Query.select(Catalog.fields())
        |> Ash.read_one!()

      {:ok, Catalog.build(account(args.account_id), cached)}
    end)
  end

  defp execute(:snapshot, args, _) do
    with {:ok, window} <- Window.parse(args.from_iso, args.to_iso, args.local_date) do
      Access.serial(args.account_id, fn ->
        {:ok, Snapshot.build(account(args.account_id), state(args.account_id), window)}
      end)
    end
  end

  defp execute(:prepare, args, _) do
    with {:ok, window} <- Window.parse(args.from_iso, args.to_iso, args.local_date),
         true <- Window.fresh?(window) and Window.timezone?(args.timezone) do
      Access.serial(args.account_id, fn -> prepare_current(args, window) end)
    else
      _ -> {:error, :invalid_window}
    end
  end

  defp execute(:select_calendars, args, _) do
    Access.serial(args.account_id, fn -> select_current(args) end)
  end

  defp execute(:refresh, args, _) do
    Access.serial(args.account_id, fn ->
      account = account(args.account_id)
      current = state(args.account_id)

      if Snapshot.current?(account, current) && Snapshot.recent?(current.context_at),
        do: {:ok, Snapshot.metadata(queue(current), true)},
        else: {:ok, Snapshot.metadata(nil, Snapshot.enabled?(account))}
    end)
  end

  defp execute(:poll, args, actor) do
    if permitted_poll?(actor, args.account_id) do
      case admit(args) do
        {:ok, account, state} -> publish(args, fetch(account, state, args))
        _ -> {:ok, %{skipped: true}}
      end
    else
      {:ok, %{skipped: true}}
    end
  end

  defp execute(:sweep, _, _) do
    sweep()
    {:ok, %{swept: true}}
  end

  defp permitted_poll?(%{role: :local_owner}, _), do: true
  defp permitted_poll?(%{role: :mail_service, account_id: id}, id), do: true
  defp permitted_poll?(_, _), do: false

  defp prepare_current(args, window) do
    account = account(args.account_id)

    if Snapshot.enabled?(account) do
      prior = state(account.id)

      context =
        Snapshot.current?(account, prior) && Window.matches?(prior, window) &&
          prior.timezone == args.timezone

      attributes = context_attributes(account, prior, args, window, context)
      current = store!(attributes)
      current = if !context or due?(current), do: queue(current), else: current
      {:ok, Snapshot.metadata(current, true)}
    else
      {:ok, Snapshot.metadata(nil, false)}
    end
  end

  defp context_attributes(account, prior, args, window, context) do
    attributes =
      if Snapshot.current?(account, prior),
        do: Map.take(prior, @fields),
        else: defaults(account, window, args.timezone)

    if context do
      attributes
    else
      attributes
      |> Map.merge(window)
      |> Map.merge(%{
        timezone: args.timezone,
        revision: Ash.UUID.generate(),
        events: [],
        fetched_at: nil,
        context_at: DateTime.utc_now(),
        loading: false,
        next_poll_at: DateTime.utc_now()
      })
    end
  end

  defp select_current(args) do
    account = account(args.account_id)
    state = state(args.account_id)
    ids = Enum.uniq(args.ids)

    if account && account.generation == args.generation && valid_selection?(account, state, ids) do
      current =
        state
        |> Map.take(@fields)
        |> Map.merge(%{
          selected_ids: ids,
          explicit_selection: true,
          revision: Ash.UUID.generate(),
          events: [],
          fetched_at: nil,
          loading: false,
          selection_truncated: false
        })
        |> store!()
        |> queue()

      {:ok, Snapshot.metadata(current, true)}
    else
      {:error, :invalid_selection}
    end
  end

  defp valid_selection?(account, state, ids) do
    Snapshot.current?(account, state) && Snapshot.recent?(state.catalog_at) &&
      length(ids) <= Catalog.selection_limit() && known_ids?(state.calendars, ids)
  end

  defp known_ids?(calendars, ids) do
    known = MapSet.new(calendars, & &1["id"])
    Enum.all?(ids, &MapSet.member?(known, &1))
  end

  defp fetch(account, state, args) do
    with {:ok, token} <- Access.access_token(account),
         :ok <- admission(args),
         {:ok, response} <- provider().calendars(token),
         {:ok, calendars, truncated} <- Payload.calendars(response) do
      fetch_events(token, calendars, truncated, state, args)
    end
  rescue
    _ -> {:error, :provider}
  catch
    _, _ -> {:error, :provider}
  end

  defp fetch_events(token, calendars, truncated, state, args) do
    {selected, selection_truncated} = Payload.selected(calendars, state)
    from = DateTime.add(state.from_at, -26 * 3600) |> DateTime.to_iso8601()
    to = DateTime.add(state.to_at, 26 * 3600) |> DateTime.to_iso8601()
    request = %{token: token, from: from, to: to, state: state, args: args}
    selected_calendars = Enum.filter(calendars, &(&1["id"] in selected))

    result =
      Enum.reduce_while(
        selected_calendars,
        {:ok, [], truncated},
        &fetch_calendar(&1, &2, request)
      )

    bounded_result(result, calendars, selected, selection_truncated)
  end

  defp fetch_calendar(calendar, {:ok, events, partial}, request) do
    with :ok <- admission(request.args),
         {:ok, payload} <-
           provider().events(request.token, calendar["id"], request.from, request.to),
         {:ok, rows, limited} <- Payload.events(payload, calendar, request.state) do
      {:cont, {:ok, events ++ rows, partial or limited}}
    else
      error -> {:halt, error}
    end
  end

  defp bounded_result({:ok, events, partial}, calendars, selected, selection_truncated) do
    {events, bounded} = Payload.bounded(calendars, events)

    {:ok,
     %{
       calendars: calendars,
       selected_ids: selected,
       events: events,
       truncated: partial or bounded or selection_truncated,
       selection_truncated: selection_truncated
     }}
  end

  defp bounded_result(error, _, _, _), do: error

  defp publish(args, result) do
    Access.serial(args.account_id, fn -> publish_current(args, result) end)
  end

  # Admission evidence belongs to the account generation, not a browser-day or
  # selection revision. Discard old content without discarding a received 429.
  defp publish_current(args, {:error, :rate_limited}) do
    account = account(args.account_id)
    state = state(args.account_id)

    if Snapshot.current?(account, state) && account.generation == args.generation do
      deadline = DateTime.add(DateTime.utc_now(), 300)
      deadline = later(state.cooldown_until, deadline)

      state =
        state
        |> Map.take(@fields)
        |> Map.merge(%{
          error: :rate_limited,
          loading: false,
          cooldown_until: deadline,
          next_poll_at: later(state.next_poll_at, deadline)
        })
        |> store!()

      broadcast(state.account_id)
      {:ok, Snapshot.metadata(state, true)}
    else
      {:ok, %{skipped: true}}
    end
  end

  defp publish_current(args, result) do
    case current(args) do
      {:ok, _, state} -> commit_result(state, result)
      _ -> {:ok, %{skipped: true}}
    end
  end

  defp later(%DateTime{} = first, second) do
    if DateTime.compare(first, second) == :gt, do: first, else: second
  end

  defp later(_, second), do: second

  defp commit_result(state, result) do
    # Work already in flight cannot erase or shorten a newer 429 cooldown.
    if cooldown?(state) do
      {:ok, Snapshot.metadata(state, true)}
    else
      state = state |> Map.take(@fields) |> Map.merge(result_changes(result, state)) |> store!()
      broadcast(state.account_id)
      {:ok, Snapshot.metadata(state, true)}
    end
  end

  defp result_changes({:ok, payload}, _) do
    now = DateTime.utc_now()

    Map.merge(payload, %{
      fetched_at: now,
      catalog_at: now,
      error: nil,
      loading: false,
      next_poll_at: DateTime.add(now, 180)
    })
  end

  defp result_changes({:error, reason}, state) do
    reason = safe_error(reason)
    now = DateTime.utc_now()
    wait = if reason == :rate_limited, do: 300, else: 180

    %{
      error: reason,
      loading: false,
      next_poll_at: DateTime.add(now, wait),
      cooldown_until:
        if(reason == :rate_limited, do: DateTime.add(now, 300), else: state.cooldown_until)
    }
  end

  defp result_changes(_, state), do: result_changes({:error, :provider}, state)

  defp admit(args) do
    Access.serial(args.account_id, fn ->
      with {:ok, account, state} <- current(args),
           false <- cooldown?(state),
           false <- Access.cooldown?(account) do
        {:ok, account, state}
      else
        _ -> {:error, :cooldown}
      end
    end)
  end

  defp admission(args) do
    case admit(args) do
      {:ok, _, _} -> :ok
      error -> error
    end
  end

  defp current(args) do
    account = account(args.account_id)
    state = state(args.account_id)

    if Snapshot.current?(account, state) && account.generation == args.generation &&
         state.revision == args.revision && Snapshot.recent?(state.context_at) &&
         Window.fresh?(state),
       do: {:ok, account, state},
       else: {:error, :changed}
  end

  defp queue(state) do
    account = account(state.account_id)

    if Window.fresh?(state) and not cooldown?(state) and not Access.cooldown?(account),
      do: insert_job(state),
      else: state
  end

  defp insert_job(state) do
    case PollWorker.enqueue(state) do
      {:ok, _} ->
        state =
          state
          |> Map.take(@fields)
          |> Map.merge(%{loading: true, next_poll_at: DateTime.add(DateTime.utc_now(), 180)})
          |> store!()

        broadcast(state.account_id)
        state

      _ ->
        state
        |> Map.take(@fields)
        |> Map.merge(%{error: :unavailable, loading: false})
        |> store!()
    end
  end

  def clear(id) do
    case state(id) do
      nil -> :ok
      state -> Ash.destroy(state, action: :clear, actor: @owner)
    end
  end

  defp sweep do
    read_states(:expired) |> Enum.each(&prune_expired/1)
    read_states(:due) |> Enum.each(&queue_due/1)
    :ok
  end

  defp read_states(action),
    do: State |> Ash.Query.for_read(action, %{}, actor: @owner) |> Ash.read!()

  defp queue_due(state) do
    Access.serial(state.account_id, fn ->
      state |> Map.take([:account_id, :generation, :revision]) |> current() |> queue_current_due()
    end)
  end

  defp queue_current_due({:ok, _, state}) do
    if due?(state), do: queue(state)
  end

  defp queue_current_due(_), do: :ok

  defp prune_expired(expired) do
    Access.serial(expired.account_id, fn -> prune_current(state(expired.account_id)) end)
  end

  defp prune_current(nil), do: :ok

  defp prune_current(current) do
    changes = expired_events(current) |> Map.merge(expired_catalog(current))

    if map_size(changes) > 0 do
      current |> Map.take(@fields) |> Map.merge(changes) |> store!()
      broadcast(current.account_id)
    end
  end

  defp expired_events(current) do
    if current.fetched_at && not Snapshot.recent?(current.fetched_at),
      do: %{events: [], fetched_at: nil},
      else: %{}
  end

  defp expired_catalog(current) do
    if current.catalog_at && not Snapshot.recent?(current.catalog_at),
      do: %{calendars: [], catalog_at: nil},
      else: %{}
  end

  defp defaults(account, window, timezone) do
    Map.merge(window, %{
      account_id: account.id,
      generation: account.generation,
      revision: Ash.UUID.generate(),
      timezone: timezone,
      context_at: DateTime.utc_now(),
      next_poll_at: DateTime.utc_now(),
      calendars: [],
      selected_ids: [],
      explicit_selection: false,
      events: [],
      fetched_at: nil,
      catalog_at: nil,
      error: nil,
      cooldown_until: nil,
      loading: false,
      truncated: false,
      selection_truncated: false
    })
  end

  defp account(id) do
    case Mail.get_account(id, actor: @owner) do
      {:ok, account} -> account
      _ -> nil
    end
  end

  defp state(id),
    do: State |> Ash.Query.for_read(:read, %{account_id: id}, actor: @owner) |> Ash.read_one!()

  defp store!(attributes),
    do: State |> Ash.Changeset.for_create(:store, attributes, actor: @owner) |> Ash.create!()

  defp due?(state), do: DateTime.compare(state.next_poll_at, DateTime.utc_now()) != :gt

  defp cooldown?(%{cooldown_until: %DateTime{} = until}),
    do: DateTime.compare(until, DateTime.utc_now()) == :gt

  defp cooldown?(_), do: false

  defp safe_error(reason)
       when reason in [:rate_limited, :reconnect, :keychain, :unavailable, :provider], do: reason

  defp safe_error(reason)
       when reason in [:invalid_grant, :unauthorized, :forbidden, :insufficient_permissions],
       do: :reconnect

  defp safe_error(:cooldown), do: :rate_limited
  defp safe_error(_), do: :provider

  defp provider,
    do: Application.get_env(:monolith, :calendar_provider, Monolith.Integrations.Google.Calendar)

  defp broadcast(id),
    do: Phoenix.PubSub.broadcast(Monolith.PubSub, "mail:" <> id, {:calendar_changed, id})
end
