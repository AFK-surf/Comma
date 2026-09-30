defmodule Comma.Repo.Migrations.AddCommaUserProfiles do
  use Ecto.Migration

  def change do
    create table(:comma_user_avatars, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:user_id, references(:comma_users, type: :string, on_delete: :delete_all), null: false)
      add(:object_key, :string, null: false)
      add(:content_type, :string, null: false)
      add(:byte_size, :integer, null: false)
      add(:status, :string, null: false)
      add(:upload_token, :string)
      add(:upload_deadline_at, :utc_datetime_usec)
      add(:upload_session_url, :text)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:comma_user_avatars, [:object_key]))
    create(index(:comma_user_avatars, [:user_id, :status]))
    create(index(:comma_user_avatars, [:status, :updated_at]))

    create(
      constraint(:comma_user_avatars, :comma_user_avatars_status_check,
        check: "status IN ('pending', 'active', 'cleanup')"
      )
    )

    create(
      constraint(:comma_user_avatars, :comma_user_avatars_byte_size_valid,
        check: "byte_size > 0 AND byte_size <= 102400"
      )
    )

    create(
      constraint(:comma_user_avatars, :comma_user_avatars_upload_lease_valid,
        check:
          "(status = 'pending' AND upload_token IS NOT NULL AND upload_deadline_at IS NOT NULL) OR " <>
            "(status = 'active' AND upload_token IS NULL AND upload_deadline_at IS NULL AND upload_session_url IS NULL) OR " <>
            "(status = 'cleanup' AND upload_token IS NULL AND upload_deadline_at IS NULL)"
      )
    )

    alter table(:comma_users) do
      add(
        :avatar_id,
        references(:comma_user_avatars, type: :string, on_delete: :nilify_all)
      )
    end

    create(index(:comma_users, [:avatar_id]))
  end
end
