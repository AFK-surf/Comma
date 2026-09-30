defmodule Comma.Repo.Migrations.AddCommaRecommendations do
  use Ecto.Migration

  def change do
    create table(:comma_recommendation_profiles, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:workspace_id, references(:comma_workspaces, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:user_id, references(:comma_users, type: :string, on_delete: :delete_all), null: false)
      add(:schedule_enabled, :boolean, null: false, default: true)
      add(:schedule_hour, :integer, null: false, default: 8)
      add(:schedule_minute, :integer, null: false, default: 0)
      add(:timezone, :string, null: false, default: "Etc/UTC")
      add(:auto_enable_new_sources, :boolean, null: false, default: true)
      add(:agent_id, :string)
      add(:session_id, :string)
      add(:schedule_id, :string)
      add(:sources, :map, null: false, default: fragment("'[]'::jsonb"))
      add(:sources_checked_at, :utc_datetime_usec)
      add(:source_revision, :bigint, null: false, default: 0)
      add(:requested_generation, :bigint, null: false, default: 0)
      add(:published_generation, :bigint, null: false, default: 0)
      add(:snapshot, :map)
      add(:snapshot_source_revision, :bigint)
      add(:last_error, :string)
      add(:last_requested_at, :utc_datetime_usec)
      add(:last_published_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:comma_recommendation_profiles, [:workspace_id, :user_id]))
    create(unique_index(:comma_recommendation_profiles, [:agent_id], where: "agent_id IS NOT NULL"))

    create(
      unique_index(:comma_recommendation_profiles, [:schedule_id], where: "schedule_id IS NOT NULL")
    )

    create(
      constraint(:comma_recommendation_profiles, :comma_recommendation_profiles_schedule_check,
        check: "schedule_hour BETWEEN 0 AND 23 AND schedule_minute BETWEEN 0 AND 59"
      )
    )

    create(
      constraint(:comma_recommendation_profiles, :comma_recommendation_profiles_generation_check,
        check: "published_generation <= requested_generation AND source_revision >= 0"
      )
    )

    create table(:comma_recommendation_runs, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :profile_id,
        references(:comma_recommendation_profiles, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:generation, :bigint, null: false)
      add(:source_revision, :bigint, null: false)
      add(:source_message_id, :string)
      add(:trigger, :string, null: false)
      add(:status, :string, null: false, default: "pending")
      add(:error, :string)
      add(:finished_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:comma_recommendation_runs, [:profile_id, :generation]))

    create(
      unique_index(:comma_recommendation_runs, [:profile_id, :source_message_id],
        where: "source_message_id IS NOT NULL"
      )
    )

    create(index(:comma_recommendation_runs, [:profile_id, :inserted_at]))

    create(
      constraint(:comma_recommendation_runs, :comma_recommendation_runs_trigger_check,
        check: "trigger IN ('manual', 'schedule', 'agent_tool')"
      )
    )

    create(
      constraint(:comma_recommendation_runs, :comma_recommendation_runs_status_check,
        check: "status IN ('pending', 'running', 'published', 'superseded', 'failed')"
      )
    )
  end
end
