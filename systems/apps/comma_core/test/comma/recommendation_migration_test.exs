defmodule Comma.RecommendationMigrationTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Comma.Data.{RecommendationProfile, RecommendationRun}

  @version 20_260_912_000_001
  @migration_file Path.expand(
                    "../../priv/release_migrations/20260912000001_queue_routine_generation.exs",
                    __DIR__
                  )

  defmodule MigrationRepo do
    use Ecto.Repo, otp_app: :comma_core, adapter: Ecto.Adapters.Postgres
  end

  setup do
    # Copy the actual table definitions into an isolated namespace. The real
    # Ecto migration runs there, without changing other tests' ledgers or data.
    schema = "routine_migration_#{System.unique_integer([:positive])}"

    config =
      Comma.Repo.config()
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 3)
      |> Keyword.put(:parameters, search_path: schema <> ",public")

    repo = start_supervised!({MigrationRepo, config})
    MigrationRepo.query!("CREATE SCHEMA #{schema}")

    for table <- ~w(comma_recommendation_profiles comma_recommendation_runs oban_jobs) do
      MigrationRepo.query!("CREATE TABLE #{schema}.#{table} (LIKE public.#{table} INCLUDING ALL)")
    end

    on_exit(fn ->
      # The test supervisor can stop before on_exit. Use a fresh owned Repo
      # connection and delete only this test's namespace.
      if Process.alive?(repo), do: Supervisor.stop(repo)
      {:ok, cleanup} = MigrationRepo.start_link(config)
      MigrationRepo.query!("DROP SCHEMA #{schema} CASCADE")
      Supervisor.stop(cleanup)
    end)

    Code.require_file(@migration_file)
    %{schema: schema}
  end

  test "cutover queues accepted work once and preserves product rows and unrelated jobs", %{
    schema: schema
  } do
    profile =
      MigrationRepo.insert!(%RecommendationProfile{
        workspace_id: "migration-workspace",
        user_id: "migration-member",
        sources: [%{"connectionId" => "keep-this-account", "enabled" => true}],
        requested_generation: 2,
        published_generation: 1,
        snapshot: %{"preserved" => "published work"},
        agent_id: "keep-renderer",
        session_id: "keep-journal",
        schedule_id: "keep-schedule"
      })

    published =
      MigrationRepo.insert!(%RecommendationRun{
        profile_id: profile.id,
        generation: 1,
        source_revision: 0,
        trigger: "manual",
        status: "published"
      })

    pending =
      MigrationRepo.insert!(%RecommendationRun{
        profile_id: profile.id,
        generation: 2,
        source_revision: 0,
        trigger: "manual",
        status: "running",
        source_evidence: %{"keep" => ["https://example.test"]}
      })

    seal =
      MigrationRepo.insert!(
        Oban.Job.new(%{"profile_id" => profile.id},
          worker: "Comma.Workers.RecommendationContextSeal",
          queue: "comma_external"
        )
      )

    unrelated =
      MigrationRepo.insert!(
        Oban.Job.new(%{"unrelated" => true},
          worker: "Comma.Workers.ProfileAvatarCleanup",
          queue: "comma_external"
        )
      )

    unrelated = MigrationRepo.get!(Oban.Job, unrelated.id)

    assert :ok =
             Ecto.Migrator.up(MigrationRepo, @version, Comma.Repo.Migrations.QueueRoutineGeneration,
               prefix: schema,
               log: false
             )

    assert :already_up =
             Ecto.Migrator.up(MigrationRepo, @version, Comma.Repo.Migrations.QueueRoutineGeneration,
               prefix: schema,
               log: false
             )

    assert MigrationRepo.get!(RecommendationProfile, profile.id) == profile
    assert MigrationRepo.get!(RecommendationRun, published.id) == published
    assert MigrationRepo.get!(RecommendationRun, pending.id) == pending
    assert MigrationRepo.get!(Oban.Job, unrelated.id) == unrelated
    assert MigrationRepo.get!(Oban.Job, seal.id).state == "cancelled"

    assert [generate] =
             MigrationRepo.all(
               from(j in Oban.Job,
                 where: j.worker == "Comma.Workers.RecommendationGenerate"
               )
             )

    assert generate.args == %{"run_id" => pending.id}
    assert generate.queue == "comma_recommendations"

    assert [deadline] =
             MigrationRepo.all(
               from(j in Oban.Job,
                 where: j.worker == "Comma.Workers.RecommendationRunTimeout"
               )
             )

    assert deadline.args == %{"run_id" => pending.id}
    assert DateTime.diff(deadline.scheduled_at, pending.inserted_at) == 480

    assert [reconcile] =
             MigrationRepo.all(
               from(j in Oban.Job,
                 where: j.worker == "Comma.Workers.RecommendationReconcile"
               )
             )

    assert reconcile.args == %{"profile_id" => profile.id, "retire_renderer" => true}
    assert reconcile.queue == "comma_recommendation_control"
  end
end
