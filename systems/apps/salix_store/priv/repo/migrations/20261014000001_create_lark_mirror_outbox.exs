defmodule SalixStore.Repo.Migrations.CreateLarkMirrorOutbox do
  use Ecto.Migration

  # Durable state for the record of Lark messages (SalixIM.LarkMessageRecord).
  # Expand-only: a new table, no existing table changes.
  def change do
    # The hop between the Lark callback and ClickHouse. One row per recorded
    # message; the drainer deletes a row only after ClickHouse acknowledged it,
    # so the table is exactly the set of messages ClickHouse has not confirmed.
    create table(:lark_mirror_outbox, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:kind, :text, null: false, default: "message")
      # The normalized row in ClickHouse's column shape.
      add(:row, :jsonb, null: false)
      add(:attempts, :integer, null: false, default: 0)
      # A claim, not a fence. Expiry is release.
      add(:claimed_until, :utc_datetime_usec)
      add(:last_error, :text)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end
  end
end
