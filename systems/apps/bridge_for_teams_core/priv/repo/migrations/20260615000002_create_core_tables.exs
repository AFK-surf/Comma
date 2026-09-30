defmodule BridgeForTeams.Repo.Migrations.CreateCoreTables do
  @moduledoc """
  Phase-1 schema (design §5). Every table keyed by a UUID v7 `binary_id`
  primary key defaulting to `uuid_generate_v7()`; `timestamptz` (usec)
  timestamps with `inserted_at` renamed to `created_at`; create-only tables
  (org/project memberships, auth_sessions, api_keys, reconcile_outbox,
  audit_logs) carry only `created_at`.
  """
  use Ecto.Migration

  # Mirror the schemas' @timestamps_opts: utc_datetime_usec, created_at name.
  @ts [type: :utc_datetime_usec, inserted_at: :created_at]
  @ts_create_only [type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false]

  def change do
    # --- organizations ---------------------------------------------------
    create table(:organizations, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v7()")
      add :name, :string, null: false
      add :slug, :string, null: false
      add :status, :string, null: false, default: "active"
      # The org maps 1:1 to a Salix tenant (the IM/OAuth/API-key isolation root).
      add :salix_tenant_id, :string

      timestamps(@ts)
    end

    create unique_index(:organizations, [:slug])
    create unique_index(:organizations, [:salix_tenant_id])

    # --- users -----------------------------------------------------------
    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v7()")
      add :email, :citext, null: false
      add :name, :string
      add :status, :string, null: false, default: "active"

      timestamps(@ts)
    end

    create unique_index(:users, [:email])

    # --- org_memberships -------------------------------------------------
    create table(:org_memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v7()")

      add :org_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :role, :string, null: false

      timestamps(@ts_create_only)
    end

    create unique_index(:org_memberships, [:org_id, :user_id])
    create index(:org_memberships, [:user_id])

    # --- projects --------------------------------------------------------
    create table(:projects, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v7()")

      add :org_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :slug, :string, null: false
      add :status, :string, null: false, default: "active"
      # The project maps 1:1 to a Salix group (agents/OAuth bindings/conversations)
      # within its org's tenant.
      add :salix_group_id, :string
      add :archived_at, :utc_datetime_usec

      timestamps(@ts)
    end

    create unique_index(:projects, [:org_id, :slug])
    create unique_index(:projects, [:salix_group_id])

    # --- project_memberships ---------------------------------------------
    create table(:project_memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v7()")

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :role, :string, null: false

      timestamps(@ts_create_only)
    end

    create unique_index(:project_memberships, [:project_id, :user_id])
    create index(:project_memberships, [:user_id])

    # --- agents ----------------------------------------------------------
    create table(:agents, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v7()")

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :salix_agent_id, :string
      add :role, :string, null: false
      add :slot, :string
      add :name, :string
      add :llm_config, :map
      add :system_prompt, :text
      add :status, :string, null: false, default: "active"
      add :archived_at, :utc_datetime_usec

      timestamps(@ts)
    end

    create index(:agents, [:project_id])
    create unique_index(:agents, [:salix_agent_id])

    # --- environments ----------------------------------------------------
    create table(:environments, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v7()")

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :salix_env_id, :string
      add :name, :string
      add :status, :string, null: false, default: "pending"
      add :connector_token_hash, :string
      add :last_seen_at, :utc_datetime_usec
      add :meta, :map

      timestamps(@ts)
    end

    create index(:environments, [:project_id])
    create unique_index(:environments, [:salix_env_id])

    # --- auth_sessions ---------------------------------------------------
    create table(:auth_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v7()")
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :token_hash, :string, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec
      add :device, :string

      timestamps(@ts_create_only)
    end

    create unique_index(:auth_sessions, [:token_hash])
    create index(:auth_sessions, [:user_id])

    # --- org_sso_connections ---------------------------------------------
    create table(:org_sso_connections, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v7()")

      add :org_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :issuer, :string, null: false
      add :client_id, :string, null: false
      add :client_secret, :string
      add :allowed_domains, {:array, :string}, null: false, default: []
      add :default_role, :string, null: false, default: "member"

      timestamps(@ts)
    end

    create index(:org_sso_connections, [:org_id])
    create unique_index(:org_sso_connections, [:org_id, :issuer])

    # --- api_keys --------------------------------------------------------
    create table(:api_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v7()")

      add :org_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string
      add :key_hash, :string, null: false
      add :scopes, {:array, :string}, null: false, default: []
      add :revoked_at, :utc_datetime_usec

      timestamps(@ts_create_only)
    end

    create unique_index(:api_keys, [:key_hash])
    create index(:api_keys, [:org_id])

    # --- reconcile_outbox ------------------------------------------------
    # Loose `aggregate_id` (string) per design — drained FOR UPDATE SKIP LOCKED.
    create table(:reconcile_outbox, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v7()")
      add :aggregate, :string, null: false
      add :aggregate_id, :string, null: false
      add :op, :string, null: false
      add :payload, :map
      add :status, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :last_error, :string
      add :processed_at, :utc_datetime_usec

      timestamps(@ts_create_only)
    end

    # Supports the SKIP LOCKED claim query: pending rows oldest-first.
    create index(:reconcile_outbox, [:status, :created_at])

    # --- audit_logs ------------------------------------------------------
    # Bare binary_id columns (no FK) — loose per design (§5, §7).
    create table(:audit_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v7()")
      add :org_id, :binary_id
      add :actor_user_id, :binary_id
      add :action, :string, null: false
      add :target, :string
      add :metadata, :map

      timestamps(@ts_create_only)
    end

    create index(:audit_logs, [:org_id, :created_at])
  end
end
