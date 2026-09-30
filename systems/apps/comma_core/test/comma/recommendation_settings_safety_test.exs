defmodule Comma.RecommendationSettingsSafetyTest do
  use Comma.DataCase, async: false

  alias Comma.Data.{RecommendationProfile, Workspace, WorkspaceMembership}
  alias Comma.{Recommendations, Repo}
  alias SalixStore.Ids

  test "an invalid IANA timezone is rejected without persisting and a valid repair succeeds" do
    {profile, workspace} = profile_fixture!()
    user = %{"id" => profile.user_id}

    assert {:error, :invalid_recommendation_settings} =
             Recommendations.update_settings(
               user,
               %{},
               workspace.id,
               settings(profile, "Mars/Phobos")
             )

    unchanged = Repo.get!(RecommendationProfile, profile.id)
    assert unchanged.timezone == "Asia/Singapore"
    assert unchanged.schedule_hour == 8

    assert {:ok, envelope} =
             Recommendations.update_settings(
               user,
               %{},
               workspace.id,
               settings(profile, "America/New_York", 9)
             )

    assert get_in(envelope, ["settings", "schedule", "timezone"]) == "America/New_York"
    assert get_in(envelope, ["settings", "schedule", "hour"]) == 9

    repaired = Repo.get!(RecommendationProfile, profile.id)
    assert repaired.timezone == "America/New_York"
    assert repaired.schedule_hour == 9
    assert match?({:ok, _datetime}, DateTime.now(repaired.timezone))
  end

  test "member mode changes save atomically, preserve schedule, and invalidate old work" do
    {profile, workspace} = profile_fixture!()

    attrs =
      settings(profile, profile.timezone, profile.schedule_hour)
      |> Map.merge(%{
        "relevanceMode" => "generic"
      })

    assert {:ok, envelope} =
             Recommendations.update_settings(%{"id" => profile.user_id}, %{}, workspace.id, attrs)

    assert envelope["settings"]["relevanceMode"] == "generic"
    updated = Repo.get!(RecommendationProfile, profile.id)
    assert updated.source_revision == profile.source_revision + 1
    assert updated.schedule_hour == profile.schedule_hour
    assert updated.timezone == profile.timezone

    assert {:error, :invalid_recommendation_settings} =
             Recommendations.update_settings(
               %{"id" => profile.user_id},
               %{},
               workspace.id,
               Map.put(attrs, "relevanceMode", "unknown")
             )

    assert Repo.get!(RecommendationProfile, profile.id).source_revision == updated.source_revision

    assert {:ok, _} =
             Recommendations.update_settings(
               %{"id" => profile.user_id},
               %{},
               workspace.id,
               settings(updated, updated.timezone, 9)
             )

    assert Repo.get!(RecommendationProfile, profile.id).source_revision == updated.source_revision
  end

  test "unset profiles use member but explicit generic choices survive" do
    assert Recommendations.relevance_mode(%RecommendationProfile{}) == "member"

    assert Recommendations.relevance_mode(%RecommendationProfile{relevance_mode: "generic"}) ==
             "generic"
  end

  test "new profiles start in member mode without changing the device schedule timezone" do
    {profile, workspace} = profile_fixture!()
    Repo.delete!(profile)

    assert {:ok, envelope} =
             Recommendations.get(%{"id" => profile.user_id}, %{}, workspace.id, "Asia/Singapore")

    assert envelope["settings"]["relevanceMode"] == "member"
    assert envelope["settings"]["schedule"]["timezone"] == "Asia/Singapore"
  end

  defp settings(profile, timezone, hour \\ 10) do
    %{
      "autoEnableNewSources" => profile.auto_enable_new_sources,
      "schedule" => %{
        "enabled" => profile.schedule_enabled,
        "hour" => hour,
        "minute" => profile.schedule_minute,
        "timezone" => timezone
      },
      "sources" => []
    }
  end

  defp profile_fixture! do
    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "recommendation-settings-#{System.unique_integer([:positive])}@comma.test"
      })

    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)

    workspace =
      %Workspace{}
      |> Workspace.changeset(%{
        id: "wsp-recommendation-settings-#{System.unique_integer([:positive])}",
        owner_user_id: user["id"],
        salix_tenant_id: tenant_id,
        salix_group_id: group_id,
        group_generation: "generation-1",
        salix_router_agent_id: Ids.new_agent_id(group_id),
        salix_worker_agent_id: Ids.new_agent_id(group_id),
        billing_owner_id: "billing-#{user["id"]}",
        name: "Recommendation settings",
        status: "active"
      })
      |> Repo.insert!()

    %WorkspaceMembership{}
    |> WorkspaceMembership.changeset(%{
      workspace_id: workspace.id,
      user_id: user["id"],
      role: "owner",
      status: "active"
    })
    |> Repo.insert!()

    profile =
      %RecommendationProfile{}
      |> RecommendationProfile.create_changeset(%{
        workspace_id: workspace.id,
        user_id: user["id"],
        timezone: "Asia/Singapore"
      })
      |> Repo.insert!()

    {profile, workspace}
  end
