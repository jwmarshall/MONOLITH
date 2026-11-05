defmodule Lovelace.CalendarBoundariesTest do
  use Lovelace.DataCase, async: false

  alias Ash.Resource.Info
  alias Lovelace.Calendar
  alias Lovelace.Calendar.State
  alias Lovelace.Mail
  alias Lovelace.Mail.Connections
  alias Lovelace.Onboarding
  alias Lovelace.Onboarding.CalendarSetup

  @owner %{role: :local_owner}

  defmodule Provider do
    def calendars(token) do
      Lovelace.TestMail.record({:boundary_calendars, token})

      response =
        Agent.get(Lovelace.TestMail, fn state ->
          Map.get(state, :boundary_catalog, {
            :ok,
            %{
              calendars: [
                %{id: "primary", name: "Primary", selected: true},
                %{id: "shared", name: "Shared", selected: false}
              ],
              truncated: false
            }
          })
        end)

      deliver(response)
    end

    def events(token, id, _from, _to) do
      Lovelace.TestMail.record({:boundary_events, token, id})

      response =
        Agent.get(Lovelace.TestMail, fn state ->
          state
          |> Map.get(:boundary_events, %{})
          |> Map.get(id, {:ok, %{events: [state.boundary_event], truncated: false}})
        end)

      deliver(response)
    end

    defp deliver(callback) when is_function(callback, 0), do: callback.()
    defp deliver({:raise, message}), do: raise(message)
    defp deliver({:throw, reason}), do: throw(reason)
    defp deliver(response), do: response
  end

  setup do
    {:ok, _} = Lovelace.TestMail.start()
    keys = [:calendar_provider, :gmail_provider, :gmail_vault]
    previous = Map.new(keys, &{&1, Application.fetch_env(:lovelace, &1)})
    Application.put_env(:lovelace, :calendar_provider, Provider)
    Application.put_env(:lovelace, :gmail_provider, Lovelace.TestGoogle)
    Application.put_env(:lovelace, :gmail_vault, Lovelace.TestMailVault)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:lovelace, key, value)
          :error -> Application.delete_env(:lovelace, key)
        end
      end
    end)

    {:ok, progress} = Onboarding.save_workspace("Calendar boundaries", actor: @owner)

    {:ok, account} =
      Connections.accept(
        progress.workspace_id,
        %{subject: "boundary-owner", email: "boundary@example.invalid"},
        "boundary-refresh",
        :calendar
      )

    date = Date.utc_today()

    window = %{
      "from" => DateTime.new!(date, ~T[00:00:00], "Etc/UTC") |> DateTime.to_iso8601(),
      "to" => DateTime.new!(Date.add(date, 1), ~T[00:00:00], "Etc/UTC") |> DateTime.to_iso8601(),
      "date" => Date.to_iso8601(date),
      "timezone" => "UTC"
    }

    configure(:boundary_event, %{
      id: "boundary-event",
      title: "Private calendar entry",
      start: window["from"],
      end: window["to"],
      all_day: false,
      url: nil
    })

    %{
      account: account,
      workspace_id: progress.workspace_id,
      window: window,
      opts: [actor: @owner, workspace_id: progress.workspace_id]
    }
  end

  defp configure(key, value),
    do: Agent.update(Lovelace.TestMail, &Map.put(&1, key, value))

  defp state(account) do
    State
    |> Ash.Query.for_read(:read, %{account_id: account.id}, actor: @owner)
    |> Ash.read_one!()
  end

  defp update_state(account, changes) do
    attributes =
      account
      |> state()
      |> Map.from_struct()
      |> Map.take(Info.action(State, :store).accept)
      |> Map.merge(changes)

    State
    |> Ash.Changeset.for_create(:store, attributes, actor: @owner)
    |> Ash.create!()
  end

  defp prepare(c) do
    CalendarSetup.prepare(c.account.id, c.account.generation, c.window, c.opts)
  end

  defp populate(c) do
    assert {:ok, %{loading: true}} = prepare(c)
    assert %{error: nil} = poll(c)
    state(c.account)
  end

  defp poll(c) do
    Calendar.poll!(c.account.id, c.account.generation, state(c.account).revision, actor: @owner)
  end

  defp snapshot(c) do
    Calendar.snapshot!(
      c.account.id,
      c.window["from"],
      c.window["to"],
      c.window["date"],
      actor: @owner
    )
  end

  defp calls_since(before) do
    calls = Lovelace.TestMail.calls()
    Enum.take(calls, length(calls) - length(before))
  end

  test "a removed shared calendar does not silently fall back to the provider's selected primary",
       c do
    populate(c)
    assert {:ok, _} = CalendarSetup.select(c.account.id, c.account.generation, ["shared"], c.opts)
    poll(c)
    assert [%{calendar_id: "shared"}] = snapshot(c).events
    before = Lovelace.TestMail.calls()

    configure(:boundary_catalog, {
      :ok,
      %{
        calendars: [%{id: "primary", name: "Primary", selected: true}],
        truncated: false
      }
    })

    assert %{error: nil} = poll(c)
    assert snapshot(c).events == []
    assert snapshot(c).selected_ids == []
    assert state(c.account).explicit_selection
    assert state(c.account).selected_ids == []
    assert state(c.account).events == []
    assert state(c.account).fetched_at
    refute Enum.any?(calls_since(before), &match?({:boundary_events, _, _}, &1))
  end

  test "implicit selections follow changed provider selections but explicit choices survive them",
       c do
    populate(c)

    configure(:boundary_catalog, {
      :ok,
      %{
        calendars: [
          %{id: "primary", name: "Primary", selected: false},
          %{id: "shared", name: "Shared", selected: true}
        ],
        truncated: false
      }
    })

    assert %{error: nil} = poll(c)
    assert snapshot(c).selected_ids == ["shared"]
    assert [%{calendar_id: "shared"}] = snapshot(c).events
    refute state(c.account).explicit_selection

    assert {:ok, _} =
             CalendarSetup.select(c.account.id, c.account.generation, ["primary"], c.opts)

    assert %{error: nil} = poll(c)
    assert snapshot(c).selected_ids == ["primary"]
    assert [%{calendar_id: "primary"}] = snapshot(c).events
    assert state(c.account).explicit_selection
  end

  test "a second-calendar permission failure cannot publish a partial multi-calendar agenda", c do
    populate(c)

    assert {:ok, _} =
             CalendarSetup.select(
               c.account.id,
               c.account.generation,
               ["primary", "shared"],
               c.opts
             )

    assert %{error: nil} = poll(c)
    prior = state(c.account)
    before = Lovelace.TestMail.calls()
    configure(:boundary_events, %{"shared" => {:error, :insufficient_permissions}})

    assert %{error: :reconnect} = poll(c)
    current = state(c.account)
    assert current.events == prior.events
    assert current.fetched_at == prior.fetched_at
    assert current.catalog_at == prior.catalog_at
    assert current.selected_ids == ["primary", "shared"]
    assert snapshot(c).stale
    assert {:boundary_events, "access:boundary-refresh", "primary"} in calls_since(before)
    assert {:boundary_events, "access:boundary-refresh", "shared"} in calls_since(before)
    assert Mail.get_account!(c.account.id, actor: @owner).status == :ready
    assert Mail.get_account!(c.account.id, actor: @owner).last_error == nil
  end

  for {label, response} <- [
        {"raises", {:raise, "private provider diagnostic"}},
        {"throws", {:throw, "private provider diagnostic"}},
        {"returns an unexpected result", :unexpected_result},
        {"returns malformed catalog data", {:ok, %{calendars: nil, truncated: false}}}
      ] do
    test "catalog provider #{label} preserves the last successful agenda", c do
      prior = populate(c)
      before = Lovelace.TestMail.calls()
      configure(:boundary_catalog, unquote(Macro.escape(response)))

      assert %{error: :provider, loading: false} = poll(c)
      current = state(c.account)
      assert current.events == prior.events
      assert current.calendars == prior.calendars
      assert current.fetched_at == prior.fetched_at
      assert current.catalog_at == prior.catalog_at
      assert DateTime.compare(current.next_poll_at, DateTime.utc_now()) == :gt
      refute Enum.any?(calls_since(before), &match?({:boundary_events, _, _}, &1))
      refute inspect(snapshot(c)) =~ "private provider diagnostic"
      assert snapshot(c).stale
    end
  end

  test "a successful catalog cannot overwrite the cache when event decoding fails", c do
    prior = populate(c)
    configure(:boundary_events, %{"primary" => {:ok, %{events: nil, truncated: false}}})

    assert %{error: :provider} = poll(c)
    assert state(c.account).events == prior.events
    assert state(c.account).calendars == prior.calendars
    assert state(c.account).fetched_at == prior.fetched_at
    assert state(c.account).catalog_at == prior.catalog_at
    assert snapshot(c).stale
  end

  test "revoking Calendar between catalog and event requests fences every remaining provider call",
       c do
    prior = populate(c)
    before = Lovelace.TestMail.calls()

    configure(:boundary_catalog, fn ->
      Connections.serial(c.account.id, fn ->
        Mail.update_account!(
          c.account,
          %{expected_generation: c.account.generation, calendar_enabled: false},
          actor: @owner
        )
      end)

      {:ok, %{calendars: [%{id: "primary", name: "Primary", selected: true}], truncated: false}}
    end)

    assert %{skipped: true} = poll(c)
    refute Enum.any?(calls_since(before), &match?({:boundary_events, _, _}, &1))
    assert state(c.account).events == prior.events
    refute snapshot(c).enabled
    assert snapshot(c).events == []
    assert {:error, _} = prepare(c)

    assert {:error, _} =
             CalendarSetup.select(c.account.id, c.account.generation, [], c.opts)
  end

  test "reconnecting during the first calendar read prevents the second and clears old generation data",
       c do
    populate(c)

    assert {:ok, _} =
             CalendarSetup.select(
               c.account.id,
               c.account.generation,
               ["primary", "shared"],
               c.opts
             )

    before = Lovelace.TestMail.calls()

    configure(:boundary_events, %{
      "primary" => fn ->
        {:ok, replacement} =
          Connections.accept(
            c.workspace_id,
            %{subject: c.account.subject, email: c.account.email},
            "rotated-boundary-refresh",
            :calendar
          )

        assert replacement.generation != c.account.generation
        {:ok, %{events: [], truncated: false}}
      end
    })

    assert %{skipped: true} = poll(c)
    refute {:boundary_events, "access:boundary-refresh", "shared"} in calls_since(before)
    assert state(c.account) == nil
    assert snapshot(c).events == []

    assert {:ok, %{catalog_at: nil, calendars: [], selected_ids: []}} =
             CalendarSetup.read(actor: @owner)
  end

  test "a Gmail-only reauthorization revokes Calendar without clearing another account's agenda",
       c do
    populate(c)

    {:ok, other} =
      Connections.accept(
        c.workspace_id,
        %{subject: "independent-calendar", email: "independent@example.invalid"},
        "independent-refresh",
        :calendar
      )

    other_context = %{c | account: other}

    Calendar.prepare!(other.id, c.window["from"], c.window["to"], c.window["date"], "UTC",
      actor: @owner
    )

    assert %{error: nil} = poll(other_context)
    other_prior = state(other)
    old_revision = state(c.account).revision

    {:ok, replacement} =
      Connections.accept(
        c.workspace_id,
        %{subject: c.account.subject, email: c.account.email},
        "gmail-only-refresh",
        :gmail
      )

    before = Lovelace.TestMail.calls()
    refute replacement.calendar_enabled
    assert state(c.account) == nil
    assert state(other).events == other_prior.events
    assert state(other).generation == other_prior.generation
    assert [%{calendar_id: "primary"}] = snapshot(other_context).events
    assert Calendar.poll!(c.account.id, c.account.generation, old_revision, actor: @owner).skipped
    assert {:error, _} = prepare(c)
    assert Lovelace.TestMail.calls() == before

    assert {:ok, %{enabled: false, calendars: [], selected_ids: [], catalog_at: nil}} =
             CalendarSetup.read(actor: @owner)
  end

  test "combined Gmail and Calendar cooldown metadata uses the later deadline and never queues reads",
       c do
    populate(c)

    for {gmail_seconds, calendar_seconds} <- [{600, 300}, {300, 600}] do
      gmail_deadline = DateTime.add(DateTime.utc_now(), gmail_seconds)
      calendar_deadline = DateTime.add(DateTime.utc_now(), calendar_seconds)

      Mail.update_account!(
        c.account,
        %{
          expected_generation: c.account.generation,
          last_error: :rate_limited,
          next_poll_at: gmail_deadline
        },
        actor: @owner
      )

      update_state(c.account, %{cooldown_until: calendar_deadline, loading: true})
      before = Lovelace.TestMail.calls()
      expected = if gmail_seconds > calendar_seconds, do: gmail_deadline, else: calendar_deadline

      assert {:ok, metadata} = CalendarSetup.read(actor: @owner)
      assert metadata.cooldown_until == expected
      assert metadata.error == :rate_limited
      refute metadata.loading
      assert metadata.catalog_fresh?
      assert metadata.available?

      assert {:ok, %{loading: false, error: :rate_limited}} =
               CalendarSetup.prepare(
                 c.account.id,
                 c.account.generation,
                 c.window,
                 Keyword.put(c.opts, :refresh?, true)
               )

      assert poll(c).skipped
      assert Lovelace.TestMail.calls() == before
    end
  end

  test "removing the guide's connection rejects old forms even while its account remains connected elsewhere",
       c do
    prior = populate(c)
    other_workspace = Lovelace.Workspaces.create_workspace!("Shared account", actor: @owner)

    Mail.attach_account!(%{workspace_id: other_workspace.id, account_id: c.account.id},
      actor: @owner
    )

    [membership] = Mail.workspace_accounts!(c.workspace_id, actor: @owner)
    Mail.detach_account!(membership, actor: @owner)
    before = Lovelace.TestMail.calls()

    assert {:ok, nil} = Onboarding.connection(actor: @owner)
    assert {:ok, nil} = CalendarSetup.read(actor: @owner)
    assert {:error, _} = prepare(c)

    assert {:error, _} =
             CalendarSetup.select(c.account.id, c.account.generation, ["shared"], c.opts)

    assert state(c.account).revision == prior.revision
    assert state(c.account).selected_ids == prior.selected_ids
    assert state(c.account).events == prior.events
    assert Mail.get_account!(c.account.id, actor: @owner).status == :ready

    assert [%{account_id: account_id}] =
             Mail.workspace_accounts!(other_workspace.id, actor: @owner)

    assert account_id == c.account.id
    assert Lovelace.TestMail.calls() == before
  end

  test "changing the guide to an empty workspace never borrows the previous workspace's connection",
       c do
    prior = populate(c)
    replacement = Lovelace.Workspaces.create_workspace!("Unconnected guide", actor: @owner)
    {:ok, progress} = Onboarding.progress(actor: @owner)
    Ash.update!(progress, %{workspace_id: replacement.id}, action: :save_workspace, actor: @owner)
    before = Lovelace.TestMail.calls()

    assert {:ok, %{id: workspace_id}} = Onboarding.workspace(actor: @owner)
    assert workspace_id == replacement.id
    assert {:ok, nil} = Onboarding.connection(actor: @owner)
    assert {:ok, nil} = CalendarSetup.read(actor: @owner)
    assert {:error, _} = prepare(c)
    assert state(c.account).revision == prior.revision
    assert state(c.account).events == prior.events
    assert Lovelace.TestMail.calls() == before
  end
end
