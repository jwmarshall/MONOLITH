defmodule Lovelace.WorkspacesTest do
  use Lovelace.DataCase, async: false

  import Ash.Test

  alias Ash.Error.Forbidden
  alias Ash.Error.Invalid
  alias Lovelace.Workspaces
  alias Lovelace.Workspaces.Workspace

  @owner %{role: :local_owner}
  @personal_id "00000000-0000-4000-8000-000000000001"

  test "create, rename and read persist trimmed names and timestamps" do
    workspace = Workspaces.create_workspace!("  Research \n", actor: @owner)

    assert Ash.Type.UUID.cast_input(workspace.id, []) == {:ok, workspace.id}
    assert workspace.name == "Research"
    assert %DateTime{} = workspace.created_at
    assert %DateTime{} = workspace.updated_at
    assert Workspaces.get_workspace!(workspace.id, actor: @owner).name == "Research"

    renamed = Workspaces.rename_workspace!(workspace, "  Writing  ", actor: @owner)
    assert renamed.id == workspace.id
    assert renamed.name == "Writing"
    assert renamed.created_at == workspace.created_at
    assert DateTime.compare(renamed.updated_at, workspace.updated_at) == :gt
    assert Workspaces.get_workspace!(workspace.id, actor: @owner).name == "Writing"
  end

  test "reads are ordered by creation time then id, not name or rename time" do
    first = Workspaces.create_workspace!("Zebra", actor: @owner)
    second = Workspaces.create_workspace!("Apple", actor: @owner)
    Workspaces.rename_workspace!(first, "Renamed", actor: @owner)

    assert Enum.map(Workspaces.list_workspaces!(actor: @owner), & &1.id) == [first.id, second.id]

    # Lock down the tie breaker even when ordinary inserts have different timestamps.
    query = Ash.Query.for_read(Workspace, :read, %{}, actor: @owner)
    assert query.sort == [created_at: :asc, id: :asc]
  end

  test "missing workspace returns nil" do
    assert Workspaces.get_workspace!(Ash.UUID.generate(), actor: @owner) == nil
  end

  test "create requires a name" do
    Workspaces.create_workspace(%{}, actor: @owner)
    |> assert_has_error(Invalid, &match?(%{field: :name}, &1))

    assert Workspaces.list_workspaces!(actor: @owner) == []
  end

  test "create and rename reject nil, blank and overlong names without writing" do
    workspace = Workspaces.create_workspace!("Original", actor: @owner)

    for name <- [nil, "", " \t\n", String.duplicate("x", 65), String.duplicate("é", 65)] do
      Workspaces.create_workspace(name, actor: @owner)
      |> assert_has_error(Invalid, &match?(%{field: :name}, &1))

      Workspaces.rename_workspace(workspace, name, actor: @owner)
      |> assert_has_error(Invalid, &match?(%{field: :name}, &1))
    end

    assert [%{id: id, name: "Original"}] = Workspaces.list_workspaces!(actor: @owner)
    assert id == workspace.id
  end

  test "the 64 character limit applies after trimming, including Unicode" do
    name = String.duplicate("é", 64)
    workspace = Workspaces.create_workspace!("  #{name}  ", actor: @owner)
    assert workspace.name == name
    assert Workspaces.rename_workspace!(workspace, " #{name}\n", actor: @owner).name == name
  end

  test "all interfaces deny missing and incorrect actors" do
    workspace = Workspaces.create_workspace!("Private", actor: @owner)

    for options <- [[], [actor: %{}], [actor: %{role: :guest}], [actor: %{role: "local_owner"}]] do
      assert {:error, %Forbidden{}} = Workspaces.list_workspaces(options)
      assert {:error, %Forbidden{}} = Workspaces.get_workspace(workspace.id, options)
      assert {:error, %Forbidden{}} = Workspaces.get_workspace(Ash.UUID.generate(), options)
      assert {:error, %Forbidden{}} = Workspaces.create_workspace("Denied", %{}, options)

      assert {:error, %Forbidden{}} =
               Workspaces.rename_workspace(workspace, "Denied", %{}, options)
    end

    assert [%{name: "Private"}] = Workspaces.list_workspaces!(actor: @owner)
  end

  test "extra create and rename parameters cannot set ids or timestamps" do
    workspace = Workspaces.create_workspace!("Original", actor: @owner)

    for params <- [
          %{id: @personal_id},
          %{"id" => @personal_id},
          %{created_at: DateTime.utc_now()},
          %{updated_at: DateTime.utc_now()}
        ] do
      assert {:error, %Invalid{}} = Workspaces.create_workspace("Injected", params, actor: @owner)

      assert {:error, %Invalid{}} =
               Workspaces.rename_workspace(workspace, "Injected", params, actor: @owner)
    end

    assert Workspaces.get_workspace!(workspace.id, actor: @owner).name == "Original"
    assert Workspaces.get_workspace!(@personal_id, actor: @owner) == nil
  end

  test "workspace writes roll back with the enclosing transaction" do
    workspace = Workspaces.create_workspace!("Original", actor: @owner)

    assert {:error, :intentional_rollback} =
             Repo.transaction(fn ->
               Workspaces.create_workspace!("Rolled back", actor: @owner)

               Workspaces.rename_workspace!(workspace, "Rolled back",
                 actor: @owner,
                 return_notifications?: true
               )

               Repo.rollback(:intentional_rollback)
             end)

    assert [%{id: id, name: "Original"}] = Workspaces.list_workspaces!(actor: @owner)
    assert id == workspace.id
  end
end
