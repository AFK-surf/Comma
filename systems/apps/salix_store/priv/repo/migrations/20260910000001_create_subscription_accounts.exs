defmodule SalixStore.Repo.Migrations.CreateSubscriptionAccounts do
  use Ecto.Migration

  def change do
    create table(:subscription_accounts, primary_key: false) do
      add(:tenant_id, :text, primary_key: true)
      add(:id, :text, primary_key: true)
      add(:value, :map, null: false)
      add(:version, :text, null: false)
      add(:poll_delay_seconds, :integer, null: false, default: 0)
      add(:next_poll_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(index(:subscription_accounts, [:next_poll_at, :tenant_id, :id]))

    create table(:subscription_oauth_attempts, primary_key: false) do
      add(:tenant_id, :text, primary_key: true)
      add(:id, :text, primary_key: true)
      add(:ciphertext, :text, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
    end
  end
end
