defmodule Comma.Repo.Migrations.IndexAuthSessionsByLastSeen do
  use Ecto.Migration

  def change do
    create(index(:comma_auth_sessions, [:user_id, :last_seen_at, :id]))
  end
end
