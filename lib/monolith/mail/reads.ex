defmodule Monolith.Mail.Reads do
  @moduledoc false
  require Ash.Query
  alias Monolith.Mail
  alias Monolith.Mail.{ReadRequest, ReadWorker, RequestOwners, ViewData}
  alias Monolith.Security.Vault
  @owner %{role: :local_owner}
  @limit 128

  def request(args, actor) do
    with true <- args.owner == self(),
         {:ok, %{status: status, generation: generation}} <-
           Mail.get_account(args.account_id, actor: actor),
         true <- status != :disconnected,
         true <- authorized?(Map.get(args, :workspace_id), args.account_id, actor),
         true <- args.kind != :credentials or args.generation == generation,
         id = Ash.UUID.generate(),
         {:ok, previous} <- RequestOwners.register(id, args.owner) do
      admit_registered(args, actor, id, generation, previous)
    else
      _ -> {:error, :unavailable}
    end
  end

  defp admit_registered(args, actor, id, generation, previous) do
    args
    |> persist_request(actor, id, generation, previous)
    |> accepted(id)
  rescue
    _ -> admission_failed(id)
  catch
    _, _ -> admission_failed(id)
  end

  defp persist_request(args, actor, id, generation, previous) do
    Ash.transact(ReadRequest, fn ->
      prune()
      previous_job = supersede(previous)

      if Ash.count!(ReadRequest, actor: @owner) >= @limit,
        do: Ash.DataLayer.rollback(ReadRequest, :busy)

      attrs = %{
        id: id,
        account_id: args.account_id,
        generation: generation,
        workspace_id: Map.get(args, :workspace_id),
        kind: args.kind,
        input: Map.take(args, [:query, :page_token, :thread_id, :force]),
        expires_at: DateTime.add(DateTime.utc_now(), 600)
      }

      request =
        ReadRequest
        |> Ash.Changeset.for_create(:request, attrs, actor: actor)
        |> Ash.create!()

      job = Oban.insert!(ReadWorker.new(%{operation_id: id}))
      {update(request, %{job_id: job.id}), previous_job}
    end)
  end

  defp accepted({:ok, {request, previous_job}}, id) do
    RequestOwners.commit(id)
    cancel_superseded(previous_job)
    {:ok, %{operation_id: request.id, job_id: request.job_id, state: :pending}}
  end

  defp accepted(_, id), do: admission_failed(id)

  defp admission_failed(id) do
    RequestOwners.rollback(id)
    {:error, :unavailable}
  end

  def observe(id, actor) do
    case Ash.get(ReadRequest, id, actor: actor) do
      {:ok, request} when not is_nil(request) ->
        observe_current(request)

      _ ->
        {:ok, %{operation_id: id, state: :expired}}
    end
  end

  defp observe_current(request) do
    if current?(request) and RequestOwners.owner(request.id) == self(),
      do: observation(request),
      else: {:ok, %{operation_id: request.id, state: :expired}}
  end

  defp observation(request) do
    result = if request.state == :complete, do: RequestOwners.result(request.id)
    state = if request.state == :complete and is_nil(result), do: :expired, else: request.state
    {:ok, %{operation_id: request.id, job_id: request.job_id, state: state, result: result}}
  end

  def cancel(id) do
    if RequestOwners.owner(id) == self(), do: cancel_owned(id), else: true
  end

  defp cancel_owned(id) do
    case Ash.transact(ReadRequest, fn -> supersede(id) end) do
      {:ok, job} ->
        RequestOwners.release()
        cancel_superseded(job)
        true

      _ ->
        false
    end
  end

  def perform(id) do
    Vault.with_access(fn -> execute(id) end)
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp execute(id) do
    case Ash.get(ReadRequest, id, actor: @owner) do
      {:ok, %{state: :pending} = request} -> execute_pending(request)
      _ -> :ok
    end
  end

  defp execute_pending(request) do
    if current?(request) and is_pid(RequestOwners.owner(request.id)) do
      request |> fetch() |> publish_current(request)
    else
      update(request, %{state: :expired, input: %{}})
    end

    :ok
  end

  defp publish_current(result, request) do
    case Ash.get(ReadRequest, request.id, actor: @owner) do
      {:ok, %{state: :pending} = current} -> settle_result(result, current)
      _ -> :ok
    end
  end

  defp settle_result(result, request) do
    if is_pid(RequestOwners.owner(request.id)) and current?(request) do
      safe = protect(result, request)
      publish_staged(request, safe)
    else
      update(request, %{state: :expired, input: %{}})
    end
  end

  defp publish_staged(request, safe) do
    with :ok <- RequestOwners.stage(request.id, safe) do
      update(request, %{state: :complete, input: %{}, outcome: outcome(safe)})
      RequestOwners.publish(request.id)
    end
  end

  def prune do
    ReadRequest
    |> Ash.Query.filter(expires_at <= ^DateTime.utc_now())
    |> Ash.Query.limit(@limit)
    |> Ash.read!(actor: @owner)
    |> Enum.each(&Ash.destroy!(&1, actor: @owner))

    :ok
  end

  defp supersede(nil), do: nil

  defp supersede(id) do
    case Ash.get(ReadRequest, id, actor: @owner) do
      {:ok, nil} ->
        nil

      {:ok, request} ->
        Ash.destroy!(request, actor: @owner)
        request.job_id

      _ ->
        nil
    end
  end

  # Queue compaction is best-effort after commit; the removed request already
  # fences provider execution and result publication even if cancellation fails.
  defp cancel_superseded(nil), do: :ok

  defp cancel_superseded(job) do
    Oban.cancel_job(job)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp authorized?(nil, _, %{role: :local_owner}), do: true

  defp authorized?(workspace, account, actor) do
    case Mail.workspace_accounts(workspace, actor: actor) do
      {:ok, memberships} -> Enum.any?(memberships, &(&1.account_id == account))
      _ -> false
    end
  end

  defp current?(request) do
    DateTime.compare(request.expires_at, DateTime.utc_now()) == :gt and
      authorized?(request.workspace_id, request.account_id, @owner) and
      match?(
        {:ok, %{generation: generation, status: status}}
        when generation == request.generation and status != :disconnected,
        Mail.get_account(request.account_id, actor: @owner)
      )
  end

  defp fetch(%{kind: :credentials} = request),
    do: Mail.check_credentials(request.account_id, request.generation, actor: @owner)

  defp fetch(request) do
    options =
      for key <- [:query, :page_token, :force],
          value = request.input[Atom.to_string(key)],
          not is_nil(value),
          into: %{},
          do: {key, value}

    thread = request.input["thread_id"]

    case {request.workspace_id, request.kind} do
      {nil, :page} ->
        Mail.account_page(request.account_id, options, actor: @owner)

      {nil, :thread} ->
        Mail.account_thread(request.account_id, thread, Map.take(options, [:force]),
          actor: @owner
        )

      {workspace, :page} ->
        Mail.mail_page(workspace, request.account_id, options, actor: @owner)

      {workspace, :thread} ->
        Mail.thread(workspace, request.account_id, thread, Map.take(options, [:force]),
          actor: @owner
        )
    end
  end

  defp protect({:ok, %{data: data} = result}, request) when is_map(data) do
    case RequestOwners.owner(request.id) do
      owner when is_pid(owner) ->
        scope = Map.take(request, [:account_id, :generation, :workspace_id])

        {:ok,
         result |> Map.put(:data, nil) |> Map.put(:data_ref, ViewData.put(data, owner, scope))}

      _ ->
        {:ok, %{error: :unavailable}}
    end
  end

  defp protect({:ok, result}, _) when is_map(result), do: {:ok, result}
  defp protect(_, _), do: {:ok, %{error: :unavailable}}

  defp outcome({:ok, result}) do
    result |> Map.take([:error, :status, :cached, :stale])
  end

  defp update(request, attrs),
    do: request |> Ash.Changeset.for_update(:settle, attrs, actor: @owner) |> Ash.update!()
end
