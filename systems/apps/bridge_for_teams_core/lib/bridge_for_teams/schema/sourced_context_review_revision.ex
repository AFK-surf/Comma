defmodule BridgeForTeams.Schema.SourcedContextReviewRevision do
  @moduledoc "An immutable exact user review over one derivation."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "sourced_context_review_revisions" do
    field(:revision, :integer)
    field(:selection_sha256, :string)
    field(:selected_count, :integer)
    field(:created_at, :utc_datetime_usec)
    belongs_to(:run, BridgeForTeams.Schema.SlackHistoryImportRun)
    belongs_to(:snapshot, BridgeForTeams.Schema.SourcedContextSnapshot)
    belongs_to(:derivation, BridgeForTeams.Schema.SourcedContextDerivation)
    belongs_to(:parent_revision, __MODULE__)
    belongs_to(:created_by_user, BridgeForTeams.Schema.User)

    has_many(:items, BridgeForTeams.Schema.SourcedContextReviewItem,
      foreign_key: :review_revision_id
    )
  end

  def changeset(review, attrs) do
    review
    |> cast(attrs, [
      :run_id,
      :snapshot_id,
      :derivation_id,
      :parent_revision_id,
      :revision,
      :created_by_user_id,
      :selection_sha256,
      :selected_count,
      :created_at
    ])
    |> validate_required([
      :run_id,
      :snapshot_id,
      :derivation_id,
      :revision,
      :created_by_user_id,
      :selection_sha256,
      :selected_count,
      :created_at
    ])
    |> validate_format(:selection_sha256, ~r/\A[0-9a-f]{64}\z/)
    |> validate_number(:revision, greater_than: 0)
    |> validate_number(:selected_count, greater_than_or_equal_to: 0)
    |> unique_constraint([:run_id, :revision],
      name: :sourced_context_review_revisions_number_idx
    )
  end

  @type t :: %__MODULE__{}
end
