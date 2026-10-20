defmodule SalixStore.ReleaseObligationIndexTest do
  use SystemsClock.Case, async: false

  alias SalixStore.Repo

  @migration_version 20_260_901_000_102

  test "the staged migration safely resumes after a partial catalog application" do
    # Simulate a process crash after the expand columns, shape constraint, and
    # identity index committed but before the due index and migration version.
    Repo.query!("DROP INDEX IF EXISTS compute_commands_release_due_idx")

    Repo.query!(
      "DELETE FROM salix_schema_migrations WHERE version = $1",
      [@migration_version]
    )

    migrations_path = Application.app_dir(:salix_store, "priv/repo/migrations")

    assert [@migration_version] ==
             Ecto.Migrator.run(Repo, migrations_path, :up,
               to: @migration_version,
               log: false
             )

    assert [[@migration_version]] =
             Repo.query!(
               "SELECT version FROM salix_schema_migrations WHERE version = $1",
               [@migration_version]
             ).rows

    assert [["compute_commands_release_due_idx"]] =
             Repo.query!("SELECT to_regclass('compute_commands_release_due_idx')::text").rows

    assert [["compute_commands_release_incarnation_idx"]] =
             Repo.query!("SELECT to_regclass('compute_commands_release_incarnation_idx')::text").rows
  end
end
