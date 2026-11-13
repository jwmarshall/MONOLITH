defmodule MonolithWeb.CalendarLoggingTest do
  use MonolithWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Monolith.Calendar.State
  alias Monolith.Integrations.Google.ClientCredentials
  alias Monolith.{Mail, Onboarding}
  alias Monolith.Onboarding.CalendarSetup
  alias Monolith.TestSupport.OnboardingKeychain
  alias Plug.Conn.Query

  @owner %{role: :local_owner}
  @private_id "synthetic-private-calendar@example.invalid"
  @unknown_id "synthetic-rejected-calendar@example.invalid"

  setup %{conn: conn} do
    start_supervised!(OnboardingKeychain)
    {:ok, _} = Monolith.TestMail.start()

    for {key, value} <- [
          google_client_keychain: OnboardingKeychain,
          gmail_provider: Monolith.TestGoogle,
          gmail_vault: Monolith.TestMailVault
        ] do
      previous = Application.fetch_env(:monolith, key)
      Application.put_env(:monolith, key, value)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:monolith, key, value)
          :error -> Application.delete_env(:monolith, key)
        end
      end)
    end

    :ok = ClientCredentials.save("synthetic-calendar-client", "synthetic-calendar-secret")
    conn = authenticate_owner(conn)
    {:ok, _} = Onboarding.save_workspace("Calendar logging fixture", actor: @owner)
    {:ok, workspace} = Onboarding.workspace(actor: @owner)

    account =
      Mail.save_connection!(
        %{
          id: Ash.UUID.generate(),
          subject: "synthetic-calendar-logging",
          email: "synthetic-owner@example.invalid",
          generation: Ash.UUID.generate(),
          calendar_enabled: true
        },
        actor: @owner
      )

    Mail.attach_account!(%{workspace_id: workspace.id, account_id: account.id}, actor: @owner)
    now = DateTime.utc_now()
    day = Date.utc_today()

    State
    |> Ash.Changeset.for_create(
      :store,
      %{
        account_id: account.id,
        generation: account.generation,
        revision: Ash.UUID.generate(),
        calendars: [%{"id" => @private_id, "name" => "Synthetic private calendar"}],
        selected_ids: [],
        from_at: DateTime.new!(day, ~T[00:00:00]),
        to_at: DateTime.new!(Date.add(day, 1), ~T[00:00:00]),
        local_date: day,
        timezone: "Etc/UTC",
        context_at: now,
        catalog_at: now,
        next_poll_at: now
      },
      actor: @owner
    )
    |> Ash.create!()

    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    %{
      conn: conn,
      selection: %{
        "operation" => "select_calendars",
        "workspace_id" => workspace.id,
        "account_id" => account.id,
        "generation" => account.generation,
        "calendar_ids" => ["", @private_id]
      }
    }
  end

  test "ordinary Calendar form POST logs redact successful, malformed, unknown and stale selections",
       %{conn: conn, selection: selection} do
    log =
      capture_log([level: :debug], fn ->
        assert redirected_to(submit(conn, selection)) ==
                 "/onboarding/calendar?notice=calendars_saved"

        assert {:ok, %{selected_ids: [@private_id]}} = CalendarSetup.read(actor: @owner)
      end)

    assert_http_redacted(log)
    assert log =~ "select_calendars"

    for params <- [
          Map.put(selection, "calendar_ids", @private_id),
          Map.put(selection, "calendar_ids", %{"nested" => @private_id}),
          Map.put(selection, "calendar_ids", [@unknown_id]),
          Map.put(selection, "generation", Ash.UUID.generate()),
          Map.put(selection, "workspace_id", Ash.UUID.generate()),
          Map.put(selection, "account_id", Ash.UUID.generate())
        ] do
      log =
        capture_log([level: :debug], fn ->
          assert submit(conn, params) |> html_response(422) =~ "role=\"alert\""
          assert {:ok, %{selected_ids: [@private_id]}} = CalendarSetup.read(actor: @owner)
        end)

      assert_http_redacted(log)
    end
  end

  test "redaction precedes owner, CSRF and operation rejection and covers related Calendar params",
       %{conn: conn, selection: selection} do
    for refused_conn <- [
          build_conn(:get, "http://localhost/"),
          conn
          |> recycle()
          |> init_test_session(%{owner_session_token: "synthetic-invalid-session"})
        ] do
      log =
        capture_log([level: :debug], fn ->
          assert redirected_to(submit(refused_conn, selection)) == "/unlock"
        end)

      assert_http_redacted(log)
    end

    log =
      capture_log([level: :debug], fn ->
        assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
          conn
          |> put_private(:plug_skip_csrf_protection, false)
          |> submit(selection)
        end
      end)

    assert_http_redacted(log)

    for {operation, status} <- [
          {"load_calendars", 422},
          {"refresh_calendars", 422},
          {"invalid-operation", 400}
        ] do
      params =
        selection
        |> Map.put("operation", operation)
        |> Map.put("calendar_id", @unknown_id)
        |> Map.put("extra", %{"calendar_ids" => [@private_id]})

      log =
        capture_log([level: :debug], fn ->
          assert submit(conn, params).status == status
        end)

      assert_http_redacted(log)
      assert log =~ "\"calendar_id\" => \"[FILTERED]\""
      assert log =~ operation
    end

    assert {:ok, %{selected_ids: []}} = CalendarSetup.read(actor: @owner)
  end

  defp submit(conn, params) do
    conn
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> post("/onboarding/calendar", Query.encode(params))
  end

  defp assert_http_redacted(log) do
    assert log =~ "POST /onboarding/calendar"
    assert log =~ "Processing with MonolithWeb.OnboardingController.update/2"
    assert_redacted(log)
  end

  defp assert_redacted(log) do
    assert log =~ "Parameters:"
    assert log =~ "\"calendar_ids\" => \"[FILTERED]\""
    refute log =~ @private_id
    refute log =~ @unknown_id
    refute log =~ URI.encode_www_form(@private_id)
    refute log =~ URI.encode_www_form(@unknown_id)
  end
end
