defmodule SalixStore.Repo.Migrations.CreateSlackMirrorOutbox do
  use Ecto.Migration

  # The durable hop between the Slack webhook and ClickHouse. The webhook
  # inserts one row per mirrored event and returns; a drainer moves rows to
  # ClickHouse and deletes them once the insert is acknowledged. A row is never
  # deleted for any other reason, so the table is exactly the set of events
  # ClickHouse has not confirmed yet. Design: docs/salix/slack-message-mirror.md
  def change do
    create table(:slack_mirror_outbox, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      # `message` lands in slack_messages; `reaction` lands in
      # slack_message_reactions. Same outbox, same delete-after-ack rule.
      add(:kind, :text, null: false, default: "message")
      # The normalized mirror row, already in ClickHouse's column shape, so the
      # drainer needs no Slack context to write it.
      add(:row, :jsonb, null: false)
      add(:attempts, :integer, null: false, default: 0)
      # A claim, not a fence: it keeps two drainers off the same rows and lets
      # a failed batch wait before it is tried again. Expiry is release.
      add(:claimed_until, :utc_datetime_usec)
      add(:last_error, :text)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    # The drainer takes the oldest claimable rows by id, so the primary key is
    # the only index the claim needs; `claimed_until` is filtered on the rows
    # the scan already visits.
  end
end
