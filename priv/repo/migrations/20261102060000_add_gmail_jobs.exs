defmodule Lovelace.Repo.Migrations.AddGmailJobs do
  use Ecto.Migration

  def up, do: Oban.Migration.up()
  def down, do: Oban.Migration.down()
end
