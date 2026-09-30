defmodule Comma.GroupScopeMigrationE2ETest do
  use ExUnit.Case, async: false

  @migration_version 20_260_826_001_000

  defmodule MigrationRepo do
    use Ecto.Repo,
      otp_app: :comma_core,
      adapter: Ecto.Adapters.Postgres
  end

  setup do
    database = "comma_group_scope_migration_#{System.unique_integer([:positive])}"

    repo_config =
      Comma.Repo.config()
      |> Keyword.put(:database, database)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 4)

    assert :ok = Ecto.Adapters.Postgres.storage_up(repo_config)
    {:ok, repo_pid} = MigrationRepo.start_link(repo_config)
    Process.unlink(repo_pid)

    on_exit(fn ->
      Supervisor.stop(repo_pid, :normal)
      assert :ok = Ecto.Adapters.Postgres.storage_down(repo_config)
    end)

    create_pre_migration_table!()
    %{repo: MigrationRepo}
  end

  test "the online expand bounds lock acquisition and installs the new check without a table scan",
       %{repo: repo} do
    parent = self()

    writer =
      Task.async(fn ->
        repo.transaction(fn ->
          Ecto.Adapters.SQL.query!(
            repo,
            "LOCK TABLE comma_auth_sessions IN ROW EXCLUSIVE MODE"
          )

          send(parent, :writer_lock_held)

          receive do
            :release_writer -> :ok
          end
        end)
      end)

    assert_receive :writer_lock_held, 1_000

    blocked_attempt = Task.async(fn -> migrate(repo) end)
    blocked_outcome = Task.yield(blocked_attempt, 6_000)

    if blocked_outcome == nil do
      Task.shutdown(blocked_attempt, :brutal_kill)
    end

    send(writer.pid, :release_writer)
    assert {:ok, {:ok, _transaction_result}} = Task.yield(writer, 1_000)

    assert blocked_outcome == {:ok, {:postgres_error, :lock_not_available}}

    assert :ok = migrate(repo)

    assert %{rows: [[false]]} =
             Ecto.Adapters.SQL.query!(
               repo,
               """
               SELECT convalidated
               FROM pg_constraint
               WHERE conrelid = 'comma_auth_sessions'::regclass
                 AND conname = 'comma_auth_sessions_scope_valid'
               """
             )

    assert %{num_rows: 1} =
             Ecto.Adapters.SQL.query!(
               repo,
               """
               INSERT INTO comma_auth_sessions (
                 id, restricted, session_source, group_id, conversation_id
               )
               VALUES (
                 '00000000-0000-0000-0000-000000000003', true, 'ops_api',
                 'grp1_new', 'cnv1_new'
               )
               """
             )

    assert_raise Postgrex.Error, ~r/comma_auth_sessions_scope_valid/, fn ->
      Ecto.Adapters.SQL.query!(
        repo,
        """
        INSERT INTO comma_auth_sessions (
          id, restricted, session_source, conversation_id
        )
        VALUES (
          '00000000-0000-0000-0000-000000000004', true, 'ops_api',
          'cnv1_missing_group'
        )
        """
      )
    end

    assert %{rows: [[2]]} =
             Ecto.Adapters.SQL.query!(repo, "SELECT count(*) FROM comma_auth_sessions")
  end

  defp migrate(repo) do
    migration =
      require_migration!(
        "../priv/repo/migrations/20260826001000_add_group_scope_to_auth_sessions.exs",
        Comma.Repo.Migrations.AddGroupScopeToAuthSessions
      )

    case Ecto.Migrator.up(repo, @migration_version, migration,
           strict_version_order: false,
           log: false
         ) do
      :ok -> :ok
      :already_up -> :ok
    end
  rescue
    error in Postgrex.Error -> {:postgres_error, error.postgres.code}
  end

  defp create_pre_migration_table! do
    Ecto.Adapters.SQL.query!(
      MigrationRepo,
      """
      CREATE TABLE comma_auth_sessions (
        id uuid PRIMARY KEY,
        restricted boolean NOT NULL DEFAULT false,
        session_source text NOT NULL,
        workspace_id text,
        conversation_id text,
        interaction_budget_remaining integer,
        tool_allowlist text[] NOT NULL DEFAULT '{}',
        consumed_interaction_ids jsonb NOT NULL DEFAULT '{}'::jsonb
      )
      """
    )

    Ecto.Adapters.SQL.query!(
      MigrationRepo,
      """
      ALTER TABLE comma_auth_sessions
      ADD CONSTRAINT comma_auth_sessions_scope_valid CHECK (
        (
          restricted
          AND session_source = 'ops_api'
        ) OR (
          NOT restricted
          AND workspace_id IS NULL
          AND conversation_id IS NULL
          AND interaction_budget_remaining IS NULL
          AND cardinality(tool_allowlist) = 0
          AND consumed_interaction_ids = '{}'::jsonb
        )
      )
      """
    )

    Ecto.Adapters.SQL.query!(
      MigrationRepo,
      """
      INSERT INTO comma_auth_sessions (
        id, restricted, session_source, workspace_id, conversation_id
      )
      VALUES (
        '00000000-0000-0000-0000-000000000001', true, 'ops_api',
        'legacy-workspace', 'legacy-conversation'
      )
      """
    )
  end

  defp require_migration!(relative_path, module) do
    Code.require_file(Path.expand(relative_path, __DIR__))
    module
  end
end
