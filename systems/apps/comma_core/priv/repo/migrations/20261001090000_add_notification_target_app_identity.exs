defmodule Comma.Repo.Migrations.AddNotificationTargetAppIdentity do
  use Ecto.Migration

  def change do
    # No identity can be derived from an APNs token or environment. Keep legacy
    # rows nullable until their session re-enrolls or an operator supplies an
    # authoritative legacy topic. This migration neither deletes nor backfills.
    alter table(:comma_notification_targets) do
      add(:bundle_id, :text)
      add(:locale, :text, null: false, default: "en-US")
    end

    create(
      constraint(:comma_notification_targets, :notification_target_app_identity,
        check:
          "(bundle_id IS NULL OR bundle_id IN ('surf.comma.ios', 'surf.comma.ios.dev')) AND locale IN ('en-US', 'zh-Hans')"
      )
    )
  end
end
