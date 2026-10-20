defmodule SalixStore.Repo.Migrations.CreateSalixStations do
  use Ecto.Migration

  # The station roster Salix keeps as the stations' control plane
  # (`SalixStore.Stations`): the stations of each Group, the keys that sign
  # member credentials, and the credentials taken back, with the semantics of
  # comma_stations, comma_station_signing_keys and comma_station_revocations.
  # Expand-only: new tables, which Comma migration 20261010200002 fills.
  def change do
    # A still.fail station of a Group. The id is the hex Ed25519 public key
    # the station proves on every signed request. `enrolled_by` is the
    # product's opaque user id; nil for a station the control plane placed.
    create table(:salix_stations, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:tenant_id, :text, null: false)
      add(:group_id, :text, null: false)
      add(:name, :text, null: false)
      add(:version, :text)
      add(:kind, :text, null: false)
      add(:enrolled_by, :text)
      add(:enrolled_at, :utc_datetime_usec, null: false)
      add(:removed_at, :utc_datetime_usec)
      add(:last_seen_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(constraint(:salix_stations, :salix_stations_id_hex, check: "id ~ '^[0-9a-f]{64}$'"))

    create(
      constraint(:salix_stations, :salix_stations_kind_valid,
        check: "kind in ('device', 'cloud_vm')"
      )
    )

    create(
      index(:salix_stations, [:group_id, :enrolled_at],
        where: "removed_at IS NULL",
        name: :salix_stations_group_roster
      )
    )

    # Ed25519 keys that sign member credentials: one signing, at most one
    # pending, verify_only until retire_after.
    create table(:salix_station_signing_keys, primary_key: false) do
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
      constraint(:salix_station_signing_keys, :salix_station_signing_keys_status_valid,
        check: "status in ('signing', 'pending', 'verify_only')"
      )
    )

    create(
      unique_index(:salix_station_signing_keys, [:status],
        where: "status = 'signing'",
        name: :salix_station_signing_keys_one_signing
      )
    )

    create(
      unique_index(:salix_station_signing_keys, [:status],
        where: "status = 'pending'",
        name: :salix_station_signing_keys_one_pending
      )
    )

    # Credentials taken back before expiry, told to the Group's stations for
    # 31 days (one day more than a credential lasts).
    create table(:salix_station_revocations, primary_key: false) do
      add(:tenant_id, :text, null: false)
      add(:group_id, :text, primary_key: true)
      add(:kind, :text, primary_key: true)
      add(:subject_id, :text, primary_key: true)
      add(:at, :bigint, null: false)
    end

    create(
      constraint(:salix_station_revocations, :salix_station_revocations_kind_valid,
        check: "kind in ('sub', 'sid')"
      )
    )

    create(index(:salix_station_revocations, [:group_id, :at]))
  end
end
