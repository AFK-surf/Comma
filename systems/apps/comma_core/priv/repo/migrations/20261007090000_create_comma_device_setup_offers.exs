defmodule Comma.Repo.Migrations.CreateCommaDeviceSetupOffers do
  use Ecto.Migration

  def change do
    # An offer to set up an unprovisioned Comma device that a member's phone
    # found nearby. The Home Message shows it; this row owns its status.
    create table(:comma_device_setup_offers, primary_key: false) do
      add(:id, :text, primary_key: true)

      add(:workspace_id, references(:comma_workspaces, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:salix_group_id, :text, null: false)
      add(:short_id, :text, null: false)
      add(:name, :text, null: false)
      add(:model, :text, null: false)
      add(:reporter_device_id, :text, null: false)
      add(:reporter_user_id, :text, null: false)
      add(:request_id, :text, null: false)
      add(:status, :text, null: false)
      # Each status change takes the next revision. Clients show the card
      # with the highest revision, whatever order its events arrive in.
      add(:revision, :integer, null: false, default: 1)
      add(:device_id, :text)
      add(:message_id, :text)
      add(:expires_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:comma_device_setup_offers, :comma_device_setup_offers_status_valid,
        check: "status in ('open', 'started', 'dismissed', 'done', 'expired')"
      )
    )

    create(
      constraint(:comma_device_setup_offers, :comma_device_setup_offers_short_id_hex,
        check: "short_id ~ '^[0-9A-F]{4}$'"
      )
    )

    create(index(:comma_device_setup_offers, [:workspace_id, :short_id, :inserted_at]))

    create(
      index(:comma_device_setup_offers, [:salix_group_id],
        where: "status in ('open', 'started')",
        name: :comma_device_setup_offers_active_by_group
      )
    )
  end
end
