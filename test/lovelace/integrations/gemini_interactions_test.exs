defmodule Lovelace.Integrations.GeminiInteractionsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Lovelace.Integrations.Gemini.{Interactions, Transport}
  alias Lovelace.TestSupport.{JPEG, PNG}

  @key "synthetic-interactions-key-NEVER-LOG"
  @prompt "synthetic-interactions-prompt-NEVER-LOG"
  @private "synthetic-provider-diagnostics-NEVER-LOG"
  @id "v1_Abcd-Efg123"
  @request %{model: "gemini-nano-banana-2.1", input: @prompt}
  @prefix [:lovelace, :stage_designer, :transport]

  defmodule Vault do
    def get(_account) do
      send(self(), :vault_read)
      Process.get(:interactions_test_key, {:error, :not_found})
    end
  end

  setup {Req.Test, :verify_on_exit!}

  test "create uses real REST steps, header auth, revision, explicit privacy defaults and no Req defaults" do
    previous = Application.fetch_env(:req, :default_options)

    Application.put_env(:req, :default_options,
      retry: :transient,
      base_url: "https://invalid.invalid",
      redirect: true,
      headers: [{"x-unwanted", @private}]
    )

    on_exit(fn -> restore(:req, :default_options, previous) end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.scheme == :https
      assert conn.host == "generativelanguage.googleapis.com"
      assert conn.port == 443
      assert conn.request_path == "/v1beta/interactions"
      assert conn.query_string == ""
      assert Plug.Conn.get_req_header(conn, "x-goog-api-key") == [@key]
      assert Plug.Conn.get_req_header(conn, "api-revision") == ["2026-05-20"]
      assert Plug.Conn.get_req_header(conn, "accept-encoding") == ["identity"]
      assert Plug.Conn.get_req_header(conn, "x-unwanted") == []

      assert conn.body_params == %{
               "model" => @request.model,
               "input" => @prompt,
               "background" => false,
               "store" => false
             }

      Req.Test.json(conn, interaction([text("Hello"), text(" world")]))
    end)

    assert {:ok, %{id: @id, status: :completed, text: "Hello world", images: [], error: nil}} =
             create()
  end

  test "accepts a single REST text block or a text-block list" do
    for input <- [%{type: "text", text: "Hello"}, [%{type: "text", text: "Hello"}]] do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.body_params["input"] == Jason.decode!(Jason.encode!(input))
        Req.Test.json(conn, interaction([text("ok")]))
      end)

      assert {:ok, %{status: :completed}} = create(Map.put(@request, :input, input))
    end
  end

  test "background/storage are explicit, and documented chat steps/config/formats pass unchanged" do
    input = [
      %{type: "user_input", content: [%{type: "text", text: "Hello"}]},
      %{type: "model_output", content: [%{type: "text", text: "Hi"}]},
      %{type: "user_input", content: [%{type: "text", text: "Paint a landscape"}]}
    ]

    format = [
      %{type: "text"},
      %{
        type: "image",
        mime_type: "image/jpeg",
        delivery: "inline",
        aspect_ratio: "16:9",
        image_size: "1K"
      }
    ]

    config = %{
      max_output_tokens: 1024,
      seed: 10,
      temperature: 0.5,
      top_p: 0.9,
      top_k: 40,
      thinking_level: "low",
      thinking_summaries: "none"
    }

    request =
      Map.merge(@request, %{
        input: input,
        background: true,
        store: true,
        previous_interaction_id: @id,
        response_format: format,
        generation_config: config
      })

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.body_params == Jason.decode!(Jason.encode!(request))
      Req.Test.json(conn, %{"id" => @id, "status" => "in_progress"})
    end)

    assert {:ok, %{status: :in_progress, text: "", images: [], error: nil}} = create(request)

    assert {:error, :invalid_request} = create(Map.put(@request, :background, true))

    assert {:error, :invalid_request} =
             create(Map.merge(@request, %{background: true, store: false}))

    for flags <- [%{store: true}, %{background: false, store: false}] do
      request = Map.merge(@request, flags)

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.body_params["store"] == flags.store
        assert conn.body_params["background"] == false
        Req.Test.json(conn, interaction([text("ok")]))
      end)

      assert {:ok, _} = create(request)
    end
  end

  test "validates original PNG and JPEG model_output data, not SDK output_image or retrieved inputs/thoughts" do
    png = PNG.image()
    jpeg = JPEG.image(8, 8, progressive: true) |> JPEG.with_metadata()
    response = interaction([text("Scene"), image(png, "image/png"), image(jpeg, "image/jpeg")])

    response =
      Map.update!(response, "steps", fn steps ->
        [
          %{"type" => "user_input", "content" => [text(@prompt)]},
          %{"type" => "thought", "summary" => [image("invalid", "image/png")]} | steps
        ]
      end)

    stub(Map.put(response, "output_image", %{"data" => @private}))
    assert {:ok, %{text: "Scene", images: [^png, ^jpeg]}} = create()

    stub(%{"id" => @id, "status" => "completed", "output_image" => image(png, "image/png")})
    assert {:error, :invalid_response} = create()
  end

  test "GET extracts only model output from full stored steps, and DELETE accepts empty 204/200" do
    response =
      interaction([text("Only output")])
      |> Map.update!("steps", &[%{"type" => "user_input", "content" => [text(@prompt)]} | &1])

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1beta/interactions/#{@id}"
      assert conn.query_string == ""
      assert conn.body_params == %{}
      Req.Test.json(conn, response)
    end)

    assert {:ok, %{id: @id, text: "Only output"}} = Interactions.get(@id, opts())

    for status <- [204, 200] do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/v1beta/interactions/#{@id}"
        assert conn.body_params == %{}
        Plug.Conn.send_resp(conn, status, "")
      end)

      assert :ok = Interactions.delete(@id, opts())
    end

    stub(Map.put(response, "id", "another_id"))
    assert {:error, :invalid_response} = Interactions.get(@id, opts())
    stub(%{"error" => %{"status" => "NOT_FOUND", "message" => @private}}, 404)
    assert {:error, {:http_error, 404, :not_found}} = Interactions.get(@id, opts())
  end

  test "recovery DELETE treats already deleted 404 as idempotent success, but preserves other failures" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "DELETE"
      Plug.Conn.send_resp(conn, 204, "")
    end)

    assert :ok = Interactions.delete(@id, opts())

    # Repeat cleanup as recovery would after losing the successful response.
    stub(%{"error" => %{"status" => "NOT_FOUND", "message" => @private}}, 404)
    assert :ok = Interactions.delete(@id, opts())

    stub(%{"error" => %{"status" => "PERMISSION_DENIED", "message" => @private}}, 403)
    assert {:error, {:http_error, 403, :permission_denied}} = Interactions.delete(@id, opts())
  end

  test "only allowlisted statuses and sanitized provider errors escape" do
    for {status, expected} <- [
          {"in_progress", :in_progress},
          {"completed", :completed},
          {"failed", :failed},
          {"cancelled", :cancelled},
          {"incomplete", :incomplete},
          {"requires_action", :requires_action},
          {"requires_continuation", :requires_continuation}
        ] do
      stub(Map.put(interaction([text("ok")]), "status", status))
      assert {:ok, %{status: ^expected}} = create()
    end

    stub(Map.put(interaction([text("ok")]), "status", @private))
    assert {:error, :invalid_response} = create()

    for {code, expected} <- [
          {"RESOURCE_EXHAUSTED", :resource_exhausted},
          {@private, :provider_error}
        ] do
      stub(%{
        "id" => @id,
        "status" => "failed",
        "errors" => [%{"code" => code, "message" => @private}]
      })

      assert {:ok, %{status: :failed, error: ^expected}} = create()
    end
  end

  test "malicious identifiers, models, unsupported features, remote references and invalid config never reach HTTP" do
    Req.Test.stub(__MODULE__, fn _ -> flunk("invalid requests must not reach HTTP") end)

    for id <- [
          "",
          "../x",
          "a/b",
          "a%2Fb",
          "a?key=x",
          "a#x",
          "a\\x",
          "a.b",
          "a\r\nx: y",
          "https://evil.invalid",
          String.duplicate("a", 513),
          nil,
          12,
          "é"
        ] do
      assert {:error, :invalid_id} = Interactions.get(id, opts())
      assert {:error, :invalid_id} = Interactions.delete(id, opts())
      assert {:error, :invalid_request} = create(Map.put(@request, :previous_interaction_id, id))
    end

    invalid = [
      %{},
      %{"model" => "gemini", "input" => "hi"},
      Map.put(@request, :model, "model:generateContent?key=x"),
      Map.put(@request, :tools, []),
      Map.put(@request, :stream, true),
      Map.put(@request, :agent, "agent"),
      Map.put(@request, :input, [%{type: "image", uri: "https://evil.invalid/image"}]),
      Map.put(@request, :input, [%{type: "text", text: "hello", uri: "https://evil.invalid"}]),
      Map.put(@request, :input, [%{type: "function_call", content: []}]),
      Map.put(@request, :input, String.duplicate("x", 8001)),
      Map.put(@request, :input, [%{type: "text", text: <<255>>}]),
      Map.put(@request, :input, List.duplicate(%{type: "text", text: "x"}, 33)),
      Map.put(
        @request,
        :input,
        List.duplicate(%{type: "text", text: String.duplicate("x", 8000)}, 5)
      ),
      Map.put(@request, :response_format, %{type: "image", delivery: "uri"}),
      Map.put(@request, :response_format, %{type: "image", image_size: "unlimited"}),
      Map.put(@request, :response_format, %{type: "text", schema: %{}}),
      Map.put(@request, :generation_config, %{temperature: "hot"}),
      Map.put(@request, :generation_config, %{max_output_tokens: 0}),
      Map.put(@request, :generation_config, %{seed: %{secret: @private}}),
      Map.put(@request, :generation_config, %{tool_choice: "auto"}),
      Map.put(@request, :store, "true")
    ]

    for request <- invalid, do: assert({:error, :invalid_request} = create(request))

    for timeout <- [0, 121, 1.5, "10", nil] do
      assert {:error, :invalid_options} =
               Interactions.create(@request, opts(timeout_seconds: timeout))
    end

    assert {:error, :invalid_options} =
             Interactions.create(@request, opts(url: "http://evil.invalid"))

    assert {:error, :invalid_options} = Interactions.get(@id, :not_a_keyword)
    # JSON escaping may expand otherwise bounded valid text beyond the wire cap.
    input = List.duplicate(%{type: "text", text: String.duplicate("\u0001", 8000)}, 4)
    assert {:error, :request_too_large} = create(Map.put(@request, :input, input))
  end

  test "rejects malformed, remote, mismatched, oversized and excessive image outputs" do
    png = PNG.image()

    for {block, reason} <- [
          {%{"type" => "image", "uri" => "http://127.0.0.1/private"}, :unsupported_image_source},
          {image(png, "image/webp"), :unsupported_image_format},
          {image(png, "image/jpeg"), :image_mime_mismatch},
          {%{"type" => "image", "mime_type" => "image/png", "data" => "%not-base64"},
           :invalid_image_encoding},
          {image("not an image", "image/png"), :invalid_image},
          {image(binary_part(png, 0, byte_size(png) - 1), "image/png"), :invalid_image},
          {%{"type" => "image", "mime_type" => "image/png", "data" => nil},
           :malformed_image_response},
          {image(String.duplicate("x", 10 * 1024 * 1024 + 1), "image/png"), :image_too_large}
        ] do
      stub(interaction([block]))
      assert {:error, ^reason} = create()
    end

    stub(interaction(List.duplicate(image(png, "image/png"), 5)))
    assert {:error, :response_too_large} = create()
    stub(interaction([text(String.duplicate("x", 32 * 1024 + 1))]))
    assert {:error, :response_too_large} = create()
  end

  test "bounded HTTP/encoding failures expose only legacy allowlisted diagnostics and never retry" do
    for {status, code} <- [
          {429, :resource_exhausted},
          {403, :billing_disabled},
          {500, nil},
          {307, nil}
        ] do
      reason = if status == 403, do: "BILLING_DISABLED", else: @private
      provider_status = if status == 429, do: "RESOURCE_EXHAUSTED", else: @private

      stub(
        %{
          "error" => %{
            "status" => provider_status,
            "message" => @private,
            "details" => [
              %{
                "@type" => "type.googleapis.com/google.rpc.ErrorInfo",
                "reason" => reason,
                "metadata" => %{"private" => @key}
              }
            ]
          }
        },
        status
      )

      assert {:error, {:http_error, ^status, ^code}} = create()
    end

    for {type, encoding, body, reason} <- [
          {"text/html", "identity", @private, :invalid_response},
          {"application/json", "gzip", @private, :invalid_response},
          {"application/json", "identity", @private, :invalid_response},
          {"application/json", "identity", String.duplicate("x", 16 * 1024 * 1024 + 1),
           :response_too_large}
        ] do
      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", type)
        |> Plug.Conn.put_resp_header("content-encoding", encoding)
        |> Plug.Conn.send_resp(200, body)
      end)

      assert {:error, ^reason} = create()
    end
  end

  test "task exceptions/throws/exits cannot log keys, prompts or raw provider data; overall deadline kills work" do
    owner = self()

    log =
      capture_log(fn ->
        for failure <- [:raise, :throw, :exit] do
          Req.Test.expect(__MODULE__, fn _ ->
            case failure do
              :raise -> raise(@key <> @prompt <> @private)
              :throw -> throw(@key <> @prompt <> @private)
              :exit -> exit(@key <> @prompt <> @private)
            end
          end)

          assert {:error, :provider_error} = create()
        end

        Req.Test.expect(__MODULE__, fn conn ->
          send(owner, {:request_task, self()})
          Process.sleep(2000)
          Req.Test.json(conn, interaction([text("late")]))
        end)

        assert {:error, :timeout} = Interactions.create(@request, opts(timeout_seconds: 1))
        assert_receive {:request_task, pid}
        refute Process.alive?(pid)
      end)

    for sentinel <- [@key, @prompt, @private], do: refute(log =~ sentinel)
  end

  test "credentials are resolved only after validation, with no environment fallback" do
    previous = Application.fetch_env(:lovelace, :gemini_vault)
    Application.put_env(:lovelace, :gemini_vault, Vault)
    on_exit(fn -> restore(:lovelace, :gemini_vault, previous) end)
    Process.put(:interactions_test_key, {:ok, @key})
    assert {:error, :invalid_request} = Interactions.create(%{}, plug: {Req.Test, __MODULE__})
    refute_received :vault_read
    stub(interaction([text("ok")]))
    assert {:ok, _} = Interactions.create(@request, plug: {Req.Test, __MODULE__})
    assert_received :vault_read
    Process.put(:interactions_test_key, {:error, :locked})
    assert {:error, :keychain_unavailable} = Interactions.get(@id, plug: {Req.Test, __MODULE__})
    assert_received :vault_read

    assert {:error, :missing_api_key} =
             Interactions.create(@request, opts(api_key: "invalid key"))

    refute_received :vault_read
  end

  test "ordinary test connector is disabled for create/get/delete" do
    for result <- [
          Interactions.create(@request, api_key: @key),
          Interactions.get(@id, api_key: @key),
          Interactions.delete(@id, api_key: @key)
        ] do
      assert {:error, :client_configuration_error} = result
    end
  end

  test "actual shared Mint adapter sends POST/GET/DELETE with contained events and no sensitive instrumentation" do
    owner = self()

    events =
      for name <- [:finch, :req, :mint],
          operation <- [:request, :queue, :connect, :send, :recv, :stream],
          phase <- [:start, :stop, :error, :exception],
          do: [name, operation, phase]

    events = events ++ Enum.map([:start, :stop, :error, :exception], &(@prefix ++ [&1]))
    handler = {__MODULE__, make_ref()}
    :telemetry.attach_many(handler, events, &__MODULE__.handle_event/4, owner)
    on_exit(fn -> :telemetry.detach(handler) end)

    png = PNG.image()

    for method <- [:post, :get, :delete] do
      content = [text("ok"), image(png, "image/png")]
      body = if method == :delete, do: "", else: Jason.encode!(interaction(content))
      status = if method == :delete, do: 204, else: 200
      {port, server} = server(body, status)

      result =
        case method do
          :post -> Interactions.create_on_loopback(@request, [api_key: @key], port)
          :get -> Interactions.get_on_loopback(@id, [api_key: @key], port)
          :delete -> Interactions.delete_on_loopback(@id, [api_key: @key], port)
        end

      if method == :delete,
        do: assert(result == :ok),
        else: assert({:ok, %{status: :completed, text: "ok", images: [^png]}} = result)

      assert_receive {:wire, ^server, wire}
      verb = method |> Atom.to_string() |> String.upcase()
      path = if method == :post, do: "/v1beta/interactions", else: "/v1beta/interactions/#{@id}"
      assert wire =~ "#{verb} #{path} HTTP/1.1"
      assert wire =~ "x-goog-api-key: #{@key}"
      if method == :post, do: assert(wire =~ @prompt), else: refute(wire =~ @prompt)
      assert_receive {:event, start, %{system_time: time}, %{}}
      assert start == @prefix ++ [:start]
      assert is_integer(time)
      assert_receive {:event, stop, %{duration: duration}, %{status: ^status, outcome: :ok}}
      assert stop == @prefix ++ [:stop]
      assert is_integer(duration)
      refute_received {:event, _, _, _}
    end
  end

  test "transport rejects method/path mismatches, URL escapes and get/delete request bodies before connecting" do
    for {method, path, body} <- [
          {:get, "/v1beta/interactions", nil},
          {:delete, "/v1beta/interactions", nil},
          {:post, "/v1beta/interactions/#{@id}", "{}"},
          {:post, "/v1beta/interactions/#{@id}/cancel", "{}"},
          {:get, "/v1beta/interactions/a%2Fb", nil},
          {:get, "/v1beta/interactions/../x", nil},
          {:delete, "/v1beta/interactions/#{@id}", "{}"},
          {:get, "/v1beta/interactions/#{@id}?key=x", nil},
          {:put, "/v1beta/interactions/#{@id}", "{}"}
        ] do
      req =
        Req.Request.new(
          method: method,
          url: "https://generativelanguage.googleapis.com" <> path,
          body: body,
          options: [receive_timeout: 100]
        )

      req = %{req | into: fn _, acc -> {:cont, acc} end}
      assert {_, %Req.TransportError{reason: :client_configuration_error}} = Transport.run(req)
    end
  end

  def handle_event(event, measurements, metadata, owner),
    do: send(owner, {:event, event, measurements, metadata})

  defp create(request \\ @request), do: Interactions.create(request, opts())
  defp opts(extra \\ []), do: Keyword.merge([api_key: @key, plug: {Req.Test, __MODULE__}], extra)
  defp text(text), do: %{"type" => "text", "text" => text}

  defp image(bytes, mime),
    do: %{"type" => "image", "mime_type" => mime, "data" => Base.encode64(bytes)}

  defp interaction(content),
    do: %{
      "id" => @id,
      "status" => "completed",
      "steps" => [%{"type" => "model_output", "content" => content}]
    }

  defp stub(body, status \\ 200) do
    Req.Test.expect(__MODULE__, fn conn -> Req.Test.json(%{conn | status: status}, body) end)
  end

  defp restore(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore(app, key, :error), do: Application.delete_env(app, key)

  defp server(body, status) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listen)
    owner = self()

    pid =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen, 2000)
        send(owner, {:wire, self(), read_wire(socket, "")})

        :gen_tcp.send(socket, [
          "HTTP/1.1 #{status} Synthetic\r\ncontent-type: application/json\r\n",
          "content-length: #{byte_size(body)}\r\nx-private: #{@private}\r\n\r\n",
          body
        ])

        :gen_tcp.close(socket)
      end)

    on_exit(fn ->
      :gen_tcp.close(listen)
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    {port, pid}
  end

  defp read_wire(socket, acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [headers, body] ->
        size =
          case Regex.run(~r/content-length: (\d+)/i, headers) do
            [_, value] -> String.to_integer(value)
            _ -> 0
          end

        if byte_size(body) >= size, do: acc, else: read_more(socket, acc)

      _ ->
        read_more(socket, acc)
    end
  end

  defp read_more(socket, acc) do
    {:ok, chunk} = :gen_tcp.recv(socket, 0, 2000)
    read_wire(socket, acc <> chunk)
  end
end
