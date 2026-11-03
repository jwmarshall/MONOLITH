defmodule Lovelace.StageDesigner.DirectionTest do
  use Lovelace.DataCase, async: false

  alias Lovelace.StageDesigner
  alias Lovelace.StageDesigner.{Direction, DirectionOptions, Settings}
  alias Lovelace.TestSupport.{DisposableStageRepo, PNG, SceneGeneration}

  @owner %{role: :local_owner}
  @service %{role: :stage_designer}
  @now DateTime.add(DateTime.utc_now(), 86_400)
  @fallback "  Keep this configured brief exactly.\n"

  defmodule VaultSpy do
    def get(_account), do: access()
    def put(_account, _key), do: access()
    def delete(_account), do: access()

    defp access do
      send(Process.whereis(__MODULE__), :keychain_access)
      {:error, :locked}
    end
  end

  setup {Req.Test, :verify_on_exit!}

  setup do
    directory = Path.join(System.tmp_dir!(), "lovelace-direction-#{Ash.UUID.generate()}")
    previous = Application.get_env(:lovelace, :stage_designer)
    vault = Application.get_env(:lovelace, :gemini_vault)
    Process.register(self(), VaultSpy)
    Application.put_env(:lovelace, :gemini_vault, VaultSpy)

    Application.put_env(:lovelace, :stage_designer, %Settings{
      storage_dir: directory,
      prompt: @fallback
    })

    Phoenix.PubSub.subscribe(Lovelace.PubSub, "stage_designer")

    on_exit(fn ->
      Application.put_env(:lovelace, :stage_designer, previous)

      if vault,
        do: Application.put_env(:lovelace, :gemini_vault, vault),
        else: Application.delete_env(:lovelace, :gemini_vault)

      File.rm_rf!(directory)
    end)

    %{directory: directory}
  end

  test "owner APIs and persistence enforce strict capabilities" do
    for actor <- [nil, %{}, %{role: "local_owner"}, %{role: "stage_designer"}, @service] do
      assert {:error, %Ash.Error.Forbidden{}} = StageDesigner.scene_direction(actor: actor)
      assert {:error, %Ash.Error.Forbidden{}} = save(DirectionOptions.defaults(), actor)

      assert {:error, %Ash.Error.Forbidden{}} =
               StageDesigner.persist_direction(DirectionOptions.defaults(), actor: actor)
    end

    for actor <- [nil, %{}, %{role: "local_owner"}, %{role: "stage_designer"}] do
      result = StageDesigner.get_direction(1, actor: actor)
      assert match?({:error, %Ash.Error.Forbidden{}}, result), inspect({actor, result})
    end

    assert {:ok, nil} = StageDesigner.get_direction(1, actor: @service)
    assert {:ok, nil} = StageDesigner.get_direction(1, actor: @owner)
    assert {:ok, %{saved?: true}} = save(DirectionOptions.defaults())
    assert {:ok, %Direction{id: 1}} = StageDesigner.get_direction(1, actor: @service)
  end

  test "reads retain the exact configured prompt without initialization or writes" do
    observe_queries()

    for _ <- 1..3 do
      assert {:ok, %{values: values, prompt: @fallback, saved?: false}} =
               StageDesigner.scene_direction(actor: @owner)

      assert values == DirectionOptions.defaults()
    end

    assert {:ok, nil} = StageDesigner.get_direction(1, actor: @service)
    assert {:ok, nil} = StageDesigner.get_state(1, actor: @service)
    refute_receive {:database_write, _}
    refute_receive :keychain_access
  end

  test "saving even unchanged controls adopts guided defaults, upserts, and never reserves or probes" do
    values = DirectionOptions.defaults()
    prompt = DirectionOptions.compose(values)
    assert {:ok, %{values: ^values, prompt: ^prompt, saved?: true}} = save(values)
    values = %{values | subject: "landscape", setting: "coast", palette: "sea_glass"}
    prompt = DirectionOptions.compose(values)
    assert {:ok, %{values: ^values, prompt: ^prompt, saved?: true}} = save(values)
    assert [%Direction{id: 1}] = Ash.read!(Direction, actor: @service)

    Application.put_env(:lovelace, :stage_designer, %{
      Settings.get()
      | prompt: "new environment brief"
    })

    observe_queries()

    assert {:ok, %{values: ^values, prompt: ^prompt, saved?: true}} =
             StageDesigner.scene_direction(actor: @owner)

    assert {:ok, nil} = StageDesigner.get_state(1, actor: @service)
    refute_receive {:database_write, _}
    refute_receive :keychain_access
    refute_receive {:stage_background, _}
  end

  test "invalid and incomplete values cannot create or overwrite saved direction" do
    values = DirectionOptions.defaults()

    for field <- DirectionOptions.fields(),
        invalid <- ["unknown", "", nil, "amber\n", " amber ", 42, %{}] do
      params = Map.put(values, field.key, invalid)
      assert {:error, _} = save(params)
      assert {:error, _} = StageDesigner.persist_direction(params, actor: @owner)
    end

    for key <- Map.keys(values) do
      assert {:error, _} = save(Map.delete(values, key))
    end

    assert {:ok, nil} = StageDesigner.get_direction(1, actor: @service)
    assert {:ok, saved} = save(values)
    assert {:error, _} = save(%{values | subject: "private arbitrary prompt"})
    assert {:ok, ^saved} = StageDesigner.scene_direction(actor: @owner)
  end

  test "signed manual confirmation checks the exact effective prompt before any reservation" do
    assert {:error, _} =
             StageDesigner.request_scene_generation(%{confirmation: ""}, actor: @owner)

    for token <- ["stale", String.trim(@fallback)] do
      assert {:ok, :invalid_confirmation} =
               StageDesigner.request_scene_generation(%{confirmation: token}, actor: @owner)

      assert {:ok, nil} = StageDesigner.get_state(1, actor: @service)
    end

    assert {:ok, snapshot} = SceneGeneration.prepare()
    assert snapshot.prompt == @fallback
    assert {:ok, saved} = save(DirectionOptions.defaults())

    assert {:ok, :direction_changed} =
             StageDesigner.request_scene_generation(%{confirmation: snapshot.confirmation},
               actor: @owner
             )

    assert {:ok, nil} = StageDesigner.get_state(1, actor: @service)

    Req.Test.expect(__MODULE__, fn request ->
      assert_prompt(request, saved.prompt)
      respond(request)
    end)

    assert {:ok, :started} = manual()
    assert %{status: :queued, prompt: prompt} = SceneGeneration.current()
    assert prompt == saved.prompt
    assert %{status: :completed} = SceneGeneration.submit(__MODULE__)
    assert_receive {:stage_background, %{status: :ready, url: url}}, 2_000
    assert is_binary(url)
    refute_receive :keychain_access
  end

  test "unsaved manual and startup use exact configured fallback, without saving defaults" do
    Req.Test.expect(__MODULE__, fn request ->
      assert_prompt(request, @fallback)
      respond(request)
    end)

    assert {:ok, :started} = manual()
    assert %{status: :completed} = SceneGeneration.submit(__MODULE__)
    assert_receive {:stage_background, %{status: :ready, url: url}}, 2_000
    assert is_binary(url)
    enable_startup()

    Req.Test.expect(__MODULE__, fn request ->
      assert_prompt(request, @fallback)
      respond(request)
    end)

    assert {:ok, :generated} = startup(DateTime.add(@now, 86_400))
    assert {:ok, nil} = StageDesigner.get_direction(1, actor: @service)
  end

  test "manual captures saved direction and later startup consumes newly saved direction" do
    assert {:ok, saved} = save(%{DirectionOptions.defaults() | subject: "abstract"})

    Req.Test.expect(__MODULE__, fn request ->
      assert_prompt(request, saved.prompt)
      respond(request)
    end)

    assert {:ok, :started} = manual()
    assert SceneGeneration.current().prompt == saved.prompt

    assert {:ok, next} =
             save(%{DirectionOptions.defaults() | subject: "landscape", light: "dawn"})

    assert %{status: :completed} = SceneGeneration.submit(__MODULE__)
    assert_receive {:stage_background, %{status: :ready, url: url}}, 2_000
    assert is_binary(url)
    enable_startup()

    Req.Test.expect(__MODULE__, fn request ->
      assert_prompt(request, next.prompt)
      respond(request)
    end)

    assert {:ok, :generated} = startup(DateTime.add(@now, 86_400))
    refute_receive :keychain_access
  end

  test "unreadable direction fails closed for generation but disabled startup does not read it",
       %{
         directory: directory
       } do
    pools = DisposableStageRepo.start!(directory)

    DisposableStageRepo.migrate!(pools.first, [
      {20_261_103_210_745, "20261103210745_tracked_gemini_generations.exs",
       Lovelace.Repo.Migrations.TrackedGeminiGenerations}
    ])

    on_exit(fn ->
      DisposableStageRepo.stop(pools.first)
      DisposableStageRepo.stop(pools.second)
    end)

    # This deliberately older disposable schema has stage state but no direction table.
    DisposableStageRepo.on_repo(pools.first, fn ->
      assert {:ok, :disabled} = StageDesigner.generate_on_startup(actor: @service)
      assert {:error, _} = manual()
      enable_startup()
      assert {:ok, :unavailable} = startup(@now)
      assert {:ok, nil} = StageDesigner.get_state(1, actor: @service)
    end)

    refute_receive :keychain_access
    refute_receive {:stage_background, _}
  end

  defp save(values, actor \\ @owner), do: StageDesigner.save_scene_direction(values, actor: actor)

  defp manual, do: SceneGeneration.manual()

  defp startup(now) do
    StageDesigner.generate_on_startup(%{now: now}, actor: @service)
    |> SceneGeneration.finish(__MODULE__)
  end

  defp enable_startup do
    Application.put_env(:lovelace, :stage_designer, %{Settings.get() | enabled: true})
  end

  defp assert_prompt(request, prompt) do
    {:ok, body, request} = Plug.Conn.read_body(request)

    assert Jason.decode!(body)["input"] == prompt

    request
  end

  defp respond(request) do
    SceneGeneration.respond(request, PNG.image())
  end

  defp observe_queries do
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(handler, [:lovelace, :repo, :query], &__MODULE__.observe_query/4, self())

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  @doc false
  def observe_query(_event, _measurements, metadata, owner) do
    if Regex.match?(~r/\A(?:INSERT|UPDATE|DELETE)/, metadata.query),
      do: send(owner, {:database_write, metadata.query})
  end
end
