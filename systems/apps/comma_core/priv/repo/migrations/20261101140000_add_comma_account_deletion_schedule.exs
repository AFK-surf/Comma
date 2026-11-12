defmodule Comma.Repo.Migrations.AddCommaAccountDeletionSchedule do
  use Ecto.Migration

  # A confirmed account deletion waits seven days (`Comma.AccountDeletion`).
  # Signing in again before `deletion_scheduled_at` clears it; the hourly
  # sweep deletes accounts whose time has come.
  def change do
    alter table(:comma_users) do
      add(:deletion_scheduled_at, :utc_datetime_usec)
    end

    create(
      index(:comma_users, [:deletion_scheduled_at],
        name: :comma_users_deletion_scheduled_at_index,
        where: "deletion_scheduled_at IS NOT NULL"
      )
    )
  end
end
