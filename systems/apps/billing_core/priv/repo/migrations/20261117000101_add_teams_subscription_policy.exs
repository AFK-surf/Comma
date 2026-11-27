defmodule BillingCore.Repo.Migrations.AddTeamsSubscriptionPolicy do
  use Ecto.Migration

  def change do
    alter table(:billing_accounts) do
      add(:teams_subscription_required, :boolean, null: false, default: false)
    end

    create(index(:billing_subscription_cycles, [:billing_account_id, :period_end, :period_start]))
  end
end
