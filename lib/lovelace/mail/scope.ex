defmodule Lovelace.Mail.Scope do
  @moduledoc false
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_), do: "local owner or a service scoped to this account"

  @impl true
  def match?(%{role: :local_owner}, _, _), do: true

  def match?(%{role: :mail_service, account_id: id}, context, _) when is_binary(id) do
    case context do
      %{changeset: %Ash.Changeset{} = changeset} ->
        field = if changeset.resource == Lovelace.Mail.Account, do: :id, else: :account_id
        Ash.Changeset.get_attribute(changeset, field) == id

      %{query: %Ash.Query{arguments: %{account_id: ^id}}} ->
        true

      _ ->
        false
    end
  end

  def match?(_, _, _), do: false
end
