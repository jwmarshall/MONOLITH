defmodule Lovelace.StageDesigner.GenerationFailuresTest do
  use LovelaceWeb.ConnCase, async: false
  use Oban.Testing, repo: Lovelace.Repo, engine: Oban.Engines.Lite

  import ExUnit.CaptureLog

  alias Lovelace.{Repo, StageDesigner}
  alias Lovelace.StageDesigner.{Attempt, Generation, GenerationWorker, Scene, Settings, Storage}
  alias Lovelace.TestSupport.{PNG, SceneGeneration}

  @owner %{role: :local_owner}
  @service %{role: :stage_designer}
  @provider_id "interaction_failure_recovery"
  @private "private-provider-output-never-persist"

  setup {Req.Test, :verify_on_exit!}

  setup do
    previous = Application.get_env(:lovelace, :stage_designer)

    directory =
      Path.join(System.tmp_dir!(), "lovelace-generation-failures-#{Ash.UUID.generate()}")

    Application.put_env(:lovelace, :stage_designer, %Settings{storage_dir: directory})

    on_exit(fn ->
      Application.put_env(:lovelace, :stage_designer, previous)
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
