defmodule Lovelace.OnboardingTest do
  use Lovelace.DataCase, async: false

  alias Lovelace.Integrations.Google.ClientCredentials
  alias Lovelace.{Mail, Onboarding, Workspaces}
  alias Lovelace.TestSupport.OnboardingKeychain

  @owner [actor: %{role: :local_owner}]

  setup do
    start_supervised!(OnboardingKeychain)
    previous = Application.fetch_env(:lovelace, :google_client_keychain)
    Application.put_env(:lovelace, :google_client_keychain, OnboardingKeychain)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:lovelace, :google_client_keychain, value)
        :error -> Application.delete_env(:lovelace, :google_client_keychain)
      end
    end)
  end

  test "existing installations without guide state retain Home as the unlock default" do
    assert {:ok, nil} = Onboarding.progress(@owner)
    assert Onboarding.entry_path() == "/"
    refute Onboarding.pending?()
    assert {:ok, nil} = Onboarding.progress(@owner)
  end

  test "explicit start is owner-only, idempotent, and resumes saved progress" do
    assert {:error, _} = Onboarding.start()
    assert {:error, _} = Onboarding.progress()
    assert {:ok, %{step: :project}} = Onboarding.start(@owner)
    assert Onboarding.pending?()
    assert Onboarding.entry_path() == "/onboarding/project"
    assert {:ok, %{step: :authentication}} = Onboarding.continue(:project, @owner)
    assert {:ok, %{step: :authentication}} = Onboarding.start(@owner)
    assert Onboarding.entry_path() == "/onboarding/authentication"
    assert [%{id: id, name: "Personal"}] = Workspaces.list_workspaces!(@owner)
    assert id == Onboarding.personal_workspace_id()
    assert {:ok, %{step: :audience}} = Onboarding.continue(:authentication, @owner)
    assert {:ok, %{step: :client}} = Onboarding.continue(:audience, @owner)
    assert {:error, :save_credentials_first} = Onboarding.continue(:client, @owner)
    assert Onboarding.entry_path() == "/onboarding/client"
  end

  test "credential action owns direct bounded keychain storage but never provider verification" do
    assert {:error, _} = Onboarding.save_credentials("synthetic-client", "synthetic-secret")
    assert OnboardingKeychain.writes() == 0

    assert {:ok, true} =
             Onboarding.save_credentials("synthetic-client", "synthetic-secret", @owner)

    assert {:ok, %{client_id: "synthetic-client", client_secret: "synthetic-secret"}} =
             ClientCredentials.read()

    assert {:ok, %{step: :connect, credentials_saved: true}} = Onboarding.progress(@owner)
    assert {:ok, nil} = Onboarding.connection(@owner)
    assert OnboardingKeychain.calls() == []
    assert {:ok, %{step: :connect}} = Onboarding.continue(:client, @owner)
  end

  test "invalid credentials and private adapter failures never advance progress or echo values" do
    Onboarding.start(@owner)

    for value <- ["", "synthetic secret", "synthetic\nsecret", String.duplicate("x", 8193)] do
      assert {:error, error} = Onboarding.save_credentials("synthetic-client", value, @owner)
      refute inspect(error) =~ "synthetic-client"
      refute inspect(error) =~ "synthetic secret"
      assert {:ok, %{step: :project, credentials_saved: false}} = Onboarding.progress(@owner)
    end

    OnboardingKeychain.fail("synthetic private native diagnostic")

    assert {:error, error} =
             Onboarding.save_credentials("synthetic-client", "synthetic-secret", @owner)

    refute inspect(error) =~ "synthetic private native diagnostic"
    assert {:ok, %{credentials_saved: false}} = Onboarding.progress(@owner)
  end

  test "finishing without Gmail ends only the guide and keeps it reachable" do
    assert {:ok, %{step: :complete}} = Onboarding.continue(:connect, @owner)
    assert {:ok, nil} = Onboarding.connection(@owner)
    assert {:ok, %{finished: true}} = Onboarding.finish(@owner)
    refute Onboarding.pending?()
    assert Onboarding.entry_path() == "/"
    assert {:ok, %{finished: true}} = Onboarding.start(@owner)
    assert Onboarding.path(:project) == "/onboarding/project"
    assert {:ok, nil} = Onboarding.connection(@owner)
  end

  test "connection evidence belongs to the receiving workspace and preserves first-read uncertainty" do
    Onboarding.start(@owner)
    other = Workspaces.create_workspace!("Other fixture workspace", @owner)

    account =
      Mail.save_connection!(
        %{
          subject: "synthetic-subject",
          email: "synthetic@example.invalid",
          generation: Ash.UUID.generate()
        },
        @owner
      )

    Mail.attach_account!(%{workspace_id: other.id, account_id: account.id}, @owner)
    assert {:ok, nil} = Onboarding.connection(@owner)

    Mail.attach_account!(
      %{workspace_id: Onboarding.personal_workspace_id(), account_id: account.id},
      @owner
    )

    assert {:ok, %{id: id, status: :ready, last_success_at: nil, inbox_unread_at: nil}} =
             Onboarding.connection(@owner)

    assert id == account.id

    Mail.update_account!(
      account,
      %{expected_generation: account.generation, status: :reconnect},
      @owner
    )

    assert {:ok, %{status: :reconnect}} = Onboarding.connection(@owner)

    Mail.update_account!(
      account,
      %{expected_generation: account.generation, status: :disconnected},
      @owner
    )

    assert {:ok, nil} = Onboarding.connection(@owner)
    assert OnboardingKeychain.calls() == []
  end
end
