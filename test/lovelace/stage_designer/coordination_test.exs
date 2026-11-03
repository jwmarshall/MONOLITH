defmodule Lovelace.StageDesigner.CoordinationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Lovelace.Repo
  alias Lovelace.StageDesigner
  alias Lovelace.StageDesigner.{Coordination, Generation, Scene, Settings, Startup, Storage}
  alias Lovelace.TestSupport.{DisposableStageRepo, PNG, SceneGeneration}

  @actor %{role: :stage_designer}
  @now ~U[2026-11-01 12:00:00.000000Z]

  setup do
    directory = Path.join(System.tmp_dir!(), "lovelace-coordination-#{Ash.UUID.generate()}")
    %{first: first, second: second} = repos = DisposableStageRepo.start!(directory)

    DisposableStageRepo.migrate!(first, [
      {20_261_103_184_507, "20261103184507_add_scene_direction.exs",
       Lovelace.Repo.Migrations.AddSceneDirection},
      {20_261_103_210_745, "20261103210745_tracked_gemini_generations.exs",
       Lovelace.Repo.Migrations.TrackedGeminiGenerations},
      {20_261_102_060_000, "20261102060000_add_gmail_jobs.exs",
       Lovelace.Repo.Migrations.AddGmailJobs}
    ])

    settings = %Settings{
      enabled: true,
      storage_dir: Path.join(directory, "images")
    }

    previous = Application.get_env(:lovelace, :stage_designer)
    Application.put_env(:lovelace, :stage_designer, settings)
    Repo.put_dynamic_repo(first)
    StageDesigner.initialize_state!(%{}, actor: @actor)

    on_exit(fn ->
      Application.put_env(:lovelace, :stage_designer, previous)
      DisposableStageRepo.stop(first)
      DisposableStageRepo.stop(second)
      File.rm_rf!(directory)
    end)

    Map.put(repos, :settings, settings)
  end

  test "A's delayed cleanup preserves every catalog-registered publication", context do
    %{first: first, second: second, settings: settings} = context
    parent = self()

    a =
      worker(first, fn ->
        published = publish!(settings, PNG.image(2, 2), @now)
        send(parent, {:a_published, self(), published.history})
        receive do: (:cleanup -> Storage.prune(settings, published.history))
      end)

    assert_receive {:a_published, a_pid, stale_history}, 2_000

    b = on_repo(second, fn -> publish!(settings, PNG.image(3, 2), later(1)) end)
    send(a_pid, :cleanup)
    assert Task.await(a, 2_000) == :ok
    assert StageDesigner.get_state!(1, actor: @actor).history == b.history
    assert_image(settings, hd(b.history), PNG.image(3, 2))
    assert File.exists?(image_path(settings, hd(stale_history)))
    assert length(image_files(settings)) == 2
  end

  test "stale reconciliation rereads authority and preserves five-minute orphan/temp grace", %{
    second: second,
    settings: settings
  } do
    old = publish!(settings, PNG.image(2, 2), @now)
    current = on_repo(second, fn -> publish!(settings, PNG.image(3, 2), later(1)) end)
    old_path = image_path(settings, hd(old.history))
    current_path = image_path(settings, hd(current.history))
    temporary = Path.join(settings.storage_dir, ".stage-#{Ash.UUID.generate()}.tmp")
    recent = Path.join(settings.storage_dir, ".stage-#{Ash.UUID.generate()}.tmp")
    unrelated = Path.join(settings.storage_dir, "user-file.txt")
    Enum.each([temporary, recent, unrelated], &File.write!(&1, "synthetic interrupted write"))
    now = DateTime.to_unix(later(1))
    Enum.each([old_path, current_path, temporary, unrelated], &File.touch!(&1, now - 600))
    File.touch!(recent, now - 299)

    assert :ok = Storage.reconcile(settings, old.history, now)
    assert File.exists?(old_path)
    refute File.exists?(temporary)
    assert File.exists?(recent)
    assert File.exists?(unrelated)
    assert_image(settings, hd(current.history), PNG.image(3, 2))
  end

  test "current in-flight writes and identical digests exclude cleanup on another connection", %{
    first: first,
    second: second,
    settings: settings
  } do
    original = publish!(settings, PNG.image(2, 2), @now)

    for {bytes, day} <- [{PNG.image(3, 2), 1}, {PNG.image(3, 2), 2}] do
      reserved = reserve!(later(day))
      task = paused_publication(first, settings, reserved, bytes, later(day))
      assert_receive {:publication_paused, pid}, 2_000
      digest = hash(bytes)
      assert {:ok, ^bytes} = Storage.read(settings, digest)

      # An actual second SQLite writer fails SQLITE_BUSY, not a shared sandbox
      # read. It cannot obtain permission to delete an in-flight file.
      assert {:error, :coordination_error} =
               on_repo(second, fn -> Storage.prune(settings, original.history) end)

      assert File.exists?(image_path(settings, digest))
      send(pid, :commit)
      assert {:ok, published} = Task.await(task, 2_000)
      assert :ok = on_repo(second, fn -> Storage.prune(settings, original.history) end)
      assert published.history == [digest | original.history]
      assert_image(settings, digest, bytes)
    end
  end

  test "selection shares publication exclusion and uses the durable catalog", %{
    first: first,
    second: second,
    settings: settings
  } do
    original = publish!(settings, PNG.image(2, 2), @now)
    selected = hd(original.history)
    reserved = reserve!(later(1))
    task = paused_publication(first, settings, reserved, PNG.image(3, 2), later(1))
    assert_receive {:publication_paused, pid}, 2_000

    assert {:error, :coordination_error} =
             on_repo(second, fn -> Storage.select(settings, selected) end)

    send(pid, :commit)
    assert {:ok, published} = Task.await(task, 2_000)

    # A later publication does not expire old gallery selections.
    assert {:ok, :selected} = on_repo(second, fn -> Storage.select(settings, selected) end)

    assert StageDesigner.get_state!(1, actor: @actor).selected_digest == selected
    assert :ok = Storage.prune(settings, published.history)
    assert File.exists?(image_path(settings, selected))
  end

  test "notification snapshots exclude publication until synchronous dispatch completes", %{
    first: first,
    second: second,
    settings: settings
  } do
    Phoenix.PubSub.subscribe(Lovelace.PubSub, "stage_designer")
    original = publish!(settings, PNG.image(2, 2), @now)
    reserved = reserve!(later(1))
    parent = self()
    handler = {__MODULE__, make_ref()}
    on_exit(fn -> :telemetry.detach(handler) end)

    notification =
      worker(first, fn ->
        :telemetry.attach(
          handler,
          [:lovelace, :repo, :query],
          &__MODULE__.pause_manifest/4,
          {self(), parent}
        )

        try do
          Startup.notify()
        after
          :telemetry.detach(handler)
        end
      end)

    assert_receive {:manifest_paused, pid}, 2_000
    bytes = PNG.image(3, 2)

    assert {:error, {:storage, :storage_error}} =
             on_repo(second, fn ->
               Storage.store_and_publish(settings, bytes, reserved, later(1))
             end)

    assert {:error, :coordination_error} =
             on_repo(second, fn ->
               Storage.select(settings, hd(original.history))
             end)

    send(pid, :continue_cleanup)
    assert Task.await(notification, 2_000) == :ok
    assert_receive {:stage_background, %{url: old_url}}, 1_000
    assert old_url == Storage.url(hd(original.history))

    {:ok, published} =
      on_repo(second, fn ->
        Storage.store_and_publish(settings, bytes, reserved, later(1))
      end)

    assert :ok = on_repo(second, &Startup.notify/0)
    assert_receive {:stage_background, %{url: new_url}}, 1_000
    assert new_url == Storage.url(hd(published.history))
    assert new_url != old_url
    refute_receive {:stage_background, _}
  end

  test "publication process death rolls back SQL, retains prior files and releases the writer lock",
       %{
         first: first,
         second: second,
         settings: settings
       } do
    original = publish!(settings, PNG.image(2, 2), @now)
    reserved = reserve!(later(1))
    aborted_bytes = PNG.image(4, 2)
    task = paused_publication(first, settings, reserved, aborted_bytes, later(1))
    assert_receive {:publication_paused, pid}, 2_000
    # Do not link this intentionally killed owner to the test process.
    Process.unlink(pid)
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 2_000
    Task.shutdown(task, :brutal_kill)

    current = on_repo(second, fn -> StageDesigner.get_state!(1, actor: @actor) end)
    assert current == reserved
    assert current.history == original.history
    assert {:ok, false} = Scene.registered(hash(aborted_bytes))
    assert_image(settings, hd(original.history), PNG.image(2, 2))

    # The interrupted paid attempt remains reserved and cannot be retried by
    # ordinary startup, even though no new manifest committed.
    assert {:ok, :cached} = startup(later(1))
    winner = on_repo(second, fn -> publish!(settings, PNG.image(5, 2), later(2)) end)
    stale_bytes = PNG.image(6, 2)

    assert {:error, {:publication, :publication_error}} =
             Storage.store_and_publish(settings, stale_bytes, reserved, later(1))

    refute File.exists?(image_path(settings, hash(stale_bytes)))
    assert {:ok, false} = Scene.registered(hash(stale_bytes))

    now = DateTime.to_unix(later(2))
    File.touch!(image_path(settings, hash(aborted_bytes)), now - 600)
    assert :ok = Storage.reconcile(settings, original.history, now)
    refute File.exists?(image_path(settings, hash(aborted_bytes)))
    assert_image(settings, hd(winner.history), PNG.image(5, 2))
  end

  test "cleanup refuses tentative publication transactions, including rollback", %{
    settings: settings
  } do
    original = publish!(settings, PNG.image(2, 2), @now)
    reserved = reserve!(later(1))
    {:ok, digest} = Storage.store(settings, PNG.image(3, 2))
    File.touch!(image_path(settings, digest), System.system_time(:second) - 600)

    assert {:error, :nested_storage_transaction} =
             Repo.transaction(fn ->
               StageDesigner.publish_state!(
                 reserved,
                 %{history: [digest], generated_at: later(1)},
                 actor: @actor
               )

               assert {:error, :nested_storage_transaction} = Storage.prune(settings, [digest])
               Repo.rollback(:nested_storage_transaction)
             end)

    assert StageDesigner.get_state!(1, actor: @actor) == reserved
    assert_image(settings, hd(original.history), PNG.image(2, 2))
    assert :ok = Storage.prune(settings, [digest])
    refute File.exists?(image_path(settings, digest))
  end

  test "distinct catalog preservation and lock acquisition do not modify reservations", %{
    settings: settings
  } do
    before = StageDesigner.get_state!(1, actor: @actor)
    assert :ok = Storage.reconcile(settings, [], DateTime.to_unix(@now))
    assert {:ok, orphan} = Storage.store(settings, PNG.image(9, 2))
    File.touch!(image_path(settings, orphan), System.system_time(:second) - 600)
    assert StageDesigner.get_state!(1, actor: @actor) == before

    histories =
      for {width, day} <- [{2, 0}, {3, 1}, {2, 2}, {4, 3}, {5, 4}] do
        published = publish!(settings, PNG.image(width, 2), later(day))
        assert :ok = Storage.prune(settings, [])
        published.history
      end

    assert Enum.at(histories, 2) == [hash(PNG.image(2, 2)), hash(PNG.image(3, 2))]
    assert List.last(histories) == Enum.map([5, 4, 2, 3], &hash(PNG.image(&1, 2)))
    assert length(image_files(settings)) == 4
  end

  test "substantive cleanup errors do not undo publication or permit another startup", %{
    settings: settings
  } do
    published = publish!(settings, PNG.image(2, 2), @now)
    blocked = Path.join(settings.storage_dir, "blocked")
    File.write!(blocked, "not a directory")
    broken = %{settings | storage_dir: blocked}
    assert {:error, :coordination_error} = Storage.prune(broken, published.history)
    Application.put_env(:lovelace, :stage_designer, broken)
    assert {:ok, :cached} = startup(@now)
    assert StageDesigner.get_state!(1, actor: @actor).history == published.history
  end

  test "main connection death cannot revoke a live filesystem cleanup owner", %{
    first: first,
    first_connection: connection,
    second: second,
    settings: settings
  } do
    original = publish!(settings, PNG.image(2, 2), @now)
    {:ok, orphan} = Storage.store(settings, PNG.image(3, 2))
    File.touch!(image_path(settings, orphan), System.system_time(:second) - 600)
    parent = self()
    handler = {__MODULE__, make_ref()}
    on_exit(fn -> :telemetry.detach(handler) end)

    task =
      worker(first, fn ->
        :telemetry.attach(
          handler,
          [:lovelace, :repo, :query],
          &__MODULE__.pause_manifest/4,
          {self(), parent}
        )

        try do
          Storage.prune(settings, [])
        after
          :telemetry.detach(handler)
        end
      end)

    assert_receive {:manifest_paused, pid}, 2_000
    monitor = Process.monitor(connection)
    Process.exit(connection, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^connection, :killed}, 2_000

    # Another independently owned main connection is usable, but its filesystem
    # work is excluded by the private handle still held by the paused callback.
    assert on_repo(second, fn -> StageDesigner.get_state!(1, actor: @actor) end).history ==
             original.history

    assert {:error, :coordination_error} = on_repo(second, fn -> Storage.prune(settings, []) end)
    assert File.exists?(image_path(settings, orphan))
    send(pid, :continue_cleanup)
    assert Task.await(task, 2_000) == :ok
    refute File.exists?(image_path(settings, orphan))
    assert_image(settings, hd(original.history), PNG.image(2, 2))
  end

  test "main transaction timeout does not expire the private lock", %{
    first: first,
    first_connection: connection,
    second: second,
    settings: settings
  } do
    parent = self()

    task =
      worker(first, fn ->
        Coordination.with_lock(settings, fn ->
          Repo.transaction(
            fn ->
              send(parent, {:transaction_paused, self()})
              receive do: (:finish -> :finished)
            end,
            timeout: 25
          )
        end)
      end)

    assert_receive {:transaction_paused, pid}, 2_000
    # Listener evidence, not a sleep: DBConnection has actually revoked/reopened
    # its pooled main connection while the filesystem callback is still alive.
    log =
      capture_log(fn ->
        assert_receive {:disconnected, ^connection, _tag}, 2_000

        assert {:error, :coordination_error} =
                 on_repo(second, fn -> Coordination.with_lock(settings, fn -> :ok end) end)

        send(pid, :finish)
        assert {:error, :rollback} = Task.await(task, 2_000)
      end)

    refute log =~ "synthetic-key"
    assert :ok = on_repo(second, fn -> Coordination.with_lock(settings, fn -> :ok end) end)
  end

  test "killing the private owner permits a fresh process, never a resumed stale callback", %{
    first: first,
    second: second,
    settings: settings
  } do
    original = publish!(settings, PNG.image(2, 2), @now)
    parent = self()

    task =
      worker(first, fn ->
        Coordination.with_lock(settings, fn ->
          send(parent, {:private_owner_paused, self()})

          receive do
            :stale_delete ->
              :file.delete(image_path(settings, hd(original.history)), [:raw])
              send(parent, :stale_callback_resumed)
          end
        end)
      end)

    assert_receive {:private_owner_paused, pid}, 2_000
    Process.unlink(pid)
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 2_000
    Task.shutdown(task, :brutal_kill)

    fresh =
      worker(second, fn ->
        # Republish the identical digest that the obsolete callback intended to
        # delete. Killing before its raw call must make that deletion impossible.
        publish!(settings, PNG.image(2, 2), later(1))
        Storage.prune(settings, [])
      end)

    assert Task.await(fresh, 2_000) == :ok
    send(pid, :stale_delete)
    refute Process.alive?(pid)
    refute_received :stale_callback_resumed
    assert_image(settings, hd(original.history), PNG.image(2, 2))
  end

  test "real cleanup executes raw deletion in its lock-owning process", %{
    first: first,
    settings: settings
  } do
    publish!(settings, PNG.image(2, 2), @now)
    {:ok, orphan} = Storage.store(settings, PNG.image(3, 2))
    path = image_path(settings, orphan)
    File.touch!(path, System.system_time(:second) - 600)
    parent = self()

    task =
      worker(first, fn ->
        send(parent, {:ready_for_delete_trace, self()})
        receive do: (:start_cleanup -> Storage.prune(settings, []))
      end)

    assert_receive {:ready_for_delete_trace, pid}, 2_000
    :erlang.trace_pattern({:file, :delete, 2}, true, [:local])
    :erlang.trace(pid, true, [:call, {:tracer, self()}])

    try do
      send(pid, :start_cleanup)
      assert_receive {:trace, ^pid, :call, {:file, :delete, [^path, [:raw]]}}, 2_000
      assert Task.await(task, 2_000) == :ok
      refute File.exists?(path)
    after
      :erlang.trace_pattern({:file, :delete, 2}, false, [:local])
      if Process.alive?(pid), do: :erlang.trace(pid, false, [:call])
    end
  end

  test "sidecar is private, stable across cleanup, and never accepted as a symlink", %{
    settings: settings
  } do
    published = publish!(settings, PNG.image(2, 2), @now)
    sidecar = Path.join(settings.storage_dir, ".stage-coordination.sqlite3")
    stat = File.stat!(sidecar)
    assert Bitwise.band(stat.mode, 0o777) == 0o600
    assert :ok = Storage.prune(settings, [])
    assert File.stat!(sidecar).inode == stat.inode

    # No live handle exists here. Only this disposable test removes the file;
    # production must keep it for the root's entire lifetime.
    File.rm!(sidecar)
    File.ln_s!(image_path(settings, hd(published.history)), sidecar)
    assert {:error, :coordination_error} = Storage.prune(settings, [])
    assert {:error, :storage_error} = Storage.store(settings, PNG.image(3, 2))
    assert_image(settings, hd(published.history), PNG.image(2, 2))
  end

  test "reservation is committed and independently visible before fake HTTP proceeds", %{
    first: first,
    second: second,
    settings: settings
  } do
    parent = self()
    bytes = PNG.image(2, 2)

    plug = fn request ->
      # Gemini executes its plug in a Task: select the independent pool explicitly,
      # never depend on dynamic Repo process dictionary inheritance or sandbox sharing.
      state = on_repo(second, fn -> StageDesigner.get_state!(1, actor: @actor) end)
      send(parent, {:http_boundary, self(), state})
      receive do: (:respond -> respond(request, bytes))
    end

    assert {:ok, :started} = on_repo(first, fn -> startup(@now) end)
    attempt = SceneGeneration.current()
    assert attempt.status == :queued

    task =
      worker(first, fn ->
        Generation.perform(attempt.id, :submit, api_key: "fake-stage-key", plug: plug)
      end)

    assert_receive {:http_boundary, http_pid, state}, 2_000
    assert state.status == :generating
    assert state.last_attempt_at == @now
    assert state.version == 1
    assert state.history == []

    # An independent caller can take storage exclusion while HTTP is paused.
    # This probes the sidecar, not a main-database writer transaction.
    assert :ok = on_repo(second, fn -> Coordination.with_lock(settings, fn -> :ok end) end)
    send(http_pid, :respond)
    assert :ok = Task.await(task, 2_000)
    assert SceneGeneration.current().status == :completed
    assert_image(settings, hash(bytes), bytes)
  end

  defp paused_publication(repo, settings, reserved, bytes, now) do
    parent = self()
    handler = {__MODULE__, make_ref()}
    on_exit(fn -> :telemetry.detach(handler) end)

    worker(repo, fn ->
      :telemetry.attach(
        handler,
        [:lovelace, :repo, :query],
        &__MODULE__.pause_publish/4,
        {self(), parent}
      )

      try do
        Storage.store_and_publish(settings, bytes, reserved, now)
      after
        :telemetry.detach(handler)
      end
    end)
  end

  @doc false
  def pause_publish(_event, _measurements, metadata, {owner, parent}) do
    if self() == owner and String.starts_with?(metadata.query, "UPDATE") and
         String.contains?(metadata.query, "\"history\"") do
      send(parent, {:publication_paused, self()})
      receive do: (:commit -> :ok)
    end
  end

  @doc false
  def pause_manifest(_event, _measurements, metadata, {owner, parent}) do
    if self() == owner and String.starts_with?(metadata.query, "SELECT") and
         String.contains?(metadata.query, "stage_designer_states") do
      send(parent, {:manifest_paused, self()})
      receive do: (:continue_cleanup -> :ok)
    end
  end

  defp publish!(settings, bytes, now) do
    reserved = reserve!(now)
    {:ok, published} = Storage.store_and_publish(settings, bytes, reserved, now)
    published
  end

  defp reserve!(now) do
    StageDesigner.get_state!(1, actor: @actor)
    |> StageDesigner.reserve_state!(%{last_attempt_at: now}, actor: @actor)
  end

  defp assert_image(settings, digest, bytes) do
    assert {:ok, ^bytes} = Storage.read(settings, digest)
    assert {:ok, ^bytes} = StageDesigner.image(digest)
    assert StageDesigner.background!().url == Storage.url(digest)
    conn = Phoenix.ConnTest.build_conn(:get, "http://localhost/")

    conn =
      LovelaceWeb.Endpoint.call(
        %{
          conn
          | request_path: Storage.url(digest),
            path_info: ["stage", "background", digest <> ".png"]
        },
        LovelaceWeb.Endpoint.init([])
      )

    assert conn.status == 200
    assert conn.resp_body == bytes
  end

  defp image_files(settings) do
    Enum.filter(File.ls!(settings.storage_dir), &(Path.extname(&1) in [".png", ".jpg"]))
  end

  defp image_path(settings, digest), do: Path.join(settings.storage_dir, digest <> ".png")
  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp later(day), do: DateTime.add(@now, day * 86_400)
  defp on_repo(repo, fun), do: DisposableStageRepo.on_repo(repo, fun)
  defp worker(repo, fun), do: Task.async(fn -> on_repo(repo, fun) end)

  defp startup(now), do: StageDesigner.generate_on_startup(%{now: now}, actor: @actor)

  defp respond(request, bytes) do
    SceneGeneration.respond(request, bytes)
  end
end
