defmodule SalixStore.ReleaseObligationIndexTest do
  use ExUnit.Case, async: false

  alias SalixStore.Repo

  @migration_version 20_260_901_000_102

  test "release identity is unique and the settlement owner selects a bounded due page by index" do
    [[identity_definition]] =
      Repo.query!("SELECT pg_get_indexdef('compute_commands_release_incarnation_idx'::regclass)").rows

    assert identity_definition =~ "UNIQUE INDEX compute_commands_release_incarnation_idx"
    assert identity_definition =~ "(release_incarnation)"
    assert identity_definition =~ "WHERE (release_incarnation IS NOT NULL)"

    assert [[false, constraint_definition]] =
             Repo.query!("""
             SELECT convalidated, pg_get_constraintdef(oid)
             FROM pg_constraint
             WHERE conname = 'compute_commands_release_owner_shape'
             """).rows

    assert constraint_definition =~ "kind <> 'allocation.release'"
    assert constraint_definition =~ "release_incarnation IS NOT NULL"
    assert constraint_definition =~ "workload_id IS NULL"

    [[due_definition]] =
      Repo.query!("SELECT pg_get_indexdef('compute_commands_release_due_idx'::regclass)").rows

    assert due_definition =~ "(status, next_attempt_at, id)"
    assert due_definition =~ "kind = 'allocation.release'"
    assert due_definition =~ "status = ANY"

    plan =
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL enable_seqscan = off")
        Repo.query!("SET LOCAL enable_sort = off")

        Repo.query!("""
        EXPLAIN (COSTS OFF)
        SELECT c.id
        FROM compute_commands AS c
        WHERE c.kind = 'allocation.release'
          AND c.status IN ('failed', 'unknown_outcome')
          AND c.next_attempt_at IS NOT NULL
          AND c.next_attempt_at <= now()
        ORDER BY c.status ASC, c.next_attempt_at ASC, c.id ASC
        LIMIT 32
        FOR UPDATE SKIP LOCKED
        """)
        |> Map.fetch!(:rows)
        |> List.flatten()
        |> Enum.join("\n")
      end)
      |> elem(1)

    assert plan =~ "compute_commands_release_due_idx"
    assert plan =~ "Limit"

    backfill_plan =
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL enable_seqscan = off")
        Repo.query!("SET LOCAL enable_sort = off")

        Repo.query!("""
        EXPLAIN (COSTS OFF)
        SELECT *
        FROM compute_allocations
        WHERE id > 'allocation-cursor'
        ORDER BY id ASC
        LIMIT 100
        """)
        |> Map.fetch!(:rows)
        |> List.flatten()
        |> Enum.join("\n")
      end)
      |> elem(1)

    assert backfill_plan =~ "compute_allocations_pkey"
    assert backfill_plan =~ "Limit"
  end

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
