defmodule Comma.Repo.Migrations.AddCommaAuthSessionActiveAt do
  use Ecto.Migration

  def change do
    alter table(:comma_auth_sessions) do
      add(:active_at, :utc_datetime_usec)
    end
  end
end
