defmodule Comma.RecommendationEvidenceLifecycleTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Comma.Data.{RecommendationProfile, RecommendationRun, User, Workspace}
  alias Comma.{Recommendations, Repo}

  test "evidence recording cannot repopulate a run that settles while the write waits" do
    [settler_repo, recorder_repo, probe_repo] = start_independent_repos(3)
    fixture = on_repo(probe_repo, &seed_fixture!/0)
    parent = self()

    settler =
      Task.async(fn ->
        on_repo(settler_repo, fn ->
          Repo.transaction(fn ->
            {:ok, %{rows: [[backend_pid]]}} = Repo.query("SELECT pg_backend_pid()")

            run =
              Repo.one!(
                from(run in RecommendationRun,
                  where: run.id == ^fixture.run.id,
                  lock: "FOR UPDATE"
                )
              )

            send(parent, {:run_locked, backend_pid})

            receive do
              :settle -> :ok
            after
              10_000 -> raise "settlement was not released"
            end

            run
            |> RecommendationRun.changeset(%{
              status: "failed",
              source_evidence: %{},
              source_evidence_recorded: false,
              finished_at: DateTime.utc_now()
            })
            |> Repo.update!()
          end)
        end)
      end)

    assert_receive {:run_locked, blocker_pid}, 5_000

    recorder =
      Task.async(fn ->
        on_repo(recorder_repo, fn ->
          Recommendations.record_source_evidence(fixture.run.id, [
            %{
              "sourceId" => "ca-linear",
              "data" => %{"url" => "https://linear.app/comma/issue/COMMA-143"}
            }
          ])
        end)
      end)

    try do
      assert wait_until_evidence_write_is_blocked(probe_repo, blocker_pid, 5_000)
      send(settler.pid, :settle)

      assert {:ok,
              %RecommendationRun{
                status: "failed",
                source_evidence: %{},
                source_evidence_recorded: false
              }} =
               Task.await(settler, 10_000)

      assert {:error, :run_already_finished} = Task.await(recorder, 10_000)

      terminal = on_repo(probe_repo, fn -> Repo.get!(RecommendationRun, fixture.run.id) end)
      assert terminal.status == "failed"
      assert terminal.source_evidence == %{}
      assert terminal.source_evidence_recorded == false
    after
      if Process.alive?(settler.pid), do: send(settler.pid, :settle)

      Enum.each([settler, recorder], fn task ->
        if Process.alive?(task.pid), do: Task.shutdown(task, 5_000)
      end)

      on_repo(probe_repo, fn -> cleanup_fixture(fixture) end)
    end
  end

  defp wait_until_evidence_write_is_blocked(repo, blocker_pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until_evidence_write_is_blocked(repo, blocker_pid, deadline)
  end

  defp do_wait_until_evidence_write_is_blocked(repo, blocker_pid, deadline) do
    blocked? =
      on_repo(repo, fn ->
        {:ok, %{rows: [[blocked?]]}} =
          Repo.query(
            """
            SELECT EXISTS (
              SELECT 1
              FROM pg_stat_activity activity
              WHERE $1 = ANY(pg_blocking_pids(activity.pid))
                AND activity.query ILIKE 'UPDATE%comma_recommendation_runs%'
            )
            """,
            [blocker_pid]
          )

        blocked?
      end)

    cond do
      blocked? ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(10)
        do_wait_until_evidence_write_is_blocked(repo, blocker_pid, deadline)
    end
  end

  defp start_independent_repos(count) do
    for _index <- 1..count do
      {:ok, repo} = Repo.start_link(name: nil, pool: DBConnection.ConnectionPool, pool_size: 1)
      Process.unlink(repo)

      on_exit(fn ->
        if Process.alive?(repo), do: Supervisor.stop(repo)
      end)

      repo
    end
  end

  defp on_repo(repo, fun) do
    previous = Repo.get_dynamic_repo()
    Repo.put_dynamic_repo(repo)

    try do
      fun.()
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  defp seed_fixture! do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    user_id = "usr_#{suffix}"
    workspace_id = "wsp_recommendation_evidence_#{suffix}"

    %User{}
    |> User.changeset(%{
      id: user_id,
      normalized_email: "recommendation-evidence-#{suffix}@comma.test",
      status: "active"
    })
    |> Repo.insert!()

    workspace =
      %Workspace{}
      |> Workspace.changeset(%{
        id: workspace_id,
        owner_user_id: user_id,
        salix_tenant_id: "ten1_#{suffix}",
        salix_group_id: "grp1_#{suffix}",
        group_generation: "generation-1",
        salix_router_agent_id: "agt1_router_#{suffix}",
        salix_worker_agent_id: "agt1_worker_#{suffix}",
        billing_owner_id: "billing-#{suffix}",
        name: "Recommendation evidence",
        status: "active"
      })
      |> Repo.insert!()

    profile =
      %RecommendationProfile{}
      |> RecommendationProfile.create_changeset(%{
        workspace_id: workspace.id,
        user_id: user_id,
        timezone: "Etc/UTC"
      })
      |> Repo.insert!()

    run =
      %RecommendationRun{}
      |> RecommendationRun.changeset(%{
        profile_id: profile.id,
        generation: 1,
        source_revision: 0,
        trigger: "manual",
        status: "pending"
      })
      |> Repo.insert!()

    %{profile: profile, run: run, user_id: user_id, workspace: workspace}
  end

  defp cleanup_fixture(fixture) do
    Repo.delete_all(from(run in RecommendationRun, where: run.id == ^fixture.run.id))

    Repo.delete_all(
      from(profile in RecommendationProfile, where: profile.id == ^fixture.profile.id)
    )

    Repo.delete_all(from(workspace in Workspace, where: workspace.id == ^fixture.workspace.id))
    Repo.delete_all(from(user in User, where: user.id == ^fixture.user_id))
  end
end
