defmodule SalixStore.Repo.Migrations.CreateCalendarFeedSubscriptions do
  use Ecto.Migration

  def change do
    create table(:calendar_feed_subscriptions, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:tenant_id, :text, null: false)
      add(:group_id, :text, null: false)
      add(:calendar_id, :text, null: false)
      add(:subject_namespace, :text, null: false)
      add(:subject_id, :text, null: false)
      add(:token_digest, :binary, null: false)
      add(:revoked_at, :utc_datetime_usec)
      add(:created_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:calendar_feed_subscriptions, [:token_digest]))

    create(
      unique_index(
        :calendar_feed_subscriptions,
        [
          :tenant_id,
          :group_id,
          :calendar_id,
          :subject_namespace,
          :subject_id
        ],
        where: "revoked_at IS NULL",
        name: :calendar_feed_subscriptions_active_subject_idx
      )
    )

    create(
      constraint(:calendar_feed_subscriptions, :calendar_feed_token_digest_size,
        check: "octet_length(token_digest) = 32"
      )
    )

    create(
      constraint(:calendar_feed_subscriptions, :calendar_feed_subject_nonempty,
        check: "subject_namespace <> '' AND subject_id <> ''"
      )
    )
  end
end
