defmodule Lovelace.Integrations.Gemini.Interactions do
  @moduledoc """
  Bounded, nonstreaming Gemini Interactions REST client. Never retries or polls.

  `create/2` accepts atom-keyed maps: required `model` and `input`, optional
  `background`, `store`, `response_format`, `generation_config` and
  `previous_interaction_id`. Storage and background execution default to false;
  background execution requires explicitly setting both flags true.

  Input is UTF-8 text, text content blocks, or REST `user_input`/`model_output`
  steps containing text blocks (at most 32 turns, 8,000 bytes per text and 32 KiB
  total text). Nested request maps also use atom keys and string enum values.
  Response formats are plain text or inline PNG/JPEG image configurations, singly
  or in a list. Tools, media inputs, remote references and arbitrary options are
  unsupported. Requests are capped at 64 KiB; responses at 16 MiB, text at 32 KiB,
  and images at four validated original PNG/JPEG binaries, each at most 10 MiB.

  `create/2` and `get/2` return `{:ok, %{id: id, status: status, text: text,
  images: images, error: safe_reason_or_nil}}`. Only model-output steps contribute
  output, never retrieved user input, thoughts, SDK convenience fields or URLs.
  `delete/2` returns `:ok`. Errors contain only fixed categories/allowlisted codes.

  Options: `timeout_seconds` (1..120, default 120), and trusted `api_key`/`plug`
  test injections matching the legacy client. Credentials are resolved only at the
  HTTP boundary. Callers own authorization, cost confirmation and durable intent.
  """

  alias Lovelace.Integrations.Gemini.{Credentials, Transport}
  alias Lovelace.Security.Vault
  alias Lovelace.StageDesigner.Image

  @host "https://generativelanguage.googleapis.com/v1beta/interactions"
  @max_body 64 * 1024
  @max_text 32 * 1024
  @max_response 16 * 1024 * 1024
  @max_image 10 * 1024 * 1024
  @max_base64 4 * div(@max_image + 2, 3)
  @statuses %{
    "in_progress" => :in_progress,
    "completed" => :completed,
    "failed" => :failed,
    "cancelled" => :cancelled,
    "incomplete" => :incomplete,
    "requires_action" => :requires_action,
    "requires_continuation" => :requires_continuation
  }
  # Same diagnostic allowlist as the legacy StageDesigner.Gemini boundary.
  @safe_codes %{
    "API_KEY_INVALID" => :api_key_invalid,
    "API_KEY_SERVICE_BLOCKED" => :api_key_service_blocked,
    "API_KEY_IP_ADDRESS_BLOCKED" => :api_key_ip_address_blocked,
    "API_KEY_HTTP_REFERRER_BLOCKED" => :api_key_http_referrer_blocked,
    "BILLING_DISABLED" => :billing_disabled,
    "SERVICE_DISABLED" => :service_disabled,
    "INVALID_ARGUMENT" => :invalid_argument,
    "UNAUTHENTICATED" => :unauthenticated,
    "PERMISSION_DENIED" => :permission_denied,
    "NOT_FOUND" => :not_found,
    "RESOURCE_EXHAUSTED" => :resource_exhausted,
    "FAILED_PRECONDITION" => :failed_precondition,
    "INTERNAL" => :internal,
    "UNAVAILABLE" => :unavailable,
    "DEADLINE_EXCEEDED" => :deadline_exceeded
  }

  @type failure :: atom() | {:http_error, integer(), atom() | nil} | {:transport_error, atom()}
  @type normalized :: %{
          id: binary(),
          status:
            :in_progress
            | :completed
            | :failed
            | :cancelled
            | :incomplete
            | :requires_action
            | :requires_continuation,
          text: binary(),
          images: [binary()],
          error: failure() | nil
        }

  @spec create(map(), keyword()) :: {:ok, normalized()} | {:error, failure()}
  def create(request, opts \\ []), do: execute(:post, request, opts, nil)

  @spec get(binary(), keyword()) :: {:ok, normalized()} | {:error, failure()}
  def get(id, opts \\ []), do: execute(:get, id, opts, nil)

  @spec delete(binary(), keyword()) :: :ok | {:error, failure()}
  def delete(id, opts \\ []), do: execute(:delete, id, opts, nil)

  if Mix.env() == :test do
    @doc false
    def create_on_loopback(request, opts, port) when port in 1..65_535,
      do: execute(:post, request, opts, port)

    @doc false
    def get_on_loopback(id, opts, port) when port in 1..65_535,
      do: execute(:get, id, opts, port)

    @doc false
    def delete_on_loopback(id, opts, port) when port in 1..65_535,
      do: execute(:delete, id, opts, port)
  end

  defp execute(method, input, opts, port) do
    Vault.with_access(fn -> execute_leased(method, input, opts, port) end)
  end

  defp execute_leased(method, input, opts, port) do
    with :ok <- validate_options(opts),
         {:ok, url, body} <- prepare(method, input),
         {:ok, key} <- api_key(opts) do
      timeout = Keyword.get(opts, :timeout_seconds, 120) * 1000
      # All exceptions/throws/exits are caught INSIDE this task. A task crash
      # report must never inspect the key, prompt, provider response or closure.
      task = Task.async(fn -> leased_request(method, url, body, key, opts, timeout, port) end)

      case Task.yield(task, timeout) do
        {:ok, result} ->
          result

        nil ->
          Task.shutdown(task, :brutal_kill)
          {:error, :timeout}
      end
    end
  rescue
    _ -> {:error, :provider_error}
  catch
    _, _ -> {:error, :provider_error}
  end

  defp leased_request(method, url, body, key, opts, timeout, port) do
    Vault.with_access(fn -> request(method, url, body, key, opts, timeout, port) end)
  end

  defp validate_options(opts) when is_list(opts) do
    valid? =
      Keyword.keyword?(opts) and
        Enum.all?(Keyword.keys(opts), &(&1 in [:api_key, :plug, :timeout_seconds])) and
        is_integer(Keyword.get(opts, :timeout_seconds, 120)) and
        Keyword.get(opts, :timeout_seconds, 120) in 1..120

    if valid?, do: :ok, else: {:error, :invalid_options}
  end

  defp validate_options(_), do: {:error, :invalid_options}

  defp prepare(:post, request) do
    if valid_request?(request) do
      body =
        request
        |> Map.put_new(:store, false)
        |> Map.put_new(:background, false)
        |> Jason.encode!()

      if byte_size(body) <= @max_body,
        do: {:ok, @host, body},
        else: {:error, :request_too_large}
    else
      {:error, :invalid_request}
    end
  end

  defp prepare(_method, id) do
    if Transport.valid_id?(id),
      do: {:ok, @host <> "/" <> id, nil},
      else: {:error, :invalid_id}
  end

  defp valid_request?(%{model: model, input: input} = request) do
    only_keys?(request, [
      :model,
      :input,
      :store,
      :background,
      :response_format,
      :generation_config,
      :previous_interaction_id
    ]) and
      valid_model?(model) and valid_input?(input) and valid_storage_flags?(request) and
      valid_optional_fields?(request)
  end

  defp valid_request?(_), do: false

  defp valid_model?(model),
    do: is_binary(model) and Regex.match?(~r/\A[a-z0-9][a-z0-9.-]{0,99}\z/, model)

  defp valid_storage_flags?(request) do
    store = Map.get(request, :store, false)
    background = Map.get(request, :background, false)
    is_boolean(store) and is_boolean(background) and (not background or store)
  end

  defp valid_optional_fields?(request) do
    optional?(request, :previous_interaction_id, &Transport.valid_id?/1) and
      optional?(request, :response_format, &valid_formats?/1) and
      optional?(request, :generation_config, &valid_config?/1)
  end

  defp valid_input?(input) when is_binary(input), do: valid_text?(input)
  defp valid_input?(%{type: "text"} = input), do: valid_text_block?(input)

  defp valid_input?(input) when is_list(input) and length(input) in 1..32 do
    Enum.all?(input, &valid_input_item?/1) and input_text_bytes(input) <= @max_text
  end

  defp valid_input?(_), do: false

  defp valid_input_item?(%{type: type, content: content} = step)
       when type in ["user_input", "model_output"] and is_list(content) and
              length(content) in 1..32,
       do: only_keys?(step, [:type, :content]) and Enum.all?(content, &valid_text_block?/1)

  defp valid_input_item?(block), do: valid_text_block?(block)

  defp valid_text_block?(%{type: "text", text: text} = block),
    do: only_keys?(block, [:type, :text]) and valid_text?(text)

  defp valid_text_block?(_), do: false

  defp input_text_bytes(items) do
    Enum.reduce(items, 0, fn
      %{text: text}, size -> size + byte_size(text)
      %{content: content}, size -> size + input_text_bytes(content)
    end)
  end

  defp valid_text?(text),
    do: is_binary(text) and byte_size(text) in 1..8000 and String.valid?(text)

  defp valid_formats?(formats) when is_list(formats) and length(formats) in 1..2,
    do: Enum.all?(formats, &valid_format?/1)

  defp valid_formats?(format), do: valid_format?(format)

  defp valid_format?(%{type: "text"} = format),
    do:
      only_keys?(format, [:type, :mime_type]) and
        Map.get(format, :mime_type, "text/plain") == "text/plain"

  defp valid_format?(%{type: "image"} = format) do
    only_keys?(format, [:type, :mime_type, :delivery, :aspect_ratio, :image_size]) and
      Map.get(format, :mime_type, "image/jpeg") in ["image/png", "image/jpeg"] and
      Map.get(format, :delivery, "inline") == "inline" and
      Map.get(format, :aspect_ratio, "1:1") in [
        "1:1",
        "2:3",
        "3:2",
        "3:4",
        "4:3",
        "4:5",
        "5:4",
        "9:16",
        "16:9",
        "21:9",
        "1:8",
        "8:1",
        "1:4",
        "4:1"
      ] and
      Map.get(format, :image_size, "1K") in ["512", "1K", "2K", "4K"]
  end

  defp valid_format?(_), do: false

  defp valid_config?(config) when is_map(config),
    do: map_size(config) <= 8 and Enum.all?(config, &valid_config_value?/1)

  defp valid_config?(_), do: false

  defp valid_config_value?({:temperature, value}),
    do: is_number(value) and value >= 0 and value <= 2

  defp valid_config_value?({:top_p, value}), do: is_number(value) and value >= 0 and value <= 1
  defp valid_config_value?({:top_k, value}), do: is_integer(value) and value in 1..1000

  defp valid_config_value?({:max_output_tokens, value}),
    do: is_integer(value) and value in 1..65_536

  defp valid_config_value?({:seed, value}), do: is_integer(value) and value in 0..2_147_483_647

  defp valid_config_value?({:thinking_level, value}),
    do: value in ["minimal", "low", "medium", "high"]

  defp valid_config_value?({:thinking_summaries, value}), do: value in ["auto", "none"]
  defp valid_config_value?(_), do: false

  defp only_keys?(map, keys), do: Enum.all?(Map.keys(map), &(&1 in keys))

  defp optional?(map, key, validator),
    do: not Map.has_key?(map, key) or validator.(Map.get(map, key))

  defp api_key(opts) do
    case Keyword.fetch(opts, :api_key) do
      {:ok, key} ->
        if Credentials.validate_key(key) == :ok, do: {:ok, key}, else: {:error, :missing_api_key}

      :error ->
        Credentials.read_key()
    end
  end

  defp request(method, url, body, key, opts, timeout, port) do
    # Low-level Req.Request has NO default steps/plugins/options. In particular,
    # global Req defaults cannot restore Finch instrumentation, redirects/retries.
    request =
      Req.Request.new(
        method: method,
        url: url,
        headers: [
          {"x-goog-api-key", key},
          {"accept-encoding", "identity"},
          {"content-type", "application/json"},
          {"api-revision", "2026-05-20"}
        ],
        body: body,
        adapter: if(Keyword.has_key?(opts, :plug), do: Req.Plug, else: Transport),
        options: [receive_timeout: timeout] ++ Keyword.take(opts, [:plug])
      )

    request = %{request | into: &receive_chunk/2, private: %{lovelace_test_loopback_port: port}}

    case Req.request(request) do
      {:ok, response} -> parse_response(response, method, url)
      {:error, %Req.TransportError{reason: reason}} -> transport_error(reason)
      {:error, _} -> {:error, :transport_error}
    end
  rescue
    ArgumentError -> {:error, :client_configuration_error}
    _ -> {:error, :provider_error}
  catch
    _, _ -> {:error, :provider_error}
  end

  defp receive_chunk({:data, chunk}, {request, response}) do
    {size, chunks} = Map.get(response.private, :lovelace_body, {0, []})
    size = size + byte_size(chunk)

    if size > @max_response do
      {:halt, {request, put_in(response.private[:lovelace_oversize], true)}}
    else
      {:cont, {request, put_in(response.private[:lovelace_body], {size, [chunk | chunks]})}}
    end
  end

  defp parse_response(response, method, url) do
    cond do
      response.private[:lovelace_oversize] ->
        {:error, :response_too_large}

      not is_integer(response.status) or response.status not in 100..599 ->
        {:error, :invalid_response}

      true ->
        parse_http_response(response, method, url)
    end
  end

  # A recovery DELETE may follow a successful deletion whose response was lost.
  defp parse_http_response(%{status: status}, :delete, _url) when status in [200, 204, 404],
    do: :ok

  defp parse_http_response(%{status: 200} = response, method, url) do
    if json_response?(response),
      do: decode_response(response, method, url),
      else: {:error, :invalid_response}
  end

  defp parse_http_response(response, _method, _url), do: http_error(response)

  defp decode_response(response, method, url) do
    with {:ok, decoded} <- Jason.decode(response_body(response)),
         {:ok, normalized} <- normalize(decoded),
         true <- method != :get or url == @host <> "/" <> normalized.id do
      {:ok, normalized}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :invalid_response}
    end
  end

  defp json_response?(response) do
    type = Req.Response.get_header(response, "content-type")
    encoding = Req.Response.get_header(response, "content-encoding")

    match?([_], type) and
      type |> hd() |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase() ==
        "application/json" and encoding in [[], ["identity"]]
  end

  defp response_body(response) do
    {_size, chunks} = Map.get(response.private, :lovelace_body, {0, []})
    chunks |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp normalize(%{"id" => id, "status" => status} = interaction) do
    steps = Map.get(interaction, "steps", [])

    with true <- Transport.valid_id?(id),
         status when not is_nil(status) <- Map.get(@statuses, status),
         true <- is_list(steps) and length(steps) <= 128,
         {:ok, text, images} <- output(steps),
         true <- status != :completed or text != "" or images != [] do
      {:ok,
       %{
         id: id,
         status: status,
         text: text,
         images: images,
         error: interaction_error(interaction, status)
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_response}
    end
  end

  defp normalize(_), do: {:error, :invalid_response}

  defp output(steps) do
    Enum.reduce_while(steps, {:ok, "", []}, fn
      %{"type" => "model_output", "content" => content}, acc
      when is_list(content) and length(content) <= 128 ->
        case output_content(content, acc) do
          {:ok, _, _} = result -> {:cont, result}
          error -> {:halt, error}
        end

      %{"type" => type}, acc when type in ["user_input", "thought"] ->
        {:cont, acc}

      _, _ ->
        {:halt, {:error, :invalid_response}}
    end)
  end

  defp output_content(content, acc) do
    Enum.reduce_while(content, acc, fn block, {:ok, text, images} ->
      case output_block(block) do
        {:text, part} when byte_size(text) + byte_size(part) <= @max_text ->
          {:cont, {:ok, text <> part, images}}

        {:image, bytes} when length(images) < 4 ->
          {:cont, {:ok, text, images ++ [bytes]}}

        {:error, _} = error ->
          {:halt, error}

        _ ->
          {:halt, {:error, :response_too_large}}
      end
    end)
  end

  defp output_block(%{"type" => "text", "text" => text}) when is_binary(text) do
    if String.valid?(text), do: {:text, text}, else: {:error, :invalid_response}
  end

  defp output_block(%{"type" => "image"} = block) do
    cond do
      Map.has_key?(block, "uri") or Map.has_key?(block, "url") ->
        {:error, :unsupported_image_source}

      block["mime_type"] not in ["image/png", "image/jpeg"] ->
        {:error, :unsupported_image_format}

      not is_binary(block["data"]) ->
        {:error, :malformed_image_response}

      byte_size(block["data"]) > @max_base64 ->
        {:error, :image_too_large}

      true ->
        decode_image(block["data"], block["mime_type"])
    end
  end

  defp output_block(_), do: {:error, :invalid_response}

  defp decode_image(data, mime) do
    case Base.decode64(data) do
      {:ok, bytes} when byte_size(bytes) <= @max_image ->
        cond do
          Image.format(bytes) == :unknown -> {:error, :invalid_image}
          Image.mime_type(Image.format(bytes)) != mime -> {:error, :image_mime_mismatch}
          Image.validate(bytes) != :ok -> {:error, :invalid_image}
          true -> {:image, bytes}
        end

      {:ok, _} ->
        {:error, :image_too_large}

      :error ->
        {:error, :invalid_image_encoding}
    end
  end

  defp interaction_error(interaction, status) do
    case Map.get(interaction, "errors", []) do
      [] when status != :failed ->
        nil

      errors when is_list(errors) ->
        Enum.find_value(errors, fn
          %{"code" => code} -> Map.get(@safe_codes, code)
          _ -> nil
        end) || :provider_error

      _ ->
        :provider_error
    end
  end

  defp http_error(response) do
    code =
      with true <- json_response?(response),
           {:ok, %{"error" => error}} when is_map(error) <- Jason.decode(response_body(response)) do
        details = Map.get(error, "details", [])
        details = if is_list(details), do: details, else: []

        Enum.find_value(details, fn
          %{"@type" => "type.googleapis.com/google.rpc.ErrorInfo", "reason" => reason} ->
            Map.get(@safe_codes, reason)

          _ ->
            nil
        end) || Map.get(@safe_codes, Map.get(error, "status"))
      else
        _ -> nil
      end

    {:error, {:http_error, response.status, code}}
  end

  defp transport_error(reason)
       when reason in [
              :timeout,
              :response_too_large,
              :client_configuration_error,
              :provider_error
            ],
       do: {:error, reason}

  defp transport_error(reason)
       when reason in [
              :nxdomain,
              :econnrefused,
              :econnreset,
              :enetunreach,
              :ehostunreach,
              :closed,
              :tls_error
            ],
       do: {:error, {:transport_error, reason}}

  defp transport_error({:tls_alert, _}), do: {:error, {:transport_error, :tls_error}}
  defp transport_error(_), do: {:error, :transport_error}
end
