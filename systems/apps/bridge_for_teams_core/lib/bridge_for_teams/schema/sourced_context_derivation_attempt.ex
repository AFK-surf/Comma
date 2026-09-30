defmodule BridgeForTeams.Schema.SourcedContextDerivationAttempt do
  @moduledoc "Durable retry and idempotency control for one versioned derivation request."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]

  schema "sourced_context_derivation_attempts" do
    field(:client_request_id, :string)
    field(:status, :string, default: "pending")
    field(:model_provider, :string)
    field(:model_id, :string)
    field(:model_revision, :string)
    field(:prompt_template_id, :string)
    field(:prompt_revision, :string)
    field(:policy_revision, :string)
    field(:schema_revision, :string)
    field(:processor_config, :map, default: %{})
    field(:processor_config_sha256, :string)
    field(:retry_count, :integer, default: 0)
    field(:retry_not_before, :utc_datetime_usec)
    field(:last_error_class, :string)
    field(:lease_generation, :integer, default: 0)
    field(:lease_owner, :string)
    field(:lease_expires_at, :utc_datetime_usec)
    belongs_to(:run, BridgeForTeams.Schema.SlackHistoryImportRun)
    belongs_to(:snapshot, BridgeForTeams.Schema.SourcedContextSnapshot)
    belongs_to(:parent_derivation, BridgeForTeams.Schema.SourcedContextDerivation)
    belongs_to(:requested_by_user, BridgeForTeams.Schema.User)
    timestamps()
  end

  def create_changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [
      :id,
      :run_id,
      :snapshot_id,
      :parent_derivation_id,
      :requested_by_user_id,
      :client_request_id,
      :status,
      :model_provider,
      :model_id,
      :model_revision,
      :prompt_template_id,
      :prompt_revision,
      :policy_revision,
      :schema_revision,
      :processor_config,
      :processor_config_sha256,
      :retry_count,
      :retry_not_before,
      :last_error_class,
      :lease_generation,
      :lease_owner,
      :lease_expires_at
    ])
    |> validate_required([
      :id,
      :run_id,
      :snapshot_id,
      :requested_by_user_id,
      :client_request_id,
      :status,
      :model_provider,
      :model_id,
      :model_revision,
      :prompt_template_id,
      :prompt_revision,
      :policy_revision,
      :schema_revision,
      :processor_config_sha256
    ])
    |> validate_common()
    |> unique_constraint([:run_id, :client_request_id],
      name: :sourced_context_derivation_attempts_request_idx
    )
  end

  def transition_changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [
      :status,
      :retry_count,
      :retry_not_before,
      :last_error_class,
      :lease_generation,
      :lease_owner,
      :lease_expires_at
    ])
    |> validate_required([:status, :retry_count, :lease_generation])
    |> validate_common()
  end

  defp validate_common(changeset) do
    changeset
    |> validate_inclusion(:status, [
      "pending",
      "processing",
      "paused",
      "completed",
      "failed_terminal"
    ])
    |> validate_format(:processor_config_sha256, ~r/\A[0-9a-f]{64}\z/)
    |> validate_number(:retry_count, greater_than_or_equal_to: 0)
    |> check_constraint(:client_request_id,
      name: :sourced_context_derivation_attempts_identity
    )
    |> check_constraint(:status, name: :sourced_context_derivation_attempts_status)
    |> check_constraint(:retry_count,
      name: :sourced_context_derivation_attempts_retry_count
    )
    |> check_constraint(:status, name: :sourced_context_derivation_attempts_lease)
  end

  @type t :: %__MODULE__{}
end
