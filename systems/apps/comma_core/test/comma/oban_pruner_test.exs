defmodule Comma.ObanPrunerTest do
  # Comma.Oban keeps a day of finished jobs (Pruner max_age 86_400), so its
  # table holds about one day of job throughput while only the jobs that
  # crossed the cutoff since the last pass qualify. A pass must find those
  # through an index; in production a whole-table read of about one million
  # rows passed the 15 s checkout limit and the pass was rolled back.
  use Comma.DataCase, async: false

  @fresh 200_000
  @max_age 86_400

  setup do
    unless Oban.whereis(Comma.Oban) do
      start_supervised!(
        {Oban, name: Comma.Oban, repo: Repo, testing: :manual, queues: false, plugins: false}
      )
    end

    :ok
  end

  test "a Pruner pass over a day of finished jobs deletes the expired ones without reading the table" do
    now = SystemsClock.utc_now()
    old = now |> DateTime.add(-2 * @max_age) |> DateTime.to_naive()
    young = now |> DateTime.add(-3_600) |> DateTime.to_naive()

    Repo.query!(
      """
      INSERT INTO public.oban_jobs
        (state, queue, worker, args, attempt, max_attempts, inserted_at, scheduled_at,
         attempted_at, completed_at)
      SELECT 'completed', (ARRAY['comma_notifications', 'comma_external'])[1 + n % 2],
             'Comma.Workers.NativePushFanout', jsonb_build_object('n', n), 1, 3,
             $1::timestamp, $1::timestamp, $1::timestamp, $1::timestamp
      FROM generate_series(1, $2) AS n
      """,
      [young, @fresh]
    )

    Repo.query!(
      """
      INSERT INTO public.oban_jobs
        (state, queue, worker, args, attempt, max_attempts, inserted_at, scheduled_at,
         attempted_at, completed_at, cancelled_at, discarded_at)
      SELECT state::oban_job_state, 'comma_notifications', 'Comma.Workers.NativePush',
             jsonb_build_object('old', n), 1, 3, $1::timestamp, $1::timestamp, $1::timestamp,
             CASE WHEN state = 'completed' THEN $1::timestamp END,
             CASE WHEN state = 'cancelled' THEN $1::timestamp END,
             CASE WHEN state = 'discarded' THEN $1::timestamp END
      FROM generate_series(1, 30) AS n,
           LATERAL (SELECT (ARRAY['completed', 'cancelled', 'discarded'])[1 + n % 3] AS state) s
      """,
      [old]
    )

    Repo.query!("ANALYZE public.oban_jobs")
    scans = table_scans()

    {:ok, pruned} =
      Oban.Engines.Basic.prune_jobs(Oban.config(Comma.Oban), Oban.Job,
        limit: 10_000,
        max_age: @max_age
      )

    assert length(pruned) == 30
    assert table_scans() == scans
    assert Repo.aggregate(Oban.Job, :count) >= @fresh
  end

  # Sequential reads of public.oban_jobs in this test's transaction.
  defp table_scans do
    %{rows: [[scans]]} =
      Repo.query!("""
      SELECT seq_scan FROM pg_stat_xact_user_tables
      WHERE schemaname = 'public' AND relname = 'oban_jobs'
      """)

    scans
  end
end
