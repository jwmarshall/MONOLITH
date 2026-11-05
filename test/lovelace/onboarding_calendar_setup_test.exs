defmodule Lovelace.OnboardingCalendarSetupTest do
  use Lovelace.DataCase, async: false
  use Oban.Testing, repo: Lovelace.Repo, engine: Oban.Engines.Lite

  alias Ash.Resource.Info
  alias Lovelace.Calendar
  alias Lovelace.Calendar.{PollWorker, State}
  alias Lovelace.Mail
  alias Lovelace.Mail.Connections
  alias Lovelace.Onboarding
  alias Lovelace.Onboarding.CalendarSetup

  @owner %{role: :local_owner}

  defmodule Provider do
    def calendars(_) do
      Lovelace.TestMail.record(:calendar_catalog)

      Agent.get(Lovelace.TestMail, fn state ->
        Map.get(state, :calendar_response, {
          :ok,
          %{
            calendars: [
              %{id: "primary", name: "Primary", selected: true},
              %{id: "shared", name: "Shared calendar", selected: false}
            ],
            truncated: false
          }
        })
      end)
    end

    def events(_, id, _, _) do
      Lovelace.TestMail.record({:calendar_events, id})
      {:ok, %{events: [], truncated: false}}
    end
  end

  setup do
    {:ok, _} = Lovelace.TestMail.start()
    keys = [:calendar_provider, :gmail_provider, :gmail_vault]
    previous = Map.new(keys, &{&1, Application.get_env(:lovelace, &1)})
    Application.put_env(:lovelace, :calendar_provider, Provider)
    Application.put_env(:lovelace, :gmail_provider, Lovelace.TestGoogle)
    Application.put_env(:lovelace, :gmail_vault, Lovelace.TestMailVault)

    on_exit(fn ->
      for {key, value} <- previous do
        if value,
          do: Application.put_env(:lovelace, key, value),
          else: Application.delete_env(:lovelace, key)
      end
    end)

    {:ok, progress} = Onboarding.save_workspace("Calendar guide", actor: @owner)

    {:ok, account} =
      Connections.accept(
        progress.workspace_id,
        %{subject: "guide-calendar", email: "guide@example.invalid"},
        "guide-token",
        :calendar
      )

    date = Date.utc_today()

    window = %{
      "from" => DateTime.new!(date, ~T[00:00:00], "Etc/UTC") |> DateTime.to_iso8601(),
      "to" => DateTime.new!(Date.add(date, 1), ~T[00:00:00], "Etc/UTC") |> DateTime.to_iso8601(),
      "date" => Date.to_iso8601(date),
      "timezone" => "UTC"
    }

    %{
      account: account,
      workspace_id: progress.workspace_id,
      window: window,
      opts: [actor: @owner, workspace_id: progress.workspace_id]
    }
  end

  defp state(account) do
    State
    |> Ash.Query.for_read(:read, %{account_id: account.id}, actor: @owner)
    |> Ash.read_one!()
  end

  defp update_state(account, changes) do
    attributes =
      state(account)
      |> Map.from_struct()
      |> Map.take(Info.action(State, :store).accept)

    State
    |> Ash.Changeset.for_create(:store, Map.merge(attributes, changes), actor: @owner)
    |> Ash.create!()
  end

  defp prepare(context) do
    CalendarSetup.prepare(
      context.account.id,
      context.account.generation,
      context.window,
      context.opts
    )
  end

  defp populate(context) do
    assert {:ok, %{loading: true}} = prepare(context)
    revision = state(context.account).revision
    Calendar.poll!(context.account.id, context.account.generation, revision, actor: @owner)
    revision
  end

  test "owner-only bootstrap metadata and preparation queue without HTTP", c do
    assert {:error, _} = CalendarSetup.read()

    assert {:error, _} =
             CalendarSetup.read(actor: %{role: :mail_service, account_id: c.account.id})

    assert {:error, _} = CalendarSetup.read(authorize?: false)

    assert {:error, _} =
             CalendarSetup.prepare(c.account.id, c.account.generation, c.window,
               workspace_id: c.workspace_id
             )

    assert {:error, _} =
             CalendarSetup.select(c.account.id, c.account.generation, [],
               workspace_id: c.workspace_id
             )

    assert {:ok, metadata} = CalendarSetup.read(actor: @owner)
    assert metadata.workspace_id == c.workspace_id
    assert metadata.account_id == c.account.id
    assert metadata.generation == c.account.generation
    assert metadata.enabled
    refute metadata.loading
    refute metadata.available?
    assert metadata.catalog_at == nil
    assert metadata.error == nil
    assert metadata.calendars == []
    refute Map.has_key?(metadata, :events)
    assert {:ok, %{loading: true, catalog_at: nil}} = prepare(c)
    assert Lovelace.TestMail.calls() == []
    current = state(c.account)

    assert_enqueued(
      worker: PollWorker,
      args: %{
        account_id: c.account.id,
        generation: c.account.generation,
        revision: current.revision
      }
    )
  end

  test "manual refresh queues before due while normal preparation and duplicate clicks stay bounded",
       c do
    populate(c)
    calls = Lovelace.TestMail.calls()
    prior = state(c.account)
    assert DateTime.compare(prior.next_poll_at, DateTime.utc_now()) == :gt
    assert {:ok, %{loading: false}} = prepare(c)

    opts = Keyword.put(c.opts, :refresh?, true)

    assert {:ok, %{loading: true}} =
             CalendarSetup.prepare(c.account.id, c.account.generation, c.window, opts)

    assert state(c.account).revision == prior.revision
    jobs = all_enqueued(worker: PollWorker)
    assert length(jobs) == 1

    assert {:ok, %{loading: true}} =
             CalendarSetup.prepare(c.account.id, c.account.generation, c.window, opts)

    assert all_enqueued(worker: PollWorker) == jobs
    assert Lovelace.TestMail.calls() == calls
  end

  test "persisted bounded-result and selection warnings remain independent catalog metadata", c do
    populate(c)
    calls = Lovelace.TestMail.calls()

    for {truncated, selection_truncated} <- [{true, false}, {false, true}, {true, true}] do
      update_state(c.account, %{
        truncated: truncated,
        selection_truncated: selection_truncated
      })

      assert {:ok, metadata} = CalendarSetup.read(actor: @owner)
      assert metadata.truncated == truncated
      assert metadata.selection_truncated == selection_truncated
      assert metadata.available?
      refute Map.has_key?(metadata, :events)
    end

    update_state(c.account, %{catalog_at: DateTime.add(DateTime.utc_now(), -86_401)})
    assert {:ok, metadata} = CalendarSetup.read(actor: @owner)
    refute metadata.truncated
    refute metadata.selection_truncated
    assert Lovelace.TestMail.calls() == calls
  end

  test "shared and explicit empty selections reuse Calendar validation without provider work",
       c do
    populate(c)
    calls = Lovelace.TestMail.calls()
    assert {:ok, metadata} = CalendarSetup.read(actor: @owner)

    assert metadata.calendars == [
             %{id: "primary", name: "Primary"},
             %{id: "shared", name: "Shared calendar"}
           ]

    assert metadata.available? and metadata.catalog_fresh?
    assert metadata.selected_ids == ["primary"]
    assert metadata.catalog_at
    refute Map.has_key?(metadata, :events)

    assert {:ok, %{selected_ids: ["shared"], loading: true}} =
             CalendarSetup.select(c.account.id, c.account.generation, ["shared"], c.opts)

    assert {:ok, %{selected_ids: [], loading: true}} =
             CalendarSetup.select(c.account.id, c.account.generation, [], c.opts)

    assert state(c.account).explicit_selection

    for ids <- [["unknown"], List.duplicate("shared", 21), nil, "shared", [%{"id" => "shared"}]] do
      assert {:error, _} = CalendarSetup.select(c.account.id, c.account.generation, ids, c.opts)
    end

    assert state(c.account).selected_ids == []
    assert Lovelace.TestMail.calls() == calls
  end

  test "expired catalog, reconnect and rate limits remain honest without modifying Gmail", c do
    revision = populate(c)
    gmail = Mail.get_account!(c.account.id, actor: @owner)
    stale_at = DateTime.add(DateTime.utc_now(), -86_401)
    update_state(c.account, %{catalog_at: stale_at, selection_truncated: true})
    assert {:ok, stale} = CalendarSetup.read(actor: @owner)
    assert stale.catalog_at == stale_at
    refute stale.catalog_fresh?
    refute stale.available?
    assert stale.calendars == []
    assert stale.selected_ids == []

    assert {:error, _} =
             CalendarSetup.select(c.account.id, c.account.generation, ["shared"], c.opts)

    Agent.update(Lovelace.TestMail, &Map.put(&1, :calendar_response, {:error, :rate_limited}))
    Calendar.poll!(c.account.id, c.account.generation, revision, actor: @owner)
    assert {:ok, limited} = CalendarSetup.read(actor: @owner)
    assert limited.error == :rate_limited
    refute limited.loading
    assert limited.cooldown_until
    calls = Lovelace.TestMail.calls()
    assert {:ok, %{error: :rate_limited, loading: false}} = prepare(c)
    assert Lovelace.TestMail.calls() == calls

    assert {:ok, %{error: :rate_limited, loading: false}} =
             CalendarSetup.prepare(
               c.account.id,
               c.account.generation,
               c.window,
               Keyword.put(c.opts, :refresh?, true)
             )

    assert Mail.get_account!(c.account.id, actor: @owner).last_error == gmail.last_error

    Mail.update_account!(
      gmail,
      %{expected_generation: gmail.generation, status: :reconnect},
      actor: @owner
    )

    assert {:ok, %{enabled: false, error: :reconnect, calendars: []}} =
             CalendarSetup.read(actor: @owner)

    assert {:error, _} = prepare(c)
  end

  test "Calendar scope and provider failures preserve catalog freshness and Gmail health", c do
    revision = populate(c)
    {:ok, before} = CalendarSetup.read(actor: @owner)

    for {provider_error, displayed_error} <- [
          {:forbidden, :reconnect},
          {:provider, :provider},
          {:unavailable, :unavailable}
        ] do
      Agent.update(
        Lovelace.TestMail,
        &Map.put(&1, :calendar_response, {:error, provider_error})
      )

      Calendar.poll!(c.account.id, c.account.generation, revision, actor: @owner)
      assert {:ok, metadata} = CalendarSetup.read(actor: @owner)
      assert metadata.error == displayed_error
      assert metadata.calendars == before.calendars
      assert metadata.catalog_at == before.catalog_at
      assert metadata.catalog_fresh?
      assert metadata.available? == (displayed_error != :reconnect)
      gmail = Mail.get_account!(c.account.id, actor: @owner)
      assert gmail.status == :ready
      assert gmail.last_error == nil
    end
  end

  test "Gmail admission cooldown is visible even before any catalog exists", c do
    deadline = DateTime.add(DateTime.utc_now(), 300)

    Mail.update_account!(
      c.account,
      %{
        expected_generation: c.account.generation,
        last_error: :rate_limited,
        next_poll_at: deadline
      },
      actor: @owner
    )

    assert {:ok, %{error: :rate_limited, cooldown_until: ^deadline, loading: false}} =
             CalendarSetup.read(actor: @owner)

    assert {:ok, %{loading: false, error: :rate_limited}} = prepare(c)
    assert Lovelace.TestMail.calls() == []

    assert {:ok, %{loading: false, error: :rate_limited}} =
             CalendarSetup.prepare(
               c.account.id,
               c.account.generation,
               c.window,
               Keyword.put(c.opts, :refresh?, true)
             )
  end

  test "reconnect generations and malformed submissions cannot change the new context", c do
    populate(c)

    {:ok, replacement} =
      Connections.accept(
        c.workspace_id,
        %{subject: c.account.subject, email: c.account.email},
        "replacement-token",
        :calendar
      )

    assert replacement.generation != c.account.generation
    assert {:error, _} = prepare(c)

    assert {:error, _} =
             CalendarSetup.select(c.account.id, c.account.generation, ["shared"], c.opts)

    assert {:ok, %{generation: generation, catalog_at: nil}} = CalendarSetup.read(actor: @owner)
    assert generation == replacement.generation
    assert state(replacement) == nil

    for {id, generation, opts} <- [
          {"malformed", replacement.generation, c.opts},
          {replacement.id, "malformed", c.opts},
          {replacement.id, replacement.generation, [actor: @owner]}
        ] do
      assert {:error, _} = CalendarSetup.select(id, generation, [], opts)
    end

    for window <- [nil, %{}, Map.put(c.window, "from", []), Map.put(c.window, "timezone", "\n")] do
      assert {:error, _} =
               CalendarSetup.prepare(replacement.id, replacement.generation, window, c.opts)
    end

    assert state(replacement) == nil
  end

  test "a replaced workspace fences old forms even when the same Google account is shared", c do
    populate(c)
    replacement = Lovelace.Workspaces.create_workspace!("Other guide workspace", actor: @owner)
    Mail.attach_account!(%{workspace_id: replacement.id, account_id: c.account.id}, actor: @owner)
    {:ok, progress} = Onboarding.progress(actor: @owner)
    Ash.update!(progress, %{workspace_id: replacement.id}, action: :save_workspace, actor: @owner)
    before = state(c.account)
    assert {:ok, %{workspace_id: current_workspace}} = CalendarSetup.read(actor: @owner)
    assert current_workspace == replacement.id
    assert {:error, _} = prepare(c)

    assert {:error, _} =
             CalendarSetup.select(c.account.id, c.account.generation, ["shared"], c.opts)

    assert state(c.account).revision == before.revision
    assert state(c.account).selected_ids == before.selected_ids
  end

  test "replacing workspace membership rejects the former account without leaking its catalog",
       c do
    populate(c)
    [membership] = Mail.workspace_accounts!(c.workspace_id, actor: @owner)
    Mail.detach_account!(membership, actor: @owner)

    {:ok, replacement} =
      Connections.accept(
        c.workspace_id,
        %{subject: "new-guide-account", email: "replacement@example.invalid"},
        "replacement-token",
        :calendar
      )

    before = state(c.account)

    assert {:ok, %{account_id: id, calendars: [], catalog_at: nil}} =
             CalendarSetup.read(actor: @owner)

    assert id == replacement.id
    assert {:error, _} = prepare(c)

    assert {:error, _} =
             CalendarSetup.select(c.account.id, c.account.generation, ["shared"], c.opts)

    assert state(c.account).revision == before.revision
    [membership] = Mail.workspace_accounts!(c.workspace_id, actor: @owner)
    Mail.detach_account!(membership, actor: @owner)
    assert {:ok, nil} = CalendarSetup.read(actor: @owner)
  end
end
