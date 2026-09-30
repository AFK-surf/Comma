defmodule SalixStore.Repo.Migrations.AddLoopWebhookSecret do
  use Ecto.Migration

  def change do
    alter table(:agent_loops) do
      add(:webhook_secret, :text)
    end

    create(unique_index(:agent_loops, [:webhook_secret], where: "webhook_secret IS NOT NULL"))
  end
end
