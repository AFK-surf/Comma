defmodule SalixStore.Repo.Migrations.IndexUndeliverableTaskLoops do
  @moduledoc """
  The Reconciler's sweep finds the Task Loops paused as `undeliverable` and
  runs each again once its Task has its Worker
  (`SalixAgent.Loops.recover_undeliverable_tasks/2`). It reads one page
  after a cursor each minute; this partial index keeps that read to the
  rows it wants.
  """
  use Ecto.Migration

  def change do
    create(
      index(:agent_loops, [:id],
        name: :agent_loops_undeliverable_task_idx,
        where:
          "status = 'paused' AND paused_by = 'undeliverable' AND task_conversation_id IS NOT NULL"
      )
    )
  end
end
