defmodule Lovelace.StageDesigner.GeminiTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Lovelace.StageDesigner.{Gemini, Settings}
  alias Lovelace.TestSupport.{JPEG, PNG}

  @key "fake-stage-key-never-a-real-credential"
  @limit 16 * 1024 * 1024

  setup {Req.Test, :verify_on_exit!}

  test "sends the fixed HTTPS REST contract with header-only auth and returns unchanged PNG bytes" do
    bytes = PNG.image()

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.scheme == :https
      assert conn.host == "generativelanguage.googleapis.com"
      assert conn.port == 443
      assert conn.request_path == "/v1beta/models/gemini-nano-banana-2.1:generateContent"
      assert conn.query_string == ""
      assert Plug.Conn.get_req_header(conn, "x-goog-api-key") == [@key]
      assert Plug.Conn.get_req_header(conn, "authorization") == []
      assert Plug.Conn.get_req_header(conn, "accept-encoding") == ["identity"]

      assert conn.body_params == %{
               "contents" => [%{"role" => "user", "parts" => [%{"text" => "Generic art only"}]}],
               "generationConfig" => %{
                 "responseModalities" => ["TEXT", "IMAGE"],
                 "imageConfig" => %{"aspectRatio" => "16:9", "imageSize" => "1K"}
               },
               "store" => false
             }

      Req.Test.json(conn, response([%{"text" => "Accompanying text"}, image_part(bytes)]))
    end)

    assert {:ok, ^bytes} = generate()
  end

  test "accepts declared JPEG and preserves its original encoded metadata bytes" do
    bytes = JPEG.image(8, 8, progressive: true) |> JPEG.with_metadata()

    stub(
      response([%{"inlineData" => %{"mimeType" => "image/jpeg", "data" => Base.encode64(bytes)}}])
    )

    assert {:ok, ^bytes} = generate()
  end

  test "preserves ancillary provenance rather than transcoding" do
    <<signature::binary-size(8), rest::binary>> = PNG.image()
    # Place metadata after IHDR, before IDAT.
    <<ihdr::binary-size(25), tail::binary>> = rest
    bytes = signature <> ihdr <> PNG.chunk("tEXt", "Source\0Original provenance") <> tail
    stub(response([image_part(bytes)]))
    assert {:ok, ^bytes} = generate()
  end

  test "ignores thought images but requires one final image" do
    bytes = PNG.image()
    thought = Map.put(image_part("untrusted thought image"), "thought", true)
    stub(response([thought, image_part(bytes)]))
    assert {:ok, ^bytes} = generate()
    stub(response([thought]))
    assert {:error, :invalid_response} = generate()
  end

  test "handles prompt and candidate refusals without leaking provider text" do
    stub(%{"promptFeedback" => %{"blockReason" => "SAFETY", "message" => @key}})
    assert {:error, :blocked} = generate()

    for reason <- [
          "SAFETY",
          "RECITATION",
          "IMAGE_SAFETY",
          "IMAGE_PROHIBITED_CONTENT",
          "IMAGE_RECITATION"
        ] do
      stub(%{"candidates" => [%{"finishReason" => reason, "finishMessage" => @key}]})
      assert {:error, :blocked} = generate()
    end
  end

  test "rejects missing, malformed and multiple candidates or final images" do
    candidate = hd(response([image_part(PNG.image())])["candidates"])

    for body <- [
          nil,
          [],
          %{},
          %{"candidates" => []},
          %{"candidates" => [nil]},
          %{"candidates" => [candidate, candidate]},
          response([]),
          response([%{"text" => "No image"}]),
          response([image_part(PNG.image()), image_part(PNG.image())]),
          %{"candidates" => [%{"finishReason" => "STOP", "content" => %{"parts" => nil}}]}
        ] do
      stub(body)
      assert {:error, :invalid_response} = generate()
    end

    for reason <- ["MAX_TOKENS", "NO_IMAGE", "IMAGE_OTHER", "OTHER", "FUTURE_UNKNOWN_REASON"] do
      stub(
        put_in(
          response([image_part(PNG.image())]),
          ["candidates", Access.at(0), "finishReason"],
          reason
        )
      )

      assert {:error, :invalid_response} = generate()
    end
  end

  test "rejects unsupported formats, bad base64, MIME mismatches and oversized image bytes" do
    for {part, expected} <- [
          {%{
             "inlineData" => %{
               "mimeType" => "image/jpeg",
               "data" => Base.encode64(<<255, 216, 255>>)
             }
           }, :invalid_image},
          {%{"inlineData" => %{"mimeType" => "image/webp", "data" => "ignored"}},
           :unexpected_webp},
          {%{"inlineData" => %{"mimeType" => @key, "data" => @key}}, :unsupported_image_format},
          {%{"inlineData" => %{"mimeType" => "image/png", "data" => "not!base64"}},
           :invalid_image_encoding},
          {%{"inlineData" => %{"mimeType" => "image/png", "data" => nil}},
           :malformed_image_response},
          {%{"inlineData" => nil}, :malformed_image_response},
          {image_part(<<255, 216, 255>>), :image_mime_mismatch},
          {%{"inlineData" => %{"mimeType" => "image/jpeg", "data" => Base.encode64(PNG.image())}},
           :image_mime_mismatch},
          {image_part("not a PNG"), :invalid_image},
          {image_part(:binary.copy(<<0>>, 10 * 1024 * 1024 + 1)), :image_too_large}
        ] do
      stub(response([part]))
      assert {:error, ^expected} = generate()
    end
  end

  test "500 and redirects each make only one request and do not follow Location" do
    owner = self()

    for status <- [500, 429, 302, 307] do
      ref = make_ref()

      Req.Test.stub(__MODULE__, fn conn ->
        send(owner, {:request, ref})

        conn
        |> Plug.Conn.put_resp_header("location", "https://must-not-follow.invalid/")
        |> Plug.Conn.send_resp(status, @key)
      end)

      assert {:error, {:http_error, ^status, nil}} = generate()
      assert_received {:request, ^ref}
      refute_received {:request, ^ref}
    end
  end

  test "transport failures return atoms and are not retried" do
    owner = self()

    for {reason, error} <- [{:timeout, :timeout}, {:closed, {:transport_error, :closed}}] do
      ref = make_ref()

      Req.Test.stub(__MODULE__, fn conn ->
        send(owner, {:request, ref})
        Req.Test.transport_error(conn, reason)
      end)

      assert {:error, ^error} = generate()
      assert_received {:request, ^ref}
      refute_received {:request, ^ref}
    end
  end

  test "retains HTTP status and allowlisted error codes, never provider messages or metadata" do
    for {status, error, expected} <- [
          {400, %{"status" => "INVALID_ARGUMENT", "message" => @key}, :invalid_argument},
          {401, %{"status" => "UNAUTHENTICATED", "message" => @key}, :unauthenticated},
          {403,
           %{
             "status" => "PERMISSION_DENIED",
             "message" => @key,
             "details" => [
               %{
                 "@type" => "type.googleapis.com/google.rpc.ErrorInfo",
                 "reason" => "BILLING_DISABLED",
                 "metadata" => %{"private" => @key}
               }
             ]
           }, :billing_disabled},
          {404, %{"status" => "NOT_FOUND"}, :not_found},
          {429, %{"status" => "RESOURCE_EXHAUSTED", "message" => @key}, :resource_exhausted},
          {400, %{"status" => @key, "message" => @key, "details" => [%{"reason" => @key}]}, nil},
          {400, %{"status" => "INVALID_ARGUMENT", "details" => @key}, :invalid_argument}
        ] do
      Req.Test.stub(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{"error" => error})
      end)

      assert {:error, {:http_error, ^status, ^expected}} = generate()
    end
  end

  test "identifies local request-option failures without exposing exception text" do
    Req.Test.stub(__MODULE__, fn _conn -> raise ArgumentError, @key end)
    assert {:error, :client_configuration_error} = generate()
  end

  test "identifies safe DNS and TLS failures without exposing transport details" do
    for {reason, expected} <- [
          {:nxdomain, :nxdomain},
          {:econnrefused, :econnrefused},
          {{:tls_alert, {:unknown_ca, @key}}, :tls_error}
        ] do
      Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, reason))
      assert {:error, {:transport_error, ^expected}} = generate()
    end
  end

  test "overall deadline bounds a stuck adapter" do
    Req.Test.stub(__MODULE__, fn conn ->
      Process.sleep(5000)
      Req.Test.json(conn, response([image_part(PNG.image())]))
    end)

    assert {:error, :timeout} = generate(%Settings{timeout_seconds: 1})
  end

  test "exceptions and throws cannot escape or log fake keys" do
    log =
      capture_log(fn ->
        Req.Test.stub(__MODULE__, fn _conn -> raise "provider included #{@key}" end)
        assert {:error, :provider_error} = generate()
        Req.Test.stub(__MODULE__, fn _conn -> throw({:provider, @key}) end)
        assert {:error, :provider_error} = generate()
      end)

    refute log =~ @key
  end

  test "rejects invalid settings, unknown options and blank keys before calling the adapter" do
    Req.Test.stub(__MODULE__, fn _conn -> flunk("must not make a provider request") end)

    for settings <- [
          %Settings{model: "../escape?key=x"},
          %Settings{prompt: ""},
          %Settings{timeout_seconds: 0},
          %Settings{timeout_seconds: 121},
          %Settings{aspect_ratio: "bogus"},
          %Settings{image_size: "1k"},
          nil
        ] do
      assert {:error, :invalid_settings} = generate(settings)
    end

    for key <- [nil, "", "   ", "fake\r\nheader", 42] do
      assert {:error, :missing_api_key} =
               Gemini.generate(%Settings{}, api_key: key, plug: {Req.Test, __MODULE__})
    end

    for {option, value} <- [
          retry: true,
          adapter: Req.Finch,
          url: "http://127.0.0.1/",
          base_url: "http://127.0.0.1/",
          host: "127.0.0.1",
          test_loopback_port: 1234,
          lovelace_test_loopback_port: 1234,
          connect_options: [transport_opts: [verify: :verify_none]]
        ] do
      assert {:error, :invalid_options} =
               Gemini.generate(%Settings{}, [{:api_key, @key}, {option, value}])
    end

    assert {:error, :invalid_options} = Gemini.generate(%Settings{}, %{})
  end

  test "global Req plugins and defaults cannot add instrumentation to the private request" do
    previous = Req.default_options()
    on_exit(fn -> Req.default_options(previous) end)
    owner = self()

    Req.default_options(
      plugins: [
        fn request ->
          send(owner, :unsafe_global_plugin)
          request
        end
      ],
      redirect: true,
      retry: :transient,
      adapter: Req.Finch
    )

    bytes = PNG.image()
    stub(response([image_part(bytes)]))
    assert {:ok, ^bytes} = generate()
    refute_received :unsafe_global_plugin
  end

  test "rejects invalid JSON, wrong content types and unexpected compression" do
    for {type, encoding, body} <- [
          {"application/json", nil, "{"},
          {"text/html", nil, Jason.encode!(response([image_part(PNG.image())]))},
          {"application/json", "gzip", :zlib.gzip("{}")}
        ] do
      Req.Test.stub(__MODULE__, fn conn ->
        conn = Plug.Conn.put_resp_content_type(conn, type)

        conn =
          if encoding,
            do: Plug.Conn.put_resp_header(conn, "content-encoding", encoding),
            else: conn

        Plug.Conn.send_resp(conn, 200, body)
      end)

      assert {:error, :invalid_response} = generate()
    end
  end

  test "accepts JSON at the byte cap and halts a chunked response above it" do
    bytes = PNG.image()
    body = Jason.encode!(response([image_part(bytes)]))
    padding = :binary.copy(" ", @limit - byte_size(body))

    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, [body, padding])
    end)

    assert {:ok, ^bytes} = generate()

    Req.Test.stub(__MODULE__, fn conn ->
      conn =
        conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_chunked(200)

      chunk = :binary.copy(" ", 1024 * 1024)

      conn =
        Enum.reduce(1..16, conn, fn _, acc ->
          {:ok, acc} = Plug.Conn.chunk(acc, chunk)
          acc
        end)

      {:ok, conn} = Plug.Conn.chunk(conn, " ")
      conn
    end)

    assert {:error, :response_too_large} = generate()
  end

  test "caps error bodies too, without trusting content-length" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-length", "1")
      |> Plug.Conn.send_resp(500, :binary.copy("x", @limit + 1))
    end)

    assert {:error, :response_too_large} = generate()
  end

  defp generate(settings \\ %Settings{prompt: "Generic art only"}) do
    Gemini.generate(settings, api_key: @key, plug: {Req.Test, __MODULE__})
  end

  defp stub(body), do: Req.Test.stub(__MODULE__, &Req.Test.json(&1, body))

  defp image_part(bytes) do
    %{"inlineData" => %{"mimeType" => "image/png", "data" => Base.encode64(bytes)}}
  end

  defp response(parts) do
    %{
      "candidates" => [
        %{"finishReason" => "STOP", "content" => %{"role" => "model", "parts" => parts}}
      ]
    }
  end
end
