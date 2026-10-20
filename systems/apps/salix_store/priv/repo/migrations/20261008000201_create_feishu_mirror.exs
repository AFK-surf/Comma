defmodule SalixStore.Repo.Migrations.CreateFeishuMirror do
  use Ecto.Migration

  # Durable state for the Feishu message mirror (SalixIM.FeishuMessageMirror).
  # Expand-only: new tables, no existing table changes.
  def change do
    # The hop between the Feishu callback and ClickHouse. One row per mirrored
    # event; the drainer deletes a row only after ClickHouse acknowledged it,
    # so the table is exactly the set of events ClickHouse has not confirmed.
    create table(:feishu_mirror_outbox, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:kind, :text, null: false, default: "message")
      # The normalized mirror row in ClickHouse's column shape.
      add(:row, :jsonb, null: false)
      add(:attempts, :integer, null: false, default: 0)
      # A claim, not a fence. Expiry is release.
      add(:claimed_until, :utc_datetime_usec)
      add(:last_error, :text)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    # One row per Feishu app installation to walk. Feishu rate-limits per app,
    # so the installation is the unit a Pod claims.
    create table(:feishu_mirror_backfill_connects, primary_key: false) do
      add(:connect_id, :text, primary_key: true)
      add(:tenant_id, :text, null: false)
      add(:group_id, :text, null: false)
      add(:leased_until, :utc_datetime_usec)
      add(:due_at, :utc_datetime_usec, null: false)
      add(:last_error, :text)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(index(:feishu_mirror_backfill_connects, [:due_at]))

    # One watermark per walked container: a chat's top-level history, or one
    # thread. Keyed the way ClickHouse keys the rows (tenant, app), so a
    # watermark describes exactly one set of mirrored messages.
    create table(:feishu_mirror_containers, primary_key: false) do
      add(:tenant_id, :text, primary_key: true)
      add(:app_id, :text, primary_key: true)
      # `chat` or `thread`.
      add(:container_type, :text, primary_key: true)
      add(:container_id, :text, primary_key: true)
      # The chat a thread belongs to, or the chat itself.
      add(:chat_id, :text, null: false)
      # Every message in the container with create_time in
      # [indexed_from, indexed_to] is in ClickHouse. Only ever moves down.
      add(:indexed_from_us, :bigint)
      # Fixed by the first page: the live path owns everything after it.
      add(:indexed_to_us, :bigint)
      # Feishu continuation for the next older page. Losing it costs a re-walk.
      add(:page_token, :text)
      add(:exhausted, :boolean, null: false, default: false)
      add(:last_error, :text)
      add(:updated_at, :utc_datetime_usec, null: false)
    end
  end
end
