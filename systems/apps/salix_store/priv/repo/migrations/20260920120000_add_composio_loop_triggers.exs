defmodule SalixStore.Repo.Migrations.AddComposioLoopTriggers do
  use Ecto.Migration

  def change do
    alter table(:composio_settings) do
      add(:webhook_secret, :text)
    end

    create(unique_index(:composio_settings, [:webhook_secret]))

    alter table(:agent_loops) do
      add(:composio_trigger, :map)
    end

    execute(
      "CREATE INDEX agent_loops_composio_trigger_idx ON agent_loops (group_id, (composio_trigger->>'trigger_id')) WHERE status = 'active'",
      "DROP INDEX agent_loops_composio_trigger_idx"
    )
  end
end
