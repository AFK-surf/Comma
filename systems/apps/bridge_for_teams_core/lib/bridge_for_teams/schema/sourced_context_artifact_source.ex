defmodule BridgeForTeams.Schema.SourcedContextArtifactSource do
  @moduledoc "Immutable provenance membership from an artifact to one source object."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "sourced_context_artifact_sources" do
    belongs_to(:artifact, BridgeForTeams.Schema.SourcedContextArtifact)
    belongs_to(:source_object, BridgeForTeams.Schema.SourcedContextObject)
    field(:created_at, :utc_datetime_usec)
  end

  def changeset(source, attrs) do
    source
    |> cast(attrs, [:artifact_id, :source_object_id, :created_at])
    |> validate_required([:artifact_id, :source_object_id, :created_at])
    |> unique_constraint([:artifact_id, :source_object_id],
      name: :sourced_context_artifact_sources_identity_idx
    )
  end

  @type t :: %__MODULE__{}
end
