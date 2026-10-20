defmodule SalixStore.Repo.Migrations.AddLoopTaskRequest do
  use Ecto.Migration

  def change do
    alter table(:agent_loops) do
      add(:task_request_id, :string)
    end
  end
end
