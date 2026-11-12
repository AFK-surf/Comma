defmodule SalixStore.Repo.Migrations.IndexPendingSemanticHistory do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create_if_not_exists(
      index(:oban_jobs, ["(args->'scope')"],
        prefix: "slack_semantic",
        name: :semantic_history_scope,
        concurrently: true,
        where: "queue = 'semantic_text' AND priority = 9 AND state IN ('available', 'executing')"
      )
    )
  end
end
