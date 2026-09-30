defmodule Comma.Data.User do
  @moduledoc """
  Historical migration-ledger schema for the canonical `comma_users` table.

  Serving authentication uses `Comma.Accounts.User`; no runtime importer uses
  this wider schema.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "comma_users" do
    field(:normalized_email, :string)
    field(:status, :string, default: "active")
    field(:display_name, :string)
    field(:profile, :map, default: %{})
    field(:lock_version, :integer, default: 1)
    field(:auth_epoch, :integer, default: 0)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [
      :id,
      :normalized_email,
      :status,
      :display_name,
      :profile,
      :lock_version,
      :auth_epoch
    ])
    |> update_change(:normalized_email, &(&1 |> String.trim() |> String.downcase()))
    |> validate_required([:id, :normalized_email, :status])
    |> unique_constraint(:normalized_email)
    |> check_constraint(:status, name: :comma_users_status_check)
  end
end

defmodule Comma.Data.Workspace do
  use Ecto.Schema
  import Ecto.Changeset

  @persisted_statuses ~w(provisioning provisioning_failed active suspended failed deleted)
  @primary_key {:id, :string, autogenerate: false}
  schema "comma_workspaces" do
    field(:owner_user_id, :string)
    field(:salix_tenant_id, :string)
    field(:salix_group_id, :string)
    field(:group_generation, :string)
    field(:salix_router_agent_id, :string)
    field(:salix_worker_agent_id, :string)
    field(:billing_owner_id, :string)
    field(:name, :string)
    field(:vm, :map)
    field(:vm_recreate_generation, :integer)
    field(:status, :string, default: "active")
    field(:lock_version, :integer, default: 1)
    # Synchronicity org + default network, filled in by convergence (the
    # control plane generates them), null until then.
    field(:sync_org_id, :string)
    field(:sync_network_id, :string)
    field(:wechat_connect_id, :string)
    field(:wechat_pending_connect_id, :string)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [
      :id,
      :owner_user_id,
      :salix_tenant_id,
      :salix_group_id,
      :group_generation,
      :salix_router_agent_id,
      :salix_worker_agent_id,
      :billing_owner_id,
      :name,
      :vm,
      :vm_recreate_generation,
      :status,
      :lock_version,
      :sync_org_id,
      :sync_network_id
    ])
    |> validate_required([
      :id,
      :owner_user_id,
      :salix_tenant_id,
      :salix_group_id,
      :group_generation,
      :salix_router_agent_id,
      :salix_worker_agent_id,
      :billing_owner_id,
      :status
    ])
    |> foreign_key_constraint(:owner_user_id)
    |> unique_constraint(:id, name: :comma_workspaces_pkey)
    |> unique_constraint(:salix_tenant_id)
    |> unique_constraint(:salix_group_id)
    |> validate_inclusion(:status, @persisted_statuses)
    |> check_constraint(:vm_recreate_generation,
      name: :comma_workspaces_vm_recreate_generation_check
    )
    |> check_constraint(:status, name: :comma_workspaces_status_check)
  end
end

defmodule Comma.Data.WorkspaceMembership do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "comma_workspace_memberships" do
    field(:workspace_id, :string)
    field(:user_id, :string)
    field(:role, :string)
    field(:status, :string, default: "active")
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:workspace_id, :user_id, :role, :status])
    |> validate_required([:workspace_id, :user_id, :role, :status])
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:workspace_id, :user_id])
    |> check_constraint(:role, name: :comma_workspace_memberships_role_check)
    |> check_constraint(:status, name: :comma_workspace_memberships_status_check)
  end
end

defmodule Comma.Data.Session do
  @moduledoc """
  Legacy product-state session snapshot.

  `comma_sessions` is historical migration/archive data and never authenticates a serving
  request. Live bearer authority is `Comma.Accounts.AuthSession`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "comma_sessions" do
    field(:token_hash, :binary)
    field(:user_id, :string)
    field(:expires_at, :utc_datetime_usec)
    field(:status, :string, default: "active")
    field(:restricted, :boolean, default: false)
    field(:workspace_id, :string)
    field(:conversation_id, :string)
    field(:interaction_budget_remaining, :integer)
    field(:tool_allowlist, {:array, :string}, default: [])
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :id,
      :token_hash,
      :user_id,
      :expires_at,
      :status,
      :restricted,
      :workspace_id,
      :conversation_id,
      :interaction_budget_remaining,
      :tool_allowlist
    ])
    |> validate_required([:id, :token_hash, :user_id, :expires_at, :status, :restricted])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:workspace_id)
    |> unique_constraint(:token_hash)
    |> check_constraint(:status, name: :comma_sessions_status_check)
    |> check_constraint(:interaction_budget_remaining, name: :comma_sessions_budget_check)
    |> check_constraint(:restricted, name: :comma_sessions_scope_check)
  end
end

defmodule Comma.Data.SessionBudgetConsumption do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "comma_session_budget_consumptions" do
    field(:session_id, :string, primary_key: true)
    field(:operation_id, :string, primary_key: true)
    field(:consumed_at, :utc_datetime_usec)
  end

  def changeset(consumption, attrs) do
    consumption
    |> cast(attrs, [:session_id, :operation_id, :consumed_at])
    |> validate_required([:session_id, :operation_id, :consumed_at])
    |> foreign_key_constraint(:session_id)
    |> unique_constraint([:session_id, :operation_id],
      name: :comma_session_budget_consumptions_pkey
    )
  end
end

defmodule Comma.Data.ExternalOperation do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:operation_id, :string, autogenerate: false}
  schema "comma_external_operations" do
    field(:operation_type, :string)
    field(:owner_type, :string)
    field(:owner_id, :string)
    field(:generation, :integer)
    field(:status, :string, default: "pending")
    field(:attempt, :integer, default: 0)
    field(:next_attempt_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)
    field(:last_error_class, :string)
    field(:external_idempotency_key, :string)
    field(:external_identity, :string)
    field(:metadata, :map, default: %{})
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(operation, attrs) do
    operation
    |> cast(attrs, [
      :operation_id,
      :operation_type,
      :owner_type,
      :owner_id,
      :generation,
      :status,
      :attempt,
      :next_attempt_at,
      :finished_at,
      :last_error_class,
      :external_idempotency_key,
      :external_identity,
      :metadata
    ])
    |> validate_required([
      :operation_id,
      :operation_type,
      :owner_type,
      :owner_id,
      :generation,
      :status,
      :attempt,
      :external_idempotency_key
    ])
    |> unique_constraint([:operation_type, :owner_type, :owner_id, :generation],
      name: :comma_operation_generation_idx
    )
    |> unique_constraint(:external_idempotency_key)
    |> check_constraint(:generation, name: :comma_external_operations_generation_check)
    |> check_constraint(:status, name: :comma_external_operations_status_check)
  end
end
