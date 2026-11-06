defmodule Lovelace.StageDesigner.GenerationTest do
  use LovelaceWeb.ConnCase, async: false
  use Oban.Testing, repo: Lovelace.Repo, engine: Oban.Engines.Lite

  import ExUnit.CaptureLog

  alias Lovelace.{Repo, StageDesigner}
  alias Lovelace.StageDesigner.{Attempt, Generation, GenerationWorker, Settings, Storage}
  alias Lovelace.TestSupport.PNG

  @owner %{role: :local_owner}
  @service %{role: :stage_designer}
  @choices %{model: "gemini-nano-banana-2.1", aspect_ratio: "16:9", image_size: "1K"}

  defmodule PaidRenderFake do
    @behaviour Lovelace.StageDesigner.PaidRender

    @impl true
    def create(request, _options) do
      send(self(), {:paid_submission, request})
      {:error, :timeout}
    end

    @impl true
    def get(id, _options) do
      send(self(), {:unexpected_tracking, id})
      {:error, :provider_error}
    end

    @impl true
    def delete(id, _options) do
      send(self(), {:unexpected_cleanup, id})
      {:error, :provider_error}
    end
  end

  defmodule BrokenConfirmation do
    @behaviour Lovelace.StageDesigner.Confirmation

    @impl true
    def sign(_snapshot, options), do: fail(options)

    @impl true
    def verify(_token, options), do: fail(options)

    defp fail(raise: secret), do: raise(secret)
    defp fail(throw: secret), do: throw({:private_confirmation_failure, secret})
  end

  setup {Req.Test, :verify_on_exit!}

  setup do
    previous = Settings.get()
    directory = Path.join(System.tmp_dir!(), "lovelace-jobs-#{Ash.UUID.generate()}")
    Application.put_env(:lovelace, :stage_designer, %Settings{storage_dir: directory})

    on_exit(fn ->
      Application.put_env(:lovelace, :stage_designer, previous)
      File.rm_rf!(directory)
    end)

    :ok
  end

  test "prepare is local-only, validated and owner-authorized" do
    assert {:error, _} = StageDesigner.prepare_scene_generation(@choices)
    assert {:ok, confirmation} = prepare()
    assert confirmation.model == @choices.model
    assert {:ok, nil} = StageDesigner.get_state(1, actor: @service)
    assert {:ok, []} = Attempt.page(1)

    assert {:error, _} =
             StageDesigner.prepare_scene_generation(%{@choices | model: "not-curated"},
               actor: @owner
             )

    assert {:error, _} =
             StageDesigner.prepare_scene_generation(%{@choices | image_size: "4K"}, actor: @owner)
  end

  test "confirmation creates an ID-only job and is single-use even after terminal failure" do
    {:ok, confirmation} = prepare()
    assert {:ok, :started} = request(confirmation)
    attempt = current()
    assert attempt.model == @choices.model
    assert attempt.status == :queued
    assert_enqueued(worker: GenerationWorker, args: %{id: attempt.id, operation: "submit"})
    assert {:ok, :started} = request(confirmation)
    assert length(all_enqueued(worker: GenerationWorker)) == 1
    Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 429, "private provider detail"))
    assert :ok = Generation.perform(attempt.id, :submit, provider())
    assert current().status == :failed
    assert current().failure =~ "HTTP 429"
    refute current().failure =~ "private provider detail"
    assert {:ok, :started} = request(confirmation)
    assert current().status == :failed
    assert {:ok, attempts} = Attempt.page(1)
    assert length(attempts) == 1
  end

  test "recovery replaces missing authorized jobs but never repeats a stranded submission" do
    attempt = reserve()
    Repo.delete_all(Oban.Job)
    assert :ok = Generation.reconcile()
    assert_enqueued(worker: GenerationWorker, args: %{id: attempt.id, operation: "submit"})
    {:ok, _} = Attempt.record(attempt, %{status: :submitting})
    Repo.query!("UPDATE stage_designer_attempts SET updated_at = '2000-01-01 00:00:00.000000'")
    Repo.delete_all(Oban.Job)
    assert :ok = Generation.reconcile()
    assert current().status == :unknown
    assert all_enqueued(worker: GenerationWorker) == []
    refute StageDesigner.list_scenes!(actor: @owner).eligible
  end

  test "recovery resumes retrieval of a saved ID after losing its polling job" do
    attempt = reserve()
    Req.Test.expect(__MODULE__, &interaction(&1, "in_progress"))
    assert :ok = Generation.perform(attempt.id, :submit, provider())
    Repo.delete_all(Oban.Job)
    Repo.query!("UPDATE stage_designer_attempts SET updated_at = '2000-01-01 00:00:00.000000'")
    assert :ok = Generation.reconcile()
    assert_enqueued(worker: GenerationWorker, args: %{id: attempt.id, operation: "poll"})
    refute_enqueued(worker: GenerationWorker, args: %{id: attempt.id, operation: "submit"})

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      interaction(conn, "completed", PNG.image())
    end)

    assert :ok = Generation.perform(attempt.id, :poll, provider())
    assert current().status == :completed
  end

  test "tampered confirmation never reserves or enqueues" do
    {:ok, confirmation} = prepare()

    assert {:ok, :invalid_confirmation} =
             StageDesigner.request_scene_generation(
               %{confirmation: confirmation.confirmation <> "x"},
               actor: @owner
             )

    assert {:ok, nil} = StageDesigner.get_state(1, actor: @service)
    assert all_enqueued(worker: GenerationWorker) == []
  end

  test "confirmation signing fails closed without composition and verification preserves expiry" do
    {:ok, confirmation} = prepare()
    snapshot = Map.delete(confirmation, :confirmation)

    expired =
      Phoenix.Token.sign(LovelaceWeb.Endpoint, "scene-generation-v1", snapshot,
        signed_at: System.system_time(:second) - 601
      )

    assert {:ok, :invalid_confirmation} =
             StageDesigner.request_scene_generation(%{confirmation: expired}, actor: @owner)

    previous = Application.fetch_env!(:lovelace, :scene_confirmation)
    on_exit(fn -> Application.put_env(:lovelace, :scene_confirmation, previous) end)
    Application.delete_env(:lovelace, :scene_confirmation)
    assert {:error, _} = prepare()
    assert {:ok, :invalid_confirmation} = request(confirmation)
    assert {:ok, []} = Attempt.page(1)
    assert all_enqueued(worker: GenerationWorker) == []
  end

  for kind <- [:raise, :throw] do
    test "a confirmation adapter #{kind} cannot authorize paid work or expose signing details" do
      {:ok, confirmation} = prepare()
      previous = Application.fetch_env!(:lovelace, :scene_confirmation)
      on_exit(fn -> Application.put_env(:lovelace, :scene_confirmation, previous) end)
      secret = "synthetic-private-confirmation-signing-detail"

      Application.put_env(
        :lovelace,
        :scene_confirmation,
        {BrokenConfirmation, [{unquote(kind), secret}]}
      )

      log =
        capture_log(fn ->
          assert {:error, error} = prepare()
          refute inspect(error) =~ secret
          assert {:ok, :invalid_confirmation} = request(confirmation)
        end)

      refute log =~ secret
      assert {:ok, []} = Attempt.page(1)
      assert {:ok, nil} = StageDesigner.get_state(1, actor: @service)
      assert all_enqueued(worker: GenerationWorker) == []
    end
  end

  test "application provider contract keeps unknown paid submissions permanently one-shot" do
    previous = Application.get_env(:lovelace, :paid_render_provider)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lovelace, :paid_render_provider, previous),
        else: Application.delete_env(:lovelace, :paid_render_provider)
    end)

    Application.put_env(:lovelace, :paid_render_provider, PaidRenderFake)
    attempt = reserve()
    assert :ok = Generation.perform(attempt.id, :submit)
    assert_receive {:paid_submission, %{background: true, store: true}}
    assert current().status == :unknown
    assert :ok = Generation.perform(attempt.id, :submit)
    assert :ok = Generation.reconcile()
    refute_received {:paid_submission, _}
    refute_received {:unexpected_tracking, _}
    refute_received {:unexpected_cleanup, _}
    assert current().status == :unknown
  end

  test "protected recovery admission is authorized, ID-only and has no provider side effects" do
    assert {:error, _} = StageDesigner.schedule_recovery()
    assert {:error, _} = StageDesigner.schedule_recovery(actor: @owner)
    assert {:error, _} = StageDesigner.recover(actor: @owner)
    assert {:ok, :scheduled} = StageDesigner.schedule_recovery(actor: @service)

    assert [%Oban.Job{args: %{"id" => _id}} = job] =
             all_enqueued(worker: Lovelace.StageDesigner.RecoveryWorker)

    assert map_size(job.args) == 1
    assert {:ok, nil} = StageDesigner.get_state(1, actor: @service)
    assert {:ok, []} = Attempt.page(1)
  end

  test "submission stores provider ID; GET publishes image before DELETE and replay does not reactivate" do
    attempt = reserve()

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      assert payload["background"] == true
      assert payload["store"] == true
      assert payload["model"] == attempt.model
      assert current().status == :submitting
      interaction(conn, "in_progress")
    end)

    assert :ok = Generation.perform(attempt.id, :submit, provider())
    assert current().provider_id == "interaction_test"
    assert current().status == :rendering
    assert StageDesigner.background!().status == :rendering

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1beta/interactions/interaction_test"
      interaction(conn, "completed", PNG.image())
    end)

    assert :ok = Generation.perform(attempt.id, :poll, provider())
    completed = current()
    assert completed.status == :completed
    assert completed.cleanup == :pending
    assert completed.digest
    assert {:ok, _} = Storage.read(Settings.get(), completed.digest)
    assert_enqueued(worker: GenerationWorker, args: %{id: attempt.id, operation: "cleanup"})

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "DELETE"
      assert current().status == :completed
      assert StageDesigner.get_state!(1, actor: @service).selected_digest == completed.digest
      Plug.Conn.send_resp(conn, 204, "")
    end)

    assert :ok = Generation.perform(attempt.id, :cleanup, provider())
    assert current().cleanup == :completed
    assert :ok = Generation.perform(attempt.id, :submit, provider())
    assert :ok = Generation.perform(attempt.id, :poll, provider())
    assert :ok = Generation.perform(attempt.id, :cleanup, provider())

    assert {:error, :stale_attempt} =
             Storage.store_and_publish_attempt(
               Settings.get(),
               PNG.image(3, 3),
               completed,
               DateTime.utc_now()
             )

    assert StageDesigner.get_state!(1, actor: @service).selected_digest == completed.digest
  end

  test "rescued submission cannot POST again and unknown requires acknowledgement and fresh consent" do
    attempt = reserve()
    assert {:ok, _} = Attempt.record(attempt, %{status: :submitting})
    assert :ok = Generation.perform(attempt.id, :submit, provider())
    assert current().status == :unknown
    {:ok, next} = prepare()
    assert {:ok, :busy} = request(next)
    assert {:error, _} = StageDesigner.acknowledge_scene_attempt(%{id: attempt.id})

    assert {:ok, :acknowledged} =
             StageDesigner.acknowledge_scene_attempt(%{id: attempt.id}, actor: @owner)

    assert current().status == :abandoned
    assert {:ok, :invalid_confirmation} = request(next)
    {:ok, fresh} = prepare()
    assert {:ok, :started} = request(fresh)
    assert current().id != attempt.id

    assert {:error, :stale_attempt} =
             Storage.store_and_publish_attempt(
               Settings.get(),
               PNG.image(),
               attempt,
               DateTime.utc_now()
             )

    assert current().status == :queued
    assert :ok = Generation.perform(attempt.id, :submit, provider())
    assert {:ok, old} = Attempt.get(attempt.id)
    assert old.status == :abandoned
  end

  test "uncertain HTTP submission outcome is not presented as a definite provider rejection" do
    attempt = reserve()
    Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 503, "private detail"))
    assert :ok = Generation.perform(attempt.id, :submit, provider())
    assert current().status == :unknown
    assert StageDesigner.background!().status == :uncertain
    assert StageDesigner.list_scenes!(actor: @owner).eligible == false
    assert current().failure =~ "HTTP 503"
  end

  test "tracking failures pause safely; explicit check only retrieves the same ID" do
    attempt = reserve()
    Req.Test.expect(__MODULE__, &interaction(&1, "in_progress"))
    assert :ok = Generation.perform(attempt.id, :submit, provider())

    for _ <- 1..3 do
      Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 503, "private detail"))
      assert :ok = Generation.perform(attempt.id, :poll, provider())
    end

    assert current().status == :tracking_paused
    assert current().provider_id == "interaction_test"
    assert StageDesigner.list_scenes!(actor: @owner).eligible == false
    assert {:ok, :scheduled} = StageDesigner.check_scene_attempt(%{id: attempt.id}, actor: @owner)
    assert current().status == :rendering

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      interaction(conn, "completed", PNG.image())
    end)

    assert :ok = Generation.perform(attempt.id, :poll, provider())
    assert current().status == :completed
  end

  test "expired provider ID becomes an acknowledgeable unknown without another paid submission" do
    attempt = reserve()
    Req.Test.expect(__MODULE__, &interaction(&1, "in_progress"))
    assert :ok = Generation.perform(attempt.id, :submit, provider())

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      Plug.Conn.send_resp(conn, 404, "expired interaction")
    end)

    assert :ok = Generation.perform(attempt.id, :poll, provider())
    assert current().status == :unknown
    assert current().provider_id == "interaction_test"
    refute StageDesigner.list_scenes!(actor: @owner).eligible

    assert {:ok, :acknowledged} =
             StageDesigner.acknowledge_scene_attempt(%{id: attempt.id}, actor: @owner)

    assert StageDesigner.list_scenes!(actor: @owner).eligible
    replacement = reserve()
    assert replacement.id != attempt.id

    assert {:error, :stale_attempt} =
             Storage.store_and_publish_attempt(
               Settings.get(),
               PNG.image(),
               attempt,
               DateTime.utc_now()
             )

    assert current().id == replacement.id
  end

  test "cleanup failure keeps successful image and never retries generation" do
    attempt = reserve()
    Req.Test.expect(__MODULE__, &interaction(&1, "completed", PNG.image()))
    assert :ok = Generation.perform(attempt.id, :submit, provider())
    url = StageDesigner.background!().url
    Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 503, "private cleanup detail"))

    assert {:error, :remote_cleanup_unavailable} =
             Generation.perform(attempt.id, :cleanup, provider())

    assert current().status == :completed
    assert current().cleanup == :failed
    assert StageDesigner.background!().url == url
    refute current().cleanup_error =~ "private cleanup detail"
    assert {:ok, :scheduled} = StageDesigner.check_scene_attempt(%{id: attempt.id}, actor: @owner)
    assert current().status == :completed
    assert :ok = Generation.perform(attempt.id, :submit, provider())
  end

  test "legacy acknowledgement preserves cooldown and labels missing history honestly" do
    now = DateTime.utc_now()
    state = StageDesigner.initialize_state!(%{}, actor: @service)
    StageDesigner.reserve_state!(state, %{last_attempt_at: now}, actor: @service)

    assert {:ok, :acknowledged} =
             StageDesigner.acknowledge_scene_attempt(%{id: "legacy"}, actor: @owner)

    assert current().source == :legacy
    assert current().status == :abandoned
    assert current().failure =~ "unknown"
    assert StageDesigner.get_state!(1, actor: @service).last_attempt_at == now
    assert StageDesigner.list_scenes!(actor: @owner).eligible
    assert {:ok, :disabled} = StageDesigner.generate_on_startup(actor: @service)
  end

  test "attempt history is paginated, permanent and omits prompt/provider payloads from UI reads" do
    for _ <- 1..22 do
      attempt = reserve()
      {:ok, _} = Attempt.record(attempt, %{status: :submitting})
      :ok = Generation.perform(attempt.id, :submit, provider())

      {:ok, :acknowledged} =
        StageDesigner.acknowledge_scene_attempt(%{id: attempt.id}, actor: @owner)
    end

    first = StageDesigner.list_scenes!(actor: @owner)
    assert length(first.attempts) == 20
    assert first.attempts_has_next
    refute Map.has_key?(hd(first.attempts), :prompt)
    refute Map.has_key?(hd(first.attempts), :provider_id)
    second = StageDesigner.list_scenes!(%{attempt_page: 2}, actor: @owner)
    assert length(second.attempts) == 2
    assert second.attempts_has_previous
    refute second.attempts_has_next
  end

  defp prepare, do: StageDesigner.prepare_scene_generation(@choices, actor: @owner)

  defp request(confirmation),
    do:
      StageDesigner.request_scene_generation(%{confirmation: confirmation.confirmation},
        actor: @owner
      )

  defp reserve do
    {:ok, confirmation} = prepare()
    assert {:ok, :started} = request(confirmation)
    current()
  end

  defp current, do: Generation.current(StageDesigner.get_state!(1, actor: @service))
  defp provider, do: [api_key: "fake-stage-key", plug: {Req.Test, __MODULE__}]

  defp interaction(conn, status, bytes \\ nil) do
    content =
      if bytes,
        do: [%{type: "image", mime_type: "image/png", data: Base.encode64(bytes)}],
        else: []

    Req.Test.json(conn, %{
      id: "interaction_test",
      status: status,
      steps: [%{type: "model_output", content: content}]
    })
  end
end
