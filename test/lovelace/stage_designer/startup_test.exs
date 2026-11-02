defmodule Lovelace.StageDesigner.StartupTest do
  use LovelaceWeb.ConnCase, async: false

  import Bitwise
  import ExUnit.CaptureLog

  alias Lovelace.StageDesigner
  alias Lovelace.StageDesigner.{Image, Settings, Storage}
  alias Lovelace.TestSupport.{JPEG, PNG}

  @actor %{role: :stage_designer}
  @now ~U[2026-11-01 12:00:00.000000Z]

  setup {Req.Test, :verify_on_exit!}

  setup do
    directory = Path.join(System.tmp_dir!(), "lovelace-stage-#{Ash.UUID.generate()}")
    previous = Application.get_env(:lovelace, :stage_designer)

    Application.put_env(:lovelace, :stage_designer, %Settings{
      enabled: true,
      storage_dir: directory
    })

    on_exit(fn ->
      Application.put_env(:lovelace, :stage_designer, previous)
      File.rm_rf!(directory)
    end)

    %{directory: directory}
  end

  test "generates once, persists reservation before HTTP, and publishes locally", %{conn: conn} do
    Phoenix.PubSub.subscribe(Lovelace.PubSub, "stage_designer")
    bytes = PNG.image()

    Req.Test.expect(__MODULE__, fn request ->
      state = StageDesigner.get_state!(1, actor: @actor)
      assert state.last_attempt_at == @now
      assert state.status == :generating
      assert state.history == []
      respond(request, bytes)
    end)

    assert {:ok, :generated} = startup(@now)
    assert_receive {:stage_background, %{url: nil, status: :generating}}
    assert_receive {:stage_background, %{url: url, status: :ready}}
    assert url =~ ~r|\A/stage/background/[0-9a-f]{64}\.png\z|
    assert {:ok, %{url: ^url, status: :ready}} = StageDesigner.background()
    assert {:ok, :cached} = startup(DateTime.add(@now, 23 * 3600))

    response = get(conn, url)
    assert response(response, 200) == bytes
    assert get_resp_header(response, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(response, "content-type") == ["image/png"]
    assert get_resp_header(response, "cache-control") == ["private, max-age=86400, immutable"]
  end

  test "stores and serves JPEG with its real extension, MIME type, and unchanged provenance", %{
    conn: conn,
    directory: directory
  } do
    bytes = JPEG.image(8, 8) |> JPEG.with_metadata()
    Req.Test.expect(__MODULE__, &respond(&1, bytes))
    assert {:ok, :generated} = startup(@now)
    %{url: url} = StageDesigner.background!()
    assert String.ends_with?(url, ".jpg")
    digest = hd(StageDesigner.get_state!(1, actor: @actor).history)
    assert File.read!(Path.join(directory, digest <> ".jpg")) == bytes
    response = conn |> put_req_header("accept", "image/jpeg") |> get(url)
    assert response(response, 200) == bytes
    assert get_resp_header(response, "content-type") == ["image/jpeg"]

    assert get_resp_header(response, "content-disposition") == [
             ~s(inline; filename="lovelace-background.jpg")
           ]

    assert get_resp_header(response, "x-content-type-options") == ["nosniff"]
    assert response(get(conn, String.replace_suffix(url, ".jpg", ".png")), 404)
    assert response(get(conn, String.replace_suffix(url, ".jpg", ".jpeg")), 404)
  end

  test "retains seven mixed-format images and falls back from a damaged JPEG", %{
    directory: directory
  } do
    for day <- 0..7 do
      bytes = if rem(day, 2) == 0, do: PNG.image(day + 3, 2), else: JPEG.image(day + 3, 2)
      Req.Test.expect(__MODULE__, &respond(&1, bytes))
      assert {:ok, :generated} = startup(DateTime.add(@now, day * 24 * 3600))
    end

    state = StageDesigner.get_state!(1, actor: @actor)
    assert length(state.history) == 7
    assert length(File.ls!(directory)) == 7
    assert Enum.any?(File.ls!(directory), &String.ends_with?(&1, ".jpg"))
    assert Enum.any?(File.ls!(directory), &String.ends_with?(&1, ".png"))
    assert String.ends_with?(StageDesigner.background!().url, ".jpg")
    File.write!(Path.join(directory, hd(state.history) <> ".jpg"), "corrupt")
    assert StageDesigner.background!().url == Storage.url(Enum.at(state.history, 1), :png)
  end

  test "failed and uncertain attempts persist cooldown even without an image" do
    Req.Test.expect(__MODULE__, fn request ->
      Plug.Conn.send_resp(request, 503, "fake provider failure")
    end)

    assert {:ok, :failed} = startup(@now)
    assert {:ok, :cached} = startup(DateTime.add(@now, 1))
    assert {:ok, :cached} = startup(DateTime.add(@now, 24 * 3600 - 1))
    assert {:ok, %{url: nil, status: :failed}} = StageDesigner.background()

    Req.Test.expect(__MODULE__, &respond(&1, PNG.image()))
    assert {:ok, :generated} = startup(DateTime.add(@now, 24 * 3600))
  end

  test "an explicit operator retry reserves one failed attempt without enabling automatic retries" do
    Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 503, "fake failure"))
    assert {:ok, :failed} = startup(@now)
    later = DateTime.add(@now, 60)
    assert {:ok, :cached} = startup(later)
    assert {:error, _} = StageDesigner.retry_failed_startup(%{now: later})

    Req.Test.expect(__MODULE__, fn request ->
      assert StageDesigner.get_state!(1, actor: @actor).last_attempt_at == later
      respond(request, PNG.image())
    end)

    assert {:ok, :generated} =
             StageDesigner.retry_failed_startup(%{now: later},
               actor: @actor,
               context: %{
                 provider_options: [api_key: "fake-stage-key", plug: {Req.Test, __MODULE__}]
               }
             )

    # The operator action refuses a successful or still-running prior attempt.
    assert {:ok, :cached} = StageDesigner.retry_failed_startup(%{now: later}, actor: @actor)
    assert {:ok, :cached} = startup(DateTime.add(later, 1))
  end

  test "operator retry does not create an initial request or retry an uncertain running attempt" do
    assert {:ok, :cached} = StageDesigner.retry_failed_startup(%{now: @now}, actor: @actor)
    state = StageDesigner.get_state!(1, actor: @actor)
    assert state.last_attempt_at == nil
    StageDesigner.reserve_state!(state, %{last_attempt_at: @now}, actor: @actor)
    assert {:ok, :cached} = StageDesigner.retry_failed_startup(%{now: @now}, actor: @actor)
  end

  test "logs useful safe provider diagnostics without leaking response text or fake credentials" do
    private = "fake-provider-private-message-and-key"

    Req.Test.expect(__MODULE__, fn request ->
      request
      |> Plug.Conn.put_status(429)
      |> Req.Test.json(%{
        "error" => %{
          "status" => "RESOURCE_EXHAUSTED",
          "message" => private,
          "details" => [%{"private" => private}]
        }
      })
    end)

    log = capture_log(fn -> assert {:ok, :failed} = startup(@now) end)
    assert log =~ "provider: HTTP 429 (resource_exhausted)"
    assert log =~ "check model quota and billing"
    assert log =~ "no retry"
    refute log =~ private
    refute log =~ "fake-stage-key"
    assert {:ok, :cached} = startup(DateTime.add(@now, 1))
  end

  test "logs storage failures separately from provider failures", %{directory: directory} do
    File.mkdir_p!(directory)
    blocked = Path.join(directory, "blocked")
    File.write!(blocked, "not a directory")

    Application.put_env(:lovelace, :stage_designer, %Settings{enabled: true, storage_dir: blocked})

    Req.Test.expect(__MODULE__, &respond(&1, PNG.image()))

    log = capture_log(fn -> assert {:ok, :failed} = startup(@now) end)
    assert log =~ "storage: storage_error"
    assert log =~ "storage directory and permissions"
    refute log =~ blocked
  end

  test "optimistic reservation rejects a second claimant with the same version" do
    state = StageDesigner.initialize_state!(%{}, actor: @actor)
    assert {:ok, _} = StageDesigner.reserve_state(state, %{last_attempt_at: @now}, actor: @actor)

    assert {:error, _} =
             StageDesigner.reserve_state(state, %{last_attempt_at: @now}, actor: @actor)

    # Simulate a process dying after reservation: no HTTP request is permitted on restart.
    assert {:ok, :cached} = startup(DateTime.add(@now, 60))
  end

  test "clock rollback does not bypass a future reservation" do
    StageDesigner.initialize_state!(%{}, actor: @actor)
    |> StageDesigner.reserve_state!(%{last_attempt_at: @now}, actor: @actor)

    assert {:ok, :cached} = startup(DateTime.add(@now, -3600))
  end

  test "disabled startup makes no request or reservation" do
    Application.put_env(:lovelace, :stage_designer, %Settings{enabled: false})
    assert {:ok, :disabled} = startup(@now)
    assert {:ok, nil} = StageDesigner.get_state(1, actor: @actor)
  end

  test "requires an internal actor for writes, but permits safe public background reads" do
    assert {:error, _} = StageDesigner.initialize_state(%{})
    assert {:error, _} = StageDesigner.generate_on_startup(%{now: @now})
    assert {:ok, %{url: nil}} = StageDesigner.background()
  end

  test "retains seven successful images and falls back from corrupt current bytes", %{
    directory: directory,
    conn: conn
  } do
    urls =
      for day <- 0..7 do
        bytes = PNG.image(day + 1, 2)
        Req.Test.expect(__MODULE__, &respond(&1, bytes))
        assert {:ok, :generated} = startup(DateTime.add(@now, day * 24 * 3600))
        StageDesigner.background!().url
      end

    state = StageDesigner.get_state!(1, actor: @actor)
    assert length(state.history) == 7
    assert length(File.ls!(directory)) == 7
    assert (File.stat!(directory).mode &&& 0o777) == 0o700

    for filename <- File.ls!(directory) do
      assert (File.stat!(Path.join(directory, filename)).mode &&& 0o777) == 0o600
    end

    assert response(get(conn, hd(urls)), 404)
    current = hd(state.history)
    File.write!(Path.join(directory, current <> ".png"), "corrupt")
    expected = Storage.url(Enum.at(state.history, 1))
    assert StageDesigner.background!().url == expected
    assert response(get(conn, List.last(urls)), 404)
    assert response(get(conn, expected), 200)
  end

  test "cached startup reconciles stale orphan images and temporary files without requesting", %{
    directory: directory
  } do
    Req.Test.expect(__MODULE__, &respond(&1, PNG.image()))
    assert {:ok, :generated} = startup(@now)
    current = StageDesigner.background!().url
    retained = hd(StageDesigner.get_state!(1, actor: @actor).history)
    orphan = String.duplicate("a", 64) <> ".png"
    temporary = ".stage-#{Ash.UUID.generate()}.tmp"
    recent = String.duplicate("b", 64) <> ".png"

    for name <- [orphan, temporary, recent, "user-file.txt"] do
      File.write!(Path.join(directory, name), "interrupted data")
    end

    for name <- [orphan, temporary, "user-file.txt"] do
      File.touch!(Path.join(directory, name), DateTime.to_unix(@now) - 600)
    end

    File.touch!(Path.join(directory, recent), DateTime.to_unix(@now))
    assert {:ok, :cached} = startup(DateTime.add(@now, 1))
    assert StageDesigner.background!().url == current
    assert File.exists?(Path.join(directory, retained <> ".png"))
    refute File.exists?(Path.join(directory, orphan))
    refute File.exists?(Path.join(directory, temporary))
    assert File.exists?(Path.join(directory, recent))
    assert File.exists?(Path.join(directory, "user-file.txt"))
  end

  test "provider or storage failure preserves the last successful image", %{directory: directory} do
    Req.Test.expect(__MODULE__, &respond(&1, PNG.image()))
    assert {:ok, :generated} = startup(@now)
    url = StageDesigner.background!().url

    Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 429, "fake rate limit"))
    assert {:ok, :failed} = startup(DateTime.add(@now, 24 * 3600))
    assert StageDesigner.background!().url == url

    # A regular file cannot be used as the storage directory.
    blocked = Path.join(directory, "blocked")
    File.write!(blocked, "not a directory")

    Application.put_env(:lovelace, :stage_designer, %Settings{enabled: true, storage_dir: blocked})

    Req.Test.expect(__MODULE__, &respond(&1, PNG.image(3, 3)))
    assert {:ok, :failed} = startup(DateTime.add(@now, 48 * 3600))
    assert StageDesigner.get_state!(1, actor: @actor).history != []
  end

  test "unknown digests, malformed filenames, symlinks, and unregistered files are not served", %{
    conn: conn,
    directory: directory
  } do
    Req.Test.expect(__MODULE__, &respond(&1, PNG.image()))
    assert {:ok, :generated} = startup(@now)
    url = StageDesigner.background!().url
    digest = hd(StageDesigner.get_state!(1, actor: @actor).history)
    path = Path.join(directory, digest <> ".png")
    alternate = Path.join(directory, "elsewhere.png")
    File.rename!(path, alternate)
    File.ln_s!(alternate, path)
    assert response(get(conn, url), 404)
    assert response(get(conn, "/stage/background/#{String.duplicate("a", 64)}.png"), 404)
    assert response(get(conn, "/stage/background/not-a-digest.png"), 404)
    assert {:error, _} = StageDesigner.image("../secret")
  end

  defp startup(now) do
    StageDesigner.generate_on_startup(%{now: now},
      actor: @actor,
      context: %{provider_options: [api_key: "fake-stage-key", plug: {Req.Test, __MODULE__}]}
    )
  end

  defp respond(request, bytes) do
    Req.Test.json(request, %{
      candidates: [
        %{
          finishReason: "STOP",
          content: %{
            parts: [
              %{
                inlineData: %{
                  mimeType: Image.mime_type(Image.format(bytes)),
                  data: Base.encode64(bytes)
                }
              }
            ]
          }
        }
      ]
    })
  end
end
