defmodule Lovelace.Integrations.ProviderBoundariesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Lovelace.Integrations.Gemini.Interactions
  alias Lovelace.Integrations.Google
  alias Lovelace.Integrations.Google.ClientCredentials

  @private "synthetic-provider-secret-NEVER-LOG"
  @redirect "http://localhost:4000/oauth/google/callback"
  @verifier String.duplicate("v", 43)
  @id "boundary_interaction_123"
  @request %{model: "gemini-nano-banana-2.1", input: "Draw a quiet garden"}

  defmodule Transport do
    @behaviour Google.Transport
    def request(request, options), do: Keyword.fetch!(options, :handler).(request)
  end

  defmodule Credentials do
    def read, do: {:ok, %{client_id: "synthetic-client", client_secret: "synthetic-secret"}}
  end

  defmodule ClientVault do
    def get(_, _), do: Process.get(:client_vault_read, {:error, :not_found})

    def put(_, _, _) do
      send(self(), :client_vault_write)
      Process.get(:client_vault_write, :ok)
    end

    def delete(_, _), do: Process.get(:client_vault_delete, :ok)
  end

  setup {Req.Test, :verify_on_exit!}

  setup do
    keys = [:gmail, :google_client_credentials, :google_client_keychain]
    previous = Enum.map(keys, &{&1, Application.fetch_env(:lovelace, &1)})
    Application.put_env(:lovelace, :google_client_credentials, Credentials)
    Application.put_env(:lovelace, :google_client_keychain, ClientVault)
    configure(fn _ -> flunk("invalid input must not reach Google") end)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, old} -> Application.put_env(:lovelace, key, old)
          :error -> Application.delete_env(:lovelace, key)
        end
      end
    end)

    :ok
  end

  test "invalid OAuth and resource inputs are rejected before transport" do
    for verifier <- [nil, 43, "too-short"] do
      assert {:error, :invalid_request} =
               Google.authorization_url(%{
                 state: "synthetic-state-123456",
                 verifier: verifier,
                 redirect_uri: @redirect
               })

      assert {:error, :invalid_request} = Google.exchange_code("code", verifier, @redirect)
    end

    assert {:error, :invalid_request} = Google.authorization_url(%{})
    assert {:error, :invalid_request} = Google.exchange_code(nil, @verifier, @redirect)
    assert {:error, :invalid_request} = Google.refresh("Bearer injected\r\nheader")
    assert {:error, :invalid_request} = Google.thread("access", nil)
    assert {:error, :invalid_request} = Google.attachment("access", nil, "attachment")
    assert {:error, :invalid_request} = Google.attachment("access", "message", nil)
  end

  test "invalid local configuration cannot initiate OAuth or resource access" do
    for config <- [:invalid, nil, %{redirect_uri: nil}] do
      Application.put_env(:lovelace, :gmail, config)
      assert {:error, :invalid_configuration} = Google.refresh("refresh")
      assert {:error, :invalid_configuration} = Google.identity("access")
    end
  end

  test "resource and revocation failures preserve safe provider categories without private diagnostics" do
    log =
      capture_log(fn ->
        for {status, body, expected} <- [
              {400, @private, :provider_error},
              {400, Jason.encode!(%{error: "invalid_grant", description: @private}),
               :invalid_grant},
              {401, @private, :unauthorized},
              {404, @private, :not_found}
            ] do
          configure(fn _ -> response(status, body) end)
          assert {:error, ^expected} = Google.thread("access", "thread")
          assert {:error, ^expected} = Google.attachment("access", "message", "attachment")
          assert {:error, ^expected} = Google.revoke("refresh")
        end
      end)

    refute log =~ @private
  end

  test "a metadata failure aborts the page without returning earlier rows or requesting later rows" do
    owner = self()

    configure(fn request ->
      send(owner, {:google_path, request.path})

      case URI.parse(request.path).path do
        "/gmail/v1/users/me/threads" ->
          json(%{threads: [%{id: "first"}, %{id: "second"}, %{id: "third"}]})

        "/gmail/v1/users/me/threads/first" ->
          json(%{id: "first", messages: [%{id: "message", payload: %{headers: []}}]})

        "/gmail/v1/users/me/threads/second" ->
          response(403, @private)

        _ ->
          flunk("must stop fetching metadata after failure")
      end
    end)

    assert {:error, :forbidden} = Google.search("access", "private search")
    assert_received {:google_path, "/gmail/v1/users/me/threads?" <> _}
    assert_received {:google_path, "/gmail/v1/users/me/threads/first?" <> _}
    assert_received {:google_path, "/gmail/v1/users/me/threads/second?" <> _}
    refute_received {:google_path, _}
  end

  test "malformed successful Google envelopes never become identities or token grants" do
    for result <- [
          {:ok, %{status: 200, headers: [], body: "{}"}},
          response(200, "{}", [
            {"content-type", "application/json"},
            {"Content-Type", "application/json"}
          ]),
          response(200, "[]"),
          response(200, "not-json"),
          {:ok, %{status: 200, body: @private}}
        ] do
      configure(fn _ -> result end)
      assert {:error, :invalid_response} = Google.identity("access")
      assert {:error, :invalid_response} = Google.refresh("refresh")
    end

    configure(fn _ ->
      json(%{access_token: "access", expires_in: 3600, token_type: "Bearer", scope: ["openid"]})
    end)

    assert {:error, :invalid_response} = Google.refresh("refresh")
  end

  test "attachment response must contain bounded encoded bytes rather than a successful empty object" do
    for data <- [%{}, %{data: nil}, %{data: 12}, %{data: String.duplicate("x", 7 * 1024 * 1024)}] do
      configure(fn _ -> json(data) end)
      assert {:error, :invalid_response} = Google.attachment("access", "message", "attachment")
    end
  end

  test "client storage rejects encoded overflow without writing and classifies deletion recovery safely" do
    # Individually valid values can exceed the aggregate JSON storage budget.
    value = String.duplicate("x", 8192)
    assert {:error, :invalid_configuration} = ClientCredentials.save(value, value)
    refute_received :client_vault_write

    for {result, expected} <- [
          {{:error, :not_found}, :ok},
          {{:error, :locked}, {:error, :locked}},
          {{:error, @private}, {:error, :unavailable}},
          {{:ok, @private}, {:error, :unavailable}}
        ] do
      Process.put(:client_vault_delete, result)
      assert ClientCredentials.delete() == expected
    end

    Process.put(:client_vault_write, {:error, :not_found})
    assert {:error, :invalid_configuration} = ClientCredentials.save("client", "secret")
  end

  test "Google transport rejects structurally corrupt requests before connection" do
    for request <- [
          %{},
          %{method: "GET"},
          %{
            method: "GET",
            host: "openidconnect.googleapis.com",
            path: "/v1/userinfo",
            timeout_ms: 100,
            body: "",
            headers: ["not a header pair"]
          }
        ] do
      assert {:error, :invalid_request} = Google.Transport.validate(request)
      assert {:error, :transport_error} = Google.Transport.request(request)
    end
  end

  test "Gemini rejects malformed response structures instead of returning partial generated text" do
    for body <- [
          [],
          %{},
          %{"id" => @id, "status" => "in_progress", "steps" => [nil]},
          interaction([%{"type" => "text", "text" => "partial"}, nil]),
          interaction([%{"type" => "tool_call", "arguments" => @private}]),
          %{
            "id" => @id,
            "status" => "in_progress",
            "steps" => List.duplicate(%{"type" => "thought"}, 129)
          },
          interaction(List.duplicate(%{"type" => "text", "text" => "x"}, 129))
        ] do
      gemini_response(body)
      assert {:error, :invalid_response} = create()
    end
  end

  test "Gemini text limit accumulates across model output steps and rejects excess without partial output" do
    part = String.duplicate("x", 16 * 1024)
    step = %{"type" => "model_output", "content" => [%{"type" => "text", "text" => part}]}
    body = %{"id" => @id, "status" => "completed", "steps" => [step, step]}
    gemini_response(body)
    expected = part <> part
    assert {:ok, %{text: ^expected}} = create()

    extra = %{"type" => "model_output", "content" => [%{"type" => "text", "text" => "!"}]}
    gemini_response(Map.put(body, "steps", [step, step, extra]))
    assert {:error, :response_too_large} = create()
  end

  test "Gemini failure diagnostics ignore malformed entries and never expose untrusted error payloads" do
    log =
      capture_log(fn ->
        for errors <- [[nil, %{"message" => @private}], %{"message" => @private}, @private] do
          gemini_response(%{"id" => @id, "status" => "failed", "errors" => errors})

          assert {:ok, %{status: :failed, text: "", images: [], error: :provider_error}} =
                   create()
        end

        gemini_response(%{
          "id" => @id,
          "status" => "failed",
          "errors" => [nil, %{"code" => "UNAVAILABLE", "message" => @private}]
        })

        assert {:ok, %{error: :unavailable}} = create()
      end)

    refute log =~ @private
  end

  test "Gemini rejects malformed generation constraints and options before HTTP" do
    Req.Test.stub(__MODULE__, fn _ -> flunk("invalid request must not reach Gemini") end)

    for fields <- [
          %{response_format: nil},
          %{response_format: [%{type: "text"}, nil]},
          %{response_format: %{type: "image", delivery: "remote"}},
          %{generation_config: nil},
          %{generation_config: [temperature: 1]}
        ] do
      assert {:error, :invalid_request} = create(Map.merge(@request, fields))
    end

    assert {:error, :invalid_options} = Interactions.create(@request, [:invalid])
  end

  test "Gemini sanitizes network failure categories and client configuration errors without retry" do
    log =
      capture_log(fn ->
        for {reason, expected} <- [
              {:econnreset, {:transport_error, :econnreset}},
              {{:tls_alert, {:handshake_failure, @private}}, {:transport_error, :tls_error}},
              {:protocol_not_negotiated, :transport_error}
            ] do
          Req.Test.expect(__MODULE__, fn conn -> Req.Test.transport_error(conn, reason) end)
          assert {:error, ^expected} = create()
        end

        Req.Test.expect(__MODULE__, fn _ -> raise ArgumentError, @private end)
        assert {:error, :client_configuration_error} = create()
      end)

    refute log =~ @private
  end

  defp configure(handler) do
    Application.put_env(:lovelace, :gmail,
      transport: Transport,
      transport_options: [handler: handler]
    )
  end

  defp response(status, body, headers \\ [{"content-type", "application/json"}]),
    do: {:ok, %{status: status, headers: headers, body: body}}

  defp json(body), do: response(200, Jason.encode!(body))

  defp interaction(content),
    do: %{
      "id" => @id,
      "status" => "completed",
      "steps" => [%{"type" => "model_output", "content" => content}]
    }

  defp gemini_response(body) do
    Req.Test.expect(__MODULE__, fn conn -> Req.Test.json(conn, body) end)
  end

  defp create(request \\ @request),
    do: Interactions.create(request, api_key: "synthetic-key", plug: {Req.Test, __MODULE__})
end
