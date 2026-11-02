defmodule Lovelace.Owner.Actions do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  alias Lovelace.Owner
  @service [actor: %{role: :owner_auth_service}]
  @lifetime 12 * 60 * 60

  @impl true
  def run(input, opts, _context) do
    execute(opts[:operation], input.arguments)
  rescue
    _ -> {:error, "Local unlock unavailable"}
  end

  defp execute(:configured, _) do
    case Owner.read_credential(@service) do
      {:ok, credential} -> {:ok, not is_nil(credential)}
      _ -> {:ok, false}
    end
  end

  defp execute(:unlock, %{password: password, client: client}) do
    strategy = AshAuthentication.Info.strategy!(Owner.Credential, :password)

    with true <- Owner.Throttle.allow?(client),
         {:ok, _credential} <-
           AshAuthentication.Strategy.action(strategy, :sign_in, %{
             "id" => "owner",
             "password" => password
           }),
         token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false),
         {:ok, _session} <-
           Owner.issue_session(
             digest(token),
             DateTime.add(DateTime.utc_now(), @lifetime),
             @service
           ) do
      prune_expired()
      {:ok, token}
    else
      _ -> {:error, "Unable to unlock"}
    end
  end

  defp execute(:verify, %{token: token}) do
    if valid_token?(token), do: execute(:verify_digest, %{digest: digest(token)}), else: locked()
  end

  defp execute(:verify_digest, %{digest: digest}) do
    with {:ok, credential} when not is_nil(credential) <- Owner.read_credential(@service),
         {:ok, session} when not is_nil(session) <- Owner.find_session(digest, @service),
         :gt <- DateTime.compare(session.expires_at, DateTime.utc_now()) do
      {:ok, %{digest: session.digest, expires_at: session.expires_at}}
    else
      _ -> locked()
    end
  end

  defp execute(:logout, %{token: token}) do
    if valid_token?(token) do
      case Owner.find_session(digest(token), @service) do
        {:ok, nil} -> {:ok, true}
        {:ok, session} -> revoke(session)
        _ -> {:error, "Local unlock unavailable"}
      end
    else
      {:ok, true}
    end
  end

  defp execute(:lock_all, _) do
    with {:ok, sessions} <- Owner.list_sessions(@service) do
      Enum.reduce_while(sessions, {:ok, true}, &revoke_until_error/2)
    end
  end

  defp revoke_until_error(session, _result) do
    case revoke(session) do
      {:ok, true} -> {:cont, {:ok, true}}
      error -> {:halt, error}
    end
  end

  defp revoke(session) do
    case Owner.delete_session(session, @service) do
      :ok ->
        Phoenix.PubSub.broadcast(
          Lovelace.PubSub,
          topic(session.digest),
          %Phoenix.Socket.Broadcast{
            topic: topic(session.digest),
            event: "disconnect",
            payload: %{}
          }
        )

        {:ok, true}

      _ ->
        {:error, "Local unlock unavailable"}
    end
  end

  defp prune_expired do
    case Owner.list_sessions(@service) do
      {:ok, sessions} ->
        Enum.each(sessions, &prune_session/1)

      _ ->
        :ok
    end
  end

  defp prune_session(session) do
    if DateTime.compare(session.expires_at, DateTime.utc_now()) != :gt, do: revoke(session)
  end

  defp locked, do: {:error, "Locked"}

  defp valid_token?(token),
    do: is_binary(token) and byte_size(token) == 43 and token =~ ~r/\A[A-Za-z0-9_-]+\z/

  @doc false
  def digest(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  @doc false
  def topic(digest), do: "owner_sessions:" <> digest
end
