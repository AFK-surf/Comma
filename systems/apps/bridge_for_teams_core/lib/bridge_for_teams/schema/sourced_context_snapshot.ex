defmodule BridgeForTeams.Schema.SourcedContextSnapshot do
  @moduledoc "An immutable manifest for one complete normalized source snapshot."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "sourced_context_snapshots" do
    field(:normalization_revision, :string)
    field(:coverage_profile, :string)
    field(:manifest_sha256, :string)
    field(:object_count, :integer)
    field(:byte_count, :integer)
    field(:coverage, :map, default: %{})
    field(:started_at, :utc_datetime_usec)
    field(:finalized_at, :utc_datetime_usec)
    field(:created_at, :utc_datetime_usec)
    belongs_to(:run, BridgeForTeams.Schema.SlackHistoryImportRun)
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [
      :run_id,
      :normalization_revision,
      :coverage_profile,
      :manifest_sha256,
      :object_count,
      :byte_count,
      :coverage,
      :started_at,
      :finalized_at,
      :created_at
    ])
    |> validate_required([
      :run_id,
      :normalization_revision,
      :coverage_profile,
      :manifest_sha256,
      :object_count,
      :byte_count,
      :started_at,
      :finalized_at,
      :created_at
    ])
    |> validate_format(:manifest_sha256, ~r/\A[0-9a-f]{64}\z/)
    |> validate_number(:object_count, greater_than_or_equal_to: 0)
    |> validate_number(:byte_count, greater_than_or_equal_to: 0)
    |> unique_constraint(:run_id)
  end

  @type t :: %__MODULE__{}
end
