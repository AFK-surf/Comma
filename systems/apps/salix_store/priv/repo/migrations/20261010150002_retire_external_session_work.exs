defmodule SalixStore.Repo.Migrations.RetireExternalSessionWork do
  @moduledoc """
  External Sessions are retired: no work of theirs runs again. Remove their
  derived discovery rows and the indexes only they used, and admit only
  internal Session work. Authoritative Session state in S3 is unchanged.
  """
  use Ecto.Migration

  def up do
    execute("DELETE FROM session_work_candidates WHERE runtime_kind = 'external'")

    execute(
      "DELETE FROM session_work_backfill_expected_candidates WHERE runtime_kind = 'external'"
    )

    execute("DROP INDEX IF EXISTS session_work_candidates_external_input_idx")
    execute("DROP INDEX IF EXISTS session_work_candidates_group_id_device_runtime_id_index")

    execute("""
    ALTER TABLE session_work_candidates
      DROP CONSTRAINT session_work_candidates_runtime_kind,
      ADD CONSTRAINT session_work_candidates_runtime_kind
        CHECK (runtime_kind = 'internal') NOT VALID
    """)

    execute(
      "ALTER TABLE session_work_candidates VALIDATE CONSTRAINT session_work_candidates_runtime_kind"
    )

    execute("""
    ALTER TABLE session_work_backfill_expected_candidates
      DROP CONSTRAINT session_work_backfill_expected_runtime_kind,
      ADD CONSTRAINT session_work_backfill_expected_runtime_kind
        CHECK (runtime_kind = 'internal') NOT VALID
    """)

    execute("""
    ALTER TABLE session_work_backfill_expected_candidates
      VALIDATE CONSTRAINT session_work_backfill_expected_runtime_kind
    """)
  end

  def down do
    raise Ecto.MigrationError, "retired External Session work is not restored"
  end
end
