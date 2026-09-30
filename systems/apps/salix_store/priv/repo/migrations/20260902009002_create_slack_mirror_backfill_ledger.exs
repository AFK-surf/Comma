defmodule SalixStore.Repo.Migrations.CreateSlackMirrorBackfillLedger do
  use Ecto.Migration

  # The Slack history backfill's durable state: one watermark per channel and
  # one lease per Slack installation. Design: docs/salix/slack-message-mirror.md
  def change do
    # Keyed the way ClickHouse keys the rows, so a watermark describes exactly
    # one set of mirrored messages no matter how many bots or groups reach the
    # channel. Every write only ever moves `indexed_from_ts_us` down, which is
    # what lets any number of walkers commit without a fence: a stale commit
    # can only fail to lower it.
    create table(:slack_mirror_channel_watermarks, primary_key: false) do
      add(:tenant_id, :text, primary_key: true)
      add(:workspace_id, :text, primary_key: true)
      add(:channel_id, :text, primary_key: true)
      # Every thread parent with ts in [indexed_from, indexed_to] and every
      # reply to it is in ClickHouse. NULL until the first page lands.
      add(:indexed_from_ts_us, :bigint)
      # Fixed when the first page lands and never moved: the live path owns
      # everything after it.
      add(:indexed_to_ts_us, :bigint)
      # Slack answered with nothing older. Distinct from stopping at the floor,
      # which is the operator's choice and resumes if the floor is lowered.
      add(:exhausted, :boolean, null: false, default: false)
      # Dedupe only. Two bots in one workspace both reach a shared channel; the
      # claim keeps them from walking it twice at once. Expiry is release.
      add(:leased_until, :utc_datetime_usec)
      add(:last_error, :text)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    # Slack rate-limits per workspace and bot token, so the installation is the
    # unit of parallelism and the unit a Pod claims. Two Pods driving one token
    # would only split its budget.
    create table(:slack_mirror_backfill_connects, primary_key: false) do
      add(:connect_id, :text, primary_key: true)
      add(:tenant_id, :text, null: false)
      add(:group_id, :text, null: false)
      add(:leased_until, :utc_datetime_usec)
      add(:due_at, :utc_datetime_usec, null: false)
      add(:last_error, :text)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    # The claim takes the installation that has been due the longest.
    create(index(:slack_mirror_backfill_connects, [:due_at]))
  end
end
