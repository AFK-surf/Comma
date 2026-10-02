defmodule Comma.Repo.Migrations.AddNotificationTargetDeliveryLease do
  use Ecto.Migration

  def change do
    # Bounds concurrent delivery to one address without holding a row lock
    # across owner reads and APNs requests.
    alter table(:comma_notification_targets) do
      add(:delivery_lease_until, :utc_datetime_usec)
    end
  end
end
