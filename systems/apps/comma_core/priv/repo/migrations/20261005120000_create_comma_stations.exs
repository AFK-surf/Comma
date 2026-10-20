defmodule Comma.Repo.Migrations.CreateCommaStations do
  use Ecto.Migration

  def change do
    # A still.fail station enrolled in a Comma Workspace. The id is the hex
    # Ed25519 public key the station proves on every signed request.
    create table(:comma_stations, primary_key: false) do
      add(:id, :text, primary_key: true)

      add(:workspace_id, references(:comma_workspaces, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:name, :text, null: false)
      add(:version, :text)
      add(:enrolled_by, references(:comma_users, type: :string, on_delete: :nilify_all))
      add(:enrolled_at, :utc_datetime_usec, null: false)
      add(:removed_at, :utc_datetime_usec)
      add(:last_seen_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(constraint(:comma_stations, :comma_stations_id_hex, check: "id ~ '^[0-9a-f]{64}$'"))

    create(
      index(:comma_stations, [:workspace_id, :enrolled_at],
        where: "removed_at IS NULL",
        name: :comma_stations_workspace_roster
      )
    )

    # Ed25519 keys that sign member credentials. Same custody and rotation
    # shape as comma_oauth_signing_keys: one signing, at most one pending.
    create table(:comma_station_signing_keys, primary_key: false) do
      add(:kid, :text, primary_key: true)
      add(:public_key, :binary, null: false)
      add(:private_key_ciphertext, :binary, null: false)
      add(:private_key_iv, :binary, null: false)
      add(:private_key_tag, :binary, null: false)
      add(:status, :text, null: false)
      add(:retire_after, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create(
      constraint(:comma_station_signing_keys, :comma_station_signing_keys_status_valid,
        check: "status in ('signing', 'pending', 'verify_only')"
      )
    )

    create(
      unique_index(:comma_station_signing_keys, [:status],
        where: "status = 'signing'",
        name: :comma_station_signing_keys_one_signing
      )
    )

    create(
      unique_index(:comma_station_signing_keys, [:status],
        where: "status = 'pending'",
        name: :comma_station_signing_keys_one_pending
      )
    )

    # Credentials taken back before expiry, told to the Workspace's stations
    # for 31 days (one day more than a credential lasts).
    create table(:comma_station_revocations, primary_key: false) do
      add(:workspace_id, references(:comma_workspaces, type: :string, on_delete: :delete_all),
        primary_key: true
      )

      add(:kind, :text, primary_key: true)
      add(:subject_id, :text, primary_key: true)
      add(:at, :bigint, null: false)
    end

    create(
      constraint(:comma_station_revocations, :comma_station_revocations_kind_valid,
        check: "kind in ('sub', 'sid')"
      )
    )

    create(index(:comma_station_revocations, [:workspace_id, :at]))
  end
end
