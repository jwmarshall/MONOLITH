# Run only through `mix test.ui`: a separate test BEAM and disposable database.
if Mix.env() != :test, do: Mix.raise("UI regressions require MIX_ENV=test")

browser =
  System.get_env("LOVELACE_BROWSER") || System.find_executable("chromium") ||
    System.find_executable("chromium-browser") || System.find_executable("google-chrome") ||
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

unless File.regular?(browser),
  do: Mix.raise("Install Chrome/Chromium or set LOVELACE_BROWSER to its executable")

root = Path.join(System.tmp_dir!(), "lovelace-ui-#{Ecto.UUID.generate()}")
File.mkdir_p!(root)
File.chmod!(root, 0o700)

# No test may fall through to a real provider or credential operation. These are
# synthetic read-only responses; the normal test-build guards also remain.
defmodule Lovelace.UIFixture do
  @moduledoc false

  def get(_id), do: {:ok, "synthetic-refresh"}
  def put(_id, _token), do: :ok
  def delete(_id), do: :ok
  def refresh("synthetic-refresh"), do: {:ok, %{access_token: "synthetic-access"}}
  def revoke(_token), do: :ok

  def inbox("synthetic-access", _page) do
    threads =
      for number <- 1..20 do
        %{
          "id" => "synthetic-thread-#{number}",
          "subject" => "Synthetic conversation #{number}",
          "from" => "sender@example.test",
          "snippet" => "Read-only browser fixture",
          "date" => "Today",
          "unread" => false
        }
      end

    {:ok, %{"threads" => threads, "next_page_token" => nil}}
  end

  def search("synthetic-access", _query, _page), do: inbox("synthetic-access", nil)

  def thread("synthetic-access", id) do
    # Bounded synthetic provider latency lets Chrome inspect the real loading
    # state, rather than injecting markup or racing an immediate fake response.
    Process.sleep(400)
    subject = "Synthetic conversation #{String.replace_prefix(id, "synthetic-thread-", "")}"

    latest_text =
      Enum.map_join(1..20, "\n\n", fn
        19 ->
          "https://mail-fixture.invalid/" <> String.duplicate("synthetic-unbroken-path", 30)

        20 ->
          ~s|<img src="https://mail-fixture.invalid/body.png" onerror="alert('synthetic')">|

        number ->
          "Synthetic paragraph #{number}. This read-only conversation exercises comfortable " <>
            "long-form reading, line wrapping and the shared scrolling content pane. " <>
            "Nothing in this browser fixture is real mail, and no remote content should load."
      end)

    messages =
      for number <- 1..3 do
        %{
          "id" => "synthetic-message-#{number}",
          "subject" => if(number == 2, do: "Synthetic alternate subject", else: subject),
          "from" => "Synthetic Sender <sender@example.test>",
          "to" =>
            ~s(Browser <browser@example.test>, <img src="https://mail-fixture.invalid/recipient.png">),
          "date" =>
            "Sat, 15 Mar 2025 #{String.pad_leading(to_string(number + 8), 2, "0")}:30:00 +0000",
          "text" => if(number == 3, do: latest_text, else: "Synthetic earlier message #{number}.")
        }
      end

    {:ok, %{"messages" => messages}}
  end
end

try do
  System.put_env("LOVELACE_STAGE_ENABLED", "false")
  # Apply migrations during disposable application startup, just as releases do.
  System.put_env("RELEASE_NAME", "ui-contract-test")
  repo = Application.fetch_env!(:lovelace, Lovelace.Repo)

  Application.put_env(
    :lovelace,
    Lovelace.Repo,
    Keyword.merge(repo, database: Path.join(root, "test.db"), pool: DBConnection.ConnectionPool)
  )

  Application.put_env(:lovelace, :gmail_provider, Lovelace.UIFixture)
  Application.put_env(:lovelace, :gmail_vault, Lovelace.UIFixture)

  scenery = %Lovelace.StageDesigner.Settings{
    enabled: false,
    storage_dir: Path.join(root, "scenery")
  }

  Application.put_env(:lovelace, :stage_designer, scenery)
  Application.put_env(:lovelace, :workspace_idle_minutes, 3)

  endpoint = Application.fetch_env!(:lovelace, LovelaceWeb.Endpoint)

  Application.put_env(
    :lovelace,
    LovelaceWeb.Endpoint,
    Keyword.merge(endpoint,
      server: true,
      http: [ip: {127, 0, 0, 1}, port: 0],
      check_origin: ["//localhost"]
    )
  )

  {:ok, _} = Application.ensure_all_started(:lovelace)
  Lovelace.Owner.configure!("synthetic browser owner password", actor: %{role: :owner_setup})
  owner = %{role: :local_owner}

  # Serve a tiny locally encoded fixture through the real validated image route,
  # without invoking generation or using the user's scenery directory.
  now = DateTime.utc_now()
  actor = %{role: :stage_designer}

  reserved =
    Lovelace.StageDesigner.initialize_state!(%{}, actor: actor)
    |> Lovelace.StageDesigner.reserve_state!(%{last_attempt_at: now}, actor: actor)

  {:ok, _} =
    Lovelace.StageDesigner.Storage.store_and_publish(
      scenery,
      Lovelace.TestSupport.PNG.image(),
      reserved,
      now
    )

  workspace = Lovelace.Workspaces.create_workspace!("Browser studio", actor: owner)

  shared_workspace = Lovelace.Workspaces.create_workspace!("Synthetic space 1", actor: owner)

  for number <- 2..14,
      do: Lovelace.Workspaces.create_workspace!("Synthetic space #{number}", actor: owner)

  account =
    Lovelace.Mail.save_connection!(
      %{
        id: Ecto.UUID.generate(),
        subject: "synthetic-browser-account",
        email: "browser@example.test",
        generation: Ecto.UUID.generate()
      },
      actor: owner
    )

  Lovelace.Mail.update_account!(
    account,
    %{
      expected_generation: account.generation,
      inbox_unread_count: 7,
      inbox_unread_at: now,
      inbox_unread_error: nil
    },
    actor: owner
  )

  for space <- [workspace, shared_workspace] do
    Lovelace.Mail.attach_account!(%{workspace_id: space.id, account_id: account.id},
      actor: owner
    )
  end

  unattached =
    Lovelace.Mail.save_connection!(
      %{
        id: Ecto.UUID.generate(),
        subject: "synthetic-unattached-browser-account",
        email: "unattached@example.test",
        generation: Ecto.UUID.generate()
      },
      actor: owner
    )

  Lovelace.Mail.update_account!(
    unattached,
    %{
      expected_generation: unattached.generation,
      inbox_unread_count: 0,
      inbox_unread_at: now,
      inbox_unread_error: nil
    },
    actor: owner
  )

  {:ok, {_ip, port}} = LovelaceWeb.Endpoint.server_info(:http)

  {_output, status} =
    System.cmd(
      "node",
      [
        "test/browser/ui_contract.mjs",
        browser,
        root,
        "http://localhost:#{port}",
        workspace.id,
        account.id,
        unattached.id
      ],
      into: IO.stream(:stdio, :line),
      env: [{"LOVELACE_STAGE_ENABLED", "false"}]
    )

  if status != 0, do: Mix.raise("Browser UI contract regressions failed")
after
  Application.stop(:lovelace)
  Application.stop(:oban)
  Application.stop(:ash_sqlite)
  File.rm_rf!(root)
end
