defmodule LovelaceWeb.GeminiCredentialsTest do
  use LovelaceWeb.ConnCase, async: false
  import ExUnit.CaptureLog

  alias Lovelace.TestSupport.GeminiVault
  alias LovelaceWeb.Plugs.GeminiCredentials

  @key "synthetic-gemini-key"

  setup %{conn: conn} do
    start_supervised!(GeminiVault)
    previous = Application.get_env(:lovelace, :gemini_vault)
    Application.put_env(:lovelace, :gemini_vault, GeminiVault)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lovelace, :gemini_vault, previous),
        else: Application.delete_env(:lovelace, :gemini_vault)
    end)

    %{conn: authenticate_owner(conn)}
  end

  test "ordinary authenticated POST saves/removes without echoing secrets or entering Phoenix request telemetry",
       %{conn: conn} do
    owner = self()
    handler = "gemini-credential-test-#{System.unique_integer([:positive])}"
    events = [[:phoenix, :endpoint, :start], [:phoenix, :router_dispatch, :start]]

    :telemetry.attach_many(
      handler,
      events,
      fn event, _, meta, _ -> send(owner, {:instrumented, event, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert capture_log(fn ->
             saved = submit(conn, %{"operation" => "save", "api_key" => @key})
             assert redirected_to(saved, 303) == "/?connections=gemini&gemini=saved"
             assert saved.params == %{}
             assert saved.body_params == %{}
             assert get_resp_header(saved, "cache-control") == ["no-store"]
             refute saved.resp_body =~ @key
             assert {:ok, @key} = GeminiVault.get("unused")

             removed = submit(recycle(saved), %{"operation" => "remove"})
             assert redirected_to(removed, 303) == "/?connections=gemini&gemini=removed"
             assert {:error, :not_found} = GeminiVault.get("unused")
           end) == ""

    refute_receive {:instrumented, _, _}
  end

  test "real CSRF token is required and revoked sessions cannot change credentials", %{conn: conn} do
    conn = conn |> put_private(:plug_skip_csrf_protection, false) |> get("/")

    [csrf] =
      conn
      |> html_response(200)
      |> LazyHTML.from_document()
      |> LazyHTML.query("#owner-lock-form input[name=_csrf_token]")
      |> LazyHTML.attribute("value")

    for token <- [nil, "invalid"] do
      response =
        conn
        |> recycle()
        |> put_private(:plug_skip_csrf_protection, false)
        |> submit(%{"operation" => "save", "api_key" => @key, "_csrf_token" => token})

      assert response.status == 403
      assert response.params == %{}
      assert {:error, :not_found} = GeminiVault.get("unused")
    end

    saved =
      conn
      |> recycle()
      |> put_private(:plug_skip_csrf_protection, false)
      |> submit(%{"operation" => "save", "api_key" => @key, "_csrf_token" => csrf})

    assert redirected_to(saved, 303) =~ "gemini=saved"

    Lovelace.Owner.logout(get_session(saved, :owner_session_token))
    refused = saved |> recycle() |> submit(%{"operation" => "remove"})
    assert redirected_to(refused, 303) == "/unlock"
    assert {:ok, @key} = GeminiVault.get("unused")
  end

  test "invalid keys and vault failures return only safe failure", %{conn: conn} do
    for key <- ["", "bad\nkey", String.duplicate("x", 4097)] do
      response = submit(conn, %{"operation" => "save", "api_key" => key})
      assert redirected_to(response, 303) =~ "gemini=failed"
      refute response.resp_body =~ "bad"
    end

    GeminiVault.fail(:locked)
    response = submit(conn, %{"operation" => "save", "api_key" => @key})
    assert redirected_to(response, 303) =~ "gemini=failed"
  end

  test "early boundary consumes aliases and rejects query credentials, methods, oversized and malformed input" do
    for path <- ["/connections/gemini", "/connections/gemini/", "/connections/%67emini"] do
      conn =
        Plug.Test.conn(:post, path, "operation=save&api_key=synthetic")
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> init_test_session(%{})
        |> put_private(:plug_skip_csrf_protection, true)
        |> GeminiCredentials.call([])

      assert conn.status == 303
      assert get_resp_header(conn, "location") == ["/unlock"]
      assert conn.params == %{}
    end

    for {method, path, body, expected} <- [
          {:get, "/connections/gemini", "", 400},
          {:post, "/connections/gemini?api_key=synthetic", "", 400},
          {:post, "/connections/gemini", String.duplicate("x", 17_000), 400},
          {:post, "/connections/gemini", "api_key[x]=invalid", 303}
        ] do
      conn =
        Plug.Test.conn(method, path, body)
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> init_test_session(%{})
        |> put_private(:plug_skip_csrf_protection, true)
        |> GeminiCredentials.call([])

      assert conn.status == expected
      assert conn.halted
      assert conn.params == %{}
      assert conn.body_params == %{}
      assert conn.query_string == ""
      refute conn.resp_body =~ "synthetic"
    end
  end

  defp submit(conn, params) do
    conn
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> post("/connections/gemini", URI.encode_query(params))
  end
end
