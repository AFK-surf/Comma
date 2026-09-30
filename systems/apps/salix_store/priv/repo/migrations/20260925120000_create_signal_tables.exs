defmodule SalixStore.Repo.Migrations.CreateSignalTables do
  use Ecto.Migration

  # Durable state of Signal accounts (PLAN "Durable state"). Only the
  # account's ring-placed owner (`SalixSignal.Account.Server`) writes these
  # rows, and every write checks the owner epoch in `signal_accounts` in the
  # same transaction. Losing them means re-registration and a safety-number
  # change for every contact, so they are owned durable data.
  #
  # Every `data` column is AES-256-GCM ciphertext under the Signal storage
  # key, bound to its table, account and row key. Remote service IDs, group
  # identifiers and message identities appear only as keyed blind indexes
  # (HMAC-SHA256 under a key derived from the same storage key). Additive:
  # no existing table changes.
  def change do
    create table(:signal_accounts, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:state, :text, null: false)
      add(:scope, :text, null: false)
      add(:organization_id, :text)
      add(:aci_index, :binary)
      add(:number_index, :binary)
      add(:owner_epoch, :bigint, null: false, default: 0)
      add(:owner_node, :text)
      add(:delivered_seq, :bigint, null: false, default: 0)
      add(:data, :binary, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:signal_accounts, :signal_accounts_state_check,
        check: "state IN ('registering', 'active', 're_registering', 'retired')"
      )
    )

    create(
      constraint(:signal_accounts, :signal_accounts_scope_check,
        check:
          "(scope = 'platform' AND organization_id IS NULL) OR " <>
            "(scope = 'organization' AND organization_id IS NOT NULL)"
      )
    )

    create(unique_index(:signal_accounts, [:aci_index]))
    create(index(:signal_accounts, [:number_index]))
    create(index(:signal_accounts, [:state, :id]))

    # One row per identity (aci, pni): slot 0 holds the pre-key store
    # without its one-time keys; slots 1 (EC) and 2 (KEM) hold one row per
    # one-time pre-key, so using one deletes one row.
    create table(:signal_prekeys, primary_key: false) do
      add(:account_id, references(:signal_accounts, type: :uuid, on_delete: :delete_all),
        primary_key: true
      )

      add(:identity, :text, primary_key: true)
      add(:slot, :smallint, primary_key: true)
      add(:key_id, :integer, primary_key: true)
      add(:data, :binary, null: false)
    end

    create(
      constraint(:signal_prekeys, :signal_prekeys_identity_check,
        check: "identity IN ('aci', 'pni') AND slot IN (0, 1, 2)"
      )
    )

    create table(:signal_sessions, primary_key: false) do
      add(:account_id, references(:signal_accounts, type: :uuid, on_delete: :delete_all),
        primary_key: true
      )

      add(:name_index, :binary, primary_key: true)
      add(:device_id, :smallint, primary_key: true)
      add(:data, :binary, null: false)
    end

    # Remote identity keys (trust on first use) and per-contact state.
    create table(:signal_identities, primary_key: false) do
      add(:account_id, references(:signal_accounts, type: :uuid, on_delete: :delete_all),
        primary_key: true
      )

      add(:name_index, :binary, primary_key: true)
      add(:identity, :binary)
      add(:contact, :binary)
    end

    # Group master key, revision, decrypted state, send endorsements and
    # this device's own sender key for the group.
    create table(:signal_groups, primary_key: false) do
      add(:account_id, references(:signal_accounts, type: :uuid, on_delete: :delete_all),
        primary_key: true
      )

      add(:group_index, :binary, primary_key: true)
      add(:data, :binary, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    # Received sender keys, one per (sender, device, distribution ID).
    create table(:signal_sender_keys, primary_key: false) do
      add(:account_id, references(:signal_accounts, type: :uuid, on_delete: :delete_all),
        primary_key: true
      )

      add(:key_index, :binary, primary_key: true)
      add(:data, :binary, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(index(:signal_sender_keys, [:account_id, :updated_at]))

    # Admitted envelopes (kind 1, key = server GUID, with the encrypted
    # outcome) and received message identities (kind 2, key = blind index),
    # for deduplication after redelivery. `seq` orders the inbound feed.
    create table(:signal_inbound, primary_key: false) do
      add(:seq, :bigserial, null: false)

      add(:account_id, references(:signal_accounts, type: :uuid, on_delete: :delete_all),
        primary_key: true
      )

      add(:kind, :smallint, primary_key: true)
      add(:key, :binary, primary_key: true)
      add(:data, :binary)
      add(:admitted_at, :utc_datetime_usec, null: false)
    end

    create(index(:signal_inbound, [:account_id, :seq], where: "kind = 1"))
    create(index(:signal_inbound, [:account_id, :admitted_at]))

    # Sent content kept to answer retry requests.
    create table(:signal_sent, primary_key: false) do
      add(:account_id, references(:signal_accounts, type: :uuid, on_delete: :delete_all),
        primary_key: true
      )

      add(:key_index, :binary, primary_key: true)
      add(:data, :binary, null: false)
      add(:sent_at, :utc_datetime_usec, null: false)
    end

    create(index(:signal_sent, [:account_id, :sent_at]))
  end
end
