defmodule BridgeForTeams.Repo.Migrations.CreateFeishuAppBindings do
  use Ecto.Migration

  @ts [type: :utc_datetime_usec, inserted_at: :created_at]

  # Org-level Feishu app binding (RFC feishu-onboarding-rfc.md §4). Per option B
  # (§4.4) this row holds only NON-secret posture — capability flags and
  # `*_configured` flags — never secret bytes (which stay in their owning store:
  # SSO secret in org_sso_connections, bot secret in Salix) and never verification
  # status (honest status comes only from a live Run-checks result, RFC §6.3/§12).
  def change do
    create table(:feishu_app_bindings, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v7()")
      add :org_id, references(:organizations, type: :binary_id, on_delete: :delete_all), null: false

      add :app_id, :string, null: false
      add :display_name, :string

      add :sso_enabled, :boolean, null: false, default: false
      add :bot_enabled, :boolean, null: false, default: false

      add :app_secret_configured, :boolean, null: false, default: false
      add :verification_token_configured, :boolean, null: false, default: false
      add :encrypt_key_configured, :boolean, null: false, default: false

      timestamps(@ts)
    end

    create unique_index(:feishu_app_bindings, [:org_id, :app_id])
    create index(:feishu_app_bindings, [:org_id])
  end
end
