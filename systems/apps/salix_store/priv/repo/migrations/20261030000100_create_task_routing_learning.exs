defmodule SalixStore.Repo.Migrations.CreateTaskRoutingLearning do
  use Ecto.Migration

  def change do
    create table(:task_routing_learning, primary_key: false) do
      add(:group_id, :text, primary_key: true)
      add(:generation, :text, primary_key: true)
      add(:value, :map, null: false)
    end

    create table(:task_routing_feedback, primary_key: false) do
      add(:group_id, :text, primary_key: true)
      add(:conversation_id, :text, primary_key: true)
      add(:generation, :text, null: false)
      add(:value, :map, null: false)
    end
  end
end
