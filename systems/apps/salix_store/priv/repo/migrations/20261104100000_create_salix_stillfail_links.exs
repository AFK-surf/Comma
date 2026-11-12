defmodule SalixStore.Repo.Migrations.CreateSalixStillfailLinks do
  use Ecto.Migration

  # A Group's link to a still.fail workspace through a station's Tailcat data
  # outflow. Expand-only: a new table, which old runtimes ignore.
  def change do
    create table(:salix_stillfail_links, primary_key: false) do
      add(:group_id, :text, primary_key: true)
      add(:tenant_id, :text, null: false)
      add(:address_sealed, :text, null: false)
      add(:port, :integer, null: false)
      add(:token_sealed, :text)
      add(:state, :text, null: false)
      add(:state_at, :utc_datetime_usec, null: false)
      add(:message, :text)
      add(:scopes, {:array, :text}, null: false, default: [])
      add(:reach, :text)
      add(:next_read_at, :utc_datetime_usec, null: false)
      add(:last_read_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:salix_stillfail_links, :salix_stillfail_links_state_valid,
        check: "state in ('asking', 'granted', 'refused', 'revoked', 'failed')"
      )
    )

    create(index(:salix_stillfail_links, [:next_read_at], name: :salix_stillfail_links_due))

    # An Agent conversation waiting for a chat there to stop working.
    create table(:salix_stillfail_watches, primary_key: false) do
      add(:group_id, :text, primary_key: true)
      add(:station, :text, primary_key: true)
      add(:thread, :text, primary_key: true)
      add(:session_id, :text, primary_key: true)
      add(:tenant_id, :text, null: false)
      add(:agent_id, :text, null: false)
      add(:origin, :map)

      timestamps(type: :utc_datetime_usec)
    end
  end
end
