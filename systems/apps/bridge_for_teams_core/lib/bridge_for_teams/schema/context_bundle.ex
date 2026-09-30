defmodule BridgeForTeams.Schema.ContextBundle do
  @moduledoc "A source-neutral, product-owned context bundle registered for shared lifecycle."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]

  @lifecycle_states ~w(registered erasure_pending deletion_pending deleted failed)
  @subject_index_states ~w(pending complete failed)

  schema "context_bundles" do
    field(:source_type, :string)
    field(:source_ref, :string)
    field(:classification, :string)
    field(:policy_ref, :string)
    field(:lifecycle_state, :string, default: "registered")
    field(:subject_index_state, :string, default: "pending")
    field(:lifecycle_revision, :integer, default: 0)
    field(:last_error, :string)

    belongs_to(:org, BridgeForTeams.Schema.Organization)
    belongs_to(:project, BridgeForTeams.Schema.Project)

    has_many(:subjects, BridgeForTeams.Schema.ContextBundleSubject, foreign_key: :bundle_id)

    has_many(:lifecycle_requests, BridgeForTeams.Schema.ContextLifecycleRequest,
      foreign_key: :bundle_id
    )

    has_many(:lifecycle_evidence, BridgeForTeams.Schema.ContextLifecycleEvidence,
      foreign_key: :bundle_id
    )

    timestamps()
  end

  @spec registration_changeset(t(), map()) :: Ecto.Changeset.t()
  def registration_changeset(bundle, attrs) do
    bundle
    |> cast(attrs, [
      :org_id,
      :project_id,
      :source_type,
      :source_ref,
      :classification,
      :policy_ref
    ])
    |> validate_required([:org_id, :source_type, :source_ref, :classification, :policy_ref])
    |> validate_length(:source_type, max: 64)
    |> validate_length(:source_ref, max: 1_024)
    |> validate_length(:classification, max: 64)
    |> validate_length(:policy_ref, max: 256)
    |> check_constraint(:source_type, name: :context_bundles_nonempty_identity)
    |> unique_constraint([:org_id, :source_type, :source_ref],
      name: :context_bundles_source_identity_idx
    )
  end

  @spec lifecycle_changeset(t(), map()) :: Ecto.Changeset.t()
  def lifecycle_changeset(bundle, attrs) do
    bundle
    |> cast(attrs, [
      :lifecycle_state,
      :subject_index_state,
      :lifecycle_revision,
      :last_error
    ])
    |> validate_required([:lifecycle_state, :subject_index_state, :lifecycle_revision])
    |> validate_inclusion(:lifecycle_state, @lifecycle_states)
    |> validate_inclusion(:subject_index_state, @subject_index_states)
    |> validate_number(:lifecycle_revision, greater_than_or_equal_to: 0)
    |> check_constraint(:lifecycle_state, name: :context_bundles_lifecycle_state)
    |> check_constraint(:subject_index_state, name: :context_bundles_subject_index_state)
    |> check_constraint(:lifecycle_revision, name: :context_bundles_lifecycle_revision)
  end

  @type t :: %__MODULE__{}
end
