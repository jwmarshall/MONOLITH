defmodule Lovelace.StageDesigner.GeminiTransportTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Lovelace.StageDesigner.{Gemini, GeminiTransport, Settings}
  alias Lovelace.TestSupport.PNG

  @key "synthetic-transport-key-MUST-NOT-EMIT"
  @prompt "synthetic-private-prompt-MUST-NOT-EMIT"
  @provider "synthetic-provider-payload-MUST-NOT-EMIT"
  @prefix [:lovelace, :stage_designer, :transport]
  @limit 16 * 1024 * 1024

  setup do
    # Cover every installed Finch emission, including non-span events, plus the
    # conventional Req/Mint names (neither currently emits these). Any return to
    # Finch fails on its FIRST credential-bearing event, not just a log warning.
    spans =
      for name <- [:finch, :req, :mint],
          operation <- [:request, :queue, :connect, :send, :recv, :stream],
          phase <- [:start, :stop, :error, :exception],
          do: [name, operation, phase]

    events =
      spans ++
        Enum.map(
          [:reused_connection, :conn_max_idle_time_exceeded, :pool_max_idle_time_exceeded],
          &[:finch, &1]
        ) ++ Enum.map([:start, :stop, :error, :exception], &(@prefix ++ [&1]))

    id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach_many(id, events, &__MODULE__.handle_event/4, self())
    on_exit(fn -> :telemetry.detach(id) end)
    :ok
  end

  def handle_event(event, measurements, metadata, owner),
    do: send(owner, {:transport_event, event, measurements, metadata})

  test "test builds reject an ordinary production connector without a fake plug" do
    assert {_, %Req.TransportError{reason: :client_configuration_error}} =
             GeminiTransport.run(request())

    assert_events(:error, %{category: :client_configuration_error})

    assert {:error, :client_configuration_error} =
             Gemini.generate(%Settings{prompt: @prompt}, api_key: @key)

    assert_events(:error, %{category: :client_configuration_error})
  end

  test "actual chunked Mint success contains request, headers, image JSON and trailers, not events" do
    bytes = PNG.image()

    body =
      Jason.encode!(%{
        "candidates" => [
          %{
            "finishReason" => "STOP",
            "content" => %{
              "parts" => [
                %{"text" => @provider},
                %{"inlineData" => %{"mimeType" => "image/png", "data" => Base.encode64(bytes)}}
              ]
            }
          }
        ]
      })

    {port, server} =
      server(fn socket ->
        send_headers(socket, 200, "transfer-encoding: chunked\r\nx-private: #{@key}\r\n")
        # Distinct HTTP chunks exercise repeated into callbacks even if TCP coalesces.
        for chunk <- [binary_part(body, 0, 10), binary_part(body, 10, byte_size(body) - 10)] do
          send_chunk(socket, chunk)
        end

        :gen_tcp.send(socket, "0\r\nx-private-trailer: #{@prompt}\r\n\r\n")
      end)

    assert {:ok, ^bytes} =
             Gemini.generate_on_loopback(%Settings{prompt: @prompt}, [api_key: @key], port)

    assert_receive {:wire_request, ^server, wire}
    assert wire =~ "POST /v1beta/models/gemini-nano-banana-2.1:generateContent HTTP/1.1"
    assert wire =~ "x-goog-api-key: #{@key}"
    assert wire =~ @prompt
    assert_receive {:server_done, ^server}
    assert_events(:stop, %{status: 200, outcome: :ok})
  end

  test "informational responses do not replace final headers with trailers" do
    bytes = PNG.image()

    body =
      Jason.encode!(%{
        "candidates" => [
          %{
            "finishReason" => "STOP",
            "content" => %{
              "parts" => [
                %{"inlineData" => %{"mimeType" => "image/png", "data" => Base.encode64(bytes)}}
              ]
            }
          }
        ]
      })

    for statuses <- [[100], [103], [100, 103]] do
      {port, server} =
        server(fn socket ->
          for status <- statuses do
            :gen_tcp.send(
              socket,
              "HTTP/1.1 #{status} Synthetic\r\ncontent-type: text/plain\r\nx-private: #{@key}\r\n\r\n"
            )
          end

          send_headers(socket, 200, "transfer-encoding: chunked\r\nx-private: #{@provider}\r\n")
          send_chunk(socket, binary_part(body, 0, 10))
          send_chunk(socket, binary_part(body, 10, byte_size(body) - 10))

          :gen_tcp.send(
            socket,
            "0\r\ncontent-type: text/plain\r\nx-private-trailer: #{@prompt}\r\n\r\n"
          )
        end)

      assert {:ok, ^bytes} =
               Gemini.generate_on_loopback(%Settings{prompt: @prompt}, [api_key: @key], port)

      assert_receive {:server_done, ^server}
      assert_events(:stop, %{status: 200, outcome: :ok})
    end
  end

  test "aggregate header cap includes every informational, final and trailer block" do
    {port, server} =
      server(fn socket ->
        padding = :binary.copy("x", 20 * 1024)

        for status <- [100, 103] do
          :gen_tcp.send(
            socket,
            "HTTP/1.1 #{status} Synthetic\r\nx-private: #{@key}#{padding}\r\n\r\n"
          )
        end

        send_headers(
          socket,
          200,
          "transfer-encoding: chunked\r\nx-private: #{@provider}#{padding}\r\n"
        )

        send_chunk(socket, @provider)

        :gen_tcp.send(
          socket,
          "0\r\nx-private-trailer: #{@prompt}#{:binary.copy("x", 5 * 1024)}\r\n\r\n"
        )
      end)

    assert {_, %Req.TransportError{reason: :transport_error}} = run(port)
    assert_receive {:server_done, ^server}
    assert_events(:error, %{category: :transport_error})
  end

  test "real HTTP errors retain only allowlisted diagnostics; redirects and failures are not retried" do
    for {status, code, expected} <- [
          {429, "RESOURCE_EXHAUSTED", :resource_exhausted},
          {403, "PERMISSION_DENIED", :billing_disabled},
          {500, @key, nil},
          {302, @provider, nil},
          {307, @prompt, nil}
        ] do
      body =
        Jason.encode!(%{
          "error" => %{
            "status" => code,
            "message" => @provider,
            "details" => [
              %{
                "@type" => "type.googleapis.com/google.rpc.ErrorInfo",
                "reason" => if(status == 403, do: "BILLING_DISABLED", else: @key),
                "metadata" => %{"private" => @prompt}
              }
            ]
          }
        })

      {port, server} =
        server(fn socket ->
          send_headers(
            socket,
            status,
            "content-length: #{byte_size(body)}\r\nlocation: https://must-not-follow.invalid/\r\n"
          )

          :gen_tcp.send(socket, body)
        end)

      assert {:error, {:http_error, ^status, ^expected}} =
               Gemini.generate_on_loopback(
                 %Settings{prompt: @prompt, timeout_seconds: 1},
                 [api_key: @key],
                 port
               )

      assert_receive {:wire_request, ^server, _}
      assert_receive {:server_done, ^server}
      assert_events(:stop, %{status: status, outcome: :ok})
      refute_received {:wire_request, ^server, _}
    end
  end

  test "malformed protocol errors containing private data are normalized before instrumentation" do
    log =
      capture_log(fn ->
        {port, server} =
          server(fn socket ->
            :gen_tcp.send(socket, "HTTP/1.1 #{@key} #{@provider}\r\n#{@prompt}\r\n\r\n")
          end)

        assert {_request, %Req.TransportError{reason: :transport_error}} = run(port)
        assert_receive {:server_done, ^server}
        assert_events(:error, %{category: :transport_error})
      end)

    assert_clean(log)
  end

  test "a truncated streamed error response cannot emit its partial body or raw error" do
    {port, server} =
      server(fn socket ->
        send_headers(socket, 500, "content-length: 10000\r\n")
        :gen_tcp.send(socket, @provider <> @key <> @prompt)
      end)

    assert {_request, %Req.TransportError{reason: :closed}} = run(port)
    assert_receive {:server_done, ^server}
    assert_events(:error, %{category: :closed})
  end

  test "a continuously arriving stream cannot renew the overall transport deadline" do
    {port, server} =
      server(fn socket ->
        send_headers(socket, 200, "transfer-encoding: chunked\r\n")
        drip(socket)
      end)

    start = System.monotonic_time(:millisecond)
    assert {_request, %Req.TransportError{reason: :timeout}} = run(port, timeout: 100)
    assert System.monotonic_time(:millisecond) - start < 1000
    assert_events(:error, %{category: :timeout})
    assert_receive {:server_done, ^server}, 1000
  end

  test "callback exceptions, throws and exits never emit reasons, stacktraces or task crash logs" do
    log =
      capture_log(fn ->
        for {failure, expected} <- [
              {fn data -> raise ArgumentError, @key <> @prompt <> data end,
               :client_configuration_error},
              {fn data -> raise @key <> @prompt <> data end, :provider_error},
              {fn data -> throw({@key, @prompt, data}) end, :provider_error},
              {fn data -> exit({@key, @prompt, data}) end, :provider_error}
            ] do
          {port, server} =
            server(fn socket ->
              send_headers(socket, 200, "content-length: #{byte_size(@provider)}\r\n")
              :gen_tcp.send(socket, @provider)
              # Client must close even when its stream callback fails.
              assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1000)
            end)

          callback = fn {:data, data}, _acc -> failure.(data) end
          assert {_request, %Req.TransportError{reason: ^expected}} = run(port, into: callback)
          assert_events(:exception, %{category: expected})
          assert_receive {:server_done, ^server}
        end
      end)

    assert_clean(log)
  end

  test "early stream halt closes the connection without exposing its accumulator" do
    {port, server} =
      server(fn socket ->
        send_headers(socket, 200, "transfer-encoding: chunked\r\n")
        send_chunk(socket, @provider)
        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1000)
      end)

    callback = fn {:data, data}, {request, response} ->
      {:halt, {request, put_in(response.private[:secret_accumulator], {@key, @prompt, data})}}
    end

    assert {_, %Req.Response{private: %{secret_accumulator: {@key, @prompt, @provider}}}} =
             run(port, into: callback)

    assert_events(:stop, %{status: 200, outcome: :ok})
    assert_receive {:server_done, ^server}
  end

  test "callback-returned transport errors cannot introduce unsafe telemetry categories" do
    {port, server} =
      server(fn socket ->
        send_headers(socket, 200, "content-length: #{byte_size(@provider)}\r\n")
        :gen_tcp.send(socket, @provider)
      end)

    callback = fn {:data, data}, {request, _response} ->
      {:halt, {request, %Req.TransportError{reason: {@key, @prompt, data}}}}
    end

    assert {_, %Req.TransportError{}} = run(port, into: callback)
    assert_events(:error, %{category: :transport_error})
    assert_receive {:server_done, ^server}
  end

  test "even callback-modified response metadata is never copied into telemetry" do
    {port, server} =
      server(fn socket ->
        send_headers(socket, 200, "content-length: #{byte_size(@provider)}\r\n")
        :gen_tcp.send(socket, @provider)
      end)

    callback = fn {:data, data}, {request, response} ->
      {:cont, {request, %{response | status: {@key, @prompt, data}}}}
    end

    assert {_, %Req.Response{}} = run(port, into: callback)
    assert_events(:error, %{category: :invalid_response})
    assert_receive {:server_done, ^server}
  end

  test "actual streaming counts body bytes at the cap, including error responses" do
    for extra <- [0, 1] do
      {port, server} =
        server(fn socket ->
          send_headers(socket, 500, "transfer-encoding: chunked\r\n")
          chunk = :binary.copy("x", 1024 * 1024)
          for _ <- 1..16, do: send_chunk(socket, chunk)
          if extra == 1, do: send_chunk(socket, "x")
          :gen_tcp.send(socket, "0\r\n\r\n")
        end)

      callback = fn {:data, data}, {request, response} ->
        count = Map.get(response.private, :count, 0) + byte_size(data)
        {:cont, {request, put_in(response.private[:count], count)}}
      end

      result = run(port, into: callback)

      if extra == 0 do
        assert {_, %Req.Response{status: 500, private: %{count: @limit}}} = result
        assert_events(:stop, %{status: 500, outcome: :ok})
      else
        assert {_, %Req.TransportError{reason: :response_too_large}} = result
        assert_events(:error, %{category: :response_too_large})
      end

      assert_receive {:server_done, ^server}, 1000
    end
  end

  test "oversized response headers and aggregate trailers fail safely" do
    for headers <- [
          "x-private: #{@key}#{:binary.copy("x", 64 * 1024)}\r\n",
          "transfer-encoding: chunked\r\nx-private: #{@key}#{:binary.copy("x", 33 * 1024)}\r\n"
        ] do
      {port, server} =
        server(fn socket ->
          send_headers(socket, 200, headers)

          :gen_tcp.send(
            socket,
            "0\r\nx-private: #{@provider}#{:binary.copy("x", 33 * 1024)}\r\n\r\n"
          )
        end)

      assert {_, %Req.TransportError{reason: :transport_error}} = run(port)
      assert_events(:error, %{category: :transport_error})
      assert_receive {:server_done, ^server}
    end
  end

  test "fixed production policy verifies TLS; invalid destinations and oversized requests never connect" do
    options = GeminiTransport.production_connection_options(100)
    assert options[:protocols] == [:http1]
    assert options[:mode] == :passive
    assert options[:log] == false
    assert options[:transport_opts][:verify] == :verify_peer

    assert options[:transport_opts][:server_name_indication] ==
             ~c"generativelanguage.googleapis.com"

    assert [_ | _] = options[:transport_opts][:cacerts]
    assert options[:transport_opts][:versions] == [:"tlsv1.3", :"tlsv1.2"]
    refute Keyword.has_key?(options, :proxy)

    for url <- [
          "http://generativelanguage.googleapis.com/v1beta/models/model:generateContent",
          "https://attacker.invalid/v1beta/models/model:generateContent",
          "https://generativelanguage.googleapis.com:8443/v1beta/models/model:generateContent",
          "https://generativelanguage.googleapis.com/v1beta/models/model:generateContent?key=x"
        ] do
      request = %{request() | url: URI.parse(url)}

      assert {_, %Req.TransportError{reason: :client_configuration_error}} =
               GeminiTransport.run(request)

      assert_events(:error, %{category: :client_configuration_error})
    end

    assert {_, %Req.TransportError{reason: :client_configuration_error}} =
             GeminiTransport.run(%{request() | body: :binary.copy("x", 64 * 1024 + 1)})

    assert_events(:error, %{category: :client_configuration_error})
  end

  test "the real TLS connector rejects an untrusted local certificate before sending credentials" do
    cert =
      :public_key.pkix_test_data(%{
        root: [key: {:rsa, 2048, 65_537}],
        intermediates: [],
        peer: [key: {:rsa, 2048, 65_537}]
      })

    {:ok, listen} =
      :ssl.listen(
        0,
        [:binary, active: false, ip: {127, 0, 0, 1}, cert: cert[:cert], key: cert[:key]]
      )

    {:ok, {_, port}} = :ssl.sockname(listen)
    owner = self()

    pid =
      spawn_link(fn ->
        {:ok, socket} = :ssl.transport_accept(listen, 2000)
        result = :ssl.handshake(socket, 2000)
        send(owner, {:tls_rejected, match?({:error, _}, result)})
        :ssl.close(socket)
      end)

    on_exit(fn ->
      :ssl.close(listen)
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    log =
      capture_log(fn ->
        assert {_, %Req.TransportError{reason: :tls_error}} =
                 GeminiTransport.run_on_loopback_tls(request(), port)

        assert_receive {:tls_rejected, true}
        assert_events(:error, %{category: :tls_error})
      end)

    assert_clean(log)
  end

  defp request(opts \\ []) do
    request =
      Req.Request.new(
        method: :post,
        url: "https://generativelanguage.googleapis.com/v1beta/models/model:generateContent",
        headers: [{"x-goog-api-key", @key}, {"content-type", "application/json"}],
        body: Jason.encode!(%{prompt: @prompt}),
        options: [receive_timeout: Keyword.get(opts, :timeout, 2000)],
        adapter: GeminiTransport
      )

    callback = fn {:data, _chunk}, acc -> {:cont, acc} end
    %{request | into: Keyword.get(opts, :into, callback)}
  end

  defp run(port, opts \\ []), do: GeminiTransport.run_on_loopback(request(opts), port)

  defp server(fun) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_ip, port}} = :inet.sockname(listen)
    owner = self()

    pid =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen, 2000)
        wire = read_request(socket, "")
        send(owner, {:wire_request, self(), wire})
        fun.(socket)
        :gen_tcp.close(socket)
        send(owner, {:server_done, self()})
      end)

    on_exit(fn ->
      :gen_tcp.close(listen)
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    {port, pid}
  end

  defp read_request(socket, acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [headers, body] ->
        [_, size] = Regex.run(~r/content-length: (\d+)/i, headers)

        if byte_size(body) >= String.to_integer(size) do
          acc
        else
          {:ok, data} = :gen_tcp.recv(socket, 0, 2000)
          read_request(socket, acc <> data)
        end

      _ ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 2000)
        read_request(socket, acc <> data)
    end
  end

  defp send_headers(socket, status, headers),
    do:
      :gen_tcp.send(
        socket,
        "HTTP/1.1 #{status} Synthetic\r\ncontent-type: application/json\r\n" <> headers <> "\r\n"
      )

  defp send_chunk(socket, chunk),
    do: :gen_tcp.send(socket, [Integer.to_string(byte_size(chunk), 16), "\r\n", chunk, "\r\n"])

  defp drip(socket) do
    receive do
      :stop -> :ok
    after
      10 ->
        case send_chunk(socket, @provider) do
          :ok -> drip(socket)
          {:error, _} -> :ok
        end
    end
  end

  defp assert_events(phase, expected) do
    assert_receive {:transport_event, start, %{system_time: system_time}, %{}}
    assert start == @prefix ++ [:start]
    assert is_integer(system_time)
    assert_receive {:transport_event, event, %{duration: duration}, metadata}
    assert event == @prefix ++ [phase]
    assert is_integer(duration) and duration >= 0
    # Exact shapes reject ANY raw struct, binary, header, accumulator, exception
    # or stacktrace, not merely values that happen to match our sentinels.
    assert metadata == expected
    assert_clean(:erlang.term_to_binary({start, event, metadata}))
    refute_received {:transport_event, _, _, _}
  end

  defp assert_clean(data) do
    for sentinel <- [@key, @prompt, @provider], do: refute(data =~ sentinel)
  end
end
