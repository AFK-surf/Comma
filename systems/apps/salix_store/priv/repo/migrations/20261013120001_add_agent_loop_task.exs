defmodule SalixStore.Repo.Migrations.AddAgentLoopTask do
  use Ecto.Migration

  # A Background Loop that a Worker creates while it works a Task belongs to
  # that Task (docs/salix/tasks-background-execution.md, "Background loops").
  # `task_conversation_id` is the Task Conversation in the Loop's own Group,
  # set once at creation and never changed. The unique index holds the
  # one-Loop-per-Task rule and serves the batched lookup by Task.
  #
  # `cron_trigger` names the Schedule definition (receiver `loop`) that
  # delivers the Loop's timed events, with the cron and timezone it was
  # created with. The Loop owns that definition: deleting the Loop deletes it.
  def change do
    alter table(:agent_loops) do
      add(:task_conversation_id, :text)
      add(:cron_trigger, :map)
    end

    create(
      unique_index(:agent_loops, [:group_id, :task_conversation_id],
        name: :agent_loops_task_idx,
        where: "task_conversation_id IS NOT NULL"
      )
    )
  end
end
