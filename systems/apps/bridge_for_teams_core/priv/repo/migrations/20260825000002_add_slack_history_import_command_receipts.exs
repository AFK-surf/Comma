defmodule BridgeForTeams.Repo.Migrations.AddSlackHistoryImportCommandReceipts do
  use Ecto.Migration

  def up do
    alter table(:slack_history_import_runs) do
      add(:commit_base_generation, :bigint)
    end

    create table(:slack_history_import_command_receipts, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :run_id,
        references(:slack_history_import_runs, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:command_id, :string, null: false)
      add(:kind, :string, null: false)
      add(:expected_generation, :bigint, null: false)
      add(:resulting_generation, :bigint, null: false)
      add(:result, :map, null: false, default: %{})
      add(:created_at, :utc_datetime_usec, null: false)
    end

    create(
      unique_index(
        :slack_history_import_command_receipts,
        [:run_id, :command_id],
        name: :slack_history_import_command_receipts_identity_idx
      )
    )

    create(
      constraint(
        :slack_history_import_command_receipts,
        :slack_history_import_command_receipts_nonempty_command,
        check: "length(btrim(command_id)) > 0"
      )
    )

    create(
      constraint(
        :slack_history_import_command_receipts,
        :slack_history_import_command_receipts_kind,
        check: "kind IN ('committed', 'canceled', 'rolled_back_after_late_cancel', 'rolled_back')"
      )
    )

    create(
      constraint(
        :slack_history_import_command_receipts,
        :slack_history_import_command_receipts_generations,
        check: "expected_generation >= 0 AND resulting_generation >= 0"
      )
    )

    execute("""
    CREATE FUNCTION reject_slack_history_import_command_receipt_update()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'slack history import command receipts are immutable';
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER slack_history_import_command_receipts_immutable
    BEFORE UPDATE ON slack_history_import_command_receipts
    FOR EACH ROW EXECUTE FUNCTION reject_slack_history_import_command_receipt_update()
    """)
  end

  def down do
    execute(
      "DROP TRIGGER IF EXISTS slack_history_import_command_receipts_immutable ON slack_history_import_command_receipts"
    )

    drop(table(:slack_history_import_command_receipts))
    execute("DROP FUNCTION IF EXISTS reject_slack_history_import_command_receipt_update()")

    alter table(:slack_history_import_runs) do
      remove(:commit_base_generation)
    end
  end
end
