defmodule SalixStore.Repo.Migrations.AddLoopPendingEvents do
  use Ecto.Migration

  def change do
    alter table(:agent_loops) do
      add(:pending_events, :map, null: false, default: %{})
    end
  end
end
