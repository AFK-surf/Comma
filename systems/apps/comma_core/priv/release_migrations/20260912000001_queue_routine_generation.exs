defmodule Comma.Repo.Migrations.QueueRoutineGeneration do
  @moduledoc "Move accepted Routine work to durable jobs after the old runtime stops."
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '900s'")

    # The request/run rows, snapshots, preferences, and renderer journals survive.
    # Reconcile transforms each profile's owned schedule through its domain API.
    execute("""
    INSERT INTO oban_jobs (queue, worker, args, max_attempts, priority)
    SELECT 'comma_recommendation_control', 'Comma.Workers.RecommendationReconcile',
           jsonb_build_object('profile_id', id::text, 'retire_renderer', true), 5, 2
    FROM comma_recommendation_profiles
    """)

    execute("""
    INSERT INTO oban_jobs (queue, worker, args, max_attempts)
    SELECT 'comma_recommendations', 'Comma.Workers.RecommendationGenerate',
           jsonb_build_object('run_id', id::text), 3
    FROM comma_recommendation_runs WHERE status IN ('pending', 'running')
    """)

    execute("""
    INSERT INTO oban_jobs (queue, worker, args, max_attempts, scheduled_at)
    SELECT 'comma_recommendation_control', 'Comma.Workers.RecommendationRunTimeout',
           jsonb_build_object('run_id', id::text), 5, inserted_at + interval '480 seconds'
    FROM comma_recommendation_runs WHERE status IN ('pending', 'running')
    """)

    # These jobs only compact an implementation-specific model context. They
    # own no accepted generation; run rows and preserved schedule receipts own accepted work.
    execute("""
    UPDATE oban_jobs SET state = 'cancelled', cancelled_at = now()
    WHERE worker = 'Comma.Workers.RecommendationContextSeal'
      AND state IN ('available', 'scheduled', 'executing', 'retryable')
    """)
  end
end
