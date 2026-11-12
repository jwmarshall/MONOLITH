defmodule Monolith.StageDesigner.Diagnostics do
  @moduledoc "Allowlisted failure descriptions. Never formats provider text, exceptions, or credentials."

  @messages %{
    missing_api_key: "no valid Gemini API key is stored; connect Gemini in Settings",
    keychain_unavailable:
      "the Gemini key could not be read; unlock or check macOS Keychain access",
    invalid_settings:
      "image model, size, aspect ratio, prompt length, or timeout configuration is invalid",
    invalid_options: "the provider client received unsupported options",
    invalid_request: "the Interactions request contains unsupported input or configuration",
    request_too_large: "the request exceeded the 64 KiB safety limit; reduce the input",
    invalid_id:
      "the provider interaction ID is unavailable or invalid; no new generation was submitted",
    unsupported_image_source:
      "Google returned a remote image reference; only inline image bytes are accepted",
    client_configuration_error: "the HTTP client rejected its request options",
    timeout: "the request deadline expired; its outcome may be unknown",
    transport_error: "the connection failed before a usable response was received",
    nxdomain: "DNS lookup failed",
    econnrefused: "the connection was refused",
    econnreset: "the connection was reset; its outcome may be unknown",
    enetunreach: "the network is unreachable",
    ehostunreach: "the host is unreachable",
    closed: "the connection closed; its outcome may be unknown",
    tls_error: "TLS negotiation or certificate verification failed",
    blocked: "Gemini blocked the prompt or image under its content policy",
    response_too_large: "the provider response exceeded the 16 MiB safety limit",
    invalid_response: "Gemini returned an unexpected response or no single completed image",
    unexpected_webp: "Gemini returned WebP, but LOVELACE accepts only PNG or JPEG",
    unsupported_image_format:
      "Gemini returned an unsupported image MIME type; PNG or JPEG is required",
    image_mime_mismatch: "the image bytes do not match the declared PNG/JPEG MIME type",
    malformed_image_response: "Gemini returned incomplete inline image data",
    invalid_image_encoding: "Gemini returned invalid base64 image data",
    image_too_large: "the image exceeded the 10 MiB safety limit",
    invalid_image: "the image bytes failed structure, dimensions, pixel, or integrity validation",
    storage_error:
      "the validated image could not be saved; check the storage directory and permissions",
    publication_error:
      "the image manifest could not be committed; the previous image remains active",
    api_key_invalid: "Google rejected the API key",
    api_key_service_blocked: "the API key's API restrictions block this service",
    api_key_ip_address_blocked: "the API key's IP restrictions block this request",
    api_key_http_referrer_blocked: "the API key has incompatible browser-referrer restrictions",
    billing_disabled: "billing is disabled for the Google project",
    service_disabled: "the required Google API is disabled for the project",
    invalid_argument: "Google rejected the request configuration",
    unauthenticated: "Google rejected authentication",
    permission_denied:
      "Google denied access; check key restrictions, project access, and billing",
    not_found: "the configured model or API version is unavailable to this project",
    resource_exhausted:
      "Google quota or rate limits were exhausted; check model quota and billing",
    failed_precondition: "Google project or billing prerequisites are not satisfied",
    internal: "Google reported an internal error",
    unavailable: "the Google service is temporarily unavailable",
    deadline_exceeded: "Google's request deadline expired; its outcome may be unknown",
    provider_error: "the provider failed without a recognized safe diagnostic code",
    unexpected_error: "an unexpected local error occurred; sensitive details were withheld"
  }

  @http_codes %{
    400 => :invalid_argument,
    401 => :unauthenticated,
    403 => :permission_denied,
    404 => :not_found,
    408 => :deadline_exceeded,
    429 => :resource_exhausted,
    500 => :internal,
    502 => :unavailable,
    503 => :unavailable,
    504 => :deadline_exceeded
  }

  def describe(stage, reason) do
    stage_name =
      case stage do
        :provider -> "provider"
        :storage -> "storage"
        :publication -> "publication"
        _ -> "startup"
      end

    stage_name <> ": " <> description(reason)
  end

  defp description({:http_error, status, code}) when is_integer(status) and status in 100..599 do
    code = if Map.has_key?(@messages, code), do: code, else: http_code(status)
    "HTTP #{status} (#{code}): #{@messages[code]}"
  end

  defp description({:transport_error, code}), do: description(code)

  defp description(code) when is_map_key(@messages, code), do: "#{code}: #{@messages[code]}"
  defp description(_), do: "unexpected_error: #{@messages.unexpected_error}"

  defp http_code(status), do: Map.get(@http_codes, status, :provider_error)
end
