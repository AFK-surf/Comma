defmodule SalixStore.SlackRouterThreadParticipationsTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

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

    expired_soon = NaiveDateTime.add(DateTime.to_naive(SystemsClock.utc_now()), 1, :second)

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
end
