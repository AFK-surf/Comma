defmodule SalixStore.Repo.Migrations.IndexSubscriptionAccountEmail do
  use Ecto.Migration

  def change do
    create(
      index(
        :subscription_accounts,
        [
          :tenant_id,
          "(value->>'provider')",
          "lower(btrim(value->>'email'))",
          :id
        ],
        name: :subscription_accounts_email_idx
      )
    )
  end
end
