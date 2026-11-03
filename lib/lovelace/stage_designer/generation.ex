defmodule Lovelace.StageDesigner.Generation do
  @moduledoc "Ash-owned paid submission intent, recoverable read-only tracking and post-publication cleanup."
  use Ash.Resource.Actions.Implementation

  alias Lovelace.Integrations.Gemini.Interactions
  alias Lovelace.Repo
  alias Lovelace.StageDesigner

  alias Lovelace.StageDesigner.{
    Attempt,
    Diagnostics,
    Directions,
    GenerationWorker,
    Models,
    Settings,
    Startup,
    Storage
  }

  @actor %{role: :stage_designer}
  @salt "scene-generation-v1"
  @public [
    :id,
    :status,
    :source,
    :model,
    :aspect_ratio,
    :image_size,
    :inserted_at,
    :completed_at,
    :last_checked_at,
    :failure,
    :cleanup,
    :cleanup_error,
    :acknowledged_at
  ]

  @impl true
  def run(input, opts, _context) do
    case opts[:operation] do
      :prepare -> prepare(input.arguments)
      :manual -> {:ok, manual(input.arguments.confirmation, DateTime.utc_now())}
      :acknowledge -> {:ok, acknowledge(input.arguments.id)}
      :check -> {:ok, check(input.arguments.id)}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def prepare(choices) do
    with :ok <- Models.validate(choices),
         {:ok, settings} <- Directions.effective_settings(Settings.get()),
         {:ok, state} <- StageDesigner.get_state(1, actor: @actor) do
      snapshot =
        Map.merge(Map.take(choices, [:model, :aspect_ratio, :image_size]), %{
          id: Ash.UUID.generate(),
          expected_version: if(state, do: state.version, else: 0),
          prompt: settings.prompt,
          timeout_seconds: settings.timeout_seconds
        })

      {:ok,
       Map.put(snapshot, :confirmation, Phoenix.Token.sign(LovelaceWeb.Endpoint, @salt, snapshot))}
    else
      _ -> {:error, :invalid_settings}
    end
  end

  defp manual(token, now) do
    with {:ok, snapshot} <- Phoenix.Token.verify(LovelaceWeb.Endpoint, @salt, token, max_age: 600),
         :ok <- Models.validate(snapshot) do
      case Attempt.get(snapshot.id) do
        {:ok, %Attempt{}} -> :started
        {:ok, nil} -> manual_new(snapshot, now)
        _ -> :unavailable
      end
    else
      _ -> :invalid_confirmation
    end
  end

  defp manual_new(snapshot, now) do
    with {:ok, settings} <- Directions.effective_settings(Settings.get()),
         true <- settings.prompt == snapshot.prompt do
      reserve(snapshot, :manual, now)
    else
      false -> :direction_changed
      _ -> :unavailable
    end
  end

  def startup(settings, now, retry? \\ false) do
    case Directions.effective_settings(settings) do
      {:ok, resolved} ->
        snapshot =
          resolved
          |> Map.from_struct()
          |> Map.take([:model, :aspect_ratio, :image_size, :prompt, :timeout_seconds])

        reserve(
          Map.put(snapshot, :id, Ash.UUID.generate()),
          if(retry?, do: :operator, else: :startup),
          now
        )

      _ ->
        :unavailable
    end
  end

  defp reserve(snapshot, source, now) do
    result =
      Repo.transaction(fn ->
        # The signed request ID remains idempotent even after its attempt completes.
        case Attempt.get(snapshot.id) do
          {:ok, %Attempt{}} -> :started
          {:ok, nil} -> reserve_new(snapshot, source, now)
          _ -> Repo.rollback(:unavailable)
        end
      end)

    case result do
      {:ok, :started} ->
        Startup.notify()
        :started

      {:error, reason} when reason in [:busy, :cached, :invalid_confirmation] ->
        reason

      _ ->
        :unavailable
    end
  end

  defp reserve_new(snapshot, source, now) do
    with {:ok, _} <- StageDesigner.initialize_state(%{}, actor: @actor),
         {:ok, state} <- StageDesigner.get_state(1, actor: @actor),
         :ok <- confirmation_version(state, snapshot, source),
         true <- eligible?(state, source, now),
         {:ok, reserved} <-
           StageDesigner.reserve_state(
             state,
             %{last_attempt_at: now, active_attempt_id: snapshot.id},
             actor: @actor
           ),
         {:ok, attempt} <-
           Attempt.create(
             Map.merge(Map.drop(snapshot, [:expected_version]), %{
               source: source,
               inserted_at: now,
               reservation_version: reserved.version
             })
           ),
         {:ok, _} <- GenerationWorker.enqueue(attempt.id, :submit) do
      :started
    else
      false -> Repo.rollback(if(source == :manual, do: :busy, else: :cached))
      {:error, :invalid_confirmation} -> Repo.rollback(:invalid_confirmation)
      _ -> Repo.rollback(:unavailable)
    end
  end

  defp confirmation_version(state, snapshot, :manual) do
    if Map.get(snapshot, :expected_version) == state.version,
      do: :ok,
      else: {:error, :invalid_confirmation}
  end

  defp confirmation_version(_state, _snapshot, _source), do: :ok

  defp eligible?(state, :manual, _), do: Startup.manual_eligible?(state)
  defp eligible?(state, :operator, _), do: state.status == :failed

  defp eligible?(state, :startup, now),
    do: Startup.manual_eligible?(state) and Startup.due?(state, Settings.get(), now)

  def public(nil), do: nil
  def public(attempt), do: Map.take(attempt, @public)

  def current(state) do
    with %{active_attempt_id: id} when not is_nil(id) <- state,
         {:ok, attempt} <- Attempt.get(id) do
      attempt
    else
      _ -> nil
    end
  end

  def status(%Attempt{status: :completed}), do: :ready
  def status(%Attempt{status: :unknown}), do: :uncertain
  def status(%Attempt{status: :abandoned}), do: :idle
  def status(%Attempt{status: status}), do: status

  # Called only by supervised workers or fake-provider tests. No credentials or
  # request content enters Oban args, errors or recorded stack traces.
  def perform(id, operation, opts \\ []) do
    case Attempt.get(id) do
      {:ok, %Attempt{} = attempt} -> work(attempt, operation, opts)
      _ -> :ok
    end
  rescue
    _ -> recover_exception(id, operation)
  catch
    _, _ -> recover_exception(id, operation)
  end

  defp work(%{status: :queued} = attempt, :submit, opts) do
    # Permanent CAS claim, not a lease. Even Oban rescue cannot repeat this POST.
    case Attempt.record(attempt, %{status: :submitting}) do
      {:ok, claimed} -> submit_claimed(claimed, opts)
      _ -> :ok
    end
  end

  defp work(%{status: :submitting} = attempt, :submit, _opts), do: unknown(attempt, :timeout)

  defp work(%{status: status, provider_id: id} = attempt, :poll, opts)
       when status in [:rendering, :tracking_paused] and is_binary(id) do
    handle_poll(
      attempt,
      Interactions.get(id, Keyword.put(opts, :timeout_seconds, attempt.timeout_seconds))
    )
  end

  defp work(%{status: :completed, cleanup: cleanup, provider_id: id} = attempt, :cleanup, opts)
       when cleanup in [:pending, :failed] and is_binary(id) do
    case Interactions.delete(id, opts) do
      :ok ->
        Attempt.record(attempt, %{cleanup: :completed, cleanup_error: nil})
        Startup.notify()
        :ok

      {:error, reason} ->
        Attempt.record(attempt, %{
          cleanup: :failed,
          cleanup_error: Diagnostics.describe(:provider, reason)
        })

        Startup.notify()
        {:error, :remote_cleanup_unavailable}
    end
  end

  defp work(_, _, _), do: :ok

  defp submit_claimed(claimed, opts) do
    Startup.notify()

    request = %{
      model: claimed.model,
      input: claimed.prompt,
      background: true,
      store: true,
      response_format: %{
        type: "image",
        aspect_ratio: claimed.aspect_ratio,
        image_size: claimed.image_size
      }
    }

    result =
      Interactions.create(request, Keyword.put(opts, :timeout_seconds, claimed.timeout_seconds))

    case Attempt.get(claimed.id) do
      {:ok, %Attempt{} = fresh} -> accept_submission(fresh, result)
      _ -> :ok
    end
  end

  # A late ID is historical evidence, never permission to reactivate abandoned work.
  defp accept_submission(%{status: :abandoned} = attempt, {:ok, %{id: id}}) do
    Attempt.record(attempt, %{provider_id: id})
    :ok
  end

  defp accept_submission(attempt, {:ok, %{id: id} = response}) do
    case Attempt.record(attempt, %{provider_id: id, status: :rendering}) do
      {:ok, tracking} -> handle_poll(tracking, {:ok, response})
      _ -> :ok
    end
  end

  defp accept_submission(attempt, {:error, reason}) do
    if definite_rejection?(reason),
      do: fail(attempt, :provider, reason),
      else: unknown(attempt, reason)
  end

  defp accept_submission(attempt, _), do: unknown(attempt, :invalid_response)

  # HTTP rejection and local preflight failures are known not to be a successful
  # generation. Transport/protocol failures may have lost an accepted request.
  defp definite_rejection?({:http_error, status, _}) when status in [400, 401, 403, 404, 429],
    do: true

  defp definite_rejection?(reason),
    do:
      reason in [
        :missing_api_key,
        :keychain_unavailable,
        :invalid_settings,
        :invalid_options,
        :invalid_request,
        :request_too_large,
        :client_configuration_error
      ]

  defp handle_poll(attempt, {:ok, %{status: :completed, images: [bytes]}}) do
    publish(attempt, bytes)
  end

  defp handle_poll(attempt, {:ok, %{status: :in_progress}}) do
    count = attempt.poll_count + 1

    attrs = %{
      status: if(count >= 180, do: :tracking_paused, else: :rendering),
      poll_count: count,
      tracking_errors: 0,
      last_checked_at: DateTime.utc_now(),
      failure: nil
    }

    with {:ok, updated} <- Attempt.record(attempt, attrs) do
      if count < 180, do: GenerationWorker.enqueue(updated.id, :poll, 5)
      Startup.notify()
    end

    :ok
  end

  defp handle_poll(attempt, {:ok, %{status: :failed, error: reason}}),
    do: fail(attempt, :provider, reason || :provider_error)

  defp handle_poll(attempt, {:ok, _}), do: fail(attempt, :provider, :invalid_response)

  defp handle_poll(attempt, {:error, {:http_error, 404, _} = reason}),
    do: unknown(attempt, reason)

  defp handle_poll(attempt, {:error, reason}) do
    errors = attempt.tracking_errors + 1

    with {:ok, updated} <-
           Attempt.record(attempt, %{
             status: if(errors >= 3, do: :tracking_paused, else: :rendering),
             tracking_errors: errors,
             last_checked_at: DateTime.utc_now(),
             failure: Diagnostics.describe(:provider, reason)
           }) do
      if errors < 3, do: GenerationWorker.enqueue(updated.id, :poll, errors * 10)
      Startup.notify()
    end

    :ok
  end

  defp publish(attempt, bytes) do
    # Storage's cross-BEAM exclusion is acquired before this transaction. Manifest,
    # attempt success and durable deletion intent commit together.
    case Storage.store_and_publish_attempt(Settings.get(), bytes, attempt, DateTime.utc_now()) do
      {:ok, _} ->
        GenerationWorker.enqueue(attempt.id, :cleanup)
        Startup.notify()
        :ok

      {:error, :stale_attempt} ->
        :ok

      {:error, {stage, reason}} ->
        fail(attempt, stage, reason)
    end
  end

  defp fail(attempt, stage, reason) do
    finish(attempt, :failed, Diagnostics.describe(stage, reason))
  end

  defp unknown(attempt, reason),
    do: finish(attempt, :unknown, Diagnostics.describe(:provider, reason))

  defp finish(attempt, status, failure) do
    Repo.transaction(fn -> finish_transaction(attempt, status, failure) end)
    Startup.notify()
    :ok
  end

  defp finish_transaction(attempt, status, failure) do
    with {:ok, %Attempt{} = fresh} <- Attempt.get(attempt.id),
         true <- fresh.status not in [:completed, :failed, :abandoned],
         {:ok, _} <-
           Attempt.record(fresh, %{
             status: status,
             failure: failure,
             completed_at: if(status == :failed, do: DateTime.utc_now())
           }) do
      if status == :failed, do: release_current(attempt)
    else
      _ -> Repo.rollback(:stale_attempt)
    end
  end

  defp release_current(attempt) do
    with {:ok, state} when not is_nil(state) <- StageDesigner.get_state(1, actor: @actor),
         true <-
           state.active_attempt_id == attempt.id and state.version == attempt.reservation_version,
         {:ok, _} <- StageDesigner.fail_state(state, %{}, actor: @actor) do
      :ok
    else
      _ -> Repo.rollback(:stale_attempt)
    end
  end

  defp acknowledge("legacy") do
    result =
      Repo.transaction(fn ->
        with {:ok, state} <- StageDesigner.get_state(1, actor: @actor),
             %{status: :generating, active_attempt_id: nil} <- state,
             {:ok, attempt} <-
               Attempt.create(%{
                 id: Ash.UUID.generate(),
                 source: :legacy,
                 prompt: "",
                 model: "unknown",
                 aspect_ratio: "unknown",
                 image_size: "unknown",
                 inserted_at: state.last_attempt_at || DateTime.utc_now(),
                 reservation_version: state.version
               }),
             {:ok, _} <-
               Attempt.record(attempt, %{
                 status: :abandoned,
                 failure: "Legacy submission outcome unknown; provider details unavailable.",
                 acknowledged_at: DateTime.utc_now()
               }),
             {:ok, adopted} <-
               StageDesigner.reserve_state(
                 state,
                 %{active_attempt_id: attempt.id, last_attempt_at: state.last_attempt_at},
                 actor: @actor
               ),
             {:ok, _} <- StageDesigner.fail_state(adopted, %{}, actor: @actor) do
          :acknowledged
        else
          _ -> Repo.rollback(:unavailable)
        end
      end)

    notify_result(result)
  end

  defp acknowledge(id) do
    Repo.transaction(fn -> acknowledge_transaction(id) end) |> notify_result()
  end

  defp acknowledge_transaction(id) do
    with {:ok, %Attempt{} = attempt} <- Attempt.get(id),
         true <- attempt.status in [:failed, :unknown, :abandoned, :completed, :tracking_paused],
         {:ok, _} <-
           Attempt.record(attempt, %{
             acknowledged_at: DateTime.utc_now(),
             status: if(attempt.status == :unknown, do: :abandoned, else: attempt.status)
           }) do
      if attempt.status == :unknown, do: release_current(attempt)
      :acknowledged
    else
      _ -> Repo.rollback(:unavailable)
    end
  end

  defp notify_result({:ok, result}),
    do:
      (
        Startup.notify()
        result
      )

  defp notify_result(_), do: :unavailable

  defp check(id) do
    case Attempt.get(id) do
      {:ok, %Attempt{} = attempt} -> check_attempt(attempt)
      _ -> :unavailable
    end
  end

  defp check_attempt(%{status: status, provider_id: id} = attempt)
       when status in [:rendering, :tracking_paused] and is_binary(id) do
    Repo.transaction(fn ->
      with {:ok, _} <-
             Attempt.record(attempt, %{
               status: :rendering,
               poll_count: 0,
               tracking_errors: 0,
               acknowledged_at: nil
             }),
           {:ok, _} <- GenerationWorker.enqueue(attempt.id, :poll) do
        :scheduled
      else
        _ -> Repo.rollback(:unavailable)
      end
    end)
    |> notify_result()
  end

  defp check_attempt(%{status: :completed, cleanup: :failed} = attempt) do
    case GenerationWorker.enqueue(attempt.id, :cleanup) do
      {:ok, _} -> :scheduled
      _ -> :unavailable
    end
  end

  defp check_attempt(_), do: :unavailable

  def reconcile do
    with {:ok, attempts} <- Attempt.recoverable() do
      Enum.each(attempts, &reconcile_attempt/1)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp reconcile_attempt(attempt) do
    age = DateTime.diff(DateTime.utc_now(), attempt.updated_at)

    cond do
      attempt.status == :queued ->
        GenerationWorker.enqueue(attempt.id, :submit)

      attempt.status == :submitting and age > 180 ->
        unknown(attempt, :timeout)

      attempt.status == :rendering and age > 30 ->
        GenerationWorker.enqueue(attempt.id, :poll)

      attempt.status == :completed and attempt.cleanup == :pending ->
        GenerationWorker.enqueue(attempt.id, :cleanup)

      true ->
        :ok
    end
  end

  defp recover_exception(id, operation) do
    case Attempt.get(id) do
      {:ok, %Attempt{} = attempt} when operation == :submit ->
        unknown(attempt, :unexpected_error)

      {:ok, %Attempt{} = attempt} when operation == :poll ->
        handle_poll(attempt, {:error, :unexpected_error})

      {:ok, %Attempt{} = attempt} when operation == :cleanup ->
        Attempt.record(attempt, %{
          cleanup: :failed,
          cleanup_error: Diagnostics.describe(:provider, :unexpected_error)
        })

        Startup.notify()
        {:error, :remote_cleanup_unavailable}

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end
end
