defmodule BridgeForTeams.Schema.SourcedContextPublication do
  @moduledoc "The reversible audience edge for one reviewed context bundle."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]

  schema "sourced_context_publications" do
    field(:status, :string)
    field(:audience_scope, :string)
    field(:commit_command_id, :string)
    field(:activated_at, :utc_datetime_usec)
    field(:deactivated_at, :utc_datetime_usec)
    field(:deactivation_reason, :string)
    belongs_to(:run, BridgeForTeams.Schema.SlackHistoryImportRun)
    belongs_to(:bundle, BridgeForTeams.Schema.ContextBundle)
    belongs_to(:review_revision, BridgeForTeams.Schema.SourcedContextReviewRevision)
    belongs_to(:committed_by_user, BridgeForTeams.Schema.User)
    timestamps()
  end

  def active_changeset(publication, attrs) do
    publication
    |> cast(attrs, [
      :id,
      :run_id,
      :bundle_id,
      :review_revision_id,
      :status,
      :audience_scope,
      :committed_by_user_id,
      :commit_command_id,
      :activated_at
    ])
    |> validate_required([
      :id,
      :run_id,
      :bundle_id,
      :review_revision_id,
      :status,
      :audience_scope,
      :committed_by_user_id,
      :commit_command_id,
      :activated_at
    ])
    |> validate_inclusion(:status, ["active"])
    |> check_constraint(:status, name: :sourced_context_publications_status)
    |> unique_constraint(:run_id)
  end

  def deactivate_changeset(publication, attrs) do
    publication
    |> cast(attrs, [:status, :deactivated_at, :deactivation_reason])
    |> validate_required([:status, :deactivated_at, :deactivation_reason])
    |> validate_inclusion(:status, ["inactive"])
    |> check_constraint(:status, name: :sourced_context_publications_status)
  end

  @type t :: %__MODULE__{}
end
