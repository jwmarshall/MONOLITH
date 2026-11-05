defmodule Lovelace.Repo.Migrations.AddInboxUnreadRecentCount do
  use Ecto.Migration

  def up do
    alter table(:gmail_accounts) do
      add :inbox_unread_recent_count, :bigint
    end
  end

  def down do
    alter table(:gmail_accounts) do
      remove :inbox_unread_recent_count
    end
  end
end
