defmodule SalixStore.Repo.Migrations.CreateLocalFileRefs do
  use Ecto.Migration

  def change do
    create table(:local_file_refs, primary_key: false) do
      add(:ref_digest, :text, primary_key: true)
      add(:version, :integer, null: false)
      add(:tenant_id, :text, null: false)
      add(:group_id, :text, null: false)
      add(:owner_user_id, :text, null: false)
      add(:stable_device_id, :text, null: false)
      add(:state, :text, null: false)
      add(:conversation_id, :text)
      add(:message_id, :text)
      add(:created_at, :utc_datetime_usec, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:bound_at, :utc_datetime_usec)
      add(:revoked_at, :utc_datetime_usec)
      add(:retired_at, :utc_datetime_usec)
    end

    # Retired ref-digest tombstones are permanent. Keep them out of the
    # periodic expiry walk so one bounded cleanup pass never scans historical
    # tombstones before reaching live lifecycle rows.
    create(
      index(:local_file_refs, [:expires_at, :ref_digest],
        name: :local_file_refs_active_expiry_idx,
        where: "state IN ('registered', 'bound', 'revoked')"
      )
    )

    create(
      constraint(:local_file_refs, :local_file_refs_state,
        check: "state IN ('registered', 'bound', 'revoked', 'retired')"
      )
    )

    create(
      constraint(:local_file_refs, :local_file_refs_binding,
        check: """
        (state = 'registered' AND conversation_id IS NULL AND message_id IS NULL AND bound_at IS NULL) OR
        (state = 'bound' AND conversation_id IS NOT NULL AND message_id IS NOT NULL AND bound_at IS NOT NULL) OR
        state = 'revoked' OR
        (state = 'retired' AND conversation_id IS NULL AND message_id IS NULL AND bound_at IS NULL)
        """
      )
    )
  end
end
