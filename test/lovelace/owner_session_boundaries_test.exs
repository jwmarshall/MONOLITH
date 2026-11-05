defmodule Lovelace.OwnerSessionBoundariesTest do
  use Lovelace.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias Lovelace.Owner
  alias Lovelace.Owner.Actions

  @password "synthetic owner boundary password"
  @service [actor: %{role: :owner_auth_service}]

  test "resuming interrupted setup authenticates the existing owner without replacing its password" do
    assert {:ok, credential} = Actions.configure_or_authenticate(@password)
    assert credential.id == "owner"
    assert {:ok, true} = Owner.configured()

    assert {:error, "Unable to unlock"} =
             Actions.configure_or_authenticate("another sufficiently long password")

    assert Owner.list_sessions!(@service) == []
    assert Owner.read_credential!(@service).hashed_password == credential.hashed_password

    assert {:ok, token} = Actions.configure_or_authenticate(@password)
    assert {:ok, %{digest: digest}} = Owner.verify_session(token)
    assert digest == Actions.digest(token)
    assert Owner.read_credential!(@service).hashed_password == credential.hashed_password
  end

  test "successful authentication prunes expired sessions and disconnects only their subscribers" do
    assert {:ok, _} = Actions.configure_or_authenticate(@password)
    expired = issue("expired", -60)
    current = issue("current", 3600)
    expired_topic = Actions.topic(expired.digest)
    current_topic = Actions.topic(current.digest)
    Phoenix.PubSub.subscribe(Lovelace.PubSub, expired_topic)
    Phoenix.PubSub.subscribe(Lovelace.PubSub, current_topic)

    assert {:ok, token} = Actions.configure_or_authenticate(@password)
    assert {:ok, _} = Owner.verify_session(token)
    assert Owner.find_session!(expired.digest, @service) == nil
    assert Owner.find_session!(current.digest, @service).expires_at == current.expires_at
    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^expired_topic}
    refute_receive %Phoenix.Socket.Broadcast{topic: ^current_topic}
  end

  test "failed revocation is not reported as successful logout or a successful global lock" do
    assert {:ok, _} = Actions.configure_or_authenticate(@password)
    assert {:ok, token} = Actions.configure_or_authenticate(@password)
    digest = Actions.digest(token)
    topic = Actions.topic(digest)
    Phoenix.PubSub.subscribe(Lovelace.PubSub, topic)

    reject_revocation(fn ->
      assert {:error, _} = Owner.logout(token)
      assert {:error, _} = Owner.lock_all(actor: %{role: :local_owner})
      assert {:ok, _} = Owner.verify_session(token)
      refute_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^topic}
    end)

    assert {:ok, true} = Owner.logout(token)
    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^topic}
    assert {:error, _} = Owner.verify_session(token)
  end

  test "session persistence failure cannot issue a usable token or alter the owner credential" do
    assert {:ok, credential} = Actions.configure_or_authenticate(@password)

    SQL.query!(
      Repo,
      "CREATE TEMP TRIGGER lovelace_reject_boundary_session BEFORE INSERT ON owner_sessions BEGIN SELECT RAISE(ABORT, 'synthetic session failure'); END",
      [],
      log: false,
      telemetry_event: nil
    )

    try do
      assert {:error, "Unable to unlock"} = Actions.configure_or_authenticate(@password)
      assert Owner.list_sessions!(@service) == []
      assert Owner.read_credential!(@service).hashed_password == credential.hashed_password
    after
      SQL.query!(Repo, "DROP TRIGGER IF EXISTS lovelace_reject_boundary_session", [],
        log: false,
        telemetry_event: nil
      )
    end
  end

  defp issue(seed, seconds) do
    Owner.issue_session!(
      Actions.digest(seed),
      DateTime.add(DateTime.utc_now(), seconds),
      @service
    )
  end

  defp reject_revocation(fun) do
    SQL.query!(
      Repo,
      "CREATE TEMP TRIGGER lovelace_reject_boundary_revoke BEFORE DELETE ON owner_sessions BEGIN SELECT RAISE(ABORT, 'synthetic revoke failure'); END",
      [],
      log: false,
      telemetry_event: nil
    )

    try do
      fun.()
    after
      SQL.query!(Repo, "DROP TRIGGER IF EXISTS lovelace_reject_boundary_revoke", [],
        log: false,
        telemetry_event: nil
      )
    end
  end
end
