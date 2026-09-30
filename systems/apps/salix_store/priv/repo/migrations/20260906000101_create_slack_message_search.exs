defmodule SalixStore.Repo.Migrations.CreateSlackMessageSearch do
  use Ecto.Migration

  # Local metadata only; no provider, ClickHouse, or encoder calls. The source
  # epoch and outbox admission commit together. Content stays in the existing
  # pending outbox and in ClickHouse, never in the publication catalog.
  def change do
    # An old webhook drainer must never see a history/repair batch: it would
    # treat that batch as a live Triage event. This source-write outbox also
    # keeps history retries behind live webhook delivery after rollout.
    create table(:slack_mirror_source_writes, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:kind, :text, null: false, default: "message")
      add(:row, :map, null: false)
      add(:context, :map, null: false, default: %{})
      add(:attempts, :integer, null: false, default: 0)
      add(:claimed_until, :utc_datetime_usec)
      add(:last_error, :text)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create(
      index(
        :slack_mirror_source_writes,
        [
          "(row->>'tenant_id')",
          "(row->>'workspace_id')",
          "(row->>'channel_id')",
          "(row->>'message_ts_us')"
        ],
        name: :slack_search_pending_history_source
      )
    )

    create table(:search_sources, prefix: "slack_semantic", primary_key: false) do
      add(:tenant_id, :text, primary_key: true)
      add(:workspace_id, :text, primary_key: true)
      add(:channel_id, :text, primary_key: true)
      add(:message_ts_us, :bigint, primary_key: true)
      add(:change_epoch, :bigint, null: false, default: 0)
    end

    execute(
      "CREATE SEQUENCE slack_semantic.search_build_sequence AS bigint",
      "DROP SEQUENCE slack_semantic.search_build_sequence"
    )

    create table(:search_components, prefix: "slack_semantic", primary_key: false) do
      add(:tenant_id, :text, primary_key: true)
      add(:group_id, :text, primary_key: true)
      add(:connect_id, :text, primary_key: true)
      add(:connect_generation, :text, null: false, default: "")
      add(:workspace_id, :text, primary_key: true)
      add(:channel_id, :text, primary_key: true)
      add(:message_ts_us, :bigint, primary_key: true)
      add(:component, :text, primary_key: true)
      add(:change_epoch, :bigint, null: false)
      add(:build_id, :uuid, null: false)
      add(:build_sequence, :bigint, null: false)
      add(:message_identity, :text, null: false)
      add(:payload_identity, :text, null: false)
      add(:file_id, :text, null: false, default: "")
      add(:file_epoch, :bigint, null: false, default: 0)
      add(:unit_count, :integer, null: false)
      add(:published_at, :utc_datetime_usec, null: false)
    end

    create(
      index(
        :search_components,
        [
          :tenant_id,
          :workspace_id,
          :file_id,
          :group_id,
          :connect_id,
          :channel_id,
          :message_ts_us
        ],
        prefix: "slack_semantic"
      )
    )

    create table(:search_files, prefix: "slack_semantic", primary_key: false) do
      add(:tenant_id, :text, primary_key: true)
      add(:workspace_id, :text, primary_key: true)
      add(:file_id, :text, primary_key: true)
      add(:change_epoch, :bigint, null: false, default: 0)
      add(:deleted, :boolean, null: false, default: false)
      add(:refresh_pending, :boolean, null: false, default: false)
      add(:refresh_cursor, :map, null: false, default: %{})

      add(:changed_at, :utc_datetime_usec,
        null: false,
        default: fragment("timezone('UTC', now())")
      )
    end

    create(
      index(:search_files, [:changed_at, :tenant_id, :workspace_id, :file_id],
        where: "refresh_pending",
        prefix: "slack_semantic"
      )
    )

    create table(:search_connects, prefix: "slack_semantic", primary_key: false) do
      add(:tenant_id, :text, primary_key: true)
      add(:group_id, :text, primary_key: true)
      add(:connect_id, :text, primary_key: true)
      add(:connect_generation, :text, null: false)
      add(:workspace_id, :text, null: false)
      add(:active, :boolean, null: false)
    end

    create table(:search_channels, prefix: "slack_semantic", primary_key: false) do
      add(:tenant_id, :text, primary_key: true)
      add(:group_id, :text, primary_key: true)
      add(:connect_id, :text, primary_key: true)
      add(:connect_generation, :text, null: false, default: "")
      add(:workspace_id, :text, primary_key: true)
      add(:channel_id, :text, primary_key: true)
    end

    create table(:search_cursors, prefix: "slack_semantic", primary_key: false) do
      add(:tenant_id, :text, primary_key: true)
      add(:workspace_id, :text, primary_key: true)
      add(:channel_id, :text, primary_key: true)
      add(:group_id, :text, primary_key: true)
      add(:connect_id, :text, primary_key: true)
      add(:before_ts_us, :bigint, null: false, default: 0)
    end

    create table(:search_windows, prefix: "slack_semantic", primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:tenant_id, :text, null: false)
      add(:group_id, :text, null: false)
      add(:request, :map, null: false)
      add(:candidates, {:array, :map}, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
    end

    create(index(:search_windows, [:expires_at, :id], prefix: "slack_semantic"))
  end
end
