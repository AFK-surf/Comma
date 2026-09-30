defmodule BridgeForTeams.Schema.SourcedContextDerivation do
  @moduledoc "One immutable, versioned interpretation of a frozen source snapshot."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "sourced_context_derivations" do
    field(:model_provider, :string)
    field(:model_id, :string)
    field(:model_revision, :string)
    field(:prompt_template_id, :string)
    field(:prompt_revision, :string)
    field(:policy_revision, :string)
    field(:schema_revision, :string)
    field(:processor_config, :map, default: %{})
    field(:output_sha256, :string)
    field(:artifact_count, :integer)
    field(:warnings, :map, default: %{})
    field(:created_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)
    belongs_to(:run, BridgeForTeams.Schema.SlackHistoryImportRun)
    belongs_to(:snapshot, BridgeForTeams.Schema.SourcedContextSnapshot)
    belongs_to(:parent_derivation, __MODULE__)

    has_many(:artifacts, BridgeForTeams.Schema.SourcedContextArtifact,
      foreign_key: :derivation_id
    )
  end

  def changeset(derivation, attrs) do
    derivation
    |> cast(attrs, [
      :run_id,
      :snapshot_id,
      :parent_derivation_id,
      :model_provider,
      :model_id,
      :model_revision,
      :prompt_template_id,
      :prompt_revision,
      :policy_revision,
      :schema_revision,
      :processor_config,
      :output_sha256,
      :artifact_count,
      :warnings,
      :created_at,
      :completed_at
    ])
    |> validate_required([
      :run_id,
      :snapshot_id,
      :model_provider,
      :model_id,
      :model_revision,
      :prompt_template_id,
      :prompt_revision,
      :policy_revision,
      :schema_revision,
      :output_sha256,
      :artifact_count,
      :created_at,
      :completed_at
    ])
    |> validate_format(:output_sha256, ~r/\A[0-9a-f]{64}\z/)
    |> validate_number(:artifact_count, greater_than_or_equal_to: 0)
    |> unique_constraint(:snapshot_id, name: :sourced_context_derivations_evidence_idx)
  end

  @type t :: %__MODULE__{}
end
