defmodule BridgeForTeams.Repo.Migrations.MultiSwarmDailyBrief do
  use Ecto.Migration

  # Each Agent Swarm of an organization keeps its own daily brief settings
  # (one row per Swarm, not per organization).
  #
  # A member stays one row per organization and provider. It names the Swarm
  # whose bot sends its personal brief (`project_id`), and keeps its Feishu or
  # Lark open id in every app it was linked through (`app_open_ids`, by app
  # id): an open id is scoped to its app.
  #
  # Existing members are sent by their organization's first settings of the
  # same provider, which is the only one so far, and keep their one open id.
  def up do
    drop unique_index(:daily_brief_settings, [:org_id])
    create unique_index(:daily_brief_settings, [:org_id, :project_id])

    alter table(:daily_brief_members) do
      add :project_id, references(:projects, type: :binary_id, on_delete: :nilify_all)
      add :app_open_ids, :map, null: false, default: %{}
    end

    create index(:daily_brief_members, [:org_id, :project_id])

    execute """
    UPDATE daily_brief_members m
    SET project_id = (
      SELECT s.project_id FROM daily_brief_settings s
      WHERE s.org_id = m.org_id AND s.provider = m.provider
      ORDER BY s.created_at ASC, s.id ASC
      LIMIT 1
    )
    WHERE m.project_id IS NULL
    """

    execute """
    UPDATE daily_brief_members
    SET app_open_ids = jsonb_build_object(app_id, open_id)
    WHERE provider IN ('feishu', 'lark') AND app_id IS NOT NULL AND open_id IS NOT NULL
      AND app_open_ids = '{}'::jsonb
    """
  end

  def down do
    drop index(:daily_brief_members, [:org_id, :project_id])

    alter table(:daily_brief_members) do
      remove :app_open_ids
      remove :project_id
    end

    # Only the organization's first settings stay.
    execute """
    DELETE FROM daily_brief_settings s
    WHERE EXISTS (
      SELECT 1 FROM daily_brief_settings o
      WHERE o.org_id = s.org_id AND (o.created_at, o.id) < (s.created_at, s.id)
    )
    """

    drop unique_index(:daily_brief_settings, [:org_id, :project_id])
    create unique_index(:daily_brief_settings, [:org_id])
  end
end
