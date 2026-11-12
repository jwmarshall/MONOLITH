defmodule Monolith.ConnectionDiagnostics.Operations do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  require Ash.Query
  alias Ash.DataLayer
  alias Monolith.ConnectionDiagnostics, as: Diagnostics
  alias Monolith.ConnectionDiagnostics.{State, Worker}
  alias Monolith.GitHub.Error, as: GitHubError
  alias Monolith.{Repo, Security.Vault}

  @actor %{role: :connection_diagnostics}
  @owner %{role: :local_owner}
  @providers [:google, :gemini, :github]

  @impl true
  def run(input, opts, _context) do
    Vault.with_access(fn ->
      case opts[:operation] do
        :request -> request(input.arguments.provider)
        :observe -> observe(input.arguments.provider, input.arguments.id)
      end
    end)
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp request(provider) do
    Ash.transact(State, fn -> request_current(provider, DateTime.utc_now()) end)
  end

  defp request_current(provider, now) do
    case get(provider) do
      {:ok, %{status: :pending, requested_at: at} = state} ->
        if DateTime.diff(now, at) < 120 && active_job?(state),
          do: public(state),
          else: enqueue(provider, now, state)

      {:ok, state} ->
        enqueue(provider, now, state)

      _ ->
        DataLayer.rollback(State, :unavailable)
    end
  end

  defp enqueue(provider, now, previous) do
    if previous && previous.job_id, do: Oban.cancel_job(previous.job_id)
    id = Ash.UUID.generate()
    delay = if previous, do: max(5 - DateTime.diff(now, previous.requested_at), 0), else: 0

    with {:ok, state} <- put(%{provider: provider, id: id, status: :pending, requested_at: now}),
         {:ok, job} <- Worker.new(%{"id" => id}, schedule_in: delay) |> Oban.insert(),
         {:ok, state} <- record(state, %{job_id: job.id}) do
      public(state)
    else
      _ -> DataLayer.rollback(State, :unavailable)
    end
  end

  defp observe(provider, id) do
    case get(provider) do
      {:ok, %{id: ^id} = state} -> {:ok, public(state)}
      _ -> {:ok, %{id: id, status: :unavailable, app_slug: nil}}
    end
  end

  def invalidate(provider) when provider in @providers do
    case Ash.transact(State, fn -> invalidate_current(provider) end) do
      {:ok, :ok} -> :ok
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp invalidate_current(provider) do
    with {:ok, previous} <- get(provider),
         {:ok, _} <-
           put(%{
             provider: provider,
             id: Ash.UUID.generate(),
             status: :unavailable,
             requested_at: ~U[1970-01-01 00:00:00.000000Z]
           }) do
      if previous && previous.job_id, do: Oban.cancel_job(previous.job_id)
      :ok
    else
      _ -> DataLayer.rollback(State, :unavailable)
    end
  end

  def perform(id) do
    Vault.with_access(fn -> perform_admitted(id) end)

    :ok
  rescue
    _ -> fail_current(id)
  catch
    _, _ -> fail_current(id)
  end

  defp perform_admitted(id) do
    case State |> Ash.Query.filter(id == ^id) |> Ash.read_one(actor: @actor) do
      {:ok, %{provider: provider}} ->
        Diagnostics.serial(provider, fn -> diagnose(provider, id) end)

      _ ->
        :ok
    end
  end

  defp fail_current(id) do
    Vault.with_access(fn ->
      case State
           |> Ash.Query.filter(id == ^id and status == :pending)
           |> Ash.read_one(actor: @actor) do
        {:ok, %State{} = state} -> record(state, %{status: :unavailable, app_slug: nil})
        _ -> :ok
      end
    end)

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp diagnose(provider, id) do
    with {:ok, %{id: ^id, status: :pending} = state} <- get(provider),
         true <- DateTime.diff(DateTime.utc_now(), state.requested_at) < 120 do
      # No database transaction spans the bounded native credential read. Credential
      # mutations share this provider lock; observations and admission never take it.
      result = diagnostic(provider)

      with {:ok, %{id: ^id, status: :pending} = current} <- get(provider),
           true <- DateTime.diff(DateTime.utc_now(), current.requested_at) < 120 do
        record(current, result)
      end
    end

    :ok
  end

  defp diagnostic(:google), do: atom_result(Monolith.Google.client_status(actor: @owner))

  defp diagnostic(:gemini),
    do: atom_result(Monolith.StageDesigner.gemini_connection_status(actor: @owner))

  defp diagnostic(:github) do
    case Monolith.GitHub.client_status(actor: @owner) do
      {:ok, %{configured?: true, app_slug: slug}} when is_binary(slug) ->
        if Regex.match?(~r/\A[a-z0-9][a-z0-9-]{0,99}\z/, slug),
          do: %{status: :stored, app_slug: slug},
          else: %{status: :invalid}

      {:ok, %{configured?: false}} ->
        %{status: :not_connected}

      {:error, :locked} ->
        %{status: :locked}

      {:error, error} ->
        %{status: github_failure_status(error)}
    end
  rescue
    _ -> %{status: :unavailable}
  catch
    _, _ -> %{status: :unavailable}
  end

  defp github_failure_status(%GitHubError{reason: :locked}), do: :locked

  defp github_failure_status(%Ash.Error.Invalid{errors: errors}) do
    if Enum.any?(errors, &match?(%GitHubError{reason: :locked}, &1)),
      do: :locked,
      else: :unavailable
  end

  defp github_failure_status(_), do: :unavailable

  defp atom_result({:ok, status})
       when status in [:stored, :not_connected, :locked, :unavailable, :invalid],
       do: %{status: status}

  defp atom_result(_), do: %{status: :unavailable}

  defp public(state) do
    status =
      if state.status == :pending &&
           (DateTime.diff(DateTime.utc_now(), state.requested_at) >= 120 || !active_job?(state)),
         do: :unavailable,
         else: state.status

    %{id: state.id, status: status, app_slug: state.app_slug}
  end

  defp active_job?(%{job_id: id}) when is_integer(id) do
    case Repo.get(Oban.Job, id) do
      %{state: state} when state in ["available", "scheduled", "executing", "retryable"] -> true
      _ -> false
    end
  end

  defp active_job?(_), do: false

  defp get(provider), do: Ash.get(State, provider, actor: @actor, not_found_error?: false)

  defp put(attrs),
    do:
      State
      |> Ash.Changeset.for_create(:put, Map.merge(%{app_slug: nil, job_id: nil}, attrs),
        actor: @actor
      )
      |> Ash.create()

  defp record(state, attrs),
    do:
      state
      |> Ash.Changeset.for_update(:record, Map.put(attrs, :expected_id, state.id), actor: @actor)
      |> Ash.update()
end
