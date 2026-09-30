defmodule Comma.Repo.Migrations.CreateCommaProductState do
  use Ecto.Migration

  def change do
    create table(:comma_users, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:normalized_email, :string, null: false)
      add(:status, :string, null: false, default: "active")
      add(:display_name, :string)
      add(:profile, :map, null: false, default: %{})
      add(:lock_version, :integer, null: false, default: 1)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:comma_users, [:normalized_email]))

    create(
      constraint(:comma_users, :comma_users_status_check,
        check: "status IN ('active', 'disabled', 'deleted')"
      )
    )

    create table(:comma_workspaces, primary_key: false) do
      add(:id, :string, primary_key: true)

      add(:owner_user_id, references(:comma_users, type: :string, on_delete: :restrict),
        null: false
      )

      add(:salix_tenant_id, :string, null: false)
      add(:salix_group_id, :string, null: false)
      add(:group_generation, :string, null: false)
      add(:salix_router_agent_id, :string, null: false)
      add(:salix_worker_agent_id, :string, null: false)
      add(:billing_owner_id, :string, null: false)
      add(:name, :string)
      add(:status, :string, null: false, default: "active")
      add(:lock_version, :integer, null: false, default: 1)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:comma_workspaces, [:salix_tenant_id]))
    create(unique_index(:comma_workspaces, [:salix_group_id]))
    create(index(:comma_workspaces, [:owner_user_id, :status]))

    create(
      constraint(:comma_workspaces, :comma_workspaces_status_check,
        check: "status IN ('provisioning', 'active', 'suspended', 'failed', 'deleted')"
      )
    )

    create table(:comma_workspace_memberships) do
      add(:workspace_id, references(:comma_workspaces, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:user_id, references(:comma_users, type: :string, on_delete: :delete_all), null: false)
      add(:role, :string, null: false)
      add(:status, :string, null: false, default: "active")
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:comma_workspace_memberships, [:workspace_id, :user_id]))
    create(index(:comma_workspace_memberships, [:user_id, :status, :workspace_id]))

    create(
      constraint(:comma_workspace_memberships, :comma_workspace_memberships_role_check,
        check: "role IN ('owner', 'admin', 'member', 'viewer')"
      )
    )

    create(
      constraint(:comma_workspace_memberships, :comma_workspace_memberships_status_check,
        check: "status IN ('active', 'invited', 'removed')"
      )
    )

    create table(:comma_conversation_bindings, primary_key: false) do
      add(:id, :string, primary_key: true)

      add(:workspace_id, references(:comma_workspaces, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:salix_conversation_id, :string, null: false)
      add(:kind, :string, null: false)
      add(:state, :string, null: false, default: "active")
      add(:binding_version, :integer, null: false, default: 1)
      add(:lock_version, :integer, null: false, default: 1)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:comma_conversation_bindings, [:salix_conversation_id]))
    create(index(:comma_conversation_bindings, [:workspace_id, :kind, :state, :id]))

    create(
      constraint(:comma_conversation_bindings, :comma_conversation_bindings_kind_check,
        check: "kind IN ('user_chat', 'agent_task')"
      )
    )

    create(
      constraint(:comma_conversation_bindings, :comma_conversation_bindings_state_check,
        check: "state IN ('pending', 'active', 'archived', 'failed')"
      )
    )

    create table(:comma_sessions, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:token_hash, :binary, null: false)
      add(:user_id, references(:comma_users, type: :string, on_delete: :delete_all), null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:status, :string, null: false, default: "active")
      add(:restricted, :boolean, null: false, default: false)
      add(:workspace_id, references(:comma_workspaces, type: :string, on_delete: :nilify_all))

      add(
        :conversation_id,
        references(:comma_conversation_bindings, type: :string, on_delete: :nilify_all)
      )

      add(:interaction_budget_remaining, :integer)
      add(:tool_allowlist, {:array, :string}, null: false, default: [])
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:comma_sessions, [:token_hash]))
    create(index(:comma_sessions, [:user_id, :status, :expires_at]))
    create(index(:comma_sessions, [:workspace_id, :conversation_id]))

    create(
      constraint(:comma_sessions, :comma_sessions_status_check,
        check: "status IN ('active', 'revoked', 'expired')"
      )
    )

    create(
      constraint(:comma_sessions, :comma_sessions_budget_check,
        check: "interaction_budget_remaining IS NULL OR interaction_budget_remaining >= 0"
      )
    )

    create(
      constraint(:comma_sessions, :comma_sessions_scope_check,
        check:
          "restricted OR (workspace_id IS NULL AND conversation_id IS NULL AND interaction_budget_remaining IS NULL AND cardinality(tool_allowlist) = 0)"
      )
    )

    create table(:comma_salix_conversation_projections, primary_key: false) do
      add(:salix_conversation_id, :string, primary_key: true)

      add(
        :conversation_id,
        references(:comma_conversation_bindings, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:workspace_id, references(:comma_workspaces, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:source_version, :string, null: false)
      add(:fresh_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:comma_salix_conversation_projections, [:conversation_id]))
    create(index(:comma_salix_conversation_projections, [:workspace_id, :fresh_at]))

    create table(:comma_assistant_chat_bindings) do
      add(:user_id, references(:comma_users, type: :string, on_delete: :delete_all), null: false)

      add(:workspace_id, references(:comma_workspaces, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:salix_group_id, :string, null: false)
      add(:group_generation, :string, null: false)

      add(
        :conversation_id,
        references(:comma_conversation_bindings, type: :string, on_delete: :delete_all),
        null: false
      )

      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(
        :comma_assistant_chat_bindings,
        [
          :user_id,
          :workspace_id,
          :salix_group_id,
          :group_generation
        ],
        name: :comma_assistant_chat_business_key_idx
      )
    )

    create(unique_index(:comma_assistant_chat_bindings, [:conversation_id]))

    create table(:comma_workspace_conversation_items) do
      add(:workspace_id, references(:comma_workspaces, type: :string, on_delete: :delete_all),
        null: false
      )

      add(
        :conversation_id,
        references(:comma_conversation_bindings, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:sort_key, :bigint, null: false)
      add(:occurred_at, :utc_datetime_usec, null: false)
      add(:fresh_at, :utc_datetime_usec, null: false)
      add(:source_version, :string, null: false)
      add(:metadata, :map, null: false, default: %{})
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:comma_workspace_conversation_items, [:workspace_id, :conversation_id],
        name: :comma_workspace_item_identity_idx
      )
    )

    create(
      index(
        :comma_workspace_conversation_items,
        [
          :workspace_id,
          :sort_key,
          :conversation_id
        ],
        name: :comma_workspace_conversation_items_page_idx
      )
    )

    create table(:comma_external_operations, primary_key: false) do
      add(:operation_id, :string, primary_key: true)
      add(:operation_type, :string, null: false)
      add(:owner_type, :string, null: false)
      add(:owner_id, :string, null: false)
      add(:generation, :integer, null: false)
      add(:status, :string, null: false, default: "pending")
      add(:attempt, :integer, null: false, default: 0)
      add(:next_attempt_at, :utc_datetime_usec)
      add(:last_error_class, :string)
      add(:external_idempotency_key, :string, null: false)
      add(:external_identity, :string)
      add(:metadata, :map, null: false, default: %{})
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(
        :comma_external_operations,
        [
          :operation_type,
          :owner_type,
          :owner_id,
          :generation
        ],
        name: :comma_operation_generation_idx
      )
    )

    create(unique_index(:comma_external_operations, [:external_idempotency_key]))

    create(
      index(:comma_external_operations, [:status, :next_attempt_at, :operation_id],
        name: :comma_operation_claim_idx
      )
    )

    create(
      constraint(:comma_external_operations, :comma_external_operations_generation_check,
        check: "generation >= 0 AND attempt >= 0"
      )
    )

    create(
      constraint(:comma_external_operations, :comma_external_operations_status_check,
        check:
          "status IN ('pending', 'executing', 'retryable', 'succeeded', 'terminal_failed', 'superseded')"
      )
    )

    create table(:comma_conversation_adoption_suppressions, primary_key: false) do
      add(:source_key, :string, primary_key: true)

      add(:workspace_id, references(:comma_workspaces, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:salix_conversation_id, :string, null: false)
      add(:reason, :string, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      index(:comma_conversation_adoption_suppressions, [:workspace_id, :expires_at],
        name: :comma_adoption_suppression_expiry_idx
      )
    )

    create table(:comma_conversation_adoption_attempts, primary_key: false) do
      add(:source_id, :string, primary_key: true)

      add(:workspace_id, references(:comma_workspaces, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:salix_conversation_id, :string, null: false)
      add(:outcome, :string, null: false)
      add(:error_class, :string)
      add(:observed_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      index(
        :comma_conversation_adoption_attempts,
        [
          :workspace_id,
          :observed_at,
          :source_id
        ],
        name: :comma_adoption_attempt_page_idx
      )
    )

    create table(:comma_reconciliation_cursors, primary_key: false) do
      add(:source_key, :string, primary_key: true)

      add(:workspace_id, references(:comma_workspaces, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:kind, :string, null: false)
      add(:cursor, :string)
      add(:high_water_mark, :string)
      add(:lock_version, :integer, null: false, default: 1)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:comma_reconciliation_cursors, [:workspace_id, :kind]))
  end
end
