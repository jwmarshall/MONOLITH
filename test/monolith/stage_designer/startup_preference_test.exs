defmodule Monolith.StageDesigner.StartupPreferenceTest do
  use Monolith.DataCase, async: false
  use Oban.Testing, repo: Monolith.Repo, engine: Oban.Engines.Lite

  alias Monolith.{Repo, StageDesigner}

  alias Monolith.StageDesigner.{
    Attempt,
    Generation,
    GenerationWorker,
    Settings,
    StartupPreference
  }

  alias Monolith.TestSupport.{PNG, SceneGeneration}

  @owner %{role: :local_owner}
  @service %{role: :stage_designer}
  @now DateTime.add(DateTime.utc_now(), 86_400)

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
    directory = Path.join(System.tmp_dir!(), "monolith-startup-preference-#{Ash.UUID.generate()}")
    previous = Application.get_env(:monolith, :stage_designer)
    vault = Application.get_env(:monolith, :gemini_vault)
    Process.register(self(), VaultSpy)
    Application.put_env(:monolith, :gemini_vault, VaultSpy)

    Application.put_env(:monolith, :stage_designer, %Settings{
      enabled: true,
      storage_dir: directory
    })

    Phoenix.PubSub.subscribe(Monolith.PubSub, "stage_designer")

    on_exit(fn ->
      Application.put_env(:monolith, :stage_designer, previous)

      if vault,
        do: Application.put_env(:monolith, :gemini_vault, vault),
        else: Application.delete_env(:monolith, :gemini_vault)

      File.rm_rf!(directory)
    end)

    :ok
  end

  test "absent preference is off and reads never initialize persistence or admit work" do
    for _ <- 1..3 do
      assert {:ok, %{enabled: false, environment_enabled: true}} =
               StageDesigner.startup_preference(actor: @owner)
    end

    assert {:ok, nil} = StageDesigner.get_startup_preference(1, actor: @service)
    assert {:ok, :disabled} = startup()
    assert {:ok, :disabled} = retry_startup()
    assert_no_admission()
  end

  test "only the strict local owner may read or save the public preference" do
    for actor <- [nil, %{}, %{role: "local_owner"}, %{role: "stage_designer"}, @service] do
      assert {:error, %Ash.Error.Forbidden{}} = StageDesigner.startup_preference(actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} =
               StageDesigner.save_startup_preference(%{enabled: true}, actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} =
               StageDesigner.persist_startup_preference(%{enabled: true}, actor: actor)
    end

    for actor <- [nil, %{}, %{role: "local_owner"}, %{role: "stage_designer"}] do
      assert {:error, %Ash.Error.Forbidden{}} =
               StageDesigner.get_startup_preference(1, actor: actor)
    end

    assert {:ok, nil} = StageDesigner.get_startup_preference(1, actor: @service)
    assert_no_admission()
  end

  test "saving upserts the observed flag without credentials, generation, jobs or reservation" do
    for enabled <- [true, true, false, true] do
      assert {:ok, %{enabled: ^enabled, environment_enabled: true}} = save(enabled)
      assert %{enabled: ^enabled} = StageDesigner.startup_preference!(actor: @owner)

      assert [%StartupPreference{id: 1, enabled: ^enabled}] =
               Ash.read!(StartupPreference, actor: @service)

      assert_no_admission()
    end
  end

  test "boolean validation rejects nil, omitted and invalid values without changing the flag" do
    assert {:ok, %{enabled: false}} = save(false)

    for input <- [%{}, %{enabled: nil}, %{enabled: "sometimes"}, %{enabled: []}] do
      assert {:error, %Ash.Error.Invalid{}} =
               StageDesigner.save_startup_preference(input, actor: @owner)

      assert %{enabled: false} = StageDesigner.startup_preference!(actor: @owner)
    end

    assert_no_admission()
  end

  test "both gates are required and the retry flag bypasses neither" do
    assert {:ok, %{enabled: false}} = save(false)
    assert {:ok, :disabled} = startup()
    assert {:ok, :disabled} = retry_startup()
    assert :disabled = Generation.startup(Settings.get(), @now, true)
    assert_no_admission()

    assert {:ok, %{enabled: true}} = save(true)
    Application.put_env(:monolith, :stage_designer, %{Settings.get() | enabled: false})

    assert %{enabled: true, environment_enabled: false} =
             StageDesigner.startup_preference!(actor: @owner)

    assert {:ok, :disabled} = startup()
    assert {:ok, :disabled} = retry_startup()
    assert :disabled = Generation.startup(Settings.get(), @now, true)
    assert_no_admission()

    Application.put_env(:monolith, :stage_designer, %{Settings.get() | enabled: true})
    assert {:ok, :started} = startup()
    attempt = SceneGeneration.current()
    assert attempt.source == :startup
    assert attempt.status == :queued
    assert_enqueued(worker: GenerationWorker, args: %{id: attempt.id, operation: "submit"})
    refute_received :keychain_access
  end

  test "an eligible failed-attempt diagnostic retry still requires both startup gates" do
    StageDesigner.initialize_state!(%{}, actor: @service)
    |> StageDesigner.reserve_state!(%{last_attempt_at: @now}, actor: @service)
    |> StageDesigner.fail_state!(%{}, actor: @service)

    assert {:ok, %{enabled: false}} = save(false)
    assert {:ok, :disabled} = retry_startup()
    assert {:ok, %{enabled: true}} = save(true)
    Application.put_env(:monolith, :stage_designer, %{Settings.get() | enabled: false})
    assert {:ok, :disabled} = retry_startup()
    assert {:ok, []} = Attempt.page(1)
    assert all_enqueued() == []
    assert StageDesigner.get_state!(1, actor: @service).last_attempt_at == @now

    Application.put_env(:monolith, :stage_designer, %{Settings.get() | enabled: true})
    assert {:ok, :started} = retry_startup()
    assert SceneGeneration.current().source == :operator
    refute_received :keychain_access
  end

  test "turning off either gate does not stop recovery or replay authorized jobs" do
    assert {:ok, %{enabled: true}} = save(true)
    assert {:ok, :started} = startup()
    attempt = SceneGeneration.current()
    Repo.delete_all(Oban.Job)
    assert {:ok, %{enabled: false}} = save(false)
    Application.put_env(:monolith, :stage_designer, %{Settings.get() | enabled: false})

    assert {:ok, :recovered} = StageDesigner.recover(actor: @service)
    assert_enqueued(worker: GenerationWorker, args: %{id: attempt.id, operation: "submit"})

    Req.Test.expect(__MODULE__, &SceneGeneration.respond(&1, PNG.image()))
    assert %{status: :completed} = SceneGeneration.submit(__MODULE__)
    assert :ok = Generation.perform(attempt.id, :submit, SceneGeneration.options(__MODULE__))
    assert {:ok, [completed]} = Attempt.page(1)
    assert completed.id == attempt.id
    assert {:ok, :disabled} = startup()
    refute_received :keychain_access
  end

  test "manual generation still requires fresh confirmation with both startup gates off" do
    Application.put_env(:monolith, :stage_designer, %{Settings.get() | enabled: false})
    assert {:error, _} = StageDesigner.request_scene_generation(actor: @owner)
    assert_no_admission()
    assert {:ok, :started} = SceneGeneration.manual()
    Req.Test.expect(__MODULE__, &SceneGeneration.respond(&1, PNG.image()))
    assert %{status: :completed} = SceneGeneration.submit(__MODULE__)
    assert {:error, _} = StageDesigner.request_scene_generation(actor: @owner)
    assert {:ok, :started} = SceneGeneration.manual()
    assert {:ok, attempts} = Attempt.page(1)
    assert length(attempts) == 2
    assert Enum.all?(attempts, &(&1.source == :manual))
    refute_received :keychain_access
  end

  defp save(enabled),
    do: StageDesigner.save_startup_preference(%{enabled: enabled}, actor: @owner)

  defp startup, do: StageDesigner.generate_on_startup(%{now: @now}, actor: @service)
  defp retry_startup, do: StageDesigner.retry_failed_startup(%{now: @now}, actor: @service)

  defp assert_no_admission do
    assert {:ok, nil} = StageDesigner.get_state(1, actor: @service)
    assert {:ok, []} = Attempt.page(1)
    assert all_enqueued() == []
    refute_received :keychain_access
    refute_received {:stage_background, _}
  end
end
