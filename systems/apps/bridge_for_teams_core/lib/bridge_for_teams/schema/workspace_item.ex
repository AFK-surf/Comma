defmodule BridgeForTeams.Schema.WorkspaceItem do
  @moduledoc """
  Bridge-owned local product row for the My Space workspace board.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]

  schema "workspace_items" do
    belongs_to :user, BridgeForTeams.Schema.User
    belongs_to :org, BridgeForTeams.Schema.Organization
    belongs_to :project, BridgeForTeams.Schema.Project

    field :title, :string
    field :description, :string
    field :category, :string
    field :kind, :string
    field :platform, :string, default: "comma"
    field :status, :string
    field :activity_status, :string
    field :source, :string
    field :payload, :map, default: %{}
    field :metadata, :map, default: %{}
    field :source_refs, :map, default: %{}
    field :labels, {:array, :string}, default: []
    field :latest_artifact, :map
    field :artifact_manifest, :map
    field :archived_at, :utc_datetime_usec
    field :external_source, :string
    field :external_id, :string
    field :salix_conversation_id, :string
    field :salix_agent_id, :string
    field :salix_schedule_id, :string
    field :vfs_path, :string
    field :synced_at, :utc_datetime_usec

    timestamps()
  end

  @fields [
    :user_id,
    :org_id,
    :project_id,
    :title,
    :description,
    :category,
    :kind,
    :platform,
    :status,
    :activity_status,
    :source,
    :payload,
    :metadata,
    :source_refs,
    :labels,
    :latest_artifact,
    :artifact_manifest,
    :archived_at,
    :external_source,
    :external_id,
    :salix_conversation_id,
    :salix_agent_id,
    :salix_schedule_id,
    :vfs_path,
    :synced_at
  ]

  def changeset(item, attrs) do
    item
    |> cast(attrs, @fields)
    |> validate_required([
      :user_id,
      :org_id,
      :project_id,
      :title,
      :category,
      :kind,
      :platform,
      :status,
      :source
    ])
    |> unique_constraint(:salix_conversation_id, name: :workspace_items_project_conversation_idx)
    |> unique_constraint(:external_id, name: :workspace_items_project_external_idx)
    |> unique_constraint(:vfs_path, name: :workspace_items_project_user_vfs_path_uniq)
  end
end
