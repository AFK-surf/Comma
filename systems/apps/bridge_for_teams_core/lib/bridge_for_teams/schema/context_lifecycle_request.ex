defmodule BridgeForTeams.Schema.ContextLifecycleRequest do
  @moduledoc "A durable, source-neutral request to erase or delete a context bundle."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]

  @states ~w(pending processing retry_wait completed canceled failed_terminal)
  @kinds ~w(deletion erasure)
  @request_reason_codes ~w(user_request retention_expired organization_request legal_requirement administrative_cleanup)
  @restore_reason_codes ~w(request_submitted_in_error legal_hold administrative_override)
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i

  schema "context_lifecycle_requests" do
    field(:command_id, :string)
    field(:kind, :string)
    field(:reason, :string)
    field(:state, :string, default: "pending")
    field(:base_revision, :integer)
    field(:retry_count, :integer, default: 0)
    field(:retry_not_before, :utc_datetime_usec)
    field(:last_error_class, :string)
    field(:lease_generation, :integer, default: 0)
    field(:lease_owner, :string)
    field(:lease_expires_at, :utc_datetime_usec)
    field(:cancel_command_id, :string)
    field(:cancel_reason, :string)
    field(:canceled_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)

    belongs_to(:bundle, BridgeForTeams.Schema.ContextBundle)
    belongs_to(:requested_by_user, BridgeForTeams.Schema.User)
    belongs_to(:canceled_by_user, BridgeForTeams.Schema.User)

    timestamps()
  end

  def create_changeset(request, attrs) do
    request
    |> cast(attrs, [
      :bundle_id,
      :requested_by_user_id,
      :command_id,
      :kind,
      :reason,
      :state,
      :base_revision,
      :retry_count,
      :lease_generation
    ])
    |> validate_required([
      :bundle_id,
      :requested_by_user_id,
      :command_id,
      :kind,
      :reason,
      :state,
      :base_revision,
      :retry_count,
      :lease_generation
    ])
    |> shared_validations()
    |> unique_constraint([:bundle_id, :command_id],
      name: :context_lifecycle_requests_command_idx
    )
    |> unique_constraint(:bundle_id, name: :context_lifecycle_requests_one_active_idx)
  end

  def transition_changeset(request, attrs) do
    request
    |> cast(attrs, [
      :state,
      :retry_count,
      :retry_not_before,
      :last_error_class,
      :lease_generation,
      :lease_owner,
      :lease_expires_at,
      :cancel_command_id,
      :canceled_by_user_id,
      :cancel_reason,
      :canceled_at,
      :completed_at
    ])
    |> validate_required([:state, :retry_count, :lease_generation])
    |> shared_validations()
    |> unique_constraint([:bundle_id, :cancel_command_id],
      name: :context_lifecycle_requests_cancel_command_idx
    )
    |> unique_constraint(:bundle_id, name: :context_lifecycle_requests_one_active_idx)
  end

  defp shared_validations(changeset) do
    changeset
    |> validate_inclusion(:state, @states)
    |> validate_inclusion(:kind, @kinds)
    |> validate_format(:command_id, @uuid)
    |> validate_inclusion(:reason, @request_reason_codes)
    |> validate_format(:cancel_command_id, @uuid)
    |> validate_inclusion(:cancel_reason, @restore_reason_codes)
    |> validate_length(:lease_owner, min: 1, max: 256)
    |> validate_number(:base_revision, greater_than_or_equal_to: 0)
    |> validate_number(:retry_count, greater_than_or_equal_to: 0)
    |> validate_number(:lease_generation, greater_than_or_equal_to: 0)
    |> check_constraint(:command_id, name: :context_lifecycle_requests_identity)
    |> check_constraint(:kind, name: :context_lifecycle_requests_kind)
    |> check_constraint(:state, name: :context_lifecycle_requests_state)
    |> check_constraint(:base_revision, name: :context_lifecycle_requests_counters)
    |> check_constraint(:state, name: :context_lifecycle_requests_lease)
    |> check_constraint(:state, name: :context_lifecycle_requests_completion)
    |> check_constraint(:state, name: :context_lifecycle_requests_cancellation)
  end

  @type t :: %__MODULE__{}
end
