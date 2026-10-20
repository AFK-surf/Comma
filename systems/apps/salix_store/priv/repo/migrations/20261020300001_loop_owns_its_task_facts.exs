defmodule SalixStore.Repo.Migrations.LoopOwnsItsTaskFacts do
  @moduledoc """
  A Background Loop holds every fact of its work
  (docs/salix/tasks-background-execution.md, "Background loops"): its
  declared trigger, its limits, its runs and its end. A Loop Task only shows
  its Loop, so a Task's request is a `pending` Loop row until the Task's
  Worker binds a program: such a row has no Session and no program yet.

  The Loops of the earlier model, where a Task kept the request and a cron
  Schedule fired the Loop, are retired by product decision (Heyang Zhou,
  2026-10-20): every Loop that belongs to a Task and every Loop with a cron
  trigger is deleted with its acknowledgements, and so is every Schedule
  definition with receiver `loop`. Loops that belong to no Task and have no
  cron trigger are unchanged.

  Expand step: old runtimes ignore the new columns. The retired columns
  `cron_trigger`, `pending_task_report` and `task_request_id` stay until
  the contract step `20261020300002`.
  """
  use Ecto.Migration

  def up do
    execute("""
    DELETE FROM agent_loop_acks
    WHERE loop_id IN (
      SELECT id FROM agent_loops
      WHERE task_conversation_id IS NOT NULL OR cron_trigger IS NOT NULL
    )
    """)

    execute(
      "DELETE FROM agent_loops WHERE task_conversation_id IS NOT NULL OR cron_trigger IS NOT NULL"
    )

    execute("DELETE FROM schedules WHERE receiver = 'loop'")

    alter table(:agent_loops) do
      add(:trigger, :map)
      add(:max_runs, :integer)
      add(:ends_at, :bigint)
      add(:stop_condition, :text)
      add(:run_count, :integer, null: false, default: 0)
      add(:last_run_at, :bigint)
      add(:last_run_source, :text)
      add(:next_run_at, :bigint)
      add(:started_at, :bigint)
      add(:ended_at, :bigint)
      add(:ended_reason, :text)
      add(:task_settle_pending, :boolean, null: false, default: false)
      modify(:session_id, :text, null: true, from: {:text, null: false})
      modify(:elf_sha256, :text, null: true, from: {:text, null: false})
      modify(:elf_path, :text, null: true, from: {:text, null: false})
    end

    create(
      index(:agent_loops, [:ends_at, :id],
        name: :agent_loops_active_ends_at_idx,
        where: "status = 'active' AND ends_at IS NOT NULL"
      )
    )

    create(
      index(:agent_loops, [:id],
        name: :agent_loops_task_settle_pending_idx,
        where: "task_settle_pending"
      )
    )
  end

  def down do
    raise Ecto.MigrationError, "retired Loop Tasks and cron-triggered Loops are not restored"
  end
end
