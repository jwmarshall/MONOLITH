defmodule Lovelace.Onboarding.CalendarSetup do
  @moduledoc "Owner-only Calendar catalog setup for the guide; provider work stays in queued Calendar actions."

  alias Lovelace.Calendar
  alias Lovelace.Calendar.{Payload, Snapshot, State}
  alias Lovelace.Mail.{Account, Connections, WorkspaceAccount}
  alias Lovelace.Mail.Operations, as: MailOperations
  alias Lovelace.Onboarding

  @catalog_fields [
    :account_id,
    :generation,
    :calendars,
    :selected_ids,
    :catalog_at,
    :truncated,
    :selection_truncated,
    :loading,
    :error,
    :cooldown_until
  ]

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
         true <- Snapshot.enabled?(account),
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

  defp account(id, opts) do
    Account
    |> Ash.Query.for_read(:scoped, %{account_id: id})
    |> Ash.Query.select([:generation, :calendar_enabled, :status, :last_error, :next_poll_at])
    |> Ash.read_one(opts)
  end

  defp metadata(workspace, account, opts) do
    State
    |> Ash.Query.for_read(:read, %{account_id: account.id})
    |> Ash.Query.select(@catalog_fields)
    |> Ash.read_one(opts)
    |> case do
      {:ok, cached} -> {:ok, build_metadata(workspace, account, cached)}
      error -> error
    end
  end

  defp build_metadata(workspace, account, cached) do
    enabled = Snapshot.enabled?(account)
    cached = if Snapshot.current?(account, cached), do: cached
    fresh = catalog_fresh?(cached)
    cooldown = MailOperations.cooldown?(account) or cooling?(cached)
    error = metadata_error(account, cached, cooldown)

    %{
      workspace_id: workspace.id,
      account_id: account.id,
      generation: account.generation,
      enabled: enabled,
      loading: loading?(cached, cooldown),
      error: error,
      catalog_at: cached && cached.catalog_at,
      catalog_fresh?: fresh,
      cooldown_until: cooldown_until(account, cached),
      available?: enabled and fresh and error != :reconnect
    }
    |> Map.merge(catalog_fields(cached, fresh))
  end

  defp catalog_fresh?(nil), do: false
  defp catalog_fresh?(cached), do: Snapshot.recent?(cached.catalog_at)

  defp loading?(%{loading: true}, false), do: true
  defp loading?(_, _), do: false

  defp metadata_error(%{status: :reconnect}, _, _), do: :reconnect
  defp metadata_error(_, _, true), do: :rate_limited
  defp metadata_error(_, nil, _), do: nil
  defp metadata_error(_, cached, _), do: cached.error

  defp catalog_fields(cached, true) do
    %{
      calendars: Enum.map(cached.calendars, &Payload.display(&1, [:id, :name])),
      selected_ids: cached.selected_ids,
      truncated: !!cached.truncated,
      selection_truncated: !!cached.selection_truncated
    }
  end

  defp catalog_fields(_, false),
    do: %{calendars: [], selected_ids: [], truncated: false, selection_truncated: false}

  defp cooling?(%{cooldown_until: %DateTime{} = until}),
    do: DateTime.compare(until, DateTime.utc_now()) == :gt

  defp cooling?(_), do: false

  defp cooldown_until(account, cached) do
    gmail = if MailOperations.cooldown?(account), do: account.next_poll_at
    calendar = if cooling?(cached), do: cached.cooldown_until

    case {gmail, calendar} do
      {nil, until} -> until
      {until, nil} -> until
      {first, second} -> if DateTime.compare(first, second) == :gt, do: first, else: second
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
    do: Connections.serial(account_id, fn -> transact(fun) end)

  defp transact(fun) do
    case Ash.transact([Onboarding.State, State, Account, WorkspaceAccount], fun) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end
end
