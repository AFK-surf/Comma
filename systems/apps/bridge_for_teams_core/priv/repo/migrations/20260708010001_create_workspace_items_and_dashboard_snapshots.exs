defmodule BridgeForTeams.Repo.Migrations.CreateWorkspaceItemsAndDashboardSnapshots do
  use Ecto.Migration

  @ts [type: :utc_datetime_usec, inserted_at: :created_at]

  def change do
    create table(:workspace_items, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v7()")
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :org_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :title, :text, null: false
      add :description, :text
      add :category, :string, null: false
      add :kind, :string, null: false
      add :platform, :string, null: false, default: "comma"
      add :status, :string, null: false
      add :activity_status, :string
      add :source, :string, null: false
      add :payload, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}
      add :source_refs, :map, null: false, default: %{}
      add :labels, {:array, :string}, null: false, default: []
      add :latest_artifact, :map
      add :artifact_manifest, :map
      add :archived_at, :utc_datetime_usec
      add :external_source, :string
      add :external_id, :string
      add :salix_conversation_id, :string
      add :salix_agent_id, :string
      add :salix_schedule_id, :string
      add :vfs_path, :string
      add :synced_at, :utc_datetime_usec

      timestamps(@ts)
    end

    create index(:workspace_items, [:user_id, :project_id, :category, :status, :updated_at],
             name: :workspace_items_user_project_category_status_updated_idx
           )

    create index(:workspace_items, [:user_id, :project_id, :updated_at],
             name: :workspace_items_user_project_updated_idx
           )

    create index(:workspace_items, [:project_id, :category, :updated_at],
             name: :workspace_items_project_category_updated_idx
           )

    create unique_index(:workspace_items, [:project_id, :user_id, :salix_conversation_id],
             where: "salix_conversation_id IS NOT NULL",
             name: :workspace_items_project_conversation_idx
           )

    create unique_index(:workspace_items, [:project_id, :user_id, :external_source, :external_id],
             where: "external_source IS NOT NULL AND external_id IS NOT NULL",
             name: :workspace_items_project_external_idx
           )

    create unique_index(:workspace_items, [:project_id, :user_id, :vfs_path],
             where: "vfs_path IS NOT NULL",
             name: :workspace_items_project_vfs_path_idx
           )

    create table(:project_dashboard_snapshots, primary_key: false) do
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :org_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :conversation_count, :integer, null: false, default: 0
      add :recent_conversations, {:array, :map}, null: false, default: []
      add :token_input, :bigint, null: false, default: 0
      add :token_output, :bigint, null: false, default: 0
      add :token_cache_read, :bigint, null: false, default: 0
      add :token_cache_write, :bigint, null: false, default: 0
      add :token_total, :bigint, null: false, default: 0
      add :connected_providers, {:array, :string}, null: false, default: []
      add :meeting_count, :integer, null: false, default: 0
      add :latest_meeting_at, :utc_datetime_usec
      add :refreshed_at, :utc_datetime_usec
      add :stale_at, :utc_datetime_usec
      add :refreshing_at, :utc_datetime_usec
      add :refresh_error, :text

      timestamps(@ts)
    end

    create index(:project_dashboard_snapshots, [:org_id, :refreshed_at],
             name: :project_dashboard_snapshots_org_refreshed_idx
           )

    create index(:project_dashboard_snapshots, [:stale_at],
             where: "stale_at IS NOT NULL",
             name: :project_dashboard_snapshots_stale_idx
           )
  end
end
