defmodule BridgeForTeams.Schema.ProjectDashboardSnapshot do
  @moduledoc """
  Rebuildable project-level dashboard projection read by the org Overview and
  Agent Swarm overview.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]

  schema "project_dashboard_snapshots" do
    belongs_to :project, BridgeForTeams.Schema.Project, primary_key: true
    belongs_to :org, BridgeForTeams.Schema.Organization

    field :conversation_count, :integer, default: 0
    field :recent_conversations, {:array, :map}, default: []
    field :token_input, :integer, default: 0
    field :token_output, :integer, default: 0
    field :token_cache_read, :integer, default: 0
    field :token_cache_write, :integer, default: 0
    field :token_total, :integer, default: 0
    field :connected_providers, {:array, :string}, default: []
    field :meeting_count, :integer, default: 0
    field :latest_meeting_at, :utc_datetime_usec
    field :refreshed_at, :utc_datetime_usec
    field :stale_at, :utc_datetime_usec
    field :refreshing_at, :utc_datetime_usec
    field :refresh_error, :string
    field :refresh_generation, :integer, default: 0

    timestamps()
  end

  @fields [
    :project_id,
    :org_id,
    :conversation_count,
    :recent_conversations,
    :token_input,
    :token_output,
    :token_cache_read,
    :token_cache_write,
    :token_total,
    :connected_providers,
    :meeting_count,
    :latest_meeting_at,
    :refreshed_at,
    :stale_at,
    :refreshing_at,
    :refresh_error,
    :refresh_generation
  ]

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, @fields)
    |> validate_required([:project_id, :org_id])
  end
end
