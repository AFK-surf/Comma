defmodule SalixStore.Repo.Migrations.AddLoopTaskReport do
  use Ecto.Migration

  def change do
    alter table(:agent_loops) do
      add(:pending_task_report, :map)
    end

    create(
      index(:agent_loops, [:id],
        name: :agent_loops_pending_task_report_idx,
        where: "pending_task_report IS NOT NULL"
      )
    )
  end
end
