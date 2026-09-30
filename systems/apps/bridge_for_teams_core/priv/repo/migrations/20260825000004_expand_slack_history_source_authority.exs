defmodule BridgeForTeams.Repo.Migrations.ExpandSlackHistorySourceAuthority do
  use Ecto.Migration

  @moduledoc """
  Expands the immutable import identity with the exact Salix and Slack app
  coordinates used by the generation-fenced reader.

  The columns stay nullable at the database layer for mixed-version safety;
  the new application changeset requires them for every newly created run.
  """

  def up do
    alter table(:slack_history_import_runs) do
      add(:salix_tenant_id, :text)
      add(:salix_group_id, :text)
      add(:source_app_id, :text)
    end

    alter table(:slack_history_page_receipts) do
      add(:accepted_channel_authority_revision, :string, size: 64)
    end

    create(
      constraint(:slack_history_import_runs, :slack_history_import_runs_source_authority,
        check: """
        (salix_tenant_id IS NULL OR (btrim(salix_tenant_id) <> '' AND length(salix_tenant_id) <= 256)) AND
        (salix_group_id IS NULL OR (btrim(salix_group_id) <> '' AND length(salix_group_id) <= 256)) AND
        (source_app_id IS NULL OR (btrim(source_app_id) <> '' AND length(source_app_id) <= 256))
        """
      )
    )

    execute("""
    CREATE OR REPLACE FUNCTION reject_slack_history_import_identity_mutation()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF ROW(
        OLD.org_id,
        OLD.project_id,
        OLD.requested_by_user_id,
        OLD.client_request_id,
        OLD.salix_tenant_id,
        OLD.salix_group_id,
        OLD.source_workspace_id,
        OLD.source_app_id,
        OLD.connect_id,
        OLD.connect_generation,
        OLD.replaces_run_id,
        OLD.range_start,
        OLD.range_end,
        OLD.policy_revision,
        OLD.coverage_profile,
        OLD.audience_scope
      ) IS DISTINCT FROM ROW(
        NEW.org_id,
        NEW.project_id,
        NEW.requested_by_user_id,
        NEW.client_request_id,
        NEW.salix_tenant_id,
        NEW.salix_group_id,
        NEW.source_workspace_id,
        NEW.source_app_id,
        NEW.connect_id,
        NEW.connect_generation,
        NEW.replaces_run_id,
        NEW.range_start,
        NEW.range_end,
        NEW.policy_revision,
        NEW.coverage_profile,
        NEW.audience_scope
      ) THEN
        RAISE EXCEPTION 'slack history import source identity is immutable';
      END IF;

      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE FUNCTION reject_slack_history_import_channel_mutation()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      RAISE EXCEPTION 'slack history import channel scope is immutable';
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER slack_history_import_channels_immutable_scope
    BEFORE UPDATE ON slack_history_import_channels
    FOR EACH ROW EXECUTE FUNCTION reject_slack_history_import_channel_mutation()
    """)
  end

  def down do
    execute(
      "DROP TRIGGER slack_history_import_channels_immutable_scope ON slack_history_import_channels"
    )

    execute("DROP FUNCTION reject_slack_history_import_channel_mutation()")

    drop(constraint(:slack_history_import_runs, :slack_history_import_runs_source_authority))

    execute("""
    CREATE OR REPLACE FUNCTION reject_slack_history_import_identity_mutation()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF ROW(
        OLD.org_id,
        OLD.project_id,
        OLD.requested_by_user_id,
        OLD.client_request_id,
        OLD.source_workspace_id,
        OLD.connect_id,
        OLD.connect_generation,
        OLD.replaces_run_id,
        OLD.range_start,
        OLD.range_end
      ) IS DISTINCT FROM ROW(
        NEW.org_id,
        NEW.project_id,
        NEW.requested_by_user_id,
        NEW.client_request_id,
        NEW.source_workspace_id,
        NEW.connect_id,
        NEW.connect_generation,
        NEW.replaces_run_id,
        NEW.range_start,
        NEW.range_end
      ) THEN
        RAISE EXCEPTION 'slack history import source identity is immutable';
      END IF;

      RETURN NEW;
    END;
    $$
    """)

    alter table(:slack_history_page_receipts) do
      remove(:accepted_channel_authority_revision)
    end

    alter table(:slack_history_import_runs) do
      remove(:source_app_id)
      remove(:salix_group_id)
      remove(:salix_tenant_id)
    end
  end
end
