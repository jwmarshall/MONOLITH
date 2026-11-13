defmodule Monolith.StageDesigner.GenerationFailuresTest do
  use MonolithWeb.ConnCase, async: false
  use Oban.Testing, repo: Monolith.Repo, engine: Oban.Engines.Lite

  import ExUnit.CaptureLog

  alias Monolith.{Repo, StageDesigner}

  alias Monolith.StageDesigner.{
    Attempt,
    DirectionOptions,
    Generation,
    GenerationWorker,
    RecoveryWorker,
    Scene,
    Settings,
    Storage
  }

  alias Monolith.TestSupport.{PNG, SceneGeneration}

  @owner %{role: :local_owner}
  @service %{role: :stage_designer}
  @provider_id "interaction_failure_recovery"
  @private "private-provider-output-never-persist"

  defmodule PaidRenderFake do
    @behaviour Monolith.StageDesigner.PaidRender
    alias Monolith.TestSupport.SceneGeneration

    @impl true
    def create(request, _options), do: respond(:create, request)

    @impl true
    def get(id, _options), do: respond(:get, id)

    @impl true
    def delete(id, _options), do: respond(:delete, id)

    def configure(operation, outcome) do
      Application.put_env(:monolith, __MODULE__, {self(), operation, outcome})
    end

    defp respond(operation, payload) do
      {observer, expected, outcome} = Application.fetch_env!(:monolith, __MODULE__)
      status = SceneGeneration.current().status
      send(observer, {:paid_call, operation, payload, status})

      case {operation == expected, outcome} do
        {true, {:raise, secret}} -> raise secret
        {true, {:throw, secret}} -> throw({:private_adapter_failure, secret})
        {true, {:return, result}} -> result
        _ -> raise "unexpected paid-render operation"
      end
    end
  end

  setup {Req.Test, :verify_on_exit!}

  setup do
    previous = Application.get_env(:monolith, :stage_designer)

    directory =
      Path.join(System.tmp_dir!(), "monolith-generation-failures-#{Ash.UUID.generate()}")

    Application.put_env(:monolith, :stage_designer, %Settings{storage_dir: directory})

    on_exit(fn ->
      Application.put_env(:monolith, :stage_designer, previous)
      File.rm_rf!(directory)
    end)

    %{directory: directory}
  end

  test "an in-progress image is not published or deleted before terminal completion" do
    baseline = publish_baseline()
    attempt = reserve()
    partial = PNG.image(5, 3)
    final = PNG.image(6, 3)

    expect("POST", "in_progress", [image(partial)])
    assert :ok = Generation.perform(attempt.id, :submit, provider())
    assert current().status == :rendering
    assert current().provider_id == @provider_id
    assert state().selected_digest == baseline.digest
    assert {:error, :unavailable_image} = Storage.read(Settings.get(), hash(partial))
    assert {:ok, false} = Scene.registered(hash(partial))
    refute_enqueued(worker: GenerationWorker, args: %{id: attempt.id, operation: "cleanup"})

    expect("GET", "completed", [image(final)])
    assert :ok = Generation.perform(attempt.id, :poll, provider())
    assert current().status == :completed
    assert current().cleanup == :pending
    assert state().selected_digest == hash(final)
    assert {:ok, ^final} = Storage.read(Settings.get(), hash(final))
    assert {:error, :unavailable_image} = Storage.read(Settings.get(), hash(partial))
    assert :ok = Generation.perform(attempt.id, :submit, provider())
    assert_calls(["POST", "POST", "GET"])
  end

  for {label, status, content} <- [
        {"incomplete image", "incomplete", :single_image},
        {"ambiguous multiple images", "completed", :multiple_images},
        {"text instead of an image", "completed", :text},
        {"provider failure with private details", "failed", :single_image}
      ] do
    test "#{label} preserves the previous background and releases the reservation" do
      baseline = publish_baseline()
      attempt = reserve()
      bytes = PNG.image(7, 3)

      content =
        case unquote(content) do
          :single_image -> [image(bytes)]
          :multiple_images -> [image(bytes), image(PNG.image(8, 3))]
          :text -> [%{type: "text", text: @private}]
        end

      expect("POST", unquote(status), content, %{
        errors: [%{code: "BILLING_DISABLED", message: @private}]
      })

      log =
        capture_log(fn -> assert :ok = Generation.perform(attempt.id, :submit, provider()) end)

      failed = current()
      assert failed.status == :failed
      assert failed.provider_id == @provider_id
      assert failed.completed_at
      assert failed.failure
      assert failed.digest == nil
      assert failed.cleanup == :none
      assert state().status == :failed
      assert state().history == [baseline.digest]
      assert state().selected_digest == baseline.digest
      assert StageDesigner.background!().url == Storage.url(baseline.digest)
      assert StageDesigner.list_scenes!(actor: @owner).eligible
      assert {:ok, false} = Scene.registered(hash(bytes))
      assert {:error, :unavailable_image} = Storage.read(Settings.get(), hash(bytes))
      refute_enqueued(worker: GenerationWorker, args: %{id: attempt.id, operation: "cleanup"})
      assert :ok = Generation.perform(attempt.id, :submit, provider())
      assert :ok = Generation.perform(attempt.id, :poll, provider())
      refute log =~ @private
      refute inspect(Generation.public(failed)) =~ @private
      assert_calls(["POST", "POST"])
    end
  end

  test "a malformed trailing image cannot turn a partial paid response into published success" do
    attempt = reserve()
    bytes = PNG.image(9, 3)

    expect("POST", "completed", [
      image(bytes),
      %{type: "image", mime_type: "image/png", data: @private}
    ])

    assert :ok = Generation.perform(attempt.id, :submit, provider())
    uncertain = current()
    assert uncertain.status == :unknown
    assert uncertain.provider_id == nil
    assert uncertain.digest == nil
    assert uncertain.cleanup == :none
    assert state().status == :generating
    refute StageDesigner.list_scenes!(actor: @owner).eligible
    assert {:ok, false} = Scene.registered(hash(bytes))
    assert {:error, :unavailable_image} = Storage.read(Settings.get(), hash(bytes))
    assert :ok = Generation.reconcile()
    assert :ok = Generation.perform(attempt.id, :submit, provider())
    assert current().status == :unknown
    refute inspect(Generation.public(current())) =~ @private
    assert_calls(["POST"])
  end

  test "a malformed retrieval preserves the saved ID and recovers with GET, never another POST" do
    attempt = reserve()
    expect("POST", "in_progress")
    assert :ok = Generation.perform(attempt.id, :submit, provider())
    bytes = PNG.image(10, 3)

    expect("GET", "completed", [
      image(bytes),
      %{type: "image", mime_type: "image/png", data: @private}
    ])

    assert :ok = Generation.perform(attempt.id, :poll, provider())
    assert current().status == :rendering
    assert current().tracking_errors == 1
    assert current().provider_id == @provider_id
    assert current().digest == nil
    assert {:error, :unavailable_image} = Storage.read(Settings.get(), hash(bytes))

    expect("GET", "completed", [image(bytes)])
    assert :ok = Generation.perform(attempt.id, :poll, provider())
    assert current().status == :completed
    assert state().selected_digest == hash(bytes)
    assert {:ok, ^bytes} = Storage.read(Settings.get(), hash(bytes))
    assert :ok = Generation.perform(attempt.id, :submit, provider())
    assert_calls(["POST", "GET", "GET"])
  end

  test "an unqueueable reservation rolls back consent and can be retried without losing it" do
    {:ok, confirmation} = SceneGeneration.prepare()
    reject_writes("BEFORE INSERT ON oban_jobs")
    result = request(confirmation)
    assert match?({:ok, :unavailable}, result) or match?({:error, _}, result)
    assert state() == nil
    assert {:ok, []} = Attempt.page(1)
    assert all_enqueued(worker: GenerationWorker) == []
    drop_rejection()

    assert {:ok, :started} = request(confirmation)
    attempt = current()
    assert attempt.id == confirmation.id
    assert {:ok, :started} = request(confirmation)
    assert length(all_enqueued(worker: GenerationWorker)) == 1
    expect("POST", "completed", [image(PNG.image())])
    assert :ok = Generation.perform(attempt.id, :submit, provider())
    assert {:ok, :started} = request(confirmation)
    assert :ok = Generation.perform(attempt.id, :submit, provider())
    assert current().status == :completed
    assert {:ok, [_]} = Attempt.page(1)
    assert_calls(["POST"])
  end

  test "startup and recovery admission refuse success when their jobs cannot be persisted" do
    Application.put_env(:monolith, :stage_designer, %{Settings.get() | enabled: true})
    StageDesigner.save_startup_preference!(%{enabled: true}, actor: @owner)
    reject_writes("BEFORE INSERT ON oban_jobs")
    assert {:ok, :unavailable} = StageDesigner.generate_on_startup(actor: @service)
    assert {:error, _} = StageDesigner.schedule_recovery(actor: @service)
    assert state() == nil
    assert {:ok, []} = Attempt.page(1)
    assert all_enqueued(worker: GenerationWorker) == []
    assert all_enqueued(worker: Monolith.StageDesigner.RecoveryWorker) == []
    drop_rejection()

    assert {:ok, :started} = StageDesigner.generate_on_startup(actor: @service)
    attempt = current()
    assert attempt.source == :startup
    assert attempt.status == :queued
    assert_enqueued(worker: GenerationWorker, args: %{id: attempt.id, operation: "submit"})
    assert {:ok, :scheduled} = StageDesigner.schedule_recovery(actor: @service)
    refute_received {:provider_call, _}
  end

  test "recovery exposes storage failure while still repairing safe authorized jobs" do
    attempt = reserve()
    Repo.delete_all(Oban.Job)
    settings = Settings.get()
    unavailable = Path.join(settings.storage_dir, "synthetic-unavailable-root")
    File.write!(unavailable, "not a directory")
    Application.put_env(:monolith, :stage_designer, %{settings | storage_dir: unavailable})

    assert {:error, _} = StageDesigner.recover(actor: @service)

    assert {:error, :background_unavailable} =
             RecoveryWorker.perform(%Oban.Job{})

    assert current().status == :queued
    assert_enqueued(worker: GenerationWorker, args: %{id: attempt.id, operation: "submit"})
    refute_received {:provider_call, _}

    Application.put_env(:monolith, :stage_designer, settings)
    assert :ok = RecoveryWorker.perform(%Oban.Job{})
    assert current().status == :queued
    refute_received {:provider_call, _}
  end

  test "recovery reports unqueueable work without consuming or reopening its permanent claim" do
    attempt = reserve()
    Repo.delete_all(Oban.Job)
    reject_writes("BEFORE INSERT ON oban_jobs")

    assert {:error, :background_unavailable} = Generation.reconcile()
    assert {:error, _} = StageDesigner.recover(actor: @service)

    assert {:error, :background_unavailable} =
             RecoveryWorker.perform(%Oban.Job{})

    assert current().status == :queued
    assert all_enqueued(worker: GenerationWorker) == []
    drop_rejection()

    assert :ok = RecoveryWorker.perform(%Oban.Job{})
    assert_enqueued(worker: GenerationWorker, args: %{id: attempt.id, operation: "submit"})
    assert {:ok, claimed} = Attempt.record(current(), %{status: :submitting})
    Repo.delete_all(Oban.Job)
    Repo.query!("UPDATE stage_designer_attempts SET updated_at = '2000-01-01 00:00:00.000000'")
    reject_writes("BEFORE UPDATE OF status ON stage_designer_attempts")

    assert {:error, :background_unavailable} = Generation.reconcile()
    assert current().status == claimed.status
    assert all_enqueued(worker: GenerationWorker) == []
    drop_rejection()

    assert :ok = RecoveryWorker.perform(%Oban.Job{})
    assert current().status == :unknown
    assert all_enqueued(worker: GenerationWorker) == []
    refute_received {:provider_call, _}
  end

  test "an acknowledged request's late ID is saved as evidence without reactivating or deleting it" do
    attempt = reserve()
    parent = self()

    Req.Test.expect(__MODULE__, fn conn ->
      send(parent, {:provider_call, conn.method})
      assert conn.method == "POST"
      {:ok, submitting} = Attempt.get(attempt.id)
      assert submitting.status == :submitting
      assert {:ok, _} = Attempt.record(submitting, %{status: :unknown})

      assert {:ok, :acknowledged} =
               StageDesigner.acknowledge_scene_attempt(%{id: attempt.id}, actor: @owner)

      response(conn, "completed", [image(PNG.image(11, 3))])
    end)

    assert :ok = Generation.perform(attempt.id, :submit, provider())
    abandoned = current()
    assert abandoned.status == :abandoned
    assert abandoned.acknowledged_at
    assert abandoned.provider_id == @provider_id
    assert abandoned.digest == nil
    assert abandoned.cleanup == :none
    assert state().status == :failed
    assert state().selected_digest == nil
    assert StageDesigner.list_scenes!(actor: @owner).eligible
    refute_enqueued(worker: GenerationWorker, args: %{id: attempt.id, operation: "poll"})
    refute_enqueued(worker: GenerationWorker, args: %{id: attempt.id, operation: "cleanup"})
    replacement = reserve()
    assert replacement.id != attempt.id
    assert :ok = Generation.perform(attempt.id, :submit, provider())
    assert :ok = Generation.perform(attempt.id, :poll, provider())
    assert current().id == replacement.id
    assert current().status == :queued
    assert_calls(["POST"])
  end

  test "an atomic image rename failure retains the old scene and never deletes remote work", %{
    directory: directory
  } do
    baseline = publish_baseline()
    attempt = reserve()
    bytes = PNG.image(12, 3)
    blocked = Path.join(directory, hash(bytes) <> ".png")
    File.mkdir_p!(blocked)
    expect("POST", "completed", [image(bytes)])

    assert :ok = Generation.perform(attempt.id, :submit, provider())
    assert current().status == :failed
    assert current().provider_id == @provider_id
    assert current().digest == nil
    assert current().cleanup == :none
    assert state().status == :failed
    assert state().history == [baseline.digest]
    assert state().selected_digest == baseline.digest
    assert {:ok, false} = Scene.registered(hash(bytes))
    assert {:ok, names} = File.ls(directory)
    refute Enum.any?(names, &String.ends_with?(&1, ".tmp"))
    refute_enqueued(worker: GenerationWorker, args: %{id: attempt.id, operation: "cleanup"})
    File.rmdir!(blocked)
    assert :ok = Generation.perform(attempt.id, :submit, provider())
    assert current().status == :failed
    assert_calls(["POST", "POST"])
  end

  for {label, rejection} <- [
        {"catalog insertion", "BEFORE INSERT ON stage_designer_scenes"},
        {"manifest publication",
         "BEFORE UPDATE ON stage_designer_states WHEN NEW.status = 'ready'"},
        {"attempt completion",
         "BEFORE UPDATE ON stage_designer_attempts WHEN NEW.status = 'completed'"}
      ] do
    test "#{label} failure rolls back publication and preserves paid-attempt evidence", %{
      directory: directory
    } do
      baseline = publish_baseline()
      attempt = reserve()
      reserved = state()
      bytes = PNG.image(13, 3)
      digest = hash(bytes)
      reject_writes(unquote(rejection))
      expect("POST", "completed", [image(bytes)])

      assert :ok = Generation.perform(attempt.id, :submit, provider())
      failed = current()
      assert failed.status == :failed
      assert failed.provider_id == @provider_id
      assert failed.completed_at
      assert failed.cleanup == :none
      assert failed.digest == nil
      assert state().status == :failed
      assert state().version == reserved.version + 1
      assert state().history == [baseline.digest]
      assert state().scene_dates == reserved.scene_dates
      assert state().selected_digest == baseline.digest
      assert state().generated_at == reserved.generated_at
      assert {:ok, false} = Scene.registered(digest)
      assert {:ok, ^bytes} = Storage.read(Settings.get(), digest)
      assert Ash.count!(Scene, actor: @service) == 1
      refute_enqueued(worker: GenerationWorker, args: %{id: attempt.id, operation: "cleanup"})
      drop_rejection()

      orphan = Path.join(directory, digest <> ".png")
      now = System.system_time(:second)
      File.touch!(orphan, now - 600)
      assert :ok = Storage.reconcile(Settings.get(), [], now)
      refute File.exists?(orphan)
      assert {:ok, _} = Storage.read(Settings.get(), baseline.digest)
      assert :ok = Generation.perform(attempt.id, :submit, provider())
      assert current().status == :failed
      assert_calls(["POST", "POST"])
    end
  end

  test "a rejected local selection leaves a generating reservation publishable" do
    first = publish_baseline()
    second = reserve()
    expect("POST", "completed", [image(PNG.image(14, 3))])
    assert :ok = Generation.perform(second.id, :submit, provider())
    selected = current().digest
    attempt = reserve()
    before_selection = state()
    reject_writes("BEFORE UPDATE OF selected_digest ON stage_designer_states")

    assert {:error, _} = StageDesigner.select_scene(first.digest, actor: @owner)
    assert state() == before_selection
    assert state().selected_digest == selected
    assert current().status == :queued
    drop_rejection()

    bytes = PNG.image(15, 3)
    expect("POST", "completed", [image(bytes)])
    assert :ok = Generation.perform(attempt.id, :submit, provider())
    assert current().status == :completed
    assert state().selected_digest == hash(bytes)
    assert state().version == before_selection.version + 1
    assert_calls(["POST", "POST", "POST"])
  end

  test "poll budget exhaustion pauses without discarding the ID and explicit resume resets the budget" do
    attempt = reserve()
    expect("POST", "in_progress")
    assert :ok = Generation.perform(attempt.id, :submit, provider())

    assert {:ok, _} =
             Attempt.record(current(), %{
               poll_count: 179,
               tracking_errors: 2,
               acknowledged_at: DateTime.utc_now()
             })

    Repo.delete_all(Oban.Job)
    expect("GET", "in_progress")
    assert :ok = Generation.perform(attempt.id, :poll, provider())
    paused = current()
    assert paused.status == :tracking_paused
    assert paused.poll_count == 180
    assert paused.tracking_errors == 0
    assert paused.failure == nil
    assert paused.last_checked_at
    assert paused.provider_id == @provider_id
    assert all_enqueued(worker: GenerationWorker) == []
    assert :ok = Generation.reconcile()
    assert all_enqueued(worker: GenerationWorker) == []
    refute StageDesigner.list_scenes!(actor: @owner).eligible
    reject_writes("BEFORE INSERT ON oban_jobs")
    result = StageDesigner.check_scene_attempt(%{id: attempt.id}, actor: @owner)
    assert match?({:ok, :unavailable}, result) or match?({:error, _}, result)
    assert current() == paused
    assert all_enqueued(worker: GenerationWorker) == []
    drop_rejection()
    assert {:ok, :scheduled} = StageDesigner.check_scene_attempt(%{id: attempt.id}, actor: @owner)
    assert current().status == :rendering
    assert current().poll_count == 0
    assert current().tracking_errors == 0
    assert current().acknowledged_at == nil
    assert_enqueued(worker: GenerationWorker, args: %{id: attempt.id, operation: "poll"})
    expect("GET", "completed", [image(PNG.image(16, 3))])
    assert :ok = Generation.perform(attempt.id, :poll, provider())
    assert current().status == :completed
    assert_calls(["POST", "GET", "GET"])
  end

  test "lost cleanup intent is restored and a failed DELETE recovers from an already-deleted ID" do
    completed = publish_baseline()
    before_cleanup = state()
    Repo.delete_all(Oban.Job)
    assert :ok = Generation.reconcile()
    assert_enqueued(worker: GenerationWorker, args: %{id: completed.id, operation: "cleanup"})
    parent = self()

    Req.Test.expect(__MODULE__, fn conn ->
      send(parent, {:provider_call, conn.method})
      assert conn.method == "DELETE"
      assert conn.request_path == "/v1beta/interactions/" <> @provider_id
      Plug.Conn.send_resp(conn, 503, @private)
    end)

    assert {:error, :remote_cleanup_unavailable} =
             Generation.perform(completed.id, :cleanup, provider())

    assert current().status == :completed
    assert current().cleanup == :failed
    assert current().cleanup_error
    refute current().cleanup_error =~ @private
    assert state() == before_cleanup
    Repo.delete_all(Oban.Job)
    failed_cleanup = current()
    reject_writes("BEFORE INSERT ON oban_jobs")
    result = StageDesigner.check_scene_attempt(%{id: completed.id}, actor: @owner)
    assert match?({:ok, :unavailable}, result) or match?({:error, _}, result)
    assert current() == failed_cleanup
    assert state() == before_cleanup
    assert all_enqueued(worker: GenerationWorker) == []
    drop_rejection()

    assert {:ok, :scheduled} =
             StageDesigner.check_scene_attempt(%{id: completed.id}, actor: @owner)

    assert_enqueued(worker: GenerationWorker, args: %{id: completed.id, operation: "cleanup"})

    Req.Test.expect(__MODULE__, fn conn ->
      send(parent, {:provider_call, conn.method})
      assert conn.method == "DELETE"
      assert conn.request_path == "/v1beta/interactions/" <> @provider_id
      Plug.Conn.send_resp(conn, 404, @private)
    end)

    assert :ok = Generation.perform(completed.id, :cleanup, provider())
    assert current().status == :completed
    assert current().cleanup == :completed
    assert current().cleanup_error == nil
    assert state() == before_cleanup
    assert {:ok, _} = Storage.read(Settings.get(), completed.digest)
    Repo.delete_all(Oban.Job)
    assert :ok = Generation.reconcile()
    assert all_enqueued(worker: GenerationWorker) == []
    assert :ok = Generation.perform(completed.id, :submit, provider())
    assert :ok = Generation.perform(completed.id, :cleanup, provider())
    assert_calls(["POST", "DELETE", "DELETE"])
  end

  test "a malformed submission result remains unknown and never authorizes another paid call" do
    use_paid_render()
    attempt = reserve()
    PaidRenderFake.configure(:create, {:return, {:unexpected, @private}})

    log = capture_log(fn -> assert %{success: 1, failure: 0} = drain_one() end)
    assert_received {:paid_call, :create, _, :submitting}
    unknown = current()
    assert unknown.status == :unknown
    assert unknown.provider_id == nil
    assert unknown.digest == nil
    refute StageDesigner.list_scenes!(actor: @owner).eligible
    assert_private_failure(unknown, @private, log)

    Repo.delete_all(Oban.Job)
    assert :ok = Generation.reconcile()
    assert :ok = Generation.perform(attempt.id, :submit)
    assert current() == unknown
    assert all_enqueued(worker: GenerationWorker) == []
    refute_received {:paid_call, _, _, _}
  end

  test "checking an unknown attempt never admits recovery or provider work" do
    assert {:ok, :unavailable} =
             StageDesigner.check_scene_attempt(%{id: Ash.UUID.generate()}, actor: @owner)

    assert {:ok, []} = Attempt.page(1)
    assert all_enqueued(worker: GenerationWorker) == []
  end

  for kind <- [:raise, :throw] do
    test "a #{kind} during paid submission records an unknown one-shot outcome without private errors" do
      use_paid_render()
      secret = @private <> "-submit-" <> Atom.to_string(unquote(kind))

      Application.put_env(:monolith, :stage_designer, %{
        Settings.get()
        | prompt: secret <> "-brief"
      })

      attempt = reserve()
      PaidRenderFake.configure(:create, {unquote(kind), secret})

      log =
        capture_log(fn ->
          assert %{success: 1, failure: 0} = drain_one()
        end)

      assert_received {:paid_call, :create, request, :submitting}
      assert request.input == attempt.prompt
      assert request.background
      assert request.store
      unknown = current()
      assert unknown.status == :unknown
      assert unknown.provider_id == nil
      assert unknown.completed_at == nil
      assert unknown.digest == nil
      assert unknown.cleanup == :none
      assert unknown.failure =~ "sensitive details were withheld"
      assert state().status == :generating
      assert StageDesigner.background!().status == :uncertain
      refute StageDesigner.list_scenes!(actor: @owner).eligible
      assert [%Oban.Job{state: "completed", errors: []}] = Repo.all(Oban.Job)
      assert_private_failure(unknown, secret, log)

      Repo.delete_all(Oban.Job)
      assert :ok = Generation.reconcile()
      assert :ok = Generation.perform(attempt.id, :submit)
      assert :ok = Generation.perform(attempt.id, :poll)
      assert :ok = Generation.perform(attempt.id, :cleanup)
      assert current() == unknown
      assert all_enqueued(worker: GenerationWorker) == []
      refute_received {:paid_call, _, _, _}
    end

    test "a #{kind} during known-ID polling preserves the ID and only retries retrieval" do
      use_paid_render()

      assert {:ok, _} =
               StageDesigner.save_scene_direction(
                 DirectionOptions.defaults(),
                 actor: @owner
               )

      attempt = reserve()

      PaidRenderFake.configure(
        :create,
        {:return, {:ok, %{id: @provider_id, status: :in_progress}}}
      )

      assert %{success: 1, failure: 0} = drain_one()
      assert_received {:paid_call, :create, _, :submitting}
      reserved = state()
      secret = @private <> "-poll-" <> Atom.to_string(unquote(kind))
      PaidRenderFake.configure(:get, {unquote(kind), secret})

      log =
        capture_log(fn ->
          assert %{success: 1, failure: 0} = drain_one()
        end)

      assert_received {:paid_call, :get, @provider_id, :rendering}
      tracking = current()
      assert tracking.status == :rendering
      assert tracking.provider_id == @provider_id
      assert tracking.tracking_errors == 1
      assert tracking.last_checked_at
      assert tracking.digest == nil
      assert tracking.cleanup == :none
      assert tracking.failure =~ "sensitive details were withheld"
      assert state() == reserved
      refute StageDesigner.list_scenes!(actor: @owner).eligible
      assert_private_failure(tracking, secret, log)
      direction = StageDesigner.get_direction!(1, actor: @service)
      refute inspect(direction, limit: :infinity) =~ tracking.prompt
      refute inspect(state(), limit: :infinity) =~ tracking.prompt
      assert :ok = Generation.perform(attempt.id, :submit)
      refute_received {:paid_call, _, _, _}

      bytes = PNG.image(17, 3)

      PaidRenderFake.configure(
        :get,
        {:return, {:ok, %{id: @provider_id, status: :completed, images: [bytes]}}}
      )

      assert %{success: 1, failure: 0} = drain_one()
      assert_received {:paid_call, :get, @provider_id, :rendering}
      assert current().status == :completed
      assert current().provider_id == @provider_id
      assert current().failure == nil
      assert state().selected_digest == hash(bytes)
      assert {:ok, ^bytes} = Storage.read(Settings.get(), hash(bytes))
      refute_received {:paid_call, _, _, _}
    end

    test "a #{kind} during remote cleanup keeps committed publication and records a safe job error" do
      completed = publish_baseline()
      published = state()
      Repo.delete_all(Oban.Job)
      use_paid_render()
      secret = @private <> "-cleanup-" <> Atom.to_string(unquote(kind))
      PaidRenderFake.configure(:delete, {unquote(kind), secret})
      assert {:ok, job} = GenerationWorker.enqueue(completed.id, :cleanup)

      log =
        capture_log(fn ->
          assert %{success: 0, failure: 1} = drain_one()
        end)

      assert_received {:paid_call, :delete, @provider_id, :completed}
      failed_cleanup = current()
      assert failed_cleanup.status == :completed
      assert failed_cleanup.digest == completed.digest
      assert failed_cleanup.completed_at == completed.completed_at
      assert failed_cleanup.provider_id == @provider_id
      assert failed_cleanup.cleanup == :failed
      assert failed_cleanup.cleanup_error =~ "sensitive details were withheld"
      assert state() == published
      assert StageDesigner.background!().url == Storage.url(completed.digest)
      assert {:ok, true} = Scene.registered(completed.digest)
      assert {:ok, _} = Storage.read(Settings.get(), completed.digest)
      recorded_job = Repo.get!(Oban.Job, job.id)
      assert recorded_job.state == "retryable"
      assert [%{"error" => error}] = recorded_job.errors
      assert error =~ "remote_cleanup_unavailable"
      assert_private_failure(failed_cleanup, secret, log)
      assert :ok = Generation.perform(completed.id, :submit)
      assert :ok = Generation.perform(completed.id, :poll)
      refute_received {:paid_call, _, _, _}

      PaidRenderFake.configure(:delete, {:return, :ok})
      assert :ok = Generation.perform(completed.id, :cleanup)
      assert_received {:paid_call, :delete, @provider_id, :completed}
      assert current().cleanup == :completed
      assert current().cleanup_error == nil
      assert state() == published
      refute_received {:paid_call, _, _, _}
    end
  end

  defp use_paid_render do
    previous = Application.fetch_env(:monolith, :paid_render_provider)
    previous_fake = Application.fetch_env(:monolith, PaidRenderFake)
    Application.put_env(:monolith, :paid_render_provider, PaidRenderFake)

    on_exit(fn ->
      for {key, value} <- [
            {:paid_render_provider, previous},
            {PaidRenderFake, previous_fake}
          ] do
        restore_env(key, value)
      end
    end)
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:monolith, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:monolith, key)

  defp drain_one do
    Oban.drain_queue(queue: :gemini, with_scheduled: true, with_limit: 1)
  end

  defp assert_private_failure(attempt, secret, log) do
    public = Generation.public(attempt)
    refute Map.has_key?(public, :prompt)
    refute Map.has_key?(public, :provider_id)

    surfaces = [
      log,
      inspect(attempt, limit: :infinity),
      inspect(public, limit: :infinity),
      inspect(StageDesigner.list_scenes!(actor: @owner), limit: :infinity),
      inspect(state(), limit: :infinity),
      inspect(Repo.all(Oban.Job), limit: :infinity)
    ]

    for surface <- surfaces do
      refute surface =~ secret
      refute surface =~ attempt.prompt
      refute surface =~ @provider_id
    end
  end

  defp reserve do
    assert {:ok, :started} = SceneGeneration.manual()
    current()
  end

  defp publish_baseline do
    attempt = reserve()
    expect("POST", "completed", [image(PNG.image())])
    assert :ok = Generation.perform(attempt.id, :submit, provider())
    assert current().status == :completed
    current()
  end

  defp request(confirmation) do
    StageDesigner.request_scene_generation(%{confirmation: confirmation.confirmation},
      actor: @owner
    )
  end

  defp current, do: SceneGeneration.current()
  defp state, do: StageDesigner.get_state!(1, actor: @service)
  defp provider, do: SceneGeneration.options(__MODULE__)
  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp image(bytes), do: %{type: "image", mime_type: "image/png", data: Base.encode64(bytes)}

  defp expect(method, status, content \\ [], extra \\ %{}) do
    parent = self()

    Req.Test.expect(__MODULE__, fn conn ->
      send(parent, {:provider_call, conn.method})
      assert conn.method == method

      if method == "GET" do
        assert conn.request_path == "/v1beta/interactions/" <> @provider_id
      end

      response(conn, status, content, extra)
    end)
  end

  defp response(conn, status, content, extra \\ %{}) do
    Req.Test.json(
      conn,
      Map.merge(
        %{
          id: @provider_id,
          status: status,
          steps: [%{type: "model_output", content: content}]
        },
        extra
      )
    )
  end

  defp assert_calls(methods) do
    for method <- methods, do: assert_received({:provider_call, ^method})
    refute_received {:provider_call, _}
  end

  defp reject_writes(clause) do
    Repo.query!("""
    CREATE TEMP TRIGGER generation_failure_test
    #{clause}
    BEGIN
      SELECT RAISE(ABORT, 'synthetic local write failure');
    END
    """)
  end

  defp drop_rejection, do: Repo.query!("DROP TRIGGER generation_failure_test")
end
