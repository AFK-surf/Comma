defmodule SalixStore.Repo.Migrations.CreateSchedules do
  use Ecto.Migration

  # Schedule definitions and run claims move from S3 to Postgres
  # (docs/salix/control-metadata-postgres.md). One `schedules` row per retired
  # `ctl/schedules/{id}.json` object; known fields are flat columns and every
  # other historical body key round-trips through the `attrs` jsonb so the two
  # legacy writer schemas (SalixCluster.Schedules and the SalixAgent.Schedules
  # heartbeat records) import without loss. Timestamps stay unix-ms integers
  # exactly as the legacy bodies carried them.
  #
  # `next_fire_at` is a lower-bound index column, not an authority: the sweep
  # SELECTs candidates through it and re-derives the exact next fire from the
  # recurrence fields (see SalixStore.Schedules). `status` becomes a real
  # column so pause finally gates firing (the S3 scanner never read it).
  #
  # `schedule_runs` is the PG image of the retired create-once run-claim
  # objects (`ctl/schedule_runs/{id}/{iso}.json`): the composite primary key IS
  # the claim (INSERT ... ON CONFLICT DO NOTHING), and `inserted_at` backs the
  # retention prune the S3 prefix never had.
  def change do
    create table(:schedules, primary_key: false) do
      add :id, :text, primary_key: true
      add :receiver, :text, null: false, default: "agent"
      add :agent_id, :text
      add :session_id, :text
      add :prompt, :text
      add :payload, :map
      add :interval_minutes, :bigint
      add :cron, :text
      add :timezone, :text
      add :run_at, :bigint
      add :status, :text, null: false, default: "active"
      add :kind, :text
      add :name, :text
      add :attrs, :map, null: false, default: %{}
      add :created_at, :bigint, null: false
      add :updated_at, :bigint
      add :last_run, :bigint
      add :next_fire_at, :bigint, null: false
    end

    # Matches the sweep predicate exactly (next_fire_at <= now AND status <>
    # 'paused') so the due scan never touches not-yet-due or paused rows.
    create index(:schedules, [:next_fire_at],
             where: "status <> 'paused'",
             name: :schedules_due_idx
           )

    create index(:schedules, [:agent_id])

    # The Task-owner disjunct of the owner-filtered listing
    # (`receiver = 'task' AND payload->>'agent_group_id' = $group`): a partial
    # expression index so the OR resolves as a BitmapOr over this and the
    # agent_id index — never a sequential scan proportional to the global
    # table. The predicate matches the query's disjunct exactly.
    execute(
      """
      CREATE INDEX schedules_task_group_idx
      ON schedules ((payload ->> 'agent_group_id'))
      WHERE receiver = 'task'
      """,
      "DROP INDEX schedules_task_group_idx"
    )

    create table(:schedule_runs, primary_key: false) do
      add :schedule_id, :text, primary_key: true
      add :scheduled_for_ms, :bigint, primary_key: true
      add :disposition, :text, null: false, default: "dispatch"
      add :receiver, :text
      add :agent_id, :text
      add :agent_group_id, :text
      add :conversation_id, :text
      add :node, :text
      add :fired_at, :bigint
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:schedule_runs, [:inserted_at])
  end
end
