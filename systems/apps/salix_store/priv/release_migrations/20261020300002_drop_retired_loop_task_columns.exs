defmodule SalixStore.Repo.Migrations.DropRetiredLoopTaskColumns do
  @moduledoc """
  Retire `agent_loops.cron_trigger`, `agent_loops.pending_task_report` and
  `agent_loops.task_request_id`. A Loop's trigger and limits are its own
  columns since `20261020300001`, which cleared every row that used these
  columns, and no runtime after that release reads or writes them.

  Before a contract operation selects this step, the operator confirms that
  every running instance of the environment is on a release with
  `20261020300001`. `down` adds the columns again, empty.
  """
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("DROP INDEX IF EXISTS agent_loops_pending_task_report_idx")

    alter table(:agent_loops) do
      remove_if_exists(:cron_trigger)
      remove_if_exists(:pending_task_report)
      remove_if_exists(:task_request_id)
    end
  end

  def down do
    alter table(:agent_loops) do
      add(:cron_trigger, :map)
      add(:pending_task_report, :map)
      add(:task_request_id, :string)
    end
  end
end
