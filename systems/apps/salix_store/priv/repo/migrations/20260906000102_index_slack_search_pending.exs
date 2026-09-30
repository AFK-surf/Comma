defmodule SalixStore.Repo.Migrations.IndexSlackSearchPending do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create_if_not_exists(
      index(
        :slack_mirror_outbox,
        [
          "(row->>'tenant_id')",
          "(row->>'workspace_id')",
          "(row->>'channel_id')",
          "(row->>'message_ts_us')"
        ],
        name: :slack_search_pending_source,
        where: "kind = 'message'",
        concurrently: true
      )
    )
  end
end
