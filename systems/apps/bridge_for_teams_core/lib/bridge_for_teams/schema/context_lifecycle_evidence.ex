defmodule BridgeForTeams.Schema.ContextLifecycleEvidence do
  @moduledoc "Content-free evidence that a shared lifecycle purge completed."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "context_lifecycle_evidence" do
    field(:source_type, :string)
    field(:purger, :string)
    field(:counts, :map, default: %{})
    field(:counts_sha256, :string)
    field(:completed_at, :utc_datetime_usec)
    field(:created_at, :utc_datetime_usec)

    belongs_to(:request, BridgeForTeams.Schema.ContextLifecycleRequest)
    belongs_to(:bundle, BridgeForTeams.Schema.ContextBundle)
  end

  def changeset(evidence, attrs) do
    evidence
    |> cast(attrs, [
      :request_id,
      :bundle_id,
      :source_type,
      :purger,
      :counts,
      :counts_sha256,
      :completed_at,
      :created_at
    ])
    |> validate_required([
      :request_id,
      :bundle_id,
      :source_type,
      :purger,
      :counts,
      :counts_sha256,
      :completed_at,
      :created_at
    ])
    |> validate_length(:source_type, min: 1, max: 64)
    |> validate_length(:purger, min: 1, max: 256)
    |> validate_format(:counts_sha256, ~r/^[0-9a-f]{64}$/)
    |> check_constraint(:source_type, name: :context_lifecycle_evidence_identity)
    |> unique_constraint(:request_id)
  end

  @type t :: %__MODULE__{}
end
