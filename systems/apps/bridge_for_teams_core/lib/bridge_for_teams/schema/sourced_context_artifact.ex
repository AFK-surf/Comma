defmodule BridgeForTeams.Schema.SourcedContextArtifact do
  @moduledoc "One immutable encrypted People, Project, Decision, or context candidate."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "sourced_context_artifacts" do
    field(:kind, :string)
    field(:stable_key, :string)
    field(:payload_ciphertext, :string)
    field(:payload_sha256, :string)
    field(:confidence_millis, :integer)
    belongs_to(:derivation, BridgeForTeams.Schema.SourcedContextDerivation)
    belongs_to(:mapped_user, BridgeForTeams.Schema.User)
    belongs_to(:mapped_project, BridgeForTeams.Schema.Project)
    field(:created_at, :utc_datetime_usec)

    has_many(:sources, BridgeForTeams.Schema.SourcedContextArtifactSource,
      foreign_key: :artifact_id
    )
  end

  def changeset(artifact, attrs) do
    artifact
    |> cast(attrs, [
      :derivation_id,
      :kind,
      :stable_key,
      :payload_ciphertext,
      :payload_sha256,
      :confidence_millis,
      :mapped_user_id,
      :mapped_project_id,
      :created_at
    ])
    |> validate_required([
      :derivation_id,
      :kind,
      :stable_key,
      :payload_ciphertext,
      :payload_sha256,
      :confidence_millis,
      :created_at
    ])
    |> validate_inclusion(:kind, ["person", "project", "decision", "context"])
    |> validate_format(:payload_sha256, ~r/\A[0-9a-f]{64}\z/)
    |> validate_number(:confidence_millis,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 1000
    )
    |> unique_constraint([:derivation_id, :kind, :stable_key],
      name: :sourced_context_artifacts_identity_idx
    )
  end

  @type t :: %__MODULE__{}
end
