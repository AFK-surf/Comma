defmodule SalixStore.Repo.Migrations.TypeSubscriptionAccounts do
  use Ecto.Migration

  def change do
    create(
      index(:runtime_subscription_bindings, [:tenant_id, :account_id, :id],
        name: :runtime_subscription_bindings_account_page_idx
      )
    )

    execute(
      """
      UPDATE subscription_accounts
      SET value = jsonb_set(value, '{credential_kind}', '"subscription_oauth"'::jsonb, true)
      WHERE NOT value ? 'credential_kind'
      """,
      """
      UPDATE subscription_accounts
      SET value = value - 'credential_kind'
      WHERE value->>'credential_kind' = 'subscription_oauth'
      """
    )
  end
end
