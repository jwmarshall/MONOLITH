defmodule Monolith.CalendarTest.Provider do
  @behaviour Monolith.Calendar.Provider
  @impl true
  def calendars(token) do
    Monolith.TestMail.record({:calendars, token})

    case Agent.get(__MODULE__, & &1.response) do
      :ok -> {:ok, %{calendars: Agent.get(__MODULE__, & &1.calendars), truncated: false}}
      error -> error
    end
  end

  @impl true
  def events(token, id, from, to) do
    Monolith.TestMail.record({:events, token, id, from, to})

    case Agent.get(__MODULE__, & &1.events) do
      {:wait_error, pid, reason} ->
        send(pid, {:calendar_waiting, self()})

        receive do
          :continue -> {:error, reason}
        end

      {:wait, pid, events} ->
        send(pid, {:calendar_waiting, self()})

        receive do
          :continue -> {:ok, %{events: events, truncated: false}}
        end

      events ->
        {:ok, %{events: events, truncated: false}}
    end
  end
end

defmodule Monolith.CalendarTest do
  use Monolith.DataCase, async: false
  use Oban.Testing, repo: Monolith.Repo, engine: Oban.Engines.Lite
  alias Ash.Resource.Info
  alias Ecto.Adapters.SQL.Sandbox
  alias Monolith.Calendar
  alias Monolith.Calendar.{PollWorker, State, SweepWorker}
  alias Monolith.CalendarTest.Provider
  alias Monolith.Google.Access
  alias Monolith.Mail
  alias Monolith.Mail.PollWorker, as: MailPollWorker
  @owner %{role: :local_owner}

  setup do
    {:ok, _} = Monolith.TestMail.start()
    keys = [:calendar_provider, :gmail_provider, :gmail_vault]
    previous = Map.new(keys, &{&1, Application.get_env(:monolith, &1)})
    Application.put_env(:monolith, :calendar_provider, Provider)
    Application.put_env(:monolith, :gmail_provider, Monolith.TestGoogle)
    Application.put_env(:monolith, :gmail_vault, Monolith.TestMailVault)

    on_exit(fn ->
      for {key, value} <- previous do
        if value,
          do: Application.put_env(:monolith, key, value),
          else: Application.delete_env(:monolith, key)
      end
    end)

    workspace = Monolith.Workspaces.create_workspace!("Calendar fixture", actor: @owner)

    {:ok, a} =
      Access.accept(
        workspace.id,
        %{subject: "calendar-a", email: "a@example.invalid"},
        "token-a",
        :calendar
      )

    {:ok, b} =
      Access.accept(
        workspace.id,
        %{subject: "calendar-b", email: "b@example.invalid"},
        "token-b",
        :calendar
      )

    date = Date.utc_today()
    from = DateTime.new!(date, ~T[00:00:00], "Etc/UTC") |> DateTime.to_iso8601()
    to = DateTime.new!(Date.add(date, 1), ~T[00:00:00], "Etc/UTC") |> DateTime.to_iso8601()

    event = %{
      id: "same",
      title: "Synthetic agenda",
      start: from,
      end: to,
      all_day: false,
      url: "https://calendar.google.com/calendar/event?eid=synthetic"
    }

    {:ok, _} =
      Agent.start_link(
        fn ->
          %{
            response: :ok,
            events: [event],
            calendars: [
              %{id: "primary", name: "Primary", selected: true},
              %{id: "shared", name: "Shared", selected: false}
            ]
          }
        end,
        name: Provider
      )

    %{
      a: a,
      b: b,
      workspace: workspace,
      from: from,
      to: to,
      date: Date.to_iso8601(date),
      event: event
    }
  end

  defp datetime(iso) do
    {:ok, time, _} = DateTime.from_iso8601(iso)
    time
  end

  defp prepare(c, account) do
    Calendar.prepare!(account.id, c.from, c.to, c.date, "UTC", actor: @owner)
  end

  defp snapshot(c, account),
    do: Calendar.snapshot!(account.id, c.from, c.to, c.date, actor: @owner)

  defp poll(account, revision),
    do: Calendar.poll!(account.id, account.generation, revision, actor: @owner)

  defp state(account),
    do:
      State
      |> Ash.Query.for_read(:read, %{account_id: account.id}, actor: @owner)
      |> Ash.read_one!()

  defp update_state(account, changes) do
    attrs =
      state(account)
      |> Map.from_struct()
      |> Map.take(Info.action(State, :store).accept)

    State
    |> Ash.Changeset.for_create(:store, Map.merge(attrs, changes), actor: @owner)
    |> Ash.create!()
  end

  test "owner-only, no HTTP during prepare/snapshot, opaque jobs and mutation returns", c do
    assert {:error, _} = Calendar.prepare(c.a.id, c.from, c.to, c.date, "UTC")
    assert {:error, _} = Calendar.snapshot(c.a.id, c.from, c.to, c.date)
    assert {:error, _} = Calendar.catalog(c.a.id)

    assert {:error, _} =
             Calendar.catalog(c.a.id, actor: %{role: :mail_service, account_id: c.a.id})

    assert {:error, _} = Calendar.sweep()
    result = prepare(c, c.a)
    assert result.loading and result.enabled and is_binary(result.revision)
    refute Map.has_key?(result, :events)
    assert Monolith.TestMail.calls() == []
    assert snapshot(c, c.a).pending

    assert_enqueued(
      worker: PollWorker,
      args: %{account_id: c.a.id, generation: c.a.generation, revision: result.revision}
    )

    assert {:error, _} = State |> Ash.Query.for_read(:read, %{account_id: c.a.id}) |> Ash.read()
  end

  test "authorized catalog is day-independent metadata and never exposes cached events", c do
    prepared = prepare(c, c.a)
    poll(c.a, prepared.revision)
    before = Monolith.TestMail.calls()
    catalog = Calendar.catalog!(c.a.id, actor: @owner)
    assert catalog.account_id == c.a.id
    assert catalog.generation == c.a.generation
    assert catalog.selection_limit == 20
    assert catalog.available? and catalog.catalog_fresh?

    assert catalog.calendars == [
             %{id: "primary", name: "Primary"},
             %{id: "shared", name: "Shared"}
           ]

    assert catalog.selected_ids == ["primary"]
    refute Map.has_key?(catalog, :events)
    refute Map.has_key?(catalog, :fetched_at)
    refute Map.has_key?(catalog, :from_at)
    assert Monolith.TestMail.calls() == before

    update_state(c.a, %{catalog_at: DateTime.add(DateTime.utc_now(), -86_401)})
    stale = Calendar.catalog!(c.a.id, actor: @owner)
    refute stale.available?
    refute stale.catalog_fresh?
    assert stale.calendars == []
    assert stale.selected_ids == []
    assert snapshot(c, c.a).events != []
  end

  test "shared grant reset completes before replacement jobs and rejects old consent", c do
    prepared = prepare(c, c.a)
    poll(c.a, prepared.revision)
    assert state(c.a).events != []

    {:ok, replacement} =
      Access.accept(
        c.workspace.id,
        %{subject: c.a.subject, email: c.a.email},
        :reuse_existing,
        :calendar,
        c.a.generation
      )

    assert replacement.generation != c.a.generation
    assert state(replacement) == nil
    refute Access.current?(c.a.id, c.a.generation)
    assert Access.current?(replacement.id, replacement.generation)
    assert poll(c.a, prepared.revision).skipped
    assert {:ok, "token-a"} = Access.vault().get(replacement.id)

    assert_enqueued(
      worker: MailPollWorker,
      args: %{account_id: replacement.id, generation: replacement.generation}
    )

    assert {:error, :reconnect} =
             Access.accept(
               c.workspace.id,
               %{subject: c.a.subject, email: c.a.email},
               "obsolete-callback-token",
               :calendar,
               c.a.generation
             )

    assert {:ok, "token-a"} = Access.vault().get(replacement.id)
    assert Mail.get_account!(replacement.id, actor: @owner).generation == replacement.generation
  end

  test "shared Gmail grant publication fences stale callbacks but admits a deliberate reconnect",
       c do
    prepared = prepare(c, c.a)
    poll(c.a, prepared.revision)

    assert {:error, :reconnect} =
             Access.accept(
               c.workspace.id,
               %{subject: c.a.subject, email: c.a.email},
               "obsolete-gmail-token",
               :gmail,
               Ash.UUID.generate()
             )

    assert {:ok, "token-a"} = Access.vault().get(c.a.id)
    assert state(c.a).revision == prepared.revision

    disconnected =
      Access.serial(c.a.id, fn ->
        Mail.update_account!(
          c.a,
          %{expected_generation: c.a.generation, status: :disconnected},
          actor: @owner
        )
      end)

    {:ok, reconnected} =
      Access.accept(
        c.workspace.id,
        %{subject: c.a.subject, email: c.a.email},
        "deliberate-reconnect-token",
        :gmail,
        disconnected.generation
      )

    assert reconnected.status == :ready
    refute reconnected.calendar_enabled
    assert reconnected.generation != disconnected.generation
    assert state(reconnected) == nil
    assert {:ok, "deliberate-reconnect-token"} = Access.vault().get(reconnected.id)
  end

  test "unbound Gmail publication cannot claim a subject that appeared after admission", c do
    identity = %{subject: c.a.subject, email: c.a.email}

    assert {:error, :reconnect} =
             Access.accept(c.workspace.id, identity, "obsolete-add-token", :gmail, nil, :absent)

    assert {:ok, "token-a"} = Access.vault().get(c.a.id)
    new_identity = %{subject: "new-unbound-subject", email: "new-unbound@example.invalid"}

    assert {:ok, added} =
             Access.accept(c.workspace.id, new_identity, "new-add-token", :gmail, nil, :absent)

    assert {:error, :reconnect} =
             Access.accept(
               c.workspace.id,
               new_identity,
               "duplicate-add-token",
               :gmail,
               nil,
               :absent
             )

    assert {:ok, "new-add-token"} = Access.vault().get(added.id)
    assert Mail.get_account!(added.id, actor: @owner).generation == added.generation
  end

  test "captured subject identity fences disconnect but permits a freshly admitted reconnect",
       c do
    identity = %{subject: c.a.subject, email: c.a.email}
    captured = %{id: c.a.id, generation: c.a.generation}

    assert {:error, :reconnect} =
             Access.accept(
               c.workspace.id,
               identity,
               "wrong-identity-token",
               :gmail,
               nil,
               %{captured | id: c.b.id}
             )

    disconnected =
      Access.serial(c.a.id, fn ->
        Mail.update_account!(
          c.a,
          %{
            expected_generation: c.a.generation,
            generation: Ash.UUID.generate(),
            status: :disconnected
          },
          actor: @owner
        )
      end)

    assert {:error, :reconnect} =
             Access.accept(c.workspace.id, identity, "old-add-token", :gmail, nil, captured)

    assert {:ok, "token-a"} = Access.vault().get(c.a.id)
    current = %{id: disconnected.id, generation: disconnected.generation}

    assert {:ok, reconnected} =
             Access.accept(c.workspace.id, identity, "fresh-add-token", :gmail, nil, current)

    assert reconnected.status == :ready
    assert reconnected.generation != disconnected.generation
    assert {:ok, "fresh-add-token"} = Access.vault().get(reconnected.id)
  end

  test "per-account selected defaults, shared overrides and explicit empty selection", c do
    first = prepare(c, c.a)
    assert poll(c.a, first.revision).error == nil
    result = snapshot(c, c.a)
    assert [%{title: "Synthetic agenda", calendar_id: "primary"}] = result.events
    assert result.selected_ids == ["primary"]
    assert result.fetched_at && not result.pending
    refute Map.has_key?(poll(c.a, first.revision), :events)
    assert snapshot(c, c.b).events == []
    override = Calendar.select_calendars!(c.a.id, c.a.generation, ["shared"], actor: @owner)
    assert override.revision != first.revision
    assert snapshot(c, c.a).events == []
    poll(c.a, override.revision)
    assert [%{calendar_id: "shared"}] = snapshot(c, c.a).events
    empty = Calendar.select_calendars!(c.a.id, c.a.generation, [], actor: @owner)
    poll(c.a, empty.revision)
    assert snapshot(c, c.a).events == []
    assert snapshot(c, c.a).explicit_selection

    assert {:error, _} =
             Calendar.select_calendars(c.a.id, c.a.generation, ["unknown"], actor: @owner)
  end

  test "a displayed selection cannot cross a reconnect with overlapping calendar IDs", c do
    first = prepare(c, c.a)
    poll(c.a, first.revision)
    displayed_generation = c.a.generation

    assert {:ok, current} =
             Access.accept(
               c.workspace.id,
               %{subject: c.a.subject, email: c.a.email},
               "replacement-calendar-token",
               :calendar,
               c.a.generation
             )

    refute current.generation == displayed_generation
    prepared = prepare(c, current)
    poll(current, prepared.revision)
    before = state(current)
    assert before.generation == current.generation
    assert before.selected_ids == ["primary"]
    assert before.events != []
    jobs = all_enqueued(worker: PollWorker)
    calls = Monolith.TestMail.calls()

    for ids <- [["shared"], []],
        generation <- [displayed_generation, Ash.UUID.generate(), nil, "forged-generation"] do
      assert {:error, _} =
               Calendar.select_calendars(current.id, generation, ids, actor: @owner)

      assert state(current) == before
      assert all_enqueued(worker: PollWorker) == jobs
      assert Monolith.TestMail.calls() == calls
    end

    assert {:error, _} =
             Calendar.select_calendars(current.id, current.generation, ["shared"],
               actor: %{role: :mail_service, account_id: current.id}
             )

    assert state(current) == before
    assert all_enqueued(worker: PollWorker) == jobs

    assert {:ok, selected} =
             Calendar.select_calendars(current.id, current.generation, ["shared"], actor: @owner)

    refute selected.revision == before.revision
    assert state(current).selected_ids == ["shared"]
    assert state(current).events == []
  end

  test "exact overlap includes ongoing/multiday but excludes cancelled and exclusive ends", c do
    date = Date.from_iso8601!(c.date)

    events = [
      c.event,
      %{c.event | id: "boundary", start: c.to, end: c.to},
      Map.put(%{c.event | id: "cancelled"}, :status, "cancelled"),
      %{
        c.event
        | id: "all",
          all_day: true,
          start: Date.to_iso8601(Date.add(date, -1)),
          end: Date.to_iso8601(Date.add(date, 1))
      },
      %{
        c.event
        | id: "ended",
          all_day: true,
          start: Date.to_iso8601(Date.add(date, -1)),
          end: c.date
      }
    ]

    Agent.update(Provider, &%{&1 | events: events})
    result = prepare(c, c.a)
    poll(c.a, result.revision)
    assert MapSet.new(snapshot(c, c.a).events, & &1.id) == MapSet.new(["same", "all"])
    {:events, _, _, from, to} = Enum.find(Monolith.TestMail.calls(), &(elem(&1, 0) == :events))
    assert DateTime.diff(datetime(c.from), datetime(from)) == 26 * 3600
    assert DateTime.diff(datetime(to), datetime(c.to)) == 26 * 3600
  end

  test "window mismatch, expiry and invalid windows never expose another day's content", c do
    result = prepare(c, c.a)
    poll(c.a, result.revision)
    other_date = Date.from_iso8601!(c.date) |> Date.add(1) |> Date.to_iso8601()
    other_to = datetime(c.to) |> DateTime.add(86_400) |> DateTime.to_iso8601()
    assert Calendar.snapshot!(c.a.id, c.to, other_to, other_date, actor: @owner).events == []

    update_state(c.a, %{
      fetched_at: DateTime.add(DateTime.utc_now(), -86_401),
      catalog_at: DateTime.add(DateTime.utc_now(), -86_401)
    })

    assert snapshot(c, c.a).events == []
    assert snapshot(c, c.a).calendars == []
    assert {:error, _} = Calendar.prepare(c.a.id, c.from, other_to, c.date, "UTC", actor: @owner)
  end

  test "failure preserves known events and timestamps without changing Gmail health", c do
    prepared = prepare(c, c.a)
    poll(c.a, prepared.revision)
    before = snapshot(c, c.a)
    Agent.update(Provider, &%{&1 | response: {:error, :forbidden}})
    assert poll(c.a, prepared.revision).error == :reconnect
    after_failure = snapshot(c, c.a)
    assert after_failure.events == before.events
    assert after_failure.fetched_at == before.fetched_at
    assert after_failure.stale
    assert Mail.get_account!(c.a.id, actor: @owner).status == :ready
    assert Mail.get_account!(c.a.id, actor: @owner).last_error == nil
  end

  test "429 cooldown cannot be bypassed by refresh, revision changes or queued polls", c do
    prepared = prepare(c, c.a)
    poll(c.a, prepared.revision)
    Agent.update(Provider, &%{&1 | response: {:error, :rate_limited}})
    assert poll(c.a, prepared.revision).error == :rate_limited
    calls = Monolith.TestMail.calls()
    until = state(c.a).cooldown_until
    Calendar.refresh!(c.a.id, actor: @owner)
    revised = Calendar.select_calendars!(c.a.id, c.a.generation, ["shared"], actor: @owner)
    assert poll(c.a, revised.revision).skipped
    assert state(c.a).cooldown_until == until
    assert Monolith.TestMail.calls() == calls
  end

  test "Gmail cooldown gates Calendar without mutating Gmail errors", c do
    prepared = prepare(c, c.a)

    Mail.update_account!(
      c.a,
      %{
        expected_generation: c.a.generation,
        last_error: :rate_limited,
        next_poll_at: DateTime.add(DateTime.utc_now(), 300)
      },
      actor: @owner
    )

    assert poll(c.a, prepared.revision).skipped
    Calendar.refresh!(c.a.id, actor: @owner)
    assert Monolith.TestMail.calls() == []
  end

  test "wrong service, generation and revision are fenced before HTTP", c do
    prepared = prepare(c, c.a)

    assert Calendar.poll!(c.a.id, c.a.generation, prepared.revision,
             actor: %{role: :mail_service, account_id: c.b.id}
           ).skipped

    assert Calendar.poll!(c.a.id, Ash.UUID.generate(), prepared.revision, actor: @owner).skipped
    assert Calendar.poll!(c.a.id, c.a.generation, Ash.UUID.generate(), actor: @owner).skipped
    assert Monolith.TestMail.calls() == []
    assert :ok = Access.serial(c.a.id, fn -> Calendar.clear(c.a.id) end)
    assert :ok = Access.serial(c.a.id, fn -> Calendar.clear(c.a.id) end)
    assert poll(c.a, prepared.revision).skipped
  end

  test "delayed HTTP is discarded when selection revision changes", c do
    prepared = prepare(c, c.a)
    poll(c.a, prepared.revision)
    test = self()
    Agent.update(Provider, &%{&1 | events: {:wait, test, [c.event]}})
    task = Task.async(fn -> poll(c.a, prepared.revision) end)
    Sandbox.allow(Monolith.Repo, self(), task.pid)
    assert_receive {:calendar_waiting, pid}, 2000

    revision =
      Calendar.select_calendars!(c.a.id, c.a.generation, ["shared"], actor: @owner).revision

    send(pid, :continue)
    assert Task.await(task).skipped
    assert state(c.a).revision == revision
    assert snapshot(c, c.a).events == []
  end

  test "a received 429 survives a newer browser-day context and blocks its queued poll", c do
    prepared = prepare(c, c.a)
    test = self()
    Agent.update(Provider, &%{&1 | events: {:wait_error, test, :rate_limited}})
    task = Task.async(fn -> poll(c.a, prepared.revision) end)
    Sandbox.allow(Monolith.Repo, self(), task.pid)
    assert_receive {:calendar_waiting, pid}, 2000
    earlier = datetime(c.from) |> DateTime.add(-3600) |> DateTime.to_iso8601()
    revised = Calendar.prepare!(c.a.id, earlier, c.to, c.date, "UTC-01", actor: @owner)
    send(pid, :continue)
    assert Task.await(task).error == :rate_limited
    current = state(c.a)
    assert current.revision == revised.revision
    assert DateTime.diff(current.cooldown_until, DateTime.utc_now()) in 295..300
    assert current.events == []
    calls = Monolith.TestMail.calls()
    assert poll(c.a, revised.revision).skipped
    Calendar.refresh!(c.a.id, actor: @owner)
    assert Monolith.TestMail.calls() == calls
    assert state(c.b) == nil
  end

  test "a received 429 survives selection changes and cannot shorten an existing cooldown", c do
    prepared = prepare(c, c.a)
    poll(c.a, prepared.revision)
    test = self()
    Agent.update(Provider, &%{&1 | events: {:wait_error, test, :rate_limited}})
    task = Task.async(fn -> poll(c.a, prepared.revision) end)
    Sandbox.allow(Monolith.Repo, self(), task.pid)
    assert_receive {:calendar_waiting, pid}, 2000
    revised = Calendar.select_calendars!(c.a.id, c.a.generation, ["shared"], actor: @owner)
    deadline = DateTime.add(DateTime.utc_now(), 600)
    update_state(c.a, %{cooldown_until: deadline, next_poll_at: deadline})
    send(pid, :continue)
    assert Task.await(task).error == :rate_limited
    assert state(c.a).revision == revised.revision
    assert state(c.a).cooldown_until == deadline
    assert state(c.a).selected_ids == ["shared"]
    assert poll(c.a, revised.revision).skipped
  end

  test "a received 429 cannot contaminate a reconnected account generation", c do
    prepared = prepare(c, c.a)
    test = self()
    Agent.update(Provider, &%{&1 | events: {:wait_error, test, :rate_limited}})
    task = Task.async(fn -> poll(c.a, prepared.revision) end)
    Sandbox.allow(Monolith.Repo, self(), task.pid)
    assert_receive {:calendar_waiting, pid}, 2000

    {:ok, current} =
      Access.accept(
        c.workspace.id,
        %{subject: c.a.subject, email: c.a.email},
        "new-generation-refresh",
        :calendar
      )

    fresh = prepare(c, current)
    send(pid, :continue)
    assert Task.await(task).skipped
    assert state(current).revision == fresh.revision
    assert state(current).cooldown_until == nil
    assert state(current).error == nil
  end

  test "sweep enqueues due contexts and prunes expired private payloads", c do
    assert Ecto.Changeset.get_field(SweepWorker.new(%{}), :queue) == "calendar"
    assert Ecto.Changeset.get_field(PollWorker.new(%{}), :queue) == "calendar"
    prepared = prepare(c, c.a)
    poll(c.a, prepared.revision)
    update_state(c.a, %{next_poll_at: DateTime.add(DateTime.utc_now(), -1)})
    before = Monolith.TestMail.calls()
    assert :ok = SweepWorker.perform(%Oban.Job{})
    assert state(c.a).loading
    assert DateTime.compare(state(c.a).next_poll_at, DateTime.utc_now()) == :gt
    assert Monolith.TestMail.calls() == before

    update_state(c.a, %{
      fetched_at: DateTime.add(DateTime.utc_now(), -86_401),
      catalog_at: DateTime.add(DateTime.utc_now(), -86_401)
    })

    assert :ok = SweepWorker.perform(%Oban.Job{})
    assert state(c.a).events == []
    assert state(c.a).calendars == []
    assert state(c.a).fetched_at == nil
    assert state(c.a).catalog_at == nil
  end

  test "generation changes and disabling Calendar discard delayed results", c do
    prepared = prepare(c, c.a)
    poll(c.a, prepared.revision)
    test = self()
    Agent.update(Provider, &%{&1 | events: {:wait, test, [c.event]}})
    task = Task.async(fn -> poll(c.a, prepared.revision) end)
    Sandbox.allow(Monolith.Repo, self(), task.pid)
    assert_receive {:calendar_waiting, pid}, 2000

    Access.serial(c.a.id, fn ->
      Mail.update_account!(c.a, %{expected_generation: c.a.generation, calendar_enabled: false},
        actor: @owner
      )
    end)

    send(pid, :continue)
    assert Task.await(task).skipped
    assert snapshot(c, c.a).events == []
    refute snapshot(c, c.a).enabled

    current = Mail.get_account!(c.a.id, actor: @owner)

    current =
      Mail.update_account!(
        current,
        %{
          expected_generation: current.generation,
          calendar_enabled: true,
          generation: Ash.UUID.generate()
        },
        actor: @owner
      )

    assert Calendar.poll!(c.a.id, current.generation, prepared.revision, actor: @owner).skipped
    assert snapshot(c, current).events == []
  end

  test "a late success cannot clear a newer Calendar 429", c do
    prepared = prepare(c, c.a)
    poll(c.a, prepared.revision)
    before = snapshot(c, c.a)
    test = self()
    Agent.update(Provider, &%{&1 | events: {:wait, test, [c.event]}})
    task = Task.async(fn -> poll(c.a, prepared.revision) end)
    Sandbox.allow(Monolith.Repo, self(), task.pid)
    assert_receive {:calendar_waiting, pid}, 2000
    Agent.update(Provider, &%{&1 | response: {:error, :rate_limited}})
    assert poll(c.a, prepared.revision).error == :rate_limited
    until = state(c.a).cooldown_until
    send(pid, :continue)
    assert Task.await(task).error == :rate_limited
    assert state(c.a).cooldown_until == until
    assert snapshot(c, c.a).fetched_at == before.fetched_at
    assert snapshot(c, c.a).events == before.events
  end

  test "revising the browser window fences delayed work and broadcasts identifiers only", c do
    id = c.a.id
    Phoenix.PubSub.subscribe(Monolith.PubSub, "mail:" <> id)
    prepared = prepare(c, c.a)
    assert_receive {:calendar_changed, ^id}
    poll(c.a, prepared.revision)
    assert_receive {:calendar_changed, ^id}
    test = self()
    Agent.update(Provider, &%{&1 | events: {:wait, test, [c.event]}})
    task = Task.async(fn -> poll(c.a, prepared.revision) end)
    Sandbox.allow(Monolith.Repo, self(), task.pid)
    assert_receive {:calendar_waiting, pid}, 2000
    earlier = datetime(c.from) |> DateTime.add(-3600) |> DateTime.to_iso8601()
    revised = Calendar.prepare!(id, earlier, c.to, c.date, "UTC-01", actor: @owner)
    assert revised.revision != prepared.revision
    assert snapshot(c, c.a).events == []
    send(pid, :continue)
    assert Task.await(task).skipped
    assert Calendar.snapshot!(id, earlier, c.to, c.date, actor: @owner).events == []
  end

  test "escaped calendar text also obeys the total JSON byte budget", c do
    calendars =
      Enum.map(
        1..100,
        &%{id: "large-#{&1}", name: String.duplicate("\u0001", 1024), selected: true}
      )

    Agent.update(Provider, &%{&1 | calendars: calendars})
    prepared = prepare(c, c.a)
    poll(c.a, prepared.revision)
    assert snapshot(c, c.a).truncated
    stored = state(c.a)

    assert byte_size(
             Jason.encode!(%{
               calendars: stored.calendars,
               events: stored.events,
               selected_ids: stored.selected_ids
             })
           ) <= 512 * 1024
  end

  test "bounded payload and selected calendar caps report truncation", c do
    calendars = Enum.map(1..25, &%{id: "calendar-#{&1}", name: "Synthetic", selected: true})
    events = Enum.map(1..100, &%{c.event | id: "e#{&1}", title: String.duplicate("x", 4096)})
    Agent.update(Provider, &%{&1 | calendars: calendars, events: events})
    prepared = prepare(c, c.a)
    poll(c.a, prepared.revision)
    result = snapshot(c, c.a)
    assert result.truncated and result.selection_truncated
    assert length(result.selected_ids) == 20
    assert length(result.events) <= 500

    assert byte_size(
             Jason.encode!(%{
               calendars: state(c.a).calendars,
               events: state(c.a).events,
               selected_ids: state(c.a).selected_ids
             })
           ) <= 512 * 1024
  end
end
