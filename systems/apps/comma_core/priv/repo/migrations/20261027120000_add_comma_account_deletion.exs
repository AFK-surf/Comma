defmodule Comma.Repo.Migrations.AddCommaAccountDeletion do
  use Ecto.Migration

  # A deleted User stays as a row without personal data, so Workspaces,
  # billing and audit records keep their reference. `deleted_email_hash` is a
  # keyed hash of the email it had: a new User with that email gets no
  # registration credits.
  def change do
    alter table(:comma_users) do
      add(:deleted_at, :utc_datetime_usec)
      add(:deleted_email_hash, :binary)
    end

    create(
      index(:comma_users, [:deleted_email_hash],
        name: :comma_users_deleted_email_hash_index,
        where: "deleted_email_hash IS NOT NULL"
      )
    )
  end
end
