defmodule BridgeForTeams.Repo.Migrations.CreateOnboardingAndAgentTasks do
  @moduledoc """
  The New Home dashboard data model: per-user onboarding state, per-user
  per-swarm assistant chat bindings, per-user per-org dashboard preferences,
  and the agent-task board rows. Every board task belongs to a project (the
  Agent Swarm whose agent works it) — `project_id` is NOT NULL by design, and
  provenance columns link agent-produced rows to the runtime objects behind
  them.
  """
  use Ecto.Migration

  @ts [type: :utc_datetime_usec, inserted_at: :created_at]

  def change do
    create table(:user_onboardings, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v7()")
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "in_progress"
      add :current_step, :string, null: false, default: "capabilities"
      add :capabilities, :map, null: false, default: %{}
      add :profile, :map, null: false, default: %{}
      add :completed_at, :utc_datetime_usec

      timestamps(@ts)
    end

    create unique_index(:user_onboardings, [:user_id])

    create table(:user_assistant_chats, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v7()")
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :org_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all)
      add :conversation_id, :string, null: false

      timestamps(@ts)
    end

    # One chat rail thread per user per swarm.
    create unique_index(:user_assistant_chats, [:user_id, :project_id])

    # Per-user, per-org dashboard state (distinct from the global one-shot
    # onboarding): the selected swarm and the widget-board layout.
    create table(:user_dashboard_prefs, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v7()")
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :org_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :selected_project_id, references(:projects, type: :binary_id, on_delete: :nilify_all)

      # Widget order per swarm: %{project_id => [category, ...]}.
      add :home_layout, :map, null: false, default: %{}

      timestamps(@ts)
    end

    create unique_index(:user_dashboard_prefs, [:user_id, :org_id])

    create table(:agent_tasks, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v7()")
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :org_id, references(:organizations, type: :binary_id, on_delete: :delete_all)

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :title, :string, null: false
      add :description, :text
      add :category, :string, null: false
      add :platform, :string, null: false, default: "comma"
      add :status, :string, null: false, default: "suggested"
      add :source, :string, null: false, default: "onboarding"
      add :payload, :map, null: false, default: %{}

      # Soft archive: the task leaves the board without losing the record.
      add :archived_at, :utc_datetime_usec

      # Provenance: the real runtime objects that produced (or are producing)
      # the row — the delegated Salix conversation and agent, the schedule
      # definition that fires it, and the workspace file holding the work
      # product. All nullable — a task without provenance is pre-delegation
      # onboarding intent.
      add :salix_conversation_id, :string
      add :salix_agent_id, :string
      add :salix_schedule_id, :string
      add :vfs_path, :string

      timestamps(@ts)
    end

    create index(:agent_tasks, [:user_id, :status])
    create index(:agent_tasks, [:user_id, :category])
    create index(:agent_tasks, [:user_id, :project_id])
    create index(:agent_tasks, [:org_id])
  end
end
