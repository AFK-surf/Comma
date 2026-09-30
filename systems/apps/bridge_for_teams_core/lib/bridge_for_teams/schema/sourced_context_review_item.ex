defmodule BridgeForTeams.Schema.SourcedContextReviewItem do
  @moduledoc "One immutable selected or user-edited artifact in an exact review revision."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "sourced_context_review_items" do
    field(:kind, :string)
    field(:payload_ciphertext, :string)
    field(:payload_sha256, :string)
    field(:created_at, :utc_datetime_usec)
    belongs_to(:review_revision, BridgeForTeams.Schema.SourcedContextReviewRevision)
    belongs_to(:artifact, BridgeForTeams.Schema.SourcedContextArtifact)
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :review_revision_id,
      :artifact_id,
      :kind,
      :payload_ciphertext,
      :payload_sha256,
      :created_at
    ])
    |> validate_required([
      :review_revision_id,
      :artifact_id,
      :kind,
      :payload_ciphertext,
      :payload_sha256,
      :created_at
    ])
    |> validate_inclusion(:kind, ["person", "project", "decision", "context"])
    |> validate_format(:payload_sha256, ~r/\A[0-9a-f]{64}\z/)
    |> unique_constraint([:review_revision_id, :artifact_id],
      name: :sourced_context_review_items_identity_idx
    )
  end

  @type t :: %__MODULE__{}
end
