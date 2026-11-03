defmodule Lovelace.Mail.Connections do
  @moduledoc "Credential lifecycle boundary: tokens never enter Ash inputs, SQL, logs or jobs."
  alias Lovelace.Mail
  alias Lovelace.Mail.{Account, Operations, PollWorker, WorkspaceAccount}
  @owner %{role: :local_owner}

  @doc false
  def serial(id, fun), do: :global.trans({{__MODULE__, id}, self()}, fun, [node()])

  def accept(workspace_id, %{subject: subject, email: email}, refresh_token)
      when is_binary(refresh_token) and byte_size(refresh_token) > 0 do
    case Lovelace.Workspaces.get_workspace(workspace_id, actor: @owner) do
      {:ok, _} ->
        serial({:subject, :crypto.hash(:sha256, subject)}, fn ->
          accept_identity(workspace_id, subject, email, refresh_token)
        end)

      _ ->
        {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def accept(_, _, _), do: {:error, :reconnect}

  defp accept_identity(workspace_id, subject, email, token) do
    with {:ok, previous} <- Mail.find_account(subject, actor: @owner) do
      id = if previous, do: previous.id, else: Ash.UUID.generate()
      serial(id, fn -> commit(workspace_id, id, subject, email, token) end)
    end
  end

  defp commit(workspace_id, id, subject, email, token) do
    with {:ok, prior} <- read_prior(id),
         :ok <- write_token(id, token) do
      case persist_connection(workspace_id, id, subject, email) do
        {:ok, account} ->
          PollWorker.enqueue(account)
          Operations.broadcast(account.id)
          {:ok, account}

        _ ->
          restore_failure(id, prior)
      end
    end
  end

  defp restore_failure(id, prior) do
    case restore(id, prior) do
      :ok -> {:error, :unavailable}
      _ -> {:error, {:keychain, :rollback_failed}}
    end
  end

  defp persist_connection(workspace_id, id, subject, email) do
    Ash.transact([Account, WorkspaceAccount], fn ->
      account =
        Mail.save_connection!(
          %{id: id, subject: subject, email: email, generation: Ash.UUID.generate()},
          actor: @owner
        )

      Mail.attach_account!(%{workspace_id: workspace_id, account_id: account.id}, actor: @owner)
      account
    end)
  rescue
    _ -> {:error, :unavailable}
  end

  defp read_prior(id) do
    case Operations.vault().get(id) do
      {:ok, value} -> {:ok, {:present, value}}
      {:error, :not_found} -> {:ok, :absent}
      {:error, reason} -> {:error, {:keychain, reason}}
      _ -> {:error, {:keychain, :unavailable}}
    end
  end

  defp write_token(id, token) do
    case Operations.vault().put(id, token) do
      :ok -> :ok
      {:error, reason} -> {:error, {:keychain, reason}}
      _ -> {:error, {:keychain, :unavailable}}
    end
  end

  defp restore(id, {:present, value}), do: Operations.vault().put(id, value)
  defp restore(id, :absent), do: Operations.vault().delete(id)

  @doc false
  def check_credentials(id, generation) do
    if diagnostic_current?(id, generation) do
      status = credential_status(id)
      if diagnostic_current?(id, generation), do: status, else: :changed
    else
      :changed
    end
  end

  defp diagnostic_current?(id, generation) do
    case Mail.get_account(id, actor: @owner) do
      {:ok, %{generation: ^generation, status: status}} when status != :disconnected -> true
      _ -> false
    end
  end

  # Only safe categories leave this boundary. Never return the token or an
  # exception/provider value to Ash, LiveView, diagnostics or task crash reports.
  # No refresh, rotation, permission prompt or persistence is performed here.
  defp credential_status(id) do
    case Operations.vault().get(id) do
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

  def access_token(account) do
    serial(account.id, fn ->
      actor = %{role: :mail_service, account_id: account.id}

      with {:ok, current} <-
             Account
             |> Ash.Query.for_read(:scoped, %{account_id: account.id}, actor: actor)
             |> Ash.read_one(),
           true <- current && current.status == :ready && current.generation == account.generation,
           :ok <- provider_admission(current),
           {:ok, refresh_token} <- credential(account.id),
           {:ok, tokens} <- Operations.provider().refresh(refresh_token),
           :ok <- rotate(account.id, tokens) do
        {:ok, tokens.access_token}
      else
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

  defp provider_admission(account) do
    if Operations.cooldown?(account), do: {:error, :cooldown}, else: :ok
  end

  defp credential(id) do
    case Operations.vault().get(id) do
      {:ok, token} -> {:ok, token}
      {:error, :not_found} -> {:error, :not_found}
      _ -> {:error, :keychain}
    end
  end

  defp rotate(id, %{refresh_token: token}) when is_binary(token) and byte_size(token) > 0 do
    if Operations.vault().put(id, token) == :ok, do: :ok, else: {:error, :keychain}
  end

  defp rotate(_, _), do: :ok
end
