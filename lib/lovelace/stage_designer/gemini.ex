defmodule Lovelace.StageDesigner.Gemini do
  @moduledoc "One bounded Gemini image request; credentials and provider errors never leave this boundary."

  alias Lovelace.StageDesigner.{GeminiTransport, Image, Settings}

  @host "https://generativelanguage.googleapis.com/v1beta/models/"
  @max_response_bytes 16 * 1024 * 1024
  @max_image_bytes 10 * 1024 * 1024
  @max_base64_bytes 4 * div(@max_image_bytes + 2, 3)
  @safe_error_codes %{
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
  @spec generate(struct(), keyword()) :: {:ok, binary()} | {:error, failure()}
  def generate(settings, opts \\ []), do: do_generate(settings, opts, nil)

  if Mix.env() == :test do
    @doc false
    def generate_on_loopback(settings, opts, port) when is_integer(port) and port in 1..65_535,
      do: do_generate(settings, opts, port)
  end

  defp do_generate(settings, opts, test_port) do
    with :ok <- validate_options(opts),
         :ok <- validate_settings(settings),
         {:ok, key} <- api_key(opts) do
      bounded_request(settings, key, opts, test_port)
    end
  rescue
    _ -> {:error, :provider_error}
  catch
    _, _ -> {:error, :provider_error}
  end

  defp validate_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in [:api_key, :plug])),
      do: :ok,
      else: {:error, :invalid_options}
  end

  defp validate_options(_), do: {:error, :invalid_options}

  defp validate_settings(%Settings{} = settings) do
    valid? =
      is_binary(settings.model) and
        Regex.match?(~r/\A[a-z0-9][a-z0-9.-]{0,99}\z/, settings.model) and
        settings.aspect_ratio in ["16:9", "21:9", "4:3", "3:2", "1:1"] and
        settings.image_size in ["1K", "2K", "4K"] and
        is_binary(settings.prompt) and byte_size(settings.prompt) in 1..8000 and
        is_integer(settings.timeout_seconds) and settings.timeout_seconds in 1..120

    if valid?, do: :ok, else: {:error, :invalid_settings}
  end

  defp validate_settings(_), do: {:error, :invalid_settings}

  defp api_key(opts) do
    key =
      case Keyword.fetch(opts, :api_key) do
        {:ok, key} -> key
        :error -> System.get_env("GEMINI_API_KEY")
      end

    if is_binary(key) and byte_size(key) in 1..4096 and String.trim(key) != "" and
         not String.contains?(key, ["\r", "\n"]),
       do: {:ok, key},
       else: {:error, :missing_api_key}
  end

  defp bounded_request(settings, key, opts, test_port) do
    # Catch inside the task as well: Task crash reports must never inspect its key-bearing args.
    task = Task.async(fn -> request(settings, key, opts, test_port) end)

    case Task.yield(task, settings.timeout_seconds * 1000) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, :timeout}
    end
  end

  defp request(settings, key, opts, test_port) do
    # No default steps/plugins: no global Req defaults, redirects, decompression or retries.
    # Explicit Req.Plug injection preserves process-owned Req.Test stubs in existing tests.
    request =
      Req.Request.new(
        method: :post,
        url: @host <> settings.model <> ":generateContent",
        headers: [
          {"x-goog-api-key", key},
          {"accept-encoding", "identity"},
          {"content-type", "application/json"}
        ],
        body: Jason.encode!(payload(settings)),
        adapter: if(Keyword.has_key?(opts, :plug), do: Req.Plug, else: GeminiTransport),
        options: [receive_timeout: settings.timeout_seconds * 1000] ++ Keyword.take(opts, [:plug])
      )

    request = %{
      request
      | into: &receive_chunk/2,
        private: %{lovelace_test_loopback_port: test_port}
    }

    case Req.post(request) do
      {:ok, response} ->
        parse_response(response)

      {:error, %Req.TransportError{reason: reason}}
      when reason in [:timeout, :response_too_large, :client_configuration_error, :provider_error] ->
        {:error, reason}

      {:error, %Req.TransportError{reason: reason}} ->
        transport_error(reason)

      {:error, _} ->
        {:error, :transport_error}
    end
  rescue
    ArgumentError -> {:error, :client_configuration_error}
    _ -> {:error, :provider_error}
  catch
    _, _ -> {:error, :provider_error}
  end

  defp payload(settings) do
    %{
      contents: [%{role: "user", parts: [%{text: settings.prompt}]}],
      generationConfig: %{
        responseModalities: ["TEXT", "IMAGE"],
        imageConfig: %{aspectRatio: settings.aspect_ratio, imageSize: settings.image_size}
      },
      store: false
    }
  end

  defp receive_chunk({:data, chunk}, {request, response}) do
    {size, chunks} = Map.get(response.private, :lovelace_body, {0, []})
    size = size + byte_size(chunk)

    if size > @max_response_bytes do
      response = put_in(response.private[:lovelace_oversize], true)
      {:halt, {request, response}}
    else
      response = put_in(response.private[:lovelace_body], {size, [chunk | chunks]})
      {:cont, {request, response}}
    end
  end

  defp parse_response(response) do
    cond do
      response.private[:lovelace_oversize] -> {:error, :response_too_large}
      response.status != 200 -> http_error(response)
      not json_response?(response) -> {:error, :invalid_response}
      true -> decode_response(response)
    end
  end

  defp json_response?(response) do
    type = Req.Response.get_header(response, "content-type")
    encoding = Req.Response.get_header(response, "content-encoding")

    match?([_], type) and
      type |> hd() |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase() ==
        "application/json" and encoding in [[], ["identity"]]
  end

  defp transport_error(reason)
       when reason in [
              :nxdomain,
              :econnrefused,
              :econnreset,
              :enetunreach,
              :ehostunreach,
              :closed
            ],
       do: {:error, {:transport_error, reason}}

  defp transport_error(:tls_error), do: {:error, {:transport_error, :tls_error}}
  defp transport_error({:tls_alert, _details}), do: {:error, {:transport_error, :tls_error}}
  defp transport_error(_reason), do: {:error, :transport_error}

  defp http_error(response) do
    code =
      with true <- json_response?(response),
           {:ok, %{"error" => error}} when is_map(error) <- Jason.decode(response_body(response)) do
        safe_error_code(error)
      else
        _ -> nil
      end

    {:error, {:http_error, response.status, code}}
  end

  defp safe_error_code(error) do
    details = Map.get(error, "details", [])
    details = if is_list(details), do: details, else: []

    Enum.find_value(details, fn
      %{"@type" => "type.googleapis.com/google.rpc.ErrorInfo", "reason" => reason} ->
        Map.get(@safe_error_codes, reason)

      _ ->
        nil
    end) || Map.get(@safe_error_codes, Map.get(error, "status"))
  end

  defp response_body(response) do
    {_size, chunks} = Map.get(response.private, :lovelace_body, {0, []})
    chunks |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp decode_response(response) do
    case Jason.decode(response_body(response)) do
      {:ok, %{"promptFeedback" => %{"blockReason" => reason}}}
      when reason != "BLOCK_REASON_UNSPECIFIED" ->
        {:error, :blocked}

      {:ok, %{"candidates" => [candidate]}} ->
        candidate_image(candidate)

      _ ->
        {:error, :invalid_response}
    end
  end

  defp candidate_image(%{"finishReason" => "STOP", "content" => %{"parts" => parts}})
       when is_list(parts) do
    images =
      Enum.flat_map(parts, fn
        %{"thought" => true} -> []
        %{"inlineData" => image} -> [image]
        _ -> []
      end)

    case images do
      [%{"mimeType" => "image/png", "data" => data}] when is_binary(data) ->
        decode_image(data, :png)

      [%{"mimeType" => "image/jpeg", "data" => data}] when is_binary(data) ->
        decode_image(data, :jpeg)

      [%{"mimeType" => "image/webp"}] ->
        {:error, :unexpected_webp}

      [%{"mimeType" => mime}] when mime not in ["image/png", "image/jpeg"] ->
        {:error, :unsupported_image_format}

      [_] ->
        {:error, :malformed_image_response}

      _ ->
        {:error, :invalid_response}
    end
  end

  defp candidate_image(%{"finishReason" => reason})
       when reason in [
              "SAFETY",
              "RECITATION",
              "PROHIBITED_CONTENT",
              "BLOCKLIST",
              "SPII",
              "IMAGE_SAFETY",
              "IMAGE_PROHIBITED_CONTENT",
              "IMAGE_RECITATION"
            ] do
    {:error, :blocked}
  end

  defp candidate_image(_), do: {:error, :invalid_response}

  defp decode_image(data, expected_format) when byte_size(data) <= @max_base64_bytes do
    case Base.decode64(data) do
      {:ok, bytes} when byte_size(bytes) <= @max_image_bytes ->
        validate_image(bytes, expected_format)

      {:ok, _bytes} ->
        {:error, :image_too_large}

      :error ->
        {:error, :invalid_image_encoding}
    end
  end

  defp decode_image(_data, _format), do: {:error, :image_too_large}

  defp validate_image(bytes, expected_format) do
    case Image.format(bytes) do
      :unknown ->
        {:error, :invalid_image}

      ^expected_format ->
        case Image.validate(bytes) do
          :ok -> {:ok, bytes}
          {:error, :invalid_image} -> {:error, :invalid_image}
        end

      _ ->
        {:error, :image_mime_mismatch}
    end
  end
end