end

defmodule Comma.RecommendationLockOrderTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Comma.Data.{RecommendationProfile, RecommendationRun, User, Workspace}
  alias Comma.{Recommendations, Repo}

  test "failure settlement waits for the profile before locking its run" do
    assert_profile_first_settlement(:fail)
  end

  test "publication settlement waits for the profile before locking its run" do
    assert_profile_first_settlement(:publish)
  end

  defp assert_profile_first_settlement(kind) do
    [locker_repo, settler_repo, probe_repo] = start_independent_repos(3)
    fixture = on_repo(probe_repo, &seed_fixture!/0)
    parent = self()

    locker =
      Task.async(fn ->
        on_repo(locker_repo, fn ->
          Repo.transaction(fn ->
            {:ok, %{rows: [[backend_pid]]}} = Repo.query("SELECT pg_backend_pid()")

            Repo.one!(
              from(profile in RecommendationProfile,
                where: profile.id == ^fixture.profile.id,
                lock: "FOR UPDATE"
              )
            )

            send(parent, {:profile_locked, backend_pid})

            receive do
              :release_profile -> :ok
            after
              10_000 -> raise "profile lock was not released"
            end
          end)
        end)
      end)

    assert_receive {:profile_locked, blocker_pid}, 5_000

    settler =
      Task.async(fn ->
        on_repo(settler_repo, fn -> settle(kind, fixture) end)
      end)

    {blocked?, probe_result} =
      try do
        blocked? = wait_until_blocked(probe_repo, blocker_pid, 5_000)

        probe_result =
          on_repo(probe_repo, fn ->
            try do
              Repo.transaction(fn ->
                Repo.one!(
                  from(run in RecommendationRun,
                    where: run.id == ^fixture.run.id,
                    lock: "FOR UPDATE NOWAIT"
                  )
                )
              end)
            rescue
              error in Postgrex.Error -> {:lock_error, error}
            end
          end)

        {blocked?, probe_result}
      after
        send(locker.pid, :release_profile)
      end

    try do
      locker_result = Task.await(locker, 10_000)
      settlement_result = Task.await(settler, 10_000)

      assert blocked?, "settlement never reached the profile lock"
      assert {:ok, %RecommendationRun{id: run_id}} = probe_result
      assert run_id == fixture.run.id
      assert settlement_succeeded?(kind, settlement_result)
      assert {:ok, _} = locker_result
    after
      on_repo(probe_repo, fn -> cleanup_fixture(fixture) end)
    end
  end

  defp settle(:fail, fixture), do: Recommendations.fail(fixture.run.id, :test_failure)

  defp settle(:publish, fixture),
    do: Recommendations.publish(fixture.run.id, fixture.snapshot)

  defp settlement_succeeded?(:fail, {:ok, envelope}) when is_map(envelope), do: true

  defp settlement_succeeded?(:publish, {:ok, {:published, envelope}}) when is_map(envelope),
    do: true

  defp settlement_succeeded?(_kind, _result), do: false

  defp wait_until_blocked(repo, blocker_pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_until_blocked(repo, blocker_pid, deadline, false)
  end

  defp wait_until_blocked(repo, blocker_pid, deadline, last_result) do
    if System.monotonic_time(:millisecond) >= deadline do
      last_result
    else
      blocked? =
        on_repo(repo, fn ->
          {:ok, %{rows: [[blocked?]]}} =
            Repo.query(
              """
              SELECT EXISTS (
                SELECT 1
                FROM pg_stat_activity activity
                WHERE $1 = ANY(pg_blocking_pids(activity.pid))
              )
              """,
              [blocker_pid]
            )

          blocked?
        end)

      if blocked? do
        true
      else
        Process.sleep(10)
        wait_until_blocked(repo, blocker_pid, deadline, blocked?)
      end
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
    workspace_id = "wsp_recommendation_lock_#{suffix}"

    %User{}
    |> User.changeset(%{
      id: user_id,
      normalized_email: "recommendation-lock-#{suffix}@comma.test",
      status: "active"
    })
    |> Repo.insert!()

    workspace =
      %Workspace{}
      |> Workspace.changeset(%{
        id: workspace_id,
        owner_user_id: user_id,
        salix_tenant_id: "ten_recommendation_lock_#{suffix}",
        salix_group_id: "grp_recommendation_lock_#{suffix}",
        group_generation: "generation-1",
        salix_router_agent_id: "agt_recommendation_router_#{suffix}",
        salix_worker_agent_id: "agt_recommendation_worker_#{suffix}",
        billing_owner_id: "billing_recommendation_lock_#{suffix}",
        name: "Recommendation lock order",
        status: "active"
      })
      |> Repo.insert!()

    source = %{
      "appId" => "github",
      "appName" => "GitHub",
      "bindingAlias" => "github",
      "connectionId" => "account-github",
      "enabled" => true,
      "kind" => "composio",
      "label" => "GitHub"
    }

    profile =
      %RecommendationProfile{}
      |> RecommendationProfile.create_changeset(%{
        workspace_id: workspace.id,
        user_id: user_id,
        relevance_mode: "generic",
        timezone: "Etc/UTC"
      })
      |> RecommendationProfile.settings_changeset(%{
        schedule_enabled: true,
        schedule_hour: 8,
        schedule_minute: 0,
        timezone: "Etc/UTC",
        auto_enable_new_sources: true,
        sources: [source],
        source_revision: 0
      })
      |> Ecto.Changeset.change(requested_generation: 1)
      |> Repo.insert!()

    run =
      %RecommendationRun{}
      |> RecommendationRun.changeset(%{
        profile_id: profile.id,
        generation: 1,
        source_revision: 0,
        trigger: "manual",
        status: "pending",
        source_evidence: %{"account-github" => []},
        source_evidence_recorded: true
      })
      |> Repo.insert!()

    %{
      profile: profile,
      run: run,
      snapshot: valid_snapshot(run),
      workspace: workspace,
      user_id: user_id
    }
  end

  defp valid_snapshot(run) do
    %{
      "protocolVersion" => 1,
      "generation" => run.generation,
      "sourceRevision" => run.source_revision,
      "generatedAt" => System.system_time(:millisecond),
      "templateCatalogVersion" => 1,
      "summary" => [%{"kind" => "markdown", "text" => "Current priorities"}],
      "cards" => [
        %{
          "id" => "priority",
          "title" => "Priority",
          "template" => "text-list@1",
          "fallbackText" => "Review the current priority.",
          "sourceIds" => ["account-github"],
          "items" => [
            %{
              "id" => "item-1",
              "parts" => [%{"kind" => "markdown", "text" => "Review the open work"}],
              "action" => %{
                "type" => "open_task_form",
                "label" => "Review",
                "requiresConfirmation" => true,
                "prompt" => "Review the open work"
              }
            }
          ]
        }
      ],
      "warnings" => []
    }
  end

  defp cleanup_fixture(fixture) do
    Repo.delete_all(from(run in RecommendationRun, where: run.profile_id == ^fixture.profile.id))

    Repo.delete_all(
      from(profile in RecommendationProfile, where: profile.id == ^fixture.profile.id)
    )

    Repo.delete_all(from(workspace in Workspace, where: workspace.id == ^fixture.workspace.id))
    Repo.delete_all(from(user in User, where: user.id == ^fixture.user_id))
  end
end
