defmodule BillingCore.Repo.Migrations.AddSubscriptionCheckout do
  use Ecto.Migration

  def change do
    alter table(:billing_accounts) do
      add(:subscription_checkout, :map)
    end
  end
end
