defmodule Lovelace.Mail.Operations do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  require Ash.Query

  alias Lovelace.Mail
  alias Lovelace.Mail.{Account, CacheEntry, Connections, WorkspaceAccount}

  @max_entries 120
  @max_bytes 25 * 1024 * 1024
  @ttl 7 * 24 * 60 * 60

  @impl true
  def run(input, _, context) do
    execute(input.action.name, input.arguments, context.actor)
  rescue
    _ -> {:ok, failure(:unavailable)}
  catch
    _, _ -> {:ok, failure(:unavailable)}
  end

  defp execute(:link, args, actor) do
    with {:ok, _} <- Lovelace.Workspaces.get_workspace(args.workspace_id, actor: actor),
         {:ok, %{status: :ready}} <- Mail.get_account(args.account_id, actor: actor),
         {:ok, _} <-
           Mail.attach_account(Map.take(args, [:workspace_id, :account_id]), actor: actor) do
      {:ok, true}
    else
      _ -> {:ok, false}
    end
  end

  defp execute(:unlink, args, actor) do
    memberships(args.workspace_id, actor)
    |> Enum.filter(&(&1.account_id == args.account_id))
    |> Enum.each(&Mail.detach_account!(&1, actor: actor))

    broadcast(args.account_id)
    {:ok, true}
  end

  defp execute(:disconnect, args, actor) do
    with {:ok, account} <- Mail.get_account(args.account_id, actor: actor) do
      Connections.serial(account.id, fn ->
        disconnect(Mail.get_account!(account.id, actor: actor), actor)
      end)
    end
  end

  defp execute(:poll, args, %{role: :mail_service, account_id: id} = actor)
       when id == args.account_id do
    case scoped_account(id, actor) do
      {:ok, %{status: :ready, generation: generation} = account}
      when generation == args.generation ->
        result =
          fetch(
            account,
            page_key(nil, nil),
            fn token -> provider().inbox(token, nil) end,
            true,
            actor
          )

        broadcast(id)
        {:ok, result}

      _ ->
        {:ok, %{skipped: true}}
    end
  end

  defp execute(:poll, _, _), do: {:ok, failure(:unavailable)}

  defp execute(action, args, actor) when action in [:page, :thread] do
    with true <- member?(args.workspace_id, args.account_id, actor),
         {:ok, %{status: :ready} = account} <- Mail.get_account(args.account_id, actor: actor) do
      {key, request} = request(action, args)
      result = fetch(account, key, request, args.force, actor)

      # A detach/disconnect or reconnect while HTTP was running invalidates the result.
      if member?(args.workspace_id, args.account_id, actor) and same_connection?(account, actor) do
        {:ok, result}
      else
        {:ok, failure(:unavailable)}
      end
    else
      {:ok, %{status: :reconnect}} -> {:ok, failure(:reconnect)}
      _ -> {:ok, failure(:unavailable)}
    end
  end

  defp request(:page, args) do
    query = Map.get(args, :query)
    page = Map.get(args, :page_token)

    fun =
      if query in [nil, ""],
        do: fn token -> provider().inbox(token, page) end,
        else: fn token -> provider().search(token, query, page) end

    {page_key(query, page), fun}
  end

  defp request(:thread, args),
    do: {"thread:" <> args.thread_id, fn token -> provider().thread(token, args.thread_id) end}

  defp page_key(query, page),
    do:
      "page:" <> Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary({query || "", page})))

  defp fetch(account, key, request, force, actor) do
    prune(account.id, actor)
    cached = cache(account, key, actor)

    case current_account(account, actor) do
      {:ok, current} ->
        cond do
          cooldown?(current) ->
            cached_failure(cached, :rate_limited)

          cached && !force && DateTime.diff(DateTime.utc_now(), cached.fetched_at) < 180 ->
            cached_result(cached, true, current)

          true ->
            fetch_remote(current, key, request, cached, actor)
        end

      _ ->
        failure(:unavailable)
    end
  end

  defp fetch_remote(account, key, request, cached, actor) do
    with {:ok, token} <- Connections.access_token(account),
         :ok <- admit_request(account, actor),
         {:ok, payload} <- request.(token),
         {:ok, entry} <- publish(account, key, payload, actor),
         {:ok, current} <- current_account(account, actor) do
      cached_result(entry, false, current)
    else
      # Admission refusal is not a fresh provider 429. In particular, if its
      # deadline expires before this branch runs, do not create a new cooldown.
      {:error, :cooldown} -> cached_failure(cached, :rate_limited)
      {:error, reason} -> failed_fetch(account, cached, reason, actor)
      _ -> failed_fetch(account, cached, :unavailable, actor)
    end
  end

  defp admit_request(account, actor) do
    with {:ok, current} <- current_account(account, actor) do
      if cooldown?(current), do: {:error, :cooldown}, else: :ok
    end
  end

  @doc false
  def cooldown?(%{last_error: :rate_limited, next_poll_at: %DateTime{} = deadline}),
    do: DateTime.compare(deadline, DateTime.utc_now()) == :gt

  def cooldown?(_), do: false

  defp cached_result(entry, cached, %{last_error: error}) when not is_nil(error),
    do: Map.merge(result(entry, cached), %{error: error, stale: true})

  defp cached_result(entry, cached, _), do: result(entry, cached)

  defp cached_failure(nil, reason), do: failure(reason)

  defp cached_failure(entry, reason),
    do: Map.merge(result(entry, true), %{error: reason, stale: true})

  defp failed_fetch(account, cached, reason, actor) do
    reason = safe_reason(reason)

    # Keep the latest failure/cooldown read and its write in one short SQLite
    # transaction, so a concurrent failure cannot overwrite a newer rate limit.
    Ash.transact(Account, fn -> persist_failure(account, reason, actor) end)
    cached_failure(cached, reason)
  end

  defp persist_failure(account, reason, actor) do
    case current_account(account, actor) do
      {:ok, current} ->
        Mail.update_account(current, failure_fields(current, reason), actor: actor)

      _ ->
        :ok
    end
  end

  defp failure_fields(current, reason) do
    # Reads already in flight must not shorten or extend a known cooldown.
    if cooldown?(current) do
      %{
        expected_generation: current.generation,
        last_error: :rate_limited,
        next_poll_at: current.next_poll_at
      }
    else
      fields = %{
        expected_generation: current.generation,
        last_error: reason,
        next_poll_at:
          DateTime.add(DateTime.utc_now(), if(reason == :rate_limited, do: 300, else: 180))
      }

      if reason == :reconnect, do: Map.put(fields, :status, :reconnect), else: fields
    end
  end

  defp publish(account, key, payload, actor) do
    json = Jason.encode!(payload)

    if byte_size(json) > 5 * 1024 * 1024 do
      {:error, :provider}
    else
      Ash.transact([Account, CacheEntry], fn -> publish_current(account, key, json, actor) end)
    end
  end

  defp publish_current(account, key, json, actor) do
    case current_account(account, actor) do
      {:ok, current} ->
        now = DateTime.utc_now()
        limited = cooldown?(current)

        entry =
          CacheEntry
          |> Ash.Changeset.for_create(
            :store,
            %{
              account_id: account.id,
              key: key,
              payload: Jason.decode!(json),
              bytes: byte_size(json),
              generation: account.generation,
              fetched_at: now,
              expires_at: DateTime.add(now, @ttl)
            },
            actor: actor
          )
          |> Ash.create!()

        Mail.update_account!(
          account,
          %{
            expected_generation: account.generation,
            last_success_at: now,
            last_error: if(limited, do: :rate_limited, else: nil),
            next_poll_at: if(limited, do: current.next_poll_at, else: DateTime.add(now, 180))
          },
          actor: actor
        )

        prune(account.id, actor)
        entry

      _ ->
        {:error, :unavailable}
    end
  end

  defp result(entry, cached),
    do: %{
      data: entry.payload,
      fetched_at: entry.fetched_at,
      cached: cached,
      stale: DateTime.diff(DateTime.utc_now(), entry.fetched_at) >= 180,
      error: nil
    }

  defp failure(reason), do: %{data: nil, error: reason, stale: true, fetched_at: nil}

  defp cache(account, key, actor) do
    CacheEntry
    |> Ash.Query.for_read(:read, %{account_id: account.id}, actor: actor)
    |> Ash.Query.filter(
      key == ^key and generation == ^account.generation and expires_at > ^DateTime.utc_now()
    )
    |> Ash.read_one!()
  end

  @doc false
  def prune(account_id, actor) do
    entries =
      CacheEntry
      |> Ash.Query.for_read(:read, %{account_id: account_id}, actor: actor)
      |> Ash.Query.sort(fetched_at: :desc, id: :desc)
      |> Ash.Query.select([:account_id, :bytes, :expires_at, :fetched_at])
      |> Ash.read!()

    _retained =
      Enum.reduce(entries, {0, 0}, fn entry, {count, bytes} = retained ->
        if DateTime.compare(entry.expires_at, DateTime.utc_now()) != :gt or
             count >= @max_entries or bytes + entry.bytes > @max_bytes do
          entry |> Ash.Changeset.for_destroy(:evict, %{}, actor: actor) |> Ash.destroy!()
          retained
        else
          {count + 1, bytes + entry.bytes}
        end
      end)

    :ok
  end

  defp disconnect(account, actor) do
    credential = vault().get(account.id)

    {:ok, _} =
      Ash.transact([Account, CacheEntry, WorkspaceAccount], fn ->
        Mail.update_account!(
          account,
          %{
            expected_generation: account.generation,
            status: :disconnected,
            generation: Ash.UUID.generate(),
            # Persist cleanup intent before crossing the nontransactional vault boundary.
            last_error: :keychain
          },
          actor: actor
        )

        CacheEntry
        |> Ash.Query.for_read(:read, %{account_id: account.id}, actor: actor)
        |> Ash.read!()
        |> Enum.each(fn e ->
          e |> Ash.Changeset.for_destroy(:evict, %{}, actor: actor) |> Ash.destroy!()
        end)

        WorkspaceAccount
        |> Ash.Query.for_read(:for_account, %{account_id: account.id}, actor: actor)
        |> Ash.read!()
        |> Enum.each(&Mail.detach_account!(&1, actor: actor))

        true
      end)

    deleted = vault().delete(account.id) == :ok

    current = Mail.get_account!(account.id, actor: actor)

    Mail.update_account(
      current,
      %{
        expected_generation: current.generation,
        last_error: if(deleted, do: nil, else: :keychain)
      },
      actor: actor
    )

    revoked =
      case credential do
        {:ok, token} -> provider().revoke(token) == :ok
        {:error, :not_found} -> true
        _ -> false
      end

    broadcast(account.id)
    {:ok, %{local_removed: true, credentials_removed: deleted, revoked: revoked}}
  end

  @doc false
  def member?(workspace_id, account_id, actor),
    do: Enum.any?(memberships(workspace_id, actor), &(&1.account_id == account_id))

  defp memberships(workspace_id, actor), do: Mail.workspace_accounts!(workspace_id, actor: actor)

  defp scoped_account(id, %{role: :local_owner} = actor), do: Mail.get_account(id, actor: actor)

  defp scoped_account(id, actor) do
    Account |> Ash.Query.for_read(:scoped, %{account_id: id}, actor: actor) |> Ash.read_one()
  end

  defp same_connection?(account, actor) do
    case scoped_account(account.id, actor) do
      {:ok, %{status: status, generation: generation}} when status in [:ready, :reconnect] ->
        generation == account.generation

      _ ->
        false
    end
  end

  defp current_account(account, actor) do
    case scoped_account(account.id, actor) do
      {:ok, %{status: :ready, generation: generation} = current}
      when generation == account.generation ->
        {:ok, current}

      _ ->
        {:error, :unavailable}
    end
  end

  @doc false
  def broadcast(id),
    do: Phoenix.PubSub.broadcast(Lovelace.PubSub, "mail:#{id}", {:mail_changed, id})

  @doc false
  def provider, do: Application.get_env(:lovelace, :gmail_provider, Lovelace.Integrations.Google)
  @doc false
  def vault,
    do: Application.get_env(:lovelace, :gmail_vault, Lovelace.Integrations.Google.Keychain)

  defp safe_reason(reason) when reason in [:invalid_grant, :unauthorized, :reconnect],
    do: :reconnect

  defp safe_reason(reason) when reason in [:rate_limited, :keychain, :provider], do: reason
  defp safe_reason(_), do: :unavailable
end
