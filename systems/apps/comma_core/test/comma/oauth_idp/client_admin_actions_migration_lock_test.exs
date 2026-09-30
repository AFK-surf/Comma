defmodule Comma.OauthIdp.ClientAdminActionsMigrationLockTest do
  @moduledoc "Verifies the historical audit migration lock budget in an isolated database."
  use ExUnit.Case, async: false

  @version 20_260_826_100_000
  @migration_file Path.expand(
                    "../../../priv/repo/migrations/20260826100000_add_oauth_client_admin_actions.exs",
                    __DIR__
                  )

  defmodule LockRepo do
    use Ecto.Repo, otp_app: :comma_core, adapter: Ecto.Adapters.Postgres
  end

  setup do
    _ = Code.require_file(@migration_file)

    config =
      Comma.Repo.config()
      |> Keyword.put(:database, "comma_audit_lock_#{System.unique_integer([:positive])}")
      |> Keyword.put(:pool, Ecto.Adapters.SQL.Sandbox)
      |> Keyword.put(:pool_size, 3)

    assert :ok = Ecto.Adapters.Postgres.storage_up(config)
    on_exit(fn -> assert :ok = Ecto.Adapters.Postgres.storage_down(config) end)
    start_supervised!({LockRepo, config})

    # This historical migration changes only the audit action constraint.
    # Keep its lock target and a durable row separate from the serving test schema.
    Ecto.Adapters.SQL.query!(
      LockRepo,
      "CREATE TABLE comma_admin_audit_events (action text NOT NULL)"
    )

    Ecto.Adapters.SQL.query!(
      LockRepo,
      "INSERT INTO comma_admin_audit_events (action) VALUES ('create_user')"
    )

    migration = Comma.Repo.Migrations.AddOauthClientAdminActions
    assert :ok = migrate(:up, migration)
    %{migration: migration}
  end

  test "a held lock fails the migration within the declared budget and exact retry succeeds", %{
    migration: migration
  } do
    test_pid = self()

    holder =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(LockRepo, fn ->
          LockRepo.transaction(
            fn ->
              Ecto.Adapters.SQL.query!(
                LockRepo,
                "LOCK TABLE comma_admin_audit_events IN ACCESS SHARE MODE"
              )

              send(test_pid, :lock_held)

              receive do
                :release -> :ok
              after
                30_000 -> raise "migration attempt never finished"
              end
            end,
            timeout: 60_000
          )
        end)
      end)

    try do
      assert_receive :lock_held, 10_000
      started = System.monotonic_time(:millisecond)

      attempt =
        try do
          migrate(:down, migration)
          :completed
        rescue
          error -> {:error, error}
        end

      elapsed = System.monotonic_time(:millisecond) - started
      assert {:error, error} = attempt
      assert Exception.message(error) =~ "lock"
      assert elapsed >= 4_000, "failed before the lock budget: #{elapsed}ms"
      assert elapsed < 9_000, "exceeded the lock budget: #{elapsed}ms"
      send(holder.pid, :release)
      assert {:ok, _} = Task.await(holder, 15_000)
    after
      send(holder.pid, :release)
      Task.shutdown(holder, :brutal_kill)
    end

    assert :ok = migrate(:down, migration)
    assert :ok = migrate(:up, migration)

    assert %{rows: [[true]]} =
             Ecto.Adapters.SQL.query!(LockRepo, """
             SELECT convalidated FROM pg_constraint
             WHERE conname = 'comma_admin_audit_action_valid'
               AND conrelid = 'comma_admin_audit_events'::regclass
             """)

    assert %{rows: [["create_user"]]} =
             Ecto.Adapters.SQL.query!(
               LockRepo,
               "SELECT action FROM comma_admin_audit_events"
             )
  end

  defp migrate(direction, migration) do
    # Nontransactional statements must share the lock_timeout session.
    Ecto.Adapters.SQL.Sandbox.unboxed_run(LockRepo, fn ->
      apply(Ecto.Migrator, direction, [LockRepo, @version, migration, [log: false]])
    end)
  end
end
