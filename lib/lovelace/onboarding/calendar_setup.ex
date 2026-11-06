defmodule Lovelace.Onboarding.CalendarSetup do
  @moduledoc "Owner-only Calendar catalog setup for the guide; provider work stays in queued Calendar actions."

  alias Lovelace.Calendar
  alias Lovelace.Google.Access
  alias Lovelace.Mail
  alias Lovelace.Mail.{Account, WorkspaceAccount}
  alias Lovelace.Onboarding

  @doc "Reads only current-account catalog metadata, never cached events or provider data."
  def read(opts \\ []) do
    opts = owner_options(opts)

    case Onboarding.connection(opts) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, %{id: id, generation: generation}} ->
        serialized(id, fn -> read_current(id, generation, opts) end)

      error ->
        error
    end
  end

  defp read_current(id, generation, opts) do
    with {:ok, workspace, account} <- current(opts),
         true <- account.id == id and account.generation == generation do
      metadata(workspace, account, opts)
    else
      false -> {:error, :stale_connection}
      error -> error
    end
  end

  @doc "Prepares a browser-local day; refresh?: true requests a bounded manual read even before due."
  def prepare(account_id, generation, window_params, opts \\ []) do
    {refresh?, opts} = Keyword.pop(opts, :refresh?, false)

    with {:ok, window} <- window_params(window_params) do
      mutate(account_id, generation, opts, fn ash_opts ->
        account_id
        |> Calendar.prepare(
          window["from"],
          window["to"],
          window["date"],
          window["timezone"],
          ash_opts
        )
        |> maybe_refresh(refresh?, account_id, ash_opts)
      end)
    end
  end

  defp maybe_refresh({:ok, %{enabled: true, loading: false}}, true, account_id, opts),
    do: Calendar.refresh(account_id, opts)

  defp maybe_refresh(result, _refresh?, _account_id, _opts), do: result

  @doc "Saves an explicit selection, including [], using Calendar's catalog and size validation."
  def select(account_id, generation, ids, opts \\ []) do
    if is_list(ids) and Enum.all?(ids, &is_binary/1) do
      mutate(account_id, generation, opts, fn ash_opts ->
        Calendar.select_calendars(account_id, ids, ash_opts)
      end)
    else
      {:error, :invalid_selection}
    end
  end

  defp mutate(account_id, generation, opts, action) do
    {workspace_id, opts} = Keyword.pop(opts, :workspace_id)
    opts = owner_options(opts)

    with {:ok, ^account_id} <- Ecto.UUID.cast(account_id),
         {:ok, ^generation} <- Ecto.UUID.cast(generation),
         {:ok, ^workspace_id} <- Ecto.UUID.cast(workspace_id) do
      serialized(account_id, fn ->
        mutate_current(workspace_id, account_id, generation, opts, action)
      end)
    else
      _ -> {:error, :stale_connection}
    end
  end

  defp mutate_current(workspace_id, account_id, generation, opts, action) do
    with {:ok, %{id: ^workspace_id} = workspace, account} <- current(opts),
         true <- account.id == account_id and account.generation == generation,
         :ok <- action_result(action.(opts)) do
      metadata(workspace, account, opts)
    else
      false -> {:error, :stale_connection}
      {:ok, _, _} -> {:error, :stale_connection}
      error -> error
    end
  end

  defp action_result({:ok, %{enabled: true}}), do: :ok
  defp action_result({:ok, %{error: :unavailable}}), do: {:error, :unavailable}
  defp action_result({:ok, _}), do: {:error, :stale_connection}
  defp action_result(error), do: error

  defp current(opts) do
    with {:ok, workspace} when not is_nil(workspace) <- Onboarding.workspace(opts),
         {:ok, %{id: id, generation: generation}} <- Onboarding.connection(opts),
         {:ok, %{generation: ^generation} = account} <- account(id, opts) do
      {:ok, workspace, account}
    else
      {:ok, _} -> {:error, :stale_connection}
      error -> error
    end
  end

  defp account(id, opts), do: Mail.get_account(id, opts)

  defp metadata(workspace, account, opts) do
    case Calendar.catalog(account.id, opts) do
      {:ok, catalog} -> {:ok, Map.put(catalog, :workspace_id, workspace.id)}
      error -> error
    end
  end

  defp window_params(params) when is_map(params) do
    keys = ["from", "to", "date", "timezone"]

    if Enum.all?(keys, &is_binary(params[&1])),
      do: {:ok, Map.take(params, keys)},
      else: {:error, :invalid_window}
  end

  defp window_params(_), do: {:error, :invalid_window}

  defp owner_options(opts), do: Keyword.put(opts, :authorize?, true)

  # Association reads and Calendar writes share the SQLite transaction.
  # Reconnects use the same account lock; detach/workspace changes cannot commit
  # between a mutation's identity fence and its write.
  defp serialized(account_id, fun),
    do: Access.serial(account_id, fn -> transact(fun) end)

  defp transact(fun) do
    case Ash.transact([Onboarding.State, Account, WorkspaceAccount], fun) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end
end
