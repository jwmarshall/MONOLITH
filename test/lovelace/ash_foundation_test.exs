defmodule Lovelace.AshFoundationTest do
  use Lovelace.DataCase, async: false

  import Ash.Test

  alias Ash.Error.Changes.Required
  alias Ash.Error.Invalid
  alias Ecto.Adapters.SQL
  alias Lovelace.TestSupport.AshProbe

  setup do
    # A test-only resource/table proves the stack without introducing a product model.
    # SQLite's transactional DDL is rolled back by the sandbox after every test.
    SQL.query!(Repo, "CREATE TABLE ash_tooling_probes (id TEXT PRIMARY KEY, label TEXT NOT NULL)")
    :ok
  end

  test "Ash actions persist through the configured SQLite repo" do
    record = Ash.create!(AshProbe, %{label: "foundation"})

    assert [%{id: id, label: "foundation"}] = Ash.read!(AshProbe)
    assert id == record.id
    assert Repo.write_transactions?()
  end

  test "Ash validation errors are testable with Ash.Test" do
    AshProbe
    |> Ash.Changeset.for_create(:create, %{})
    |> assert_has_error(Invalid, &match?(%Required{field: :label}, &1))
  end

  test "an Ash write rolls back with the enclosing transaction" do
    assert {:error, :intentional_rollback} =
             Repo.transaction(fn ->
               Ash.create!(AshProbe, %{label: "not committed"})
               Repo.rollback(:intentional_rollback)
             end)

    assert Ash.read!(AshProbe) == []
  end
end
