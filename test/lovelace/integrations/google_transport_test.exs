defmodule Lovelace.Integrations.Google.TransportTest do
  use ExUnit.Case, async: false
  alias Lovelace.Integrations.Google.Transport

  defp request(overrides \\ %{}) do
    Map.merge(
      %{
        method: "GET",
        host: "openidconnect.googleapis.com",
        path: "/v1/userinfo",
        headers: [{"authorization", "Bearer fake-only"}],
        body: "",
        timeout_ms: 2_000
      },
      overrides
    )
  end

  test "test build categorically rejects ordinary Google connection" do
    assert {:error, :transport_error} = Transport.request(request())
  end

  test "fixed host/path/method allowlist and request byte limits" do
    for overrides <- [
          %{host: "evil.invalid"},
          %{path: "/unexpected"},
          %{method: "DELETE"},
          %{host: "gmail.googleapis.com", path: "/gmail/v1/users/me/threads/../../messages"},
          %{host: "gmail.googleapis.com", path: "/gmail/v1/users/me/labels/UNREAD"},
          %{host: "gmail.googleapis.com", path: "/gmail/v1/users/me/labels/INBOX?x=1"},
          %{
            host: "gmail.googleapis.com",
            method: "POST",
            path: "/gmail/v1/users/me/labels/INBOX"
          },
          %{host: "oauth2.googleapis.com", method: "POST", path: "/token?secret=x"},
          %{timeout_ms: 0},
          %{body: String.duplicate("x", 64 * 1024 + 1)},
          %{headers: [{"authorization", "fake\r\nInjected: bad"}]},
          %{headers: [{"huge", String.duplicate("x", 16 * 1024)}]}
        ] do
      assert {:error, :invalid_request} = Transport.validate(request(overrides))
    end

    assert :ok =
             Transport.validate(
               request(%{
                 host: "gmail.googleapis.com",
                 path: "/gmail/v1/users/me/threads/abc?format=metadata"
               })
             )
  end

  test "only the fixed INBOX label read is additionally allowed" do
    assert :ok =
             Transport.validate(
               request(%{host: "gmail.googleapis.com", path: "/gmail/v1/users/me/labels/INBOX"})
             )
  end

  test "Calendar allows only bounded GETs to the fixed host and list/events paths" do
    for path <- [
          "/calendar/v3/users/me/calendarList?maxResults=100",
          "/calendar/v3/calendars/primary/events?singleEvents=true",
          "/calendar/v3/calendars/fake%40example.invalid/events?maxResults=100",
          "/calendar/v3/calendars/team%2Bspecial%2F%40group/events"
        ] do
      assert :ok = Transport.validate(request(%{host: "www.googleapis.com", path: path}))
    end

    for overrides <- [
          %{host: "calendar.google.com", path: "/calendar/v3/users/me/calendarList"},
          %{host: "www.googleapis.com.evil.invalid", path: "/calendar/v3/users/me/calendarList"},
          %{
            host: "www.googleapis.com",
            path: "/calendar/v3/users/me/calendarList",
            method: "POST"
          },
          %{host: "www.googleapis.com", path: "/calendar/v3/calendars/primary/events/evt1"},
          %{host: "www.googleapis.com", path: "/calendar/v3/calendars/../events"},
          %{host: "www.googleapis.com", path: "/calendar/v3/calendars/./events"},
          %{host: "www.googleapis.com", path: "/calendar/v3/calendars/primary/acl"},
          %{host: "www.googleapis.com", path: "/calendar/v3/calendars/a/b/events"},
          %{host: "www.googleapis.com", path: "/calendar/v3/calendars/bad%ZZ/events"},
          %{host: "www.googleapis.com", path: "/calendar/v3/users/me/calendarList#fragment"},
          %{
            host: "www.googleapis.com",
            path: "/calendar/v3/users/me/calendarList?" <> String.duplicate("x", 24 * 1024)
          }
        ] do
      assert {:error, :invalid_request} = Transport.validate(request(overrides))
    end
  end

  test "passive private loopback seam exercises Mint without real provider access" do
    port =
      server(fn socket ->
        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"
        )
      end)

    assert {:ok, %{status: 200, body: "{}", headers: headers}} =
             Transport.request_on_loopback(request(), port)

    assert {"content-type", "application/json"} in headers
  end

  test "redirect returned as data, not followed" do
    port =
      server(fn socket ->
        :gen_tcp.send(
          socket,
          "HTTP/1.1 302 Found\r\nLocation: https://evil.invalid/\r\nContent-Length: 0\r\n\r\n"
        )
      end)

    assert {:ok, %{status: 302, body: ""}} = Transport.request_on_loopback(request(), port)
  end

  test "streamed response body capped independently of Content-Length" do
    port =
      server(fn socket ->
        :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n")
        chunk = String.duplicate("x", 64 * 1024)

        Enum.reduce_while(1..161, :ok, fn _, _ ->
          case :gen_tcp.send(socket, ["10000\r\n", chunk, "\r\n"]) do
            :ok -> {:cont, :ok}
            _ -> {:halt, :closed}
          end
        end)

        :gen_tcp.send(socket, "0\r\n\r\n")
      end)

    assert {:error, :response_too_large} =
             Transport.request_on_loopback(request(%{timeout_ms: 5_000}), port)
  end

  test "headers capped including multiple header lines" do
    port =
      server(fn socket ->
        headers =
          Enum.map(1..70, fn n ->
            ["X-", to_string(n), ": ", String.duplicate("x", 1024), "\r\n"]
          end)

        :gen_tcp.send(socket, ["HTTP/1.1 200 OK\r\n", headers, "Content-Length: 0\r\n\r\n"])
      end)

    assert {:error, _safe_atom} = Transport.request_on_loopback(request(), port)
  end

  test "deadline bounds server that never responds" do
    port = server(fn _ -> Process.sleep(100) end)
    assert {:error, reason} = Transport.request_on_loopback(request(%{timeout_ms: 10}), port)
    assert reason in [:timeout, :transport_error]
  end

  defp server(responder) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)

    pid =
      spawn(fn ->
        with {:ok, socket} <- :gen_tcp.accept(listener, 2_000) do
          try do
            :gen_tcp.recv(socket, 0, 2_000)
            responder.(socket)
          after
            :gen_tcp.close(socket)
            :gen_tcp.close(listener)
          end
        end
      end)

    on_exit(fn ->
      Process.exit(pid, :kill)
      :gen_tcp.close(listener)
    end)

    port
  end
end
