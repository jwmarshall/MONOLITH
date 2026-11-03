defmodule Lovelace.StageDesigner.ScenesTest do
  use Lovelace.DataCase, async: false

  alias Lovelace.StageDesigner
  alias Lovelace.StageDesigner.{Scene, Settings, Startup, Storage}
  alias Lovelace.TestSupport.{PNG, SceneGeneration}

  @service %{role: :stage_designer}
  @owner %{role: :local_owner}
  @now DateTime.add(DateTime.utc_now(), 86_400)

  setup {Req.Test, :verify_on_exit!}

  setup do
    directory = Path.join(System.tmp_dir!(), "lovelace-scenes-#{Ash.UUID.generate()}")
    previous = Application.get_env(:lovelace, :stage_designer)
    Application.put_env(:lovelace, :stage_designer, %Settings{storage_dir: directory})
    Phoenix.PubSub.subscribe(Lovelace.PubSub, "stage_designer")

    on_exit(fn ->
      Application.put_env(:lovelace, :stage_designer, previous)
      File.rm_rf!(directory)
    end)

    %{directory: directory}
  end

  test "gallery actions require the strict owner, and state remains service-only" do
    digest = String.duplicate("a", 64)

    for actor <- [nil, %{}, %{role: "local_owner"}, @service] do
      assert {:error, _} = StageDesigner.list_scenes(actor: actor)
      assert {:error, _} = StageDesigner.select_scene(digest, actor: actor)
      assert {:error, _} = StageDesigner.request_scene_generation(actor: actor)
    end

    state = StageDesigner.initialize_state!(%{}, actor: @service)
    assert {:error, _} = StageDesigner.get_state(1, actor: @owner)
    assert {:error, _} = Ash.read(Scene, actor: @owner)

    assert {:error, _} =
             Scene
             |> Ash.Changeset.for_create(:publish, %{digest: digest}, actor: @owner)
             |> Ash.create()

    assert {:error, _} =
             StageDesigner.select_state_scene(state, %{selected_digest: digest}, actor: @owner)

    assert {:ok, %{scenes: [], status: :idle, eligible: true, next_attempt_at: nil}} =
             StageDesigner.list_scenes(actor: @owner)
  end

  test "manual eligibility only excludes active or unconfirmed reservations" do
    assert Startup.manual_eligible?(nil)

    for status <- [:idle, :ready, :failed] do
      assert Startup.manual_eligible?(%{status: status})
    end

    refute Startup.manual_eligible?(%{status: :generating})
  end

  test "disabled startup permits manual requests immediately after success, reserved before HTTP" do
    assert {:ok, :disabled} = StageDesigner.generate_on_startup(%{}, actor: @service)
    assert StageDesigner.get_state!(1, actor: @service) == nil

    assert {:ok, :started} = manual(@now)
    assert_receive {:stage_background, %{status: :queued}}
    reserved = StageDesigner.get_state!(1, actor: @service)
    assert reserved.status == :generating
    assert SceneGeneration.current().status == :queued
    assert {:ok, :busy} = manual(DateTime.add(@now, 1))
    assert {:ok, :busy} = manual(DateTime.add(@now, 2 * 86_400))
    assert StageDesigner.get_state!(1, actor: @service).version == reserved.version
    assert gallery(@now).status == :queued
    refute gallery(@now).eligible
    assert gallery(@now).last_attempt_at == reserved.last_attempt_at
    assert gallery(@now).next_attempt_at == DateTime.add(reserved.last_attempt_at, 86_400)

    Req.Test.expect(__MODULE__, &respond(&1, PNG.image()))
    assert %{status: :completed} = SceneGeneration.submit(__MODULE__)
    assert_receive {:stage_background, %{status: :ready, url: url}}, 1_000
    assert is_binary(url)
    assert %{status: :ready, scenes: [%{active: true, available: true}]} = gallery(@now)
    assert gallery(@now).eligible

    assert {:ok, :started} = manual(DateTime.add(@now, 1))
    Req.Test.expect(__MODULE__, &respond(&1, PNG.image(3, 2)))
    assert %{status: :completed} = SceneGeneration.submit(__MODULE__)
    assert_receive {:stage_background, %{status: :ready, url: next_url}}, 1_000
    assert next_url != url
    assert gallery(@now).eligible
  end

  test "manual requests immediately after failure are allowed but startup keeps its cooldown" do
    Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 429, "fake rejection"))
    assert {:ok, :started} = manual(@now)
    assert %{status: :failed} = SceneGeneration.submit(__MODULE__)
    assert_receive {:stage_background, %{status: :failed}}, 1_000
    assert StageDesigner.background!().status == :failed
    assert gallery(@now).status == :failed
    assert gallery(@now).eligible
    failed_at = StageDesigner.get_state!(1, actor: @service).last_attempt_at

    Application.put_env(:lovelace, :stage_designer, %{Settings.get() | enabled: true})
    assert {:ok, :cached} = startup(DateTime.add(failed_at, 86_399))
    assert {:ok, :started} = manual(@now)
    reserved = StageDesigner.get_state!(1, actor: @service)
    assert {:ok, :cached} = startup(DateTime.add(reserved.last_attempt_at, 86_399))
    Req.Test.expect(__MODULE__, &respond(&1, PNG.image()))
    assert %{status: :completed} = SceneGeneration.submit(__MODULE__)
    assert_receive {:stage_background, %{status: :ready, url: url}}, 1_000
    assert is_binary(url)
    assert {:ok, :cached} = startup(DateTime.add(reserved.last_attempt_at, 86_399))
    assert gallery(@now).eligible
  end

  test "interrupted reservations remain busy indefinitely without guessed recovery" do
    StageDesigner.initialize_state!(%{}, actor: @service)
    |> StageDesigner.reserve_state!(%{last_attempt_at: @now}, actor: @service)

    reserved = StageDesigner.get_state!(1, actor: @service)

    for seconds <- [-1, 1, 86_399, 86_400, 2 * 86_400] do
      now = DateTime.add(@now, seconds)
      assert {:ok, :busy} = manual(now)
      assert gallery(now).status == :uncertain
      assert gallery(now).next_attempt_at == DateTime.add(@now, 86_400)
      refute gallery(now).eligible
    end

    assert StageDesigner.background!().status == :uncertain
    unchanged = StageDesigner.get_state!(1, actor: @service)
    assert unchanged.status == :generating
    assert unchanged.last_attempt_at == reserved.last_attempt_at
    assert unchanged.version == reserved.version
  end

  test "selection persists without changing history, metadata, version, or cooldown" do
    generate(0)
    generate(1)
    state = StageDesigner.get_state!(1, actor: @service)
    [latest, older] = state.history
    flush_backgrounds()
    disable_startup()

    assert {:ok, :selected} = StageDesigner.select_scene(older, actor: @owner)
    assert_receive {:stage_background, %{url: url}}
    assert url == Storage.url(older)
    selected = StageDesigner.get_state!(1, actor: @service)
    assert selected.selected_digest == older

    assert Map.drop(selected, [:selected_digest, :__metadata__]) ==
             Map.drop(state, [:selected_digest, :__metadata__])

    assert selected.version == state.version
    assert StageDesigner.background!().url == url
    assert {:ok, :disabled} = StageDesigner.generate_on_startup(%{}, actor: @service)
    assert StageDesigner.background!().url == url
    assert [^latest, ^older] = Enum.map(gallery(@now).scenes, & &1.digest)
    assert [%{active: false}, %{active: true}] = gallery(@now).scenes
    Application.put_env(:lovelace, :stage_designer, %{Settings.get() | enabled: true})
    assert {:ok, :cached} = startup(DateTime.add(@now, 86_401))
    assert gallery(@now).eligible
  end

  test "selection during an in-flight request does not invalidate successful publication" do
    generate(0)
    generate(1)
    [_, older] = StageDesigner.get_state!(1, actor: @service).history
    disable_startup()
    assert {:ok, :started} = manual(DateTime.add(@now, 2 * 86_400))
    Req.Test.expect(__MODULE__, &SceneGeneration.rendering/1)
    assert %{status: :rendering} = SceneGeneration.submit(__MODULE__)
    Req.Test.expect(__MODULE__, &respond(&1, PNG.image(9, 2)))
    reserved = StageDesigner.get_state!(1, actor: @service)
    assert {:ok, :selected} = StageDesigner.select_scene(older, actor: @owner)
    selected = StageDesigner.get_state!(1, actor: @service)
    assert selected.version == reserved.version
    assert selected.status == :generating
    assert StageDesigner.background!().url == Storage.url(older)
    flush_backgrounds()
    assert %{status: :completed} = SceneGeneration.poll(__MODULE__)
    assert_receive {:stage_background, %{status: :ready, url: url}}, 1_000
    published = StageDesigner.get_state!(1, actor: @service)
    assert published.status == :ready
    assert published.selected_digest == hd(published.history)
    assert published.selected_digest != older
    assert Storage.url(published.selected_digest) == url
    assert published.version == reserved.version + 1
  end

  test "identical generated bytes restore newest selection against the current record" do
    generate(0)
    generate(1)
    [latest, older] = StageDesigner.get_state!(1, actor: @service).history
    disable_startup()
    assert {:ok, :started} = manual(DateTime.add(@now, 2 * 86_400))
    Req.Test.expect(__MODULE__, &SceneGeneration.rendering/1)
    assert %{status: :rendering} = SceneGeneration.submit(__MODULE__)
    Req.Test.expect(__MODULE__, &respond(&1, PNG.image(3, 2)))
    assert {:ok, :selected} = StageDesigner.select_scene(older, actor: @owner)
    flush_backgrounds()
    assert %{status: :completed} = SceneGeneration.poll(__MODULE__)
    assert_receive {:stage_background, %{status: :ready, url: url}}, 1_000
    state = StageDesigner.get_state!(1, actor: @service)
    assert state.status == :ready
    assert state.history == [latest, older]
    assert state.selected_digest == latest
    assert Ash.count!(Scene, actor: @service) == 2
    assert [%{digest: ^latest, generated_at: date} | _] = gallery(@now).scenes
    assert date == state.generated_at
    assert url == Storage.url(latest)
    assert StageDesigner.background!().url == url
  end

  test "selected files are validated, with newest-first fallback and honest availability", %{
    directory: directory
  } do
    for day <- 0..2, do: generate(day)
    state = StageDesigner.get_state!(1, actor: @service)
    [latest, middle, oldest] = state.history
    assert {:ok, :selected} = StageDesigner.select_scene(oldest, actor: @owner)
    File.write!(Path.join(directory, oldest <> ".png"), PNG.image(20, 2))
    assert StageDesigner.background!().url == Storage.url(latest)

    assert [%{active: true}, %{active: false}, %{available: false, url: nil}] =
             gallery(@now).scenes

    assert {:error, _} = StageDesigner.select_scene(oldest, actor: @owner)
    assert {:error, _} = StageDesigner.select_scene(String.duplicate("a", 64), actor: @owner)
    assert {:error, _} = StageDesigner.select_scene("../private", actor: @owner)
    assert StageDesigner.get_state!(1, actor: @service).selected_digest == oldest
    File.write!(Path.join(directory, latest <> ".png"), "damaged")
    assert StageDesigner.background!().url == Storage.url(middle)
    File.write!(Path.join(directory, middle <> ".png"), "damaged")
    assert StageDesigner.background!().url == nil
    refute Enum.any?(gallery(@now).scenes, & &1.active)
  end

  test "catalog timestamps are canonical and unregistered selection is ignored" do
    settings = Settings.get()
    {:ok, older} = Storage.store(settings, PNG.image(3, 2))
    {:ok, latest} = Storage.store(settings, PNG.image(4, 2))

    StageDesigner.initialize_state!(%{}, actor: @service)
    |> StageDesigner.reserve_state!(%{last_attempt_at: @now}, actor: @service)
    |> StageDesigner.publish_state!(%{history: [latest, older], generated_at: @now},
      actor: @service
    )

    assert {:ok, _} = Scene.publish(older, nil)
    assert {:ok, _} = Scene.publish(latest, @now)

    assert [%{generated_at: @now, active: true}, %{generated_at: nil}] = gallery(@now).scenes
    state = StageDesigner.get_state!(1, actor: @service)

    StageDesigner.select_state_scene!(state, %{selected_digest: String.duplicate("a", 64)},
      actor: @service
    )

    assert StageDesigner.background!().url == Storage.url(latest)
    assert [%{active: true}, %{active: false}] = gallery(@now).scenes
  end

  test "unlimited catalog preserves files with bounded recent state and paginated gallery", %{
    directory: directory
  } do
    for day <- 0..24 do
      generate(day)
      state = StageDesigner.get_state!(1, actor: @service)
      assert state.selected_digest == hd(state.history)
      assert map_size(state.scene_dates) == min(day + 1, 7)
      assert MapSet.new(Map.keys(state.scene_dates)) == MapSet.new(state.history)

      assert state.scene_dates[state.selected_digest] == DateTime.to_iso8601(state.generated_at)

      assert {:ok, :selected} =
               StageDesigner.select_scene(List.last(state.history), actor: @owner)
    end

    first = gallery(@now)
    assert %{page: 1, page_size: 20, has_previous: false, has_next: true} = first
    assert length(first.scenes) == 20
    assert Enum.all?(first.scenes, & &1.available)

    second = StageDesigner.list_scenes!(%{page: 2}, actor: @owner)
    assert %{page: 2, has_previous: true, has_next: false} = second
    assert length(second.scenes) == 5
    assert length(Enum.filter(File.ls!(directory), &String.ends_with?(&1, ".png"))) == 25
    assert MapSet.disjoint?(MapSet.new(first.scenes), MapSet.new(second.scenes))
    oldest = List.last(second.scenes)
    state = StageDesigner.get_state!(1, actor: @service)
    refute oldest.digest in state.history
    flush_backgrounds()

    assert {:ok, :selected} = StageDesigner.select_scene(oldest.digest, actor: @owner)
    assert_receive {:stage_background, %{url: url}}
    assert url == oldest.url
    assert StageDesigner.background!().url == oldest.url
    assert {:ok, _bytes} = StageDesigner.image(oldest.digest)
    assert StageDesigner.get_state!(1, actor: @service).version == state.version
    refute Enum.any?(gallery(@now).scenes, & &1.active)

    assert Enum.find(StageDesigner.list_scenes!(%{page: 2}, actor: @owner).scenes, & &1.active) ==
             %{oldest | active: true}

    assert :ok = Storage.prune(Settings.get(), [])
    assert :ok = Storage.reconcile(Settings.get(), [], DateTime.to_unix(@now) + 100 * 86_400)
    assert File.exists?(Path.join(directory, oldest.digest <> ".png"))

    generate(25)
    published = StageDesigner.get_state!(1, actor: @service)
    assert published.selected_digest == hd(published.history)
    assert published.selected_digest != oldest.digest
    assert {:ok, _bytes} = StageDesigner.image(oldest.digest)
    assert length(published.history) == 7
    assert map_size(published.scene_dates) == 7

    assert %{scenes: [], has_previous: true, has_next: false, page: 100} =
             StageDesigner.list_scenes!(%{page: 100}, actor: @owner)
  end

  test "pagination rejects non-positive and invalid page inputs" do
    for page <- [0, -1, "no", 1.5] do
      assert {:error, _} = StageDesigner.list_scenes(%{page: page}, actor: @owner)
    end
  end

  defp gallery(now), do: StageDesigner.list_scenes!(actor: @owner, context: %{now: now})

  defp manual(_now), do: SceneGeneration.manual()

  defp startup(now) do
    StageDesigner.generate_on_startup(%{now: now}, actor: @service)
    |> SceneGeneration.finish(__MODULE__)
  end

  defp generate(day) do
    settings = %{Settings.get() | enabled: true}
    Application.put_env(:lovelace, :stage_designer, settings)
    Req.Test.expect(__MODULE__, &respond(&1, PNG.image(day + 2, 2)))
    now = DateTime.add(@now, day * 86_400)

    assert {:ok, :generated} =
             StageDesigner.generate_on_startup(%{now: now}, actor: @service)
             |> SceneGeneration.finish(__MODULE__)
  end

  defp disable_startup do
    Application.put_env(:lovelace, :stage_designer, %{Settings.get() | enabled: false})
  end

  defp flush_backgrounds do
    receive do
      {:stage_background, _} -> flush_backgrounds()
    after
      0 -> :ok
    end
  end

  defp respond(request, bytes) do
    SceneGeneration.respond(request, bytes)
  end
end
