defmodule Lovelace.Owner.HashPassword do
  @moduledoc false
  use Ash.Resource.Change
  alias Lovelace.Owner.Password

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case Password.hash(Ash.Changeset.get_argument(changeset, :password)) do
        {:ok, hash} -> Ash.Changeset.force_change_attribute(changeset, :hashed_password, hash)
        :error -> Ash.Changeset.add_error(changeset, "Unable to configure local unlock")
      end
    end)
  end
end
