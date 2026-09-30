defmodule Comma.Admin.AuditEvent do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @actions ~w(
    update_model_selection_policy
    update_free_router_models
    create_user
    update_user
    set_admin_access
    create_support_session
    bootstrap_workspace
    update_workspace_vm
    revoke_user_session
    revoke_all_user_sessions
    create_redeem_code
    disable_redeem_code
    apply_redeem_code
    issue_workspace_credits
    create_oauth_client
    rotate_oauth_client_secret
    disable_oauth_client
    enable_oauth_client
    retry_agent_vmm_install
    enable_agent_vmm_registration
    disable_agent_vmm_registration
    revoke_agent_vmm_registration
    drain_compute_environment
    revoke_compute_environment
    create_shell_workload
    update_workspace_agent_model
  )

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [
    type: :utc_datetime_usec,
    inserted_at: :created_at,
    inserted_at_source: :inserted_at
  ]

  schema "comma_admin_audit_events" do
    field(:actor_key, :string)
    field(:actor_type, :string)
    field(:actor_user_id, :string)
    field(:action, :string)
    field(:target_type, :string)
    field(:target_id, :string)
    field(:reason, :string)
    field(:idempotency_key, :string)
    field(:request_fingerprint, :binary)
    field(:outcome, :string)
    field(:error_code, :string)
    field(:evidence, :map, default: %{})
    field(:lease_expires_at, :utc_datetime_usec)

    timestamps()
  end

  def actions, do: @actions

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :actor_key,
      :actor_type,
      :actor_user_id,
      :action,
      :target_type,
      :target_id,
      :reason,
      :idempotency_key,
      :request_fingerprint,
      :outcome,
      :error_code,
      :evidence,
      :lease_expires_at
    ])
    |> validate_required([
      :actor_key,
      :actor_type,
      :action,
      :target_type,
      :target_id,
      :reason,
      :idempotency_key,
      :request_fingerprint,
      :outcome,
      :evidence
    ])
    |> validate_inclusion(:actor_type, ["comma_user", "ops"])
    |> validate_inclusion(:action, @actions)
    |> validate_inclusion(:outcome, ["started", "succeeded", "failed", "rejected"])
    |> validate_lease()
    |> validate_length(:target_type, min: 1, max: 100)
    |> validate_length(:target_id, min: 1, max: 320)
    |> validate_length(:reason, min: 3, max: 500)
    |> validate_length(:idempotency_key, min: 8, max: 200)
    |> validate_length(:error_code, max: 100)
    |> validate_actor()
    |> unique_constraint([:actor_key, :action, :idempotency_key],
      name: :comma_admin_audit_events_actor_action_idempotency_unique
    )
    |> check_constraint(:actor_type, name: :comma_admin_audit_actor_valid)
    |> check_constraint(:action, name: :comma_admin_audit_action_valid)
    |> check_constraint(:outcome, name: :comma_admin_audit_outcome_valid)
    |> check_constraint(:reason, name: :comma_admin_audit_reason_valid)
    |> check_constraint(:idempotency_key, name: :comma_admin_audit_idempotency_key_valid)
    |> check_constraint(:request_fingerprint,
      name: :comma_admin_audit_request_fingerprint_valid
    )
  end

  defp validate_lease(changeset) do
    case {get_field(changeset, :outcome), get_field(changeset, :lease_expires_at)} do
      {"started", %DateTime{}} -> changeset
      {outcome, nil} when outcome in ["succeeded", "failed", "rejected"] -> changeset
      _ -> add_error(changeset, :lease_expires_at, "does not match outcome")
    end
  end

  defp validate_actor(changeset) do
    case {
      get_field(changeset, :actor_type),
      get_field(changeset, :actor_key),
      get_field(changeset, :actor_user_id)
    } do
      {"ops", "ops", nil} ->
        changeset

      {"comma_user", actor_user_id, actor_user_id}
      when is_binary(actor_user_id) and actor_user_id != "" ->
        changeset

      _ ->
        add_error(changeset, :actor_key, "does not match actor identity")
    end
  end
end
