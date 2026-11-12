defmodule Monolith.Google.Access do
  @moduledoc """
  Shared Google identity, credential and grant coordination for Gmail and Calendar.

  One account/subject serializer owns grant replacement, refresh-token rotation,
  disconnect fencing and synchronous Calendar reset. Tokens remain in the dedicated
  credential adapter or the admitted caller's memory, never Ash inputs, SQL or jobs.
  Account resources remain exposed through Mail's supported resource actions.
  """
  alias Monolith.Mail
  alias Monolith.Mail.{Account, PollWorker, WorkspaceAccount}
  @owner %{role: :local_owner}

  @doc "Serializes shared connection work; nested calls by the same process are supported."
  def serial(id, fun), do: :global.trans({{__MODULE__, id}, self()}, fun, [node()])

  def accept(workspace_id, identity, refresh_token),
    do: accept(workspace_id, identity, refresh_token, :gmail)

  def accept(workspace_id, identity, refresh_token, capability),
    do: accept(workspace_id, identity, refresh_token, capability, nil)

  def accept(workspace_id, identity, refresh_token, capability, expected_generation),
    do: accept(workspace_id, identity, refresh_token, capability, expected_generation, :any)

  @doc "Publishes a grant only if its captured subject connection still matches under both locks."
  def accept(
        workspace_id,
        %{subject: subject, email: email},
        refresh_token,
        capability,
        expected_generation,
        expected_connection
      )
      when (refresh_token == :reuse_existing or
              (is_binary(refresh_token) and byte_size(refresh_token) > 0)) and
             capability in [:gmail, :calendar] do
    case Monolith.Workspaces.get_workspace(workspace_id, actor: @owner) do
      {:ok, _} ->
        serial({:subject, :crypto.hash(:sha256, subject)}, fn ->
          accept_identity(
            workspace_id,
            subject,
            email,
            refresh_token,
            capability,
            expected_generation,
            expected_connection
          )
        end)

      _ ->
        {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def accept(_, _, _, _, _, _), do: {:error, :reconnect}

  defp accept_identity(
         workspace_id,
         subject,
         email,
         token,
         capability,
         expected_generation,
         expected_connection
       ) do
    with {:ok, previous} <- Mail.find_account(subject, actor: @owner) do
      id = if previous, do: previous.id, else: Ash.UUID.generate()

      serial(id, fn ->
        commit(
          workspace_id,
          id,
          subject,
          email,
          token,
          capability,
          expected_generation,
          expected_connection
        )
      end)
    end
  end

  defp commit(
         workspace_id,
         id,
         subject,
         email,
         token,
         capability,
         expected_generation,
         expected_connection
       ) do
    with :ok <- expected_connection(subject, id, expected_connection),
         :ok <- current_grant(id, capability, expected_generation),
         {:ok, prior} <- read_prior(id),
         :ok <- persist_token(id, token, prior) do
      case persist_connection(workspace_id, id, subject, email, capability) do
        {:ok, account} ->
          reset(id)
          PollWorker.enqueue(account)
          Phoenix.PubSub.broadcast(Monolith.PubSub, "mail:#{id}", {:mail_changed, id})
          {:ok, account}

        _ ->
          restore_failure(id, prior)
      end
    end
  end

  defp expected_connection(_, _, :any), do: :ok

  defp expected_connection(subject, _, :absent) do
    case Mail.find_account(subject, actor: @owner) do
      {:ok, nil} -> :ok
      _ -> {:error, :reconnect}
    end
  end

  defp expected_connection(subject, id, %{id: expected_id, generation: generation})
       when id == expected_id do
    case Mail.find_account(subject, actor: @owner) do
      {:ok, %{id: ^id, generation: ^generation}} -> :ok
      _ -> {:error, :reconnect}
    end
  end

  defp expected_connection(_, _, _), do: {:error, :reconnect}

  # Optional consent cannot resurrect a disconnected or replaced generation.
  defp current_grant(id, :calendar, expected) when not is_nil(expected) do
    if current?(id, expected), do: :ok, else: {:error, :reconnect}
  end

  # A deliberately disconnected account may reconnect, but an old callback may
  # never replace a generation installed after its admission.
  defp current_grant(id, :gmail, expected) when not is_nil(expected) do
    case Mail.get_account(id, actor: @owner) do
      {:ok, %{generation: ^expected}} -> :ok
      _ -> {:error, :reconnect}
    end
  end

  defp current_grant(_, _, _), do: :ok

  @doc "Checks the immutable shared generation without accessing credentials."
  def current?(id, generation) do
    case Mail.get_account(id, actor: @owner) do
      {:ok, %{generation: ^generation, status: status}} when status != :disconnected -> true
      _ -> false
    end
  end

  @doc "Resets dependent Calendar state synchronously; caller holds serial/2."
  def reset(id), do: Monolith.Calendar.clear(id)

  defp restore_failure(id, prior) do
    case restore(id, prior) do
      :ok -> {:error, :unavailable}
      _ -> {:error, {:keychain, :rollback_failed}}
    end
  end

  defp persist_connection(workspace_id, id, subject, email, capability) do
    Ash.transact([Account, WorkspaceAccount], fn ->
      account =
        Mail.save_connection!(
          %{
            id: id,
            subject: subject,
            email: email,
            generation: Ash.UUID.generate(),
            calendar_enabled: capability == :calendar
          },
          actor: @owner
        )

      Mail.attach_account!(%{workspace_id: workspace_id, account_id: account.id}, actor: @owner)
      account
    end)
  rescue
    _ -> {:error, :unavailable}
  end

  defp read_prior(id) do
    case vault().get(id) do
      {:ok, value} -> {:ok, {:present, value}}
      {:error, :not_found} -> {:ok, :absent}
      {:error, reason} -> {:error, {:keychain, reason}}
      _ -> {:error, {:keychain, :unavailable}}
    end
  end

  # Resolve reuse under the shared account lock, never from an earlier callback snapshot.
  defp persist_token(_, :reuse_existing, {:present, token})
       when is_binary(token) and byte_size(token) > 0, do: :ok

  defp persist_token(_, :reuse_existing, _), do: {:error, :reconnect}
  defp persist_token(id, token, _), do: write_token(id, token)

  defp write_token(id, token) do
    case vault().put(id, token) do
      :ok -> :ok
      {:error, reason} -> {:error, {:keychain, reason}}
      _ -> {:error, {:keychain, :unavailable}}
    end
  end

  defp restore(id, {:present, value}), do: vault().put(id, value)
  defp restore(id, :absent), do: vault().delete(id)

  @doc "Reports only safe local credential status; does not refresh or probe Google."
  def check_credentials(id, generation) do
    if current?(id, generation) do
      status = credential_status(id)
      if current?(id, generation), do: status, else: :changed
    else
      :changed
    end
  end

  defp credential_status(id) do
    case vault().get(id) do
      {:ok, token} when is_binary(token) and byte_size(token) > 0 ->
        :accessible

      {:error, reason}
      when reason in [
             :not_found,
             :locked,
             :timeout,
             :unavailable,
             :invalid_account,
             :invalid_value
           ] ->
        reason

      _ ->
        :unavailable
    end
  rescue
    _ -> :unavailable
  catch
    _, _ -> :unavailable
  end

  @doc "Refreshes the shared credential only for the current ready, admitted generation."
  def access_token(account) do
    serial(account.id, fn ->
      actor = %{role: :mail_service, account_id: account.id}

      with {:ok, current} <-
             Account
             |> Ash.Query.for_read(:scoped, %{account_id: account.id}, actor: actor)
             |> Ash.read_one(),
           true <- current && current.status == :ready && current.generation == account.generation,
           false <- cooldown?(current),
           {:ok, refresh_token} <- credential(account.id),
           {:ok, tokens} <- provider().refresh(refresh_token),
           :ok <- rotate(account.id, tokens) do
        {:ok, tokens.access_token}
      else
        true -> {:error, :cooldown}
        false -> {:error, :unavailable}
        nil -> {:error, :unavailable}
        {:error, :not_found} -> {:error, :reconnect}
        {:error, reason} -> {:error, reason}
        _ -> {:error, :keychain}
      end
    end)
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Shared credential admission gate; Calendar retains its own provider cooldown separately."
  def cooldown?(%{last_error: :rate_limited, next_poll_at: %DateTime{} = deadline}),
    do: DateTime.compare(deadline, DateTime.utc_now()) == :gt

  def cooldown?(_), do: false

  defp credential(id) do
    case vault().get(id) do
      {:ok, token} -> {:ok, token}
      {:error, :not_found} -> {:error, :not_found}
      _ -> {:error, :keychain}
    end
  end

  defp rotate(id, %{refresh_token: token}) when is_binary(token) and byte_size(token) > 0 do
    if vault().put(id, token) == :ok, do: :ok, else: {:error, :keychain}
  end

  defp rotate(_, _), do: :ok

  @doc false
  def provider, do: Application.get_env(:monolith, :gmail_provider, Monolith.Integrations.Google)

  @doc false
  def vault,
    do: Application.get_env(:monolith, :gmail_vault, Monolith.Integrations.Google.Keychain)
end
