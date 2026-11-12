defmodule Monolith.Mail.ConnectionDiagnostics do
  @moduledoc "Allowlisted OAuth failure stages only; never retain provider responses or credentials."
  require Logger

  @stages [
    :session,
    :state,
    :consent,
    :code,
    :token_exchange,
    :identity,
    :account_binding,
    :refresh_token,
    :connection,
    :keychain,
    :callback
  ]
  @reasons [
    :unavailable,
    :invalid_state,
    :invalid_callback,
    :denied,
    :invalid_configuration,
    :invalid_request,
    :invalid_response,
    :invalid_grant,
    :unauthorized,
    :forbidden,
    :not_found,
    :rate_limited,
    :provider_error,
    :transport_error,
    :response_too_large,
    :timeout,
    :locked,
    :keychain,
    :rollback_failed,
    :wrong_account,
    :reconnect,
    :unexpected
  ]

  def step(stage, fun) when stage in @stages do
    case fun.() do
      :ok -> :ok
      {:ok, value} -> {:ok, value}
      {:error, {:keychain, reason}} -> failure(:keychain, reason)
      {:error, reason} -> failure(stage, reason)
      _ -> failure(stage, :unexpected)
    end
  rescue
    _ -> failure(stage, :unexpected)
  catch
    _, _ -> failure(stage, :unexpected)
  end

  def failure(stage, reason) do
    stage = if stage in @stages, do: stage, else: :callback
    reason = if reason in @reasons, do: reason, else: :unavailable
    stage = if reason == :keychain, do: :keychain, else: stage
    Logger.warning("MONOLITH Google connection failed (#{stage}: #{reason}); #{hint(stage)}")
    {:error, {stage, reason}}
  end

  def failure_path({stage, reason}) when stage in @stages and reason in @reasons,
    do:
      "/connections/gmail?" <> URI.encode_query(%{gmail: "failed", stage: stage, reason: reason})

  def failure_path(_), do: "/connections/gmail?gmail=failed"

  def message(stage, reason) when is_binary(stage) and is_binary(reason) do
    case Enum.find(@stages, &(Atom.to_string(&1) == stage)) do
      nil -> "Google connection was not completed. Check setup and try again."
      known -> "Google connection failed (#{known}). " <> hint(known)
    end
  end

  def message(_, _), do: "Google connection was not completed. Check setup and try again."

  defp hint(:session), do: "Unlock LOVELACE at localhost and start a new connection."

  defp hint(:state),
    do:
      "The connection attempt expired or belongs to another session. Start again without restarting the app during consent."

  defp hint(:consent),
    do: "Google consent was not completed. Start again and grant the requested read-only access."

  defp hint(:code), do: "Start a new connection from LOVELACE; do not reuse a callback URL."

  defp hint(:token_exchange),
    do: "Check the OAuth client ID/secret and restart with dotenvx before trying again."

  defp hint(:identity),
    do: "Google identity could not be verified. Check the OpenID and userinfo.email grants."

  defp hint(:account_binding), do: "Choose the same Google account when reconnecting."

  defp hint(:refresh_token),
    do: "Google did not provide reusable offline access. Start a new consent flow."

  defp hint(:keychain),
    do:
      "Unlock LOVELACE and check its dedicated keychain access. Helper rebuilds can invalidate item approvals; see docs/GMAIL.md before rebuilding or reconnecting."

  defp hint(:connection),
    do: "The local account could not be saved. Check migrations and local storage availability."

  defp hint(_), do: "Start a new connection from LOVELACE and retry."
end
