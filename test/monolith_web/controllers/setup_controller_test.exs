defmodule MonolithWeb.SetupControllerTest do
  use MonolithWeb.ConnCase, async: false
  alias Monolith.Owner
  alias Monolith.Security.Bootstrap
  @password "synthetic onboarding password"

  setup %{conn: conn} do
    # Pairing and owner creation must not inherit earlier tests' node-wide login budget.
    :ok = Supervisor.terminate_child(Monolith.Supervisor, Owner.Throttle)
    {:ok, _} = Supervisor.restart_child(Monolith.Supervisor, Owner.Throttle)
    :ok = Supervisor.terminate_child(Monolith.Supervisor, Bootstrap)
    observer = self()

    {:ok, server} =
      Bootstrap.start_link(
        status: fn -> if match?({:ok, true}, Owner.configured()), do: :configured, else: :new end,
        announce: fn code -> send(observer, {:pairing_code, code}) end,
        configure: fn password ->
          Owner.configure!(password, actor: %{role: :owner_setup})
          {:ok, _} = Monolith.Onboarding.start(actor: %{role: :local_owner})
          Owner.unlock(password, "synthetic-bootstrap")
        end
      )

    on_exit(fn ->
      if Process.alive?(server), do: GenServer.stop(server)
      Supervisor.restart_child(Monolith.Supervisor, Bootstrap)
    end)

    assert_receive {:pairing_code, code}
    %{conn: %{conn | host: "localhost"}, code: code}
  end

  test "unpaired password submission cannot create the local owner", %{conn: conn} do
    result = submit(conn, "/setup/password", password_params())
    assert redirected_to(result, 303) == "/setup?error=setup"
    assert {:ok, false} = Owner.configured()
    refute get_session(result, :owner_session_token)
    refute Map.has_key?(result.body_params, "password")
  end

  test "pairing gates owner creation, rotates the session, starts resumable guide and cannot be replayed",
       %{conn: conn, code: code} do
    paired =
      submit(init_test_session(conn, %{unrelated: "old"}), "/setup/pair", %{
        "pairing_code" => code
      })

    assert redirected_to(paired, 303) == "/setup"
    capability = get_session(paired, :bootstrap_capability)
    assert Bootstrap.paired?(capability)
    refute inspect(paired.params) =~ code
    refute inspect(paired.body_params) =~ code
    result = paired |> recycle() |> submit("/setup/password", password_params())
    assert redirected_to(result, 303) == "/onboarding"
    assert {:ok, true} = Owner.configured()
    assert {:ok, _} = Owner.verify_session(get_session(result, :owner_session_token))
    assert Monolith.Onboarding.pending?()
    refute get_session(result, :unrelated)
    refute get_session(result, :bootstrap_capability)
    assert {:error, :pairing} = Bootstrap.pair(code)
    assert get(result |> recycle(), "/setup") |> redirected_to() == "/unlock"
  end

  test "invalid CSRF and query-string pairing secrets are rejected before owner creation", %{
    conn: conn,
    code: code
  } do
    rejected =
      conn
      |> put_private(:plug_skip_csrf_protection, false)
      |> submit("/setup/pair", %{"pairing_code" => code})

    assert response(rejected, 403)
    assert {:ok, false} = Owner.configured()
    rejected = submit(conn, "/setup/pair?pairing_code=" <> code, %{})
    assert response(rejected, 400)
    assert rejected.query_string == ""
    assert rejected.query_params == %{}
    assert {:ok, _} = Bootstrap.pair(code)
  end

  test "setup secret posts bypass request logging and telemetry, including encoded path aliases",
       %{conn: conn} do
    sentinel = "synthetic-secret-that-must-never-be-instrumented"
    observer = self()
    handler = "setup-secret-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      [[:phoenix, :endpoint, :start], [:phoenix, :router_dispatch, :start]],
      fn event, _, metadata, _ -> send(observer, {:request_metadata, event, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    log =
      ExUnit.CaptureLog.capture_log([level: :debug], fn ->
        for path <- ["/setup/password", "/%73etup/password/"] do
          result = submit(conn, path, Map.put(password_params(), "password", sentinel))
          refute inspect(result.params) =~ sentinel
          refute inspect(result.body_params) =~ sentinel
        end
      end)

    refute log =~ sentinel
    refute_receive {:request_metadata, _, _}
    assert {:ok, false} = Owner.configured()
  end

  test "setup GET exposes only terminal pairing until this browser is paired", %{
    conn: conn,
    code: code
  } do
    page = get(conn, "/setup")
    document = page |> html_response(200) |> LazyHTML.from_fragment()
    assert get_resp_header(page, "cache-control") == ["no-store"]
    assert get_resp_header(page, "referrer-policy") == ["no-referrer"]

    assert exists?(document, "#setup-pair-form input[name='pairing_code'][type='password']")
    assert exists?(document, "#setup-pair-form input[name='_csrf_token']")
    refute exists?(document, "#setup-password-form")
    refute html_response(page, 200) =~ code

    paired = submit(recycle(page), "/setup/pair", %{"pairing_code" => code})
    page = get(recycle(paired), "/setup")
    document = page |> html_response(200) |> LazyHTML.from_fragment()
    refute exists?(document, "#setup-pair-form")
    assert exists?(document, "#setup-password-form input[name='_csrf_token']")
    assert exists?(document, "#setup-acknowledge[required]")
    assert exists?(document, "#setup-password[aria-describedby]")
    assert {:ok, false} = Owner.configured()
  end

  test "validation errors render accessibly without retaining passwords or consuming pairing", %{
    conn: conn,
    code: code
  } do
    rejected = submit(conn, "/setup/pair", %{"pairing_code" => String.duplicate("x", 43)})
    page = get(recycle(rejected), redirected_to(rejected, 303))
    document = page |> html_response(200) |> LazyHTML.from_fragment()
    assert exists?(document, "#setup-error[role='alert']")
    assert exists?(document, "#setup-pair-form")

    paired = submit(recycle(page), "/setup/pair", %{"pairing_code" => code})

    for {params, category} <- [
          {%{password_params() | "password" => "short"}, "password"},
          {%{password_params() | "password_confirmation" => "different confirmation"},
           "confirmation"},
          {Map.delete(password_params(), "acknowledge_recovery"), "acknowledgement"}
        ] do
      result = submit(recycle(paired), "/setup/password", params)
      assert redirected_to(result, 303) == "/setup?error=" <> category
      page = get(recycle(result), redirected_to(result, 303))
      document = page |> html_response(200) |> LazyHTML.from_fragment()
      assert exists?(document, "#setup-error[role='alert']")
      assert exists?(document, "#setup-password-form")
      refute exists?(document, "input[type='password'][value]")
      refute html_response(page, 200) =~ @password
      assert Bootstrap.paired?(get_session(page, :bootstrap_capability))
      assert {:ok, false} = Owner.configured()
    end

    result = submit(recycle(paired), "/setup/password", password_params())
    assert redirected_to(result, 303) == "/onboarding"
    assert {:ok, true} = Owner.configured()
  end

  defp exists?(document, selector), do: Enum.any?(LazyHTML.query(document, selector))

  defp password_params do
    %{
      "password" => @password,
      "password_confirmation" => @password,
      "acknowledge_recovery" => "true"
    }
  end

  defp submit(conn, path, params) do
    conn
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> post(path, URI.encode_query(params))
  end
end
