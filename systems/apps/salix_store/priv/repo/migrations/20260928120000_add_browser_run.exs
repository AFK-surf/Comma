defmodule SalixStore.Repo.Migrations.AddBrowserRun do
  use Ecto.Migration

  def change do
    create table(:browser_settings, primary_key: false) do
      add(:scope, :text, primary_key: true)
      add(:mode, :text, null: false)
      add(:account_id, :text)
      add(:token_ciphertext, :text)
      add(:idle_timeout_ms, :integer, null: false, default: 60000)
      add(:operation_timeout_ms, :integer, null: false, default: 15000)
      add(:allowed_domains, {:array, :text})
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create table(:browser_bindings, primary_key: false) do
      add(:agent_id, :text, primary_key: true)
      add(:session_id, :text, primary_key: true)
      add(:tenant_id, :text, null: false)
      add(:group_id, :text, null: false)
      add(:provider_id, :text)
      add(:account_id, :text, null: false)
      add(:token_ciphertext, :text, null: false)
      add(:credential_scope, :text, null: false)
      add(:options, :map, null: false, default: %{})
      add(:status, :text, null: false)
      add(:control, :text, null: false, default: "agent")
      add(:controller, :text)
      add(:controller_expires_at, :utc_datetime_usec)
      add(:pending, :text)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(index(:browser_bindings, [:tenant_id, :group_id, :updated_at]))
  end
end
