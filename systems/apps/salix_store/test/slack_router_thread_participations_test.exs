defmodule SalixStore.SlackRouterThreadParticipationsTest do
  use ExUnit.Case, async: false

  alias SalixStore.{Repo, SlackRouterThreadParticipations}

  @day_seconds 24 * 60 * 60
  @status_migration_version 20_260_825_000_101
  @status_expiry_index "slack_router_thread_participations_status_expiry_idx"

  Code.require_file(
    "../priv/repo/migrations/20260825000101_add_slack_router_thread_participation_status.exs",
    __DIR__
  )

  setup do
    Repo.query!("TRUNCATE slack_router_thread_participations")
    :ok
  end

  test "participating status and cache hits atomically renew the 30-day idle TTL" do
    identity = identity("base")

    assert :ok = mark_participating(identity)
    first = row(identity)

    assert first.participation_status == "participating"

    assert_in_delta NaiveDateTime.diff(first.expires_at, first.observed_at),
                    30 * @day_seconds,
                    1

    expired_soon = NaiveDateTime.add(NaiveDateTime.utc_now(), 1, :second)

    Repo.query!(
      """
      UPDATE slack_router_thread_participations
      SET expires_at = $7, status_expires_at = $7
      WHERE group_id = $1 AND connect_id = $2 AND workspace_id = $3
        AND bot_user_id = $4 AND channel_id = $5 AND thread_ts = $6
      """,
      identity ++ [expired_soon]
    )

    assert status(identity) == :participating

    renewed = row(identity)
    assert NaiveDateTime.compare(renewed.expires_at, expired_soon) == :gt

    assert_in_delta NaiveDateTime.diff(renewed.expires_at, renewed.observed_at),
                    30 * @day_seconds,
                    1
  end

  test "not-participating status is exact, expires after 24 hours, and hits do not renew it" do
    identity = identity("not-participating")

    assert {:ok, :not_participating} = mark_not_participating(identity)
    first = row(identity)
    first_version = row_version(identity)

    assert first.participation_status == "not_participating"
    assert_in_delta NaiveDateTime.diff(first.expires_at, first.observed_at), @day_seconds, 1
    assert status(identity) == :not_participating
    assert row(identity) == first
    assert row_version(identity) == first_version

    for other <- [
          List.replace_at(identity, 0, "group-other"),
          List.replace_at(identity, 1, "connect-other"),
          List.replace_at(identity, 2, "workspace-other"),
          List.replace_at(identity, 3, "bot-other"),
          List.replace_at(identity, 4, "channel-other"),
          List.replace_at(identity, 5, "thread-other")
        ] do
      assert status(other) == :unknown
    end

    expire_status(identity)
    assert status(identity) == :unknown
  end

  test "participation identity is isolated by group, connect, installation, channel, and thread" do
    base = identity("isolated")
    assert :ok = mark_participating(base)
    assert status(base) == :participating

    for other <- [
          List.replace_at(base, 0, "group-other"),
          List.replace_at(base, 1, "connect-other"),
          List.replace_at(base, 2, "workspace-other"),
          List.replace_at(base, 3, "bot-other"),
          List.replace_at(base, 4, "channel-other"),
          List.replace_at(base, 5, "thread-other")
        ] do
      assert status(other) == :unknown
    end
  end

  test "participating status supersedes not-participating status until it expires" do
    identity = identity("participating-wins")

    assert {:ok, :not_participating} = mark_not_participating(identity)
    assert status(identity) == :not_participating

    assert :ok = mark_participating(identity)
    assert status(identity) == :participating

    assert {:ok, :participating} = mark_not_participating(identity)
    assert status(identity) == :participating
    assert row(identity).participation_status == "participating"

    expire_status(identity)
    expire_legacy(identity)

    assert {:ok, :not_participating} = mark_not_participating(identity)
    assert status(identity) == :not_participating
  end

  test "an old-runtime insert defaults to participating during rollout" do
    identity = identity("old-insert")
    now = NaiveDateTime.utc_now()

    Repo.query!(
      """
      INSERT INTO slack_router_thread_participations (
        group_id, connect_id, workspace_id, bot_user_id,
        channel_id, thread_ts, last_active_at, expires_at
      ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
      """,
      identity ++ [now, NaiveDateTime.add(now, 30 * @day_seconds, :second)]
    )

    assert status(identity) == :participating
    assert row(identity).participation_status == "participating"
  end

  test "an old reader ignores not-participating status and an old write restores participating" do
    identity = identity("mixed-version")
    assert {:ok, :not_participating} = mark_not_participating(identity)

    assert %{num_rows: 0} =
             Repo.query!(
               """
               UPDATE slack_router_thread_participations
               SET expires_at = GREATEST(
                 expires_at,
                 timezone('UTC', statement_timestamp()) + interval '30 days'
               )
               WHERE group_id = $1 AND connect_id = $2 AND workspace_id = $3
                 AND bot_user_id = $4 AND channel_id = $5 AND thread_ts = $6
                 AND expires_at > timezone('UTC', statement_timestamp())
               RETURNING group_id
               """,
               identity
             )

    now = NaiveDateTime.utc_now()

    Repo.query!(
      """
      INSERT INTO slack_router_thread_participations (
        group_id, connect_id, workspace_id, bot_user_id,
        channel_id, thread_ts, last_active_at, expires_at
      ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
      ON CONFLICT (group_id, connect_id, workspace_id, bot_user_id, channel_id, thread_ts)
      DO UPDATE SET
        last_active_at = GREATEST(
          slack_router_thread_participations.last_active_at,
          EXCLUDED.last_active_at
        ),
        expires_at = GREATEST(
          slack_router_thread_participations.expires_at,
          EXCLUDED.expires_at
        )
      """,
      identity ++ [now, NaiveDateTime.add(now, 30 * @day_seconds, :second)]
    )

    assert status(identity) == :participating
    assert row(identity).participation_status == "participating"
  end

  test "an expired status is unknown and cannot renew itself" do
    identity = identity("expired")
    assert :ok = mark_participating(identity)

    expired_at = NaiveDateTime.add(NaiveDateTime.utc_now(), -1, :second)

    Repo.query!(
      """
      UPDATE slack_router_thread_participations
      SET status_expires_at = $7
      WHERE group_id = $1 AND connect_id = $2 AND workspace_id = $3
        AND bot_user_id = $4 AND channel_id = $5 AND thread_ts = $6
      """,
      identity ++ [expired_at]
    )

    expire_legacy(identity)

    assert status(identity) == :unknown
    assert NaiveDateTime.compare(row(identity).expires_at, expired_at) == :eq
  end

  test "status migration repairs an invalid index left by a failed concurrent build" do
    assert :ok = mark_participating(identity("invalid-index-a"))
    assert :ok = mark_participating(identity("invalid-index-b"))

    on_exit(fn ->
      restore_status_expiry_index!()

      Repo.query!(
        """
        INSERT INTO salix_schema_migrations (version, inserted_at)
        VALUES ($1, timezone('UTC', statement_timestamp()))
        ON CONFLICT (version) DO NOTHING
        """,
        [@status_migration_version]
      )
    end)

    Repo.query!("DROP INDEX CONCURRENTLY IF EXISTS #{@status_expiry_index}")

    assert_raise Postgrex.Error, fn ->
      Repo.query!("""
      CREATE UNIQUE INDEX CONCURRENTLY #{@status_expiry_index}
      ON slack_router_thread_participations ((1))
      """)
    end

    assert %{rows: [[false]]} = status_expiry_index_validity()

    Repo.query!(
      "DELETE FROM salix_schema_migrations WHERE version = $1",
      [@status_migration_version]
    )

    assert :ok =
             Ecto.Migrator.up(
               Repo,
               @status_migration_version,
               SalixStore.Repo.Migrations.AddSlackRouterThreadParticipationStatus,
               # The test database also contains migrations released after the
               # migration under test. Exercise this migration's repair path
               # directly; production still applies the ledger in strict order.
               strict_version_order: false,
               log: false
             )

    assert %{rows: [[true]]} = status_expiry_index_validity()

    assert %{rows: [[index_definition]]} =
             Repo.query!(
               "SELECT pg_get_indexdef(to_regclass($1))",
               [@status_expiry_index]
             )

    refute index_definition =~ "UNIQUE"
    assert index_definition =~ "status_expires_at"
    assert index_definition =~ "WHERE (status_expires_at IS NOT NULL)"

    assert %{rows: [[@status_migration_version]]} =
             Repo.query!(
               "SELECT version FROM salix_schema_migrations WHERE version = $1",
               [@status_migration_version]
             )
  end

  test "canonical cleanup uses the expiry index and deletes at most the requested bound" do
    for suffix <- ~w(expired-a expired-b expired-c live) do
      assert :ok = suffix |> identity() |> mark_participating()
    end

    Repo.query!("""
    UPDATE slack_router_thread_participations
    SET
      expires_at = timezone('UTC', statement_timestamp()) - interval '1 second',
      status_expires_at = timezone('UTC', statement_timestamp()) - interval '1 second'
    WHERE group_id <> 'group-live'
    """)

    Repo.query!("""
    INSERT INTO slack_router_thread_participations (
      group_id, connect_id, workspace_id, bot_user_id,
      channel_id, thread_ts, participation_status,
      last_active_at, expires_at, status_expires_at
    )
    SELECT
      'live-seed-' || series,
      'connect-seed',
      'workspace-seed',
      'bot-seed',
      'channel-seed',
      'thread-seed',
      'participating',
      timezone('UTC', statement_timestamp()),
      timezone('UTC', statement_timestamp()) + interval '30 days',
      timezone('UTC', statement_timestamp()) + interval '30 days'
    FROM generate_series(1, 5000) AS series
    """)

    Repo.query!("ANALYZE slack_router_thread_participations")

    %{rows: plan_rows} =
      Repo.query!("""
      EXPLAIN (COSTS OFF)
      SELECT group_id, connect_id, workspace_id, bot_user_id, channel_id, thread_ts
      FROM slack_router_thread_participations
      WHERE status_expires_at <= timezone('UTC', statement_timestamp())
        AND expires_at <= timezone('UTC', statement_timestamp())
      ORDER BY status_expires_at, group_id, connect_id, workspace_id, bot_user_id, channel_id, thread_ts
      LIMIT 2
      FOR UPDATE SKIP LOCKED
      """)

    plan = plan_rows |> List.flatten() |> Enum.join("\n")
    assert plan =~ "slack_router_thread_participations_status_expiry_idx"

    assert {:ok, 2} = SlackRouterThreadParticipations.cleanup_expired(2)
    assert {:ok, 1} = SlackRouterThreadParticipations.cleanup_expired(2)
    assert {:ok, 0} = SlackRouterThreadParticipations.cleanup_expired(2)
    assert status(identity("live")) == :participating
  end

  test "legacy compatibility cleanup remains separately bounded" do
    for suffix <- ~w(expired-a expired-b live) do
      assert :ok = suffix |> identity() |> mark_participating()
    end

    Repo.query!("""
    UPDATE slack_router_thread_participations
    SET
      status_expires_at = NULL,
      expires_at = timezone('UTC', statement_timestamp()) - interval '1 second'
    WHERE group_id <> 'group-live'
    """)

    assert {:ok, 1} = SlackRouterThreadParticipations.cleanup_legacy_expired(1)
    assert {:ok, 1} = SlackRouterThreadParticipations.cleanup_legacy_expired(1)
    assert {:ok, 0} = SlackRouterThreadParticipations.cleanup_legacy_expired(1)
  end

  test "a live participating hit racing cleanup renews without being deleted" do
    identity = identity("renew-race")
    assert :ok = mark_participating(identity)

    %{rows: [[expires_at]]} =
      Repo.query!(
        """
        UPDATE slack_router_thread_participations
        SET
          expires_at = timezone('UTC', statement_timestamp()) + interval '2 seconds',
          status_expires_at = timezone('UTC', statement_timestamp()) + interval '2 seconds'
        WHERE group_id = $1 AND connect_id = $2 AND workspace_id = $3
          AND bot_user_id = $4 AND channel_id = $5 AND thread_ts = $6
        RETURNING expires_at
        """,
        identity
      )

    parent = self()

    locker =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!(
            """
            SELECT group_id
            FROM slack_router_thread_participations
            WHERE group_id = $1 AND connect_id = $2 AND workspace_id = $3
              AND bot_user_id = $4 AND channel_id = $5 AND thread_ts = $6
            FOR UPDATE
            """,
            identity
          )

          send(parent, :participation_row_locked)

          receive do
            :release_participation_row -> :ok
          after
            10_000 -> Repo.rollback(:lock_barrier_timeout)
          end
        end)
      end)

    assert_receive :participation_row_locked, 1_000

    renewal =
      Task.async(fn ->
        Repo.checkout(fn ->
          %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:renewal_backend, backend_pid})
          status(identity, timeout_ms: 5_000)
        end)
      end)

    assert_receive {:renewal_backend, renewal_backend}, 1_000
    await_backend_lock!(renewal_backend)
    await_database_time!(expires_at)

    assert {:ok, 0} = SlackRouterThreadParticipations.cleanup_expired(1)

    send(locker.pid, :release_participation_row)
    assert {:ok, :ok} = Task.await(locker, 1_000)
    assert Task.await(renewal, 1_000) == :participating
    assert status(identity) == :participating
  end

  test "a blocked optional status query respects its explicit short timeout" do
    identity = identity("query-timeout")
    assert :ok = mark_participating(identity)
    parent = self()

    locker =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!(
            """
            SELECT group_id
            FROM slack_router_thread_participations
            WHERE group_id = $1 AND connect_id = $2 AND workspace_id = $3
              AND bot_user_id = $4 AND channel_id = $5 AND thread_ts = $6
            FOR UPDATE
            """,
            identity
          )

          send(parent, :timeout_test_row_locked)

          receive do
            :release_timeout_test_row -> :ok
          after
            5_000 -> Repo.rollback(:lock_barrier_timeout)
          end
        end)
      end)

    assert_receive :timeout_test_row_locked, 1_000
    started_at = System.monotonic_time(:millisecond)

    assert status(identity, timeout_ms: 50) == :unknown

    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    assert elapsed_ms < 500

    send(locker.pid, :release_timeout_test_row)
    assert {:ok, :ok} = Task.await(locker, 1_000)
    assert status(identity) == :participating
  end

  test "status writes are idempotent and invalid identities fail closed" do
    identity = identity("upsert")

    assert :ok = mark_participating(identity)
    assert :ok = mark_participating(identity)

    assert %{rows: [[1]]} =
             Repo.query!("SELECT count(*) FROM slack_router_thread_participations")

    assert {:error, :invalid_identity} =
             SlackRouterThreadParticipations.mark_participating(
               "",
               "connect",
               "workspace",
               "bot",
               "channel",
               "thread"
             )

    assert {:error, :invalid_identity} =
             SlackRouterThreadParticipations.mark_not_participating(
               "group",
               " \t",
               "workspace",
               "bot",
               "channel",
               "thread"
             )

    assert SlackRouterThreadParticipations.status(
             "group",
             "connect",
             "workspace",
             "bot",
             "channel",
             ""
           ) == :unknown
  end

  defp identity(suffix),
    do: [
      "group-#{suffix}",
      "connect-#{suffix}",
      "workspace-#{suffix}",
      "bot-#{suffix}",
      "channel-#{suffix}",
      "thread-#{suffix}"
    ]

  defp mark_participating([
         group_id,
         connect_id,
         workspace_id,
         bot_user_id,
         channel_id,
         thread_ts
       ]),
       do:
         SlackRouterThreadParticipations.mark_participating(
           group_id,
           connect_id,
           workspace_id,
           bot_user_id,
           channel_id,
           thread_ts
         )

  defp mark_not_participating([
         group_id,
         connect_id,
         workspace_id,
         bot_user_id,
         channel_id,
         thread_ts
       ]),
       do:
         SlackRouterThreadParticipations.mark_not_participating(
           group_id,
           connect_id,
           workspace_id,
           bot_user_id,
           channel_id,
           thread_ts
         )

  defp status(
         [group_id, connect_id, workspace_id, bot_user_id, channel_id, thread_ts],
         opts \\ []
       ),
       do:
         SlackRouterThreadParticipations.status(
           group_id,
           connect_id,
           workspace_id,
           bot_user_id,
           channel_id,
           thread_ts,
           opts
         )

  defp row(identity) do
    assert %{rows: [[participation_status, observed_at, expires_at]]} =
             Repo.query!(
               """
               SELECT participation_status, last_active_at, status_expires_at
               FROM slack_router_thread_participations
               WHERE group_id = $1 AND connect_id = $2 AND workspace_id = $3
                 AND bot_user_id = $4 AND channel_id = $5 AND thread_ts = $6
               """,
               identity
             )

    %{
      participation_status: participation_status,
      observed_at: observed_at,
      expires_at: expires_at
    }
  end

  defp row_version(identity) do
    assert %{rows: [[ctid, xmin]]} =
             Repo.query!(
               """
               SELECT ctid::text, xmin::text
               FROM slack_router_thread_participations
               WHERE group_id = $1 AND connect_id = $2 AND workspace_id = $3
                 AND bot_user_id = $4 AND channel_id = $5 AND thread_ts = $6
               """,
               identity
             )

    {ctid, xmin}
  end

  defp status_expiry_index_validity do
    Repo.query!(
      """
      SELECT index_metadata.indisvalid
      FROM pg_index AS index_metadata
      WHERE index_metadata.indexrelid = to_regclass($1)
      """,
      [@status_expiry_index]
    )
  end

  defp restore_status_expiry_index! do
    Repo.query!("DROP INDEX CONCURRENTLY IF EXISTS #{@status_expiry_index}")

    Repo.query!("""
    CREATE INDEX CONCURRENTLY #{@status_expiry_index}
    ON slack_router_thread_participations (
      status_expires_at,
      group_id,
      connect_id,
      workspace_id,
      bot_user_id,
      channel_id,
      thread_ts
    )
    WHERE status_expires_at IS NOT NULL
    """)
  end

  defp expire_status(identity) do
    Repo.query!(
      """
      UPDATE slack_router_thread_participations
      SET status_expires_at = timezone('UTC', statement_timestamp()) - interval '1 second'
      WHERE group_id = $1 AND connect_id = $2 AND workspace_id = $3
        AND bot_user_id = $4 AND channel_id = $5 AND thread_ts = $6
      """,
      identity
    )
  end

  defp expire_legacy(identity) do
    Repo.query!(
      """
      UPDATE slack_router_thread_participations
      SET expires_at = timezone('UTC', statement_timestamp()) - interval '1 second'
      WHERE group_id = $1 AND connect_id = $2 AND workspace_id = $3
        AND bot_user_id = $4 AND channel_id = $5 AND thread_ts = $6
      """,
      identity
    )
  end

  defp await_backend_lock!(backend_pid, attempts \\ 100)

  defp await_backend_lock!(_backend_pid, 0),
    do: flunk("renewal query never reached its row-lock barrier")

  defp await_backend_lock!(backend_pid, attempts) do
    case Repo.query!(
           "SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1",
           [backend_pid]
         ).rows do
      [["Lock"]] ->
        :ok

      _other ->
        Process.sleep(10)
        await_backend_lock!(backend_pid, attempts - 1)
    end
  end

  defp await_database_time!(expires_at, attempts \\ 300)

  defp await_database_time!(_expires_at, 0),
    do: flunk("database clock did not reach the cleanup boundary")

  defp await_database_time!(expires_at, attempts) do
    case Repo.query!("SELECT timezone('UTC', statement_timestamp()) >= $1", [expires_at]).rows do
      [[true]] ->
        :ok

      _other ->
        Process.sleep(10)
        await_database_time!(expires_at, attempts - 1)
    end
  end
end
