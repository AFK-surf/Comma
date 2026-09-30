defmodule SalixStore.Repo.Migrations.IndexTriageEventTrajectory do
  use Ecto.Migration

  def up do
    execute("""
    CREATE INDEX triage_product_obligations_source_idx
    ON triage_product_obligations (
      (payload -> 'product_identity' ->> 'project_id'),
      (payload -> 'product_identity' ->> 'agent_id'),
      (payload -> 'product_identity' ->> 'project_salix_group_id'),
      (payload -> 'target'), inserted_at DESC, obligation_id DESC
    );
    """)
  end

  def down do
    execute("DROP INDEX triage_product_obligations_source_idx")
  end
end
