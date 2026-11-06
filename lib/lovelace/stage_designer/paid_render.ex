defmodule Lovelace.StageDesigner.PaidRender do
  @moduledoc """
  Application-owned Gemini paid-interaction contract.

  `create/2` submits exactly once, with background execution and provider storage
  explicitly authorized by the request. No adapter retry or model fallback is
  permitted. An error classified as `:unknown` may have incurred a charge and
  must never authorize another submission. `get/2` only tracks a known ID;
  `delete/2` is idempotent cleanup (including an already-absent remote result).
  Publication must commit locally before cleanup is requested.

  Results are bounded: at most four original validated PNG/JPEG images (10 MiB
  each), 32 KiB output text and 16 MiB total response. Nothing is truncated or
  paginated silently: unsupported/oversized output fails explicitly. These are
  current provider observations, not a promise of completion or local freshness.
  Errors contain only the finite safe categories below, never provider payloads.
  """

  @type provider_code ::
          :api_key_invalid
          | :api_key_service_blocked
          | :api_key_ip_address_blocked
          | :api_key_http_referrer_blocked
          | :billing_disabled
          | :service_disabled
          | :invalid_argument
          | :unauthenticated
          | :permission_denied
          | :not_found
          | :resource_exhausted
          | :failed_precondition
          | :internal
          | :unavailable
          | :deadline_exceeded
  @type transport_failure ::
          :nxdomain
          | :econnrefused
          | :econnreset
          | :enetunreach
          | :ehostunreach
          | :closed
          | :tls_error
  @type failure ::
          :missing_api_key
          | :keychain_unavailable
          | :locked
          | :vault_unavailable
          | :invalid_settings
          | :invalid_options
          | :invalid_request
          | :invalid_id
          | :request_too_large
          | :client_configuration_error
          | :timeout
          | :provider_error
          | :transport_error
          | :response_too_large
          | :invalid_response
          | :unsupported_image_source
          | :unsupported_image_format
          | :malformed_image_response
          | :image_too_large
          | :invalid_image
          | :image_mime_mismatch
          | :invalid_image_encoding
          | provider_code()
          | {:http_error, 100..599, provider_code() | nil}
          | {:transport_error, transport_failure()}
  @type status ::
          :in_progress
          | :completed
          | :failed
          | :cancelled
          | :incomplete
          | :requires_action
          | :requires_continuation
  @type interaction :: %{
          id: binary(),
          status: status(),
          text: binary(),
          images: [binary()],
          error: failure() | nil
        }
  @type request :: %{
          required(:model) => binary(),
          required(:input) => binary() | map() | [map()],
          optional(atom()) => term()
        }

  @callback create(request(), keyword()) :: {:ok, interaction()} | {:error, failure()}
  @callback get(binary(), keyword()) :: {:ok, interaction()} | {:error, failure()}
  @callback delete(binary(), keyword()) :: :ok | {:error, failure()}

  @doc "Distinguishes known preflight/rejection failures from a possibly accepted paid POST."
  @spec submission_outcome(failure()) :: :rejected | :unknown
  def submission_outcome({:http_error, status, _}) when status in [400, 401, 403, 404, 429],
    do: :rejected

  def submission_outcome(reason)
      when reason in [
             :missing_api_key,
             :keychain_unavailable,
             :locked,
             :vault_unavailable,
             :invalid_settings,
             :invalid_options,
             :invalid_request,
             :request_too_large,
             :client_configuration_error
           ],
      do: :rejected

  def submission_outcome(_), do: :unknown
end
