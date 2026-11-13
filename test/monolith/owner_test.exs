defmodule Monolith.OwnerTest do
  use Monolith.DataCase, async: false
  alias Monolith.Owner
  alias Monolith.Owner.Actions
  @password "a long local test password"
  @setup [actor: %{role: :owner_setup}]
  @service [actor: %{role: :owner_auth_service}]

  setup do
    # Owner authentication must not inherit another test's node-wide login budget.
    :ok = Supervisor.terminate_child(Monolith.Supervisor, Owner.Throttle)
    {:ok, _} = Supervisor.restart_child(Monolith.Supervisor, Owner.Throttle)
    :ok
  end

  test "fails closed before local setup, with no registration strategy" do
    assert {:ok, false} = Owner.configured()
    assert {:error, _} = Owner.unlock(@password, client())
    assert {:error, _} = Owner.verify_session(String.duplicate("a", 43))
    strategy = AshAuthentication.Info.strategy!(Owner.Credential, :password)
    refute strategy.registration_enabled?
    refute strategy.sign_in_tokens_enabled?
    refute AshAuthentication.Info.authentication_tokens_enabled?(Owner.Credential)
  end

  test "setup is privileged, singleton, and stores only a salted password hash" do
    assert {:error, _} = Owner.configure(@password)
    assert {:error, _} = Owner.configure("short", @setup)
    credential = Owner.configure!(@password, @setup)
    assert credential.id == "owner"
    refute credential.hashed_password == @password
    assert Owner.Password.valid?(@password, credential.hashed_password)
    refute Owner.Password.valid?("wrong", credential.hashed_password)
    assert {:error, _} = Owner.configure(@password, @setup)
    assert {:error, _} = Owner.read_credential()
    assert {:error, _} = Owner.read_credential(actor: %{role: :local_owner})
    assert {:ok, true} = Owner.configured()
  end

  test "accepted surrounding password whitespace survives ordinary and maintenance unlock" do
    password = "  synthetic owner whitespace password  "
    Owner.configure!(password, @setup)
    assert {:ok, token} = Owner.unlock(password, client())
    assert {:ok, _} = Owner.verify_session(token)
    assert {:error, _} = Owner.unlock(String.trim(password), client())
    assert {:ok, _} = Owner.unlock_for_maintenance(password, @setup)
  end

  test "login mints independent opaque sessions with 12-hour absolute expiry" do
    Owner.configure!(@password, @setup)
    before = DateTime.utc_now()
    assert {:error, _} = Owner.unlock("wrong", client())
    token = Owner.unlock!(@password, client())
    another = Owner.unlock!(@password, client())
    assert token != another
    assert byte_size(token) == 43
    session = Owner.find_session!(Actions.digest(token), @service)
    assert session.digest != token
    assert DateTime.diff(session.expires_at, before) in 43_200..43_201
    assert {:ok, %{digest: digest, expires_at: expiry}} = Owner.verify_session(token)
    assert digest == session.digest
    assert expiry == session.expires_at
    assert {:error, _} = Owner.verify_session(token <> "x")
    assert {:error, _} = Owner.verify_session(nil)
    assert {:error, _} = Owner.find_session(digest)
    assert {:error, _} = Owner.verify_digest(digest)
  end

  test "logout revokes only the current token and broadcasts LiveView disconnect" do
    Owner.configure!(@password, @setup)
    token = Owner.unlock!(@password, client())
    other = Owner.unlock!(@password, client())
    topic = Actions.topic(Actions.digest(token))
    Phoenix.PubSub.subscribe(Monolith.PubSub, topic)
    assert {:ok, true} = Owner.logout(token)
    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^topic}
    assert {:error, _} = Owner.verify_session(token)
    assert {:ok, _} = Owner.verify_session(other)
    assert {:ok, true} = Owner.logout(token)
    assert {:error, _} = Owner.lock_all()
    assert {:ok, true} = Owner.lock_all(actor: %{role: :local_owner})
    assert {:error, _} = Owner.verify_session(other)
  end

  test "expired and unknown sessions cannot authenticate" do
    Owner.configure!(@password, @setup)
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    Owner.issue_session!(Actions.digest(token), DateTime.add(DateTime.utc_now(), -1), @service)
    assert {:error, _} = Owner.verify_session(token)
    assert {:error, _} = Owner.verify_session(String.duplicate("b", 43))
  end

  test "even an otherwise valid session requires a configured owner" do
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    Owner.issue_session!(Actions.digest(token), DateTime.add(DateTime.utc_now(), 60), @service)
    assert {:error, _} = Owner.verify_session(token)
  end

  defp client, do: "owner-test-#{System.unique_integer([:positive])}"
end
