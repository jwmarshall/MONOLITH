defmodule Monolith.Integrations.Gemini.Transport do
  @moduledoc """
  Private, single-request Req adapter for Gemini, without sensitive instrumentation.

  Transport review (Req 0.7.5, Finch 0.24.0, Mint 1.11.0): Req's supported adapter,
  plug, Finch/pool/connect/request options and Finch's complete option schemas offer
  no telemetry suppression/redaction control (Req.Steps.attach/1, Req.Finch,
  Finch's pool schema/request_opt/build_opt and Finch.Telemetry were inspected).
  Finch request/queue/send/recv events
  include request structs; stop events include response accumulators/headers/errors;
  exception events include reasons and stacktraces. Private metadata and Inspect
  redaction cannot prevent those emissions. Both HTTP/1 and HTTP/2 paths emit them.

  This adapter bypasses Finch entirely. The installed Mint lib tree (HTTP facade,
  HTTP1/HTTP2, proxies, core transports, parsers and errors) contains no telemetry
  calls or telemetry dependency. Its only logging sites are guarded by the
  connection's log flag; we explicitly set log: false and force HTTP/1. We use
  passive, process-owned, unpooled connections, no proxy, redirects or retries.
  Re-audit these properties when upgrading Req/Mint; no dependency source is patched.
  Mint is promoted from Req/Finch's existing transitive dependency to an explicit
  direct dependency (~> 1.11.0), because this adapter owns its API. The locked
  Mint version remains 1.11.0; no new package is introduced.

  Gemini builds a low-level Req.Request without default steps/plugins/options, so
  global Req defaults cannot reintroduce Finch, logging, retries or redirects.
  Req.Plug remains an explicit trusted test injection, not a network fallback.

  The only emitted events are [:monolith, :stage_designer, :transport, phase]:
  start has empty metadata; stop has integer status and :ok outcome; error and
  exception have an allowlisted category only. No span helper is used: even on
  exception/throw/exit there is no reason, stacktrace, request, connection, header,
  prompt, body or result in an event. Timings are numeric. HTTP provider diagnostic
  codes are separately allowlisted by Gemini, never emitted here.

  Production accepts only fixed HTTPS Google Interactions create/get/delete paths,
  with peer and hostname verification, SNI and the system CA store.
  Request/body/header caps, a monotonic overall deadline, socket timeouts and
  the Interactions outer task deadline
  bound work. Body bytes are counted independently of Content-Length, including
  streamed error responses; response headers/trailers are bounded too. Connections
  close on completion, halts, errors and exceptions; task death also closes owned
  sockets. Timeout/unknown outcomes never trigger another request.

  Test builds alone expose an internal loopback seam. It changes only the physical
  connection to 127.0.0.1, never the logical Google URL, and is not available through
  Interactions client options, application settings, environment variables or releases.
  Tests exercise the same send/receive/parser/callback/instrumentation code as
  production without contacting Google. Test builds reject the ordinary production
  connector entirely, so missing fake-plug wiring cannot become a billable request.
  This is not a general-purpose Req adapter.
  """

  @host "generativelanguage.googleapis.com"
  @max_body 16 * 1024 * 1024
  @max_headers 64 * 1024
  @event [:monolith, :stage_designer, :transport]
  @safe_reasons [
    :timeout,
    :nxdomain,
    :econnrefused,
    :econnreset,
    :enetunreach,
    :ehostunreach,
    :closed
  ]

  if Mix.env() == :test do
    @doc false
    def run(%{private: %{monolith_test_loopback_port: port}} = request)
        when is_integer(port) and port in 1..65_535,
        do: run_on_loopback(request, port)
  end

  @doc false
  def run(request), do: instrument(request, &connect/2)

  if Mix.env() == :test do
    @doc false
    def production_connection_options(timeout), do: connection_options(timeout)

    @doc false
    def run_on_loopback_tls(request, port) when is_integer(port) and port in 1..65_535 do
      instrument(request, fn timeout, _request ->
        options = Keyword.put(connection_options(timeout), :hostname, @host)
        Mint.HTTP.connect(:https, {127, 0, 0, 1}, port, options)
      end)
    end

    @doc false
    def run_on_loopback(request, port) when is_integer(port) and port in 1..65_535 do
      instrument(request, fn timeout, _request ->
        Mint.HTTP.connect(:http, {127, 0, 0, 1}, port,
          hostname: @host,
          protocols: [:http1],
          mode: :passive,
          log: false,
          max_header_list_size: @max_headers,
          transport_opts: [timeout: timeout, send_timeout: timeout, send_timeout_close: true]
        )
      end)
    end
  end

  defp instrument(request, connector) do
    start = System.monotonic_time()
    emit(:start, %{system_time: System.system_time()}, %{})

    {result, phase} = guarded_run(request, connector)
    emit_result(result, phase, System.monotonic_time() - start)
    {request, result}
  end

  defp guarded_run(request, connector) do
    {perform(request, connector), :normal}
  rescue
    ArgumentError -> {error(:client_configuration_error), :exception}
    _ -> {error(:provider_error), :exception}
  catch
    _, _ -> {error(:provider_error), :exception}
  end

  defp perform(request, connector) do
    with :ok <- validate_request(request),
         timeout = request.options.receive_timeout,
         deadline = System.monotonic_time(:millisecond) + timeout,
         {:ok, conn} <- connector.(min(timeout, 10_000), request) do
      try do
        send_request(conn, request, deadline)
      after
        Mint.HTTP.close(conn)
      end
    else
      {:error, reason} -> normalize_error(reason)
    end
  end

  defp validate_request(request) do
    valid? =
      valid_url?(request.url) and valid_route?(request.method, request.url.path) and
        valid_body_and_headers?(request) and valid_options?(request)

    if valid?, do: :ok, else: {:error, :client_configuration_error}
  end

  defp valid_url?(url) do
    url.scheme == "https" and url.host == @host and url.port == 443 and
      is_nil(url.userinfo) and is_nil(url.query) and is_nil(url.fragment) and
      is_binary(url.path)
  end

  defp valid_route?(:post, "/v1beta/interactions"), do: true

  defp valid_route?(method, "/v1beta/interactions/" <> id) when method in [:get, :delete],
    do: valid_id?(id)

  defp valid_route?(_, _), do: false

  @doc false
  def valid_id?(id) when is_binary(id) and byte_size(id) in 1..512,
    do: Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, id)

  def valid_id?(_), do: false

  defp valid_body_and_headers?(request) do
    valid_body? =
      case request.method do
        :post -> is_binary(request.body) and byte_size(request.body) <= 64 * 1024
        method when method in [:get, :delete] -> request.body in [nil, ""]
        _ -> false
      end

    valid_body? and header_bytes(Req.get_headers_list(request)) <= 16 * 1024
  end

  defp valid_options?(request) do
    is_function(request.into, 2) and is_integer(request.options[:receive_timeout]) and
      request.options.receive_timeout in 1..120_000
  end

  if Mix.env() == :test do
    # Explicitly enabled regression actions must never gain a live-provider
    # fallback, even if their cooldown or fake-plug wiring regresses.
    defp connect(_timeout, _request), do: {:error, :client_configuration_error}
  else
    defp connect(timeout, _request),
      do: Mint.HTTP.connect(:https, @host, 443, connection_options(timeout))
  end

  defp connection_options(timeout) do
    [
      protocols: [:http1],
      mode: :passive,
      log: false,
      max_header_list_size: @max_headers,
      transport_opts: [
        timeout: timeout,
        send_timeout: timeout,
        send_timeout_close: true,
        verify: :verify_peer,
        server_name_indication: String.to_charlist(@host),
        cacerts: :public_key.cacerts_get(),
        versions: [:"tlsv1.3", :"tlsv1.2"]
      ]
    ]
  end

  defp send_request(conn, request, deadline) do
    case Mint.HTTP.request(
           conn,
           request.method |> Atom.to_string() |> String.upcase(),
           request.url.path,
           Req.get_headers_list(request),
           request.body
         ) do
      {:ok, conn, ref} ->
        receive_response(conn, ref, {request, Req.Response.new()}, {0, 0}, deadline)

      {:error, _conn, reason} ->
        normalize_error(reason)
    end
  end

  defp receive_response(conn, ref, acc, sizes, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      error(:timeout)
    else
      case Mint.HTTP.recv(conn, 0, remaining) do
        {:ok, conn, events} -> consume(events, conn, ref, acc, sizes, deadline)
        {:error, _conn, reason, _events} -> normalize_error(reason)
      end
    end
  end

  defp consume([], conn, ref, acc, sizes, deadline),
    do: receive_response(conn, ref, acc, sizes, deadline)

  defp consume([{:done, ref} | _], _conn, ref, {_request, response}, _sizes, _deadline),
    do: response

  defp consume([{:status, ref, status} | events], conn, ref, {request, response}, sizes, deadline) do
    # Informational responses share the request ref with the final response.
    # Reset header-block state, but retain aggregate byte counts across every block.
    empty = Req.Response.new()

    response = %{
      response
      | status: status,
        headers: empty.headers,
        trailers: empty.trailers,
        private: Map.delete(response.private, :monolith_headers_received)
    }

    consume(events, conn, ref, {request, response}, sizes, deadline)
  end

  defp consume([{:headers, ref, headers} | events], conn, ref, acc, {body, size}, deadline) do
    size = size + header_bytes(headers)

    if size > @max_headers do
      error(:transport_error)
    else
      {request, response} = acc

      response =
        if response.private[:monolith_headers_received] do
          %{response | trailers: Req.Response.new(headers: headers).headers}
        else
          response = %{response | headers: Req.Response.new(headers: headers).headers}
          put_in(response.private[:monolith_headers_received], true)
        end

      consume(events, conn, ref, {request, response}, {body, size}, deadline)
    end
  end

  defp consume(
         [{:data, ref, chunk} | events],
         conn,
         ref,
         {request, response},
         {body, headers},
         deadline
       ) do
    body = body + byte_size(chunk)

    if body > @max_body do
      error(:response_too_large)
    else
      case request.into.({:data, chunk}, {request, response}) do
        {:cont, acc} -> consume(events, conn, ref, acc, {body, headers}, deadline)
        {:halt, {_request, response}} -> response
      end
    end
  end

  defp header_bytes(headers),
    do:
      Enum.reduce(headers, 0, fn {name, value}, size ->
        size + byte_size(name) + byte_size(value)
      end)

  defp normalize_error(%Mint.TransportError{reason: reason}), do: normalize_error(reason)
  defp normalize_error(reason) when reason in @safe_reasons, do: error(reason)
  defp normalize_error({:tls_alert, _}), do: error(:tls_error)
  defp normalize_error(:client_configuration_error), do: error(:client_configuration_error)
  defp normalize_error(_), do: error(:transport_error)

  defp error(reason), do: %Req.TransportError{reason: reason}

  defp emit_result(%Req.Response{status: status}, _phase, duration)
       when is_integer(status) and status in 100..599,
       do: emit(:stop, %{duration: duration}, %{status: status, outcome: :ok})

  defp emit_result(%Req.Response{}, _phase, duration),
    do: emit(:error, %{duration: duration}, %{category: :invalid_response})

  defp emit_result(%Req.TransportError{reason: reason}, phase, duration) do
    # Enforce containment at emission too, even if a trusted into callback
    # returns a transport-error struct instead of its normal response accumulator.
    category = safe_category(reason)
    event = if phase == :exception, do: :exception, else: :error
    emit(event, %{duration: duration}, %{category: category})
  end

  defp safe_category(reason) when reason in @safe_reasons, do: reason

  defp safe_category(reason)
       when reason in [
              :tls_error,
              :client_configuration_error,
              :provider_error,
              :transport_error,
              :response_too_large
            ],
       do: reason

  defp safe_category(_), do: :transport_error

  defp emit(phase, measurements, metadata),
    do: :telemetry.execute(@event ++ [phase], measurements, metadata)
end
