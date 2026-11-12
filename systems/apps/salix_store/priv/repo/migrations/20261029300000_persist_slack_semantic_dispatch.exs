defmodule SalixStore.Repo.Migrations.PersistSlackSemanticDispatch do
  use Ecto.Migration

  def up do
    alter table(:search_sources, prefix: "slack_semantic") do
      add(:dispatched_epoch, :bigint, null: false, default: 0)
      add(:dispatch_epoch, :bigint, null: false, default: 0)

      add(:dispatch_live, :boolean, null: false, default: false)
      add(:dispatch_cursor, :map, null: false, default: %{})

      add(:dispatch_due, :utc_datetime_usec,
        null: false,
        default: fragment("timezone('UTC', now())")
      )
    end

    # Existing sources get one finite dispatch. Existing channel cursors also
    # get one finite canonical pass, including rows without source metadata.
    execute(
      "UPDATE slack_semantic.search_sources SET dispatched_epoch=-1, dispatch_epoch=change_epoch"
    )

    create(
      index(
        :search_sources,
        [:dispatch_due, :tenant_id, :workspace_id, :channel_id, :message_ts_us],
        prefix: "slack_semantic",
        name: :search_sources_pending,
        where: "dispatched_epoch < change_epoch AND NOT dispatch_live"
      )
    )

    create(
      index(:search_sources, [:dispatch_due],
        prefix: "slack_semantic",
        name: :search_sources_live,
        where: "dispatched_epoch < change_epoch AND dispatch_live"
      )
    )

    alter table(:search_cursors, prefix: "slack_semantic") do
      add(:completed, :boolean, null: false, default: false)
      add(:due_at, :utc_datetime_usec, null: false, default: fragment("timezone('UTC', now())"))
    end

    execute("UPDATE slack_semantic.search_cursors SET before_ts_us=0")

    execute("""
    INSERT INTO slack_semantic.search_cursors
      (tenant_id, workspace_id, channel_id, group_id, connect_id)
    SELECT tenant_id, workspace_id, channel_id, group_id, connect_id
    FROM slack_semantic.search_channels ON CONFLICT DO NOTHING
    """)

    create(
      index(
        :search_cursors,
        [:due_at, :tenant_id, :workspace_id, :channel_id, :group_id, :connect_id],
        prefix: "slack_semantic",
        name: :search_initialization_pending,
        where: "NOT completed"
      )
    )

    create(
      index(:search_channels, [:tenant_id, :workspace_id, :channel_id, :group_id, :connect_id],
        prefix: "slack_semantic",
        name: :search_channel_installations
      )
    )

    alter table(:search_connects, prefix: "slack_semantic") do
      add(:initialization_pending, :boolean, null: false, default: true)
      add(:initialization_cursor, :text, null: false, default: "")

      add(:initialization_due, :utc_datetime_usec,
        null: false,
        default: fragment("timezone('UTC', now())")
      )
    end

    execute("UPDATE slack_semantic.search_connects SET initialization_pending=false")

    create(
      index(:search_connects, [:initialization_due, :tenant_id, :group_id, :connect_id],
        prefix: "slack_semantic",
        name: :search_connect_initialization_pending,
        where: "active AND initialization_pending"
      )
    )

    alter table(:search_files, prefix: "slack_semantic") do
      add(:refresh_due_at, :utc_datetime_usec)
    end

    create(
      index(:search_files, [:refresh_due_at, :tenant_id, :workspace_id, :file_id],
        prefix: "slack_semantic",
        name: :search_files_due,
        where: "refresh_due_at IS NOT NULL AND NOT refresh_pending"
      )
    )

    execute(
      "UPDATE slack_semantic.search_files SET refresh_due_at=timezone('UTC', now()) WHERE NOT deleted"
    )

    drop_if_exists(index(:oban_jobs, [], prefix: "slack_semantic", name: :semantic_history_scope))
  end

  def down do
    raise "source dispatch requires forward repair"
  end
end
