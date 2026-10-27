defmodule Comma.RecommendationsTest do
  use Comma.DataCase, async: false
  use Oban.Testing, repo: Comma.Repo

  import Ecto.Query

  alias Comma.Data.{RecommendationProfile, RecommendationRun, Workspace, WorkspaceMembership}
  alias Comma.{Recommendations, Repo}
  alias SalixStore.Ids

  test "source reconciliation preserves choices, auto-enables new ids, and invalidates disconnected snapshots" do
    {profile, _workspace} = profile_fixture!()
    github = source("mpb-github", "github")

    assert {:ok, first} = Recommendations.reconcile_discovered_sources(profile.id, [github])
    assert first.source_revision == 1
    assert [%{"connectionId" => "mpb-github", "enabled" => true}] = first.sources

    {:ok, disabled} =
      first
      |> RecommendationProfile.settings_changeset(%{
        schedule_enabled: first.schedule_enabled,
        schedule_hour: first.schedule_hour,
        schedule_minute: first.schedule_minute,
        timezone: first.timezone,
        auto_enable_new_sources: true,
        sources: [Map.put(hd(first.sources), "enabled", false)],
        source_revision: first.source_revision + 1,
        snapshot: %{"old" => true},
        snapshot_source_revision: first.source_revision + 1
      })
      |> Repo.update()

    notion = source("account-notion", "notion", "composio")

    assert {:ok, expanded} =
             Recommendations.reconcile_discovered_sources(profile.id, [github, notion])

    assert Enum.find(expanded.sources, &(&1["connectionId"] == "mpb-github"))["enabled"] == false

    assert Enum.find(expanded.sources, &(&1["connectionId"] == "account-notion"))["enabled"] ==
             true

    assert expanded.source_revision == disabled.source_revision + 1
    # An added source leaves every source the snapshot read selected.
    assert expanded.snapshot == %{"old" => true}
    assert expanded.snapshot_source_revision == expanded.source_revision

    assert {:ok, disconnected} = Recommendations.reconcile_discovered_sources(profile.id, [])
    assert disconnected.sources == []
    assert disconnected.source_revision == expanded.source_revision + 1
    assert disconnected.snapshot == nil
  end

  test "a selected source change schedules one replacement and stale jobs cannot replace a newer run" do
    {profile, _workspace} = profile_fixture!()

    assert {:ok, changed} =
             Recommendations.reconcile_discovered_sources(profile.id, [
               source("new-account", "github")
             ])

    assert_enqueued(
      worker: Comma.Workers.RecommendationSourceRefresh,
      args: %{profile_id: profile.id, source_revision: changed.source_revision}
    )

    assert {:ok, same} =
             Recommendations.reconcile_discovered_sources(profile.id, [
               source("new-account", "github")
             ])

    assert same.source_revision == changed.source_revision
    assert length(all_enqueued(worker: Comma.Workers.RecommendationSourceRefresh)) == 1

    assert {:ok, result} =
             Recommendations.begin_source_refresh(profile.id, changed.source_revision)

    assert result.run["sourceRevision"] == changed.source_revision

    assert {:ok, duplicate} =
             Recommendations.begin_source_refresh(profile.id, changed.source_revision)

    assert duplicate.run["id"] == result.run["id"]
    assert {:ok, _} = Recommendations.reconcile_discovered_sources(profile.id, [])

    assert {:ok, :skipped} =
             Recommendations.begin_source_refresh(profile.id, changed.source_revision)
  end

  test "an OAuth migration inherits the disabled flag of the Composio account it replaces" do
    {profile, _workspace} = profile_fixture!()
    github = source("account-github-old", "github", "composio") |> Map.put("toolkit", "github")
    linear = source("account-linear", "linear", "composio") |> Map.put("toolkit", "linear")

    assert {:ok, profile} =
             Recommendations.reconcile_discovered_sources(profile.id, [github, linear])

    {:ok, profile} =
      profile
      |> RecommendationProfile.settings_changeset(%{
        schedule_enabled: profile.schedule_enabled,
        schedule_hour: profile.schedule_hour,
        schedule_minute: profile.schedule_minute,
        timezone: profile.timezone,
        auto_enable_new_sources: true,
        sources: Enum.map(profile.sources, &Map.put(&1, "enabled", &1["toolkit"] == "linear")),
        source_revision: profile.source_revision + 1
      })
      |> Repo.update()

    replacement =
      source("account-github-new", "github", "managed_oauth") |> Map.put("toolkit", "github")

    notion = source("account-notion", "notion", "composio") |> Map.put("toolkit", "notion")

    assert {:ok, rotated} =
             Recommendations.reconcile_discovered_sources(profile.id, [
               replacement,
               linear,
               notion
             ])

    assert Enum.map(rotated.sources, &{&1["connectionId"], &1["enabled"]}) == [
             {"account-github-new", false},
             {"account-linear", true},
             {"account-notion", true}
           ]

    # GitHub stayed off, so only Notion joining the selected set moved the revision.
    assert rotated.source_revision == profile.source_revision + 1
  end

  test "an app language change regenerates each Routine once" do
    {profile, workspace} = profile_fixture!()
    user = %{"id" => profile.user_id}

    assert {:ok, _} =
             Recommendations.reconcile_discovered_sources(profile.id, [
               source("lang-github", "github")
             ])

    {:ok, _envelope} = Recommendations.get(user, %{}, workspace.id)
    runs_before = Repo.aggregate(RecommendationRun, :count)
    Repo.delete_all(Oban.Job)

    assert {:ok, %{"locale" => "zh-CN"}} =
             Comma.ProfileAvatar.update(profile.user_id, %{"locale" => "zh-CN"})

    # The save only enqueues the refresh; the request does no generation work.
    assert Repo.aggregate(RecommendationRun, :count) == runs_before

    assert_enqueued(
      worker: Comma.Workers.RecommendationLanguageRefresh,
      args: %{"user_id" => profile.user_id}
    )

    assert :ok =
             perform_job(Comma.Workers.RecommendationLanguageRefresh, %{
               "user_id" => profile.user_id
             })

    assert [%RecommendationRun{trigger: "agent_tool", status: "running"}] =
             Repo.all(
               from(run in RecommendationRun,
                 where:
                   run.profile_id == ^profile.id and like(run.source_message_id, "locale:zh-CN:%")
               )
             )

    # Saving the same language again is not a change.
    Repo.delete_all(Oban.Job)
    assert {:ok, _} = Comma.ProfileAvatar.update(profile.user_id, %{"locale" => "zh-CN"})
    refute_enqueued(worker: Comma.Workers.RecommendationLanguageRefresh)
  end

  test "a duplicate schedule delivery reuses its durable run" do
    {profile, workspace} = profile_fixture!()

    assert {:ok, profile} =
             Recommendations.reserve_runtime(profile.id, runtime_ids(workspace.salix_group_id))

    assert {:ok, _profile} =
             Recommendations.reconcile_discovered_sources(profile.id, [
               source("mpb-github", "github")
             ])

    source_message_id = "schedule:daily:2026-08-14"

    assert {:ok, first} =
             Recommendations.begin_scheduled(
               profile.agent_id,
               profile.session_id,
               source_message_id
             )

    assert {:ok, duplicate} =
             Recommendations.begin_scheduled(
               profile.agent_id,
               profile.session_id,
               source_message_id
             )

    assert duplicate.run["id"] == first.run["id"]
    assert Repo.aggregate(RecommendationRun, :count, :id) == 1
    assert Repo.get!(RecommendationProfile, profile.id).requested_generation == 1
  end

  test "a new scheduled run supersedes an active manual run and clears its evidence" do
    {profile, workspace} = profile_fixture!()
    user = %{"id" => profile.user_id}

    assert {:ok, profile} =
             Recommendations.reserve_runtime(profile.id, runtime_ids(workspace.salix_group_id))

    assert {:ok, _profile} =
             Recommendations.reconcile_discovered_sources(profile.id, [
               source("mpb-github", "github")
             ])

    assert {:ok, %{run: manual_run}} =
             Recommendations.request_refresh(user, %{}, workspace.id, "manual")

    evidence_url = "https://github.com/AFK-surf/Comma/pull/884"

    assert {:ok, recorded} =
             Recommendations.record_source_evidence(manual_run["id"], [
               %{"sourceId" => "mpb-github", "data" => %{"url" => evidence_url}}
             ])

    assert recorded.source_evidence_recorded == true

    assert {:ok, scheduled} =
             Recommendations.begin_scheduled(
               profile.agent_id,
               profile.session_id,
               "schedule:daily:2026-08-18"
             )

    assert scheduled.run["generation"] == manual_run["generation"] + 1

    superseded = Repo.get!(RecommendationRun, manual_run["id"])
    assert superseded.status == "superseded"
    assert superseded.finished_at
    assert superseded.source_evidence == %{}
    assert superseded.source_evidence_recorded == false

    assert Repo.aggregate(
             from(run in RecommendationRun,
               where: run.profile_id == ^profile.id and run.status in ["pending", "running"]
             ),
             :count
           ) == 1
  end

  test "publication rejects recommendation content backed only by a failed source" do
    {profile, workspace} = profile_fixture!()
    user = %{"id" => profile.user_id}

    assert {:ok, _profile} =
             Recommendations.reconcile_discovered_sources(profile.id, [
               source("mpb-github", "github"),
               source("mpb-linear", "linear")
             ])

    assert {:ok, %{run: run}} =
             Recommendations.request_refresh(user, %{}, workspace.id, "manual")

    assert {:ok, _recorded} =
             Recommendations.record_source_evidence(
               run["id"],
               [%{"sourceId" => "mpb-github", "data" => %{"notifications" => []}}],
               [%{"sourceId" => "mpb-linear", "appId" => "linear", "message" => "timeout"}]
             )

    snapshot =
      run
      |> summary_snapshot()
      |> Map.put("cards", [text_card("mpb-linear")])
      |> Map.put("warnings", [
        %{
          "code" => "partial_sources",
          "message" => "Linear could not be read for this briefing.",
          "sourceIds" => ["mpb-linear"]
        }
      ])

    assert {:error, :invalid_recommendation_evidence} =
             Recommendations.publish(run["id"], snapshot)

    failed = Repo.get!(RecommendationRun, run["id"])
    assert failed.status == "failed"
    assert failed.error =~ "invalid_recommendation_evidence"
  end

  test "an invalid publication immediately fails the active run and exposes an error state" do
    {profile, workspace} = profile_fixture!()
    user = %{"id" => profile.user_id}

    assert {:ok, _profile} =
             Recommendations.reconcile_discovered_sources(profile.id, [
               source("mpb-github", "github")
             ])

    assert {:ok, %{run: run}} =
             Recommendations.request_refresh(user, %{}, workspace.id, "manual")

    evidence_url = "https://github.com/AFK-surf/Comma/pull/884"

    assert {:ok, recorded} =
             Recommendations.record_source_evidence(run["id"], [
               %{
                 "sourceId" => "mpb-github",
                 "data" => %{"description" => "Review #{evidence_url} before standup"}
               }
             ])

    assert recorded.source_evidence == %{"mpb-github" => [evidence_url]}
    assert recorded.source_evidence_recorded == true

    assert {:error, :invalid_recommendation_snapshot} =
             Recommendations.publish(run["id"], %{})

    failed = Repo.get!(RecommendationRun, run["id"])
    assert failed.status == "failed"
    assert failed.finished_at
    assert failed.error =~ "invalid_snapshot"
    assert failed.source_evidence == %{}
    assert failed.source_evidence_recorded == false

    assert {:ok, envelope} = Recommendations.get(user, %{}, workspace.id, "UTC")
    assert envelope["state"] == "error"
    assert envelope["snapshot"] == nil
  end

  test "publication rejects unknown fields without persisting them and clears evidence" do
    {profile, workspace} = profile_fixture!()
    user = %{"id" => profile.user_id}

    assert {:ok, _profile} =
             Recommendations.reconcile_discovered_sources(profile.id, [
               source("mpb-github", "github")
             ])

    assert {:ok, %{run: run}} =
             Recommendations.request_refresh(user, %{}, workspace.id, "manual")

    evidence_url = "https://github.com/AFK-surf/Comma/pull/884"

    assert {:ok, recorded} =
             Recommendations.record_source_evidence(run["id"], [
               %{
                 "sourceId" => "mpb-github",
                 "data" => %{"url" => evidence_url}
               }
             ])

    assert recorded.source_evidence == %{"mpb-github" => [evidence_url]}
    assert recorded.source_evidence_recorded == true

    invalid_snapshot =
      run
      |> summary_snapshot()
      |> Map.put("rawProviderPayload", %{"url" => evidence_url, "private" => "must-not-persist"})

    assert {:error, :invalid_recommendation_snapshot} =
             Recommendations.publish(run["id"], invalid_snapshot)

    failed = Repo.get!(RecommendationRun, run["id"])
    assert failed.status == "failed"
    assert failed.finished_at
    assert failed.error =~ "invalid_snapshot"
    assert failed.source_evidence == %{}
    assert failed.source_evidence_recorded == false

    persisted_profile = Repo.get!(RecommendationProfile, profile.id)
    assert persisted_profile.snapshot == nil

    assert {:ok, envelope} = Recommendations.get(user, %{}, workspace.id, "UTC")
    assert envelope["state"] == "error"
    assert envelope["snapshot"] == nil
  end

  test "verified source consent is member-scoped and preserves the refresh schedule" do
    {profile, workspace} = profile_fixture!()
    user = %{"id" => profile.user_id}

    profile
    |> Ecto.Changeset.change(schedule_hour: 14, schedule_minute: 25, schedule_enabled: false)
    |> Repo.update!()

    assert {:ok, :ok} =
             Comma.MemberSourceConsents.record(
               user,
               %{},
               workspace.id,
               "gmail",
               "ca-mail"
             )

    assert {:ok, :ok} =
             Comma.MemberSourceConsents.record(
               user,
               %{},
               workspace.id,
               "googlecalendar",
               "ca-calendar"
             )

    assert {:ok, :ok} =
             Comma.MemberSourceConsents.record(
               user,
               %{},
               workspace.id,
               "gmail",
               "ca-new-mail"
             )

    assert {:error, :forbidden} =
             Comma.MemberSourceConsents.record(
               %{"id" => "other-user"},
               %{},
               workspace.id,
               "gmail",
               "ca-other"
             )

    assert {:error, :invalid_member_source_consent} =
             Comma.MemberSourceConsents.record(
               user,
               %{},
               workspace.id,
               "unknown",
               "ca-other"
             )

    stored = Repo.get!(RecommendationProfile, profile.id)

    assert Comma.MemberSourceConsents.connection_id(workspace.id, user["id"], "gmail") ==
             "ca-new-mail"

    assert Comma.MemberSourceConsents.connection_id(workspace.id, user["id"], "googlecalendar") ==
             "ca-calendar"

    assert stored.schedule_hour == 14 and stored.schedule_minute == 25
    refute stored.schedule_enabled
    assert stored.timezone == profile.timezone
    assert {:ok, envelope} = Recommendations.get(user, %{}, workspace.id)
    refute Map.has_key?(envelope["settings"], "source_consents")
    refute Map.has_key?(envelope["settings"], "sourceConsents")
  end

  test "publication keeps run metrics after settlement and copies them to the profile" do
    {profile, workspace} = profile_fixture!()
    user = %{"id" => profile.user_id}
    url = "https://github.com/comma/comma/pull/7"

    assert {:ok, _profile} =
             Recommendations.reconcile_discovered_sources(profile.id, [
               source("mpb-github", "github")
             ])

    assert {:ok, %{run: run}} =
             Recommendations.request_refresh(user, %{}, workspace.id, "manual")

    assert {:ok, _recorded} =
             Recommendations.record_source_evidence(run["id"], [
               %{"sourceId" => "mpb-github", "data" => %{"notifications" => [%{"url" => url}]}}
             ])

    snapshot =
      Map.put(summary_snapshot(run), "summary", [
        %{"kind" => "markdown", "text" => "One review waits for you: "},
        %{
          "kind" => "inline-link",
          "link" => %{"href" => url, "label" => "PR 7", "sourceId" => "mpb-github"}
        }
      ])

    collected = %{"variant" => "generic", "sources" => %{"collected" => 1, "failed" => 0}}

    assert {:ok, {:published, _envelope}} =
             Recommendations.publish(run["id"], snapshot, collected)

    expected =
      Map.put(collected, "projection", %{
        "cards" => 0,
        "rows" => 0,
        "links" => 1,
        "warnings" => 0
      })

    settled = Repo.get!(RecommendationRun, run["id"])
    assert settled.status == "published"
    assert settled.source_evidence == %{}
    assert settled.metrics == expected
    assert Repo.get!(RecommendationProfile, profile.id).published_metrics == expected
  end

  test "a hidden row that the member summary does not cite leaves the summary whole" do
    link = fn id ->
      %{
        "kind" => "inline-link",
        "link" => %{
          "href" => "https://linear.app/team/issue/#{id}",
          "label" => id,
          "promptId" => id,
          "sourceId" => "linear"
        }
      }
    end

    ids = ~w(p1 p2 p3 p4)

    # The member summary cites the first three of its four rows.
    summary = [
      %{
        "kind" => "markdown",
        "text" => "Your briefing\n\nHere is what I suggest you focus on: Review p1 "
      },
      link.("p1"),
      %{"kind" => "markdown", "text" => "; Review p2 "},
      link.("p2"),
      %{"kind" => "markdown", "text" => "; Review p3 "},
      link.("p3"),
      %{"kind" => "markdown", "text" => "."}
    ]

    snapshot = %{
      "summary" => summary,
      "cards" => [
        %{
          "id" => "linear",
          "items" =>
            Enum.map(ids, fn id ->
              %{"id" => id, "parts" => [link.(id)], "action" => %{"promptId" => id}}
            end)
        }
      ],
      "prompts" => Map.new(ids, &{&1, %{"objective" => "Review #{&1}"}})
    }

    hidden =
      Recommendations.hide_items(snapshot, fn _source, url -> String.ends_with?(url, "p4") end)

    assert hidden["summary"] == summary
    assert [%{"items" => rows}] = hidden["cards"]
    assert Enum.map(rows, & &1["id"]) == ~w(p1 p2 p3)
    assert hidden["prompts"] |> Map.keys() |> Enum.sort() == ~w(p1 p2 p3)
  end

  defp profile_fixture! do
    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "recommendation-#{SystemsRuntime.Proc.unique_integer([:positive])}@comma.test"
      })

    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)

    workspace =
      %Workspace{}
      |> Workspace.changeset(%{
        id: "wsp-recommendation-#{SystemsRuntime.Proc.unique_integer([:positive])}",
        owner_user_id: user["id"],
        salix_tenant_id: tenant_id,
        salix_group_id: group_id,
        group_generation: "generation-1",
        salix_router_agent_id: Ids.new_agent_id(group_id),
        salix_worker_agent_id: Ids.new_agent_id(group_id),
        billing_owner_id: "billing-#{user["id"]}",
        name: "Recommendations",
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
        relevance_mode: "generic",
        timezone: "Asia/Singapore"
      })
      |> Repo.insert!()

    {profile, workspace}
  end

  defp source(id, app, kind \\ "managed_oauth") do
    %{
      "appId" => app,
      "appName" => String.capitalize(app),
      "bindingAlias" => app,
      "connectionId" => id,
      "kind" => kind,
      "label" => app
    }
  end

  defp runtime_ids(group_id) do
    %{
      agent_id: Ids.new_agent_id(group_id),
      session_id: Ids.new_session_id(),
      schedule_id: Ids.new_schedule_id()
    }
  end

  defp summary_snapshot(run) do
    %{
      "cards" => [],
      "generatedAt" => SystemsClock.system_time(:millisecond),
      "generation" => run["generation"],
      "protocolVersion" => 1,
      "sourceRevision" => run["sourceRevision"],
      "summary" => [%{"kind" => "markdown", "text" => "No urgent items today."}],
      "templateCatalogVersion" => 1,
      "warnings" => []
    }
  end

  defp text_card(source_id) do
    %{
      "fallbackText" => "Review the unsupported item",
      "footerAction" => %{
        "label" => "Review",
        "prompt" => "Review the unsupported item",
        "requiresConfirmation" => false,
        "type" => "open_task_form"
      },
      "id" => "unsupported-card",
      "items" => [
        %{
          "action" => %{
            "label" => "Review item",
            "prompt" => "Review the unsupported item",
            "requiresConfirmation" => false,
            "type" => "open_task_form"
          },
          "id" => "unsupported-item",
          "parts" => [%{"kind" => "markdown", "text" => "Unsupported item"}]
        }
      ],
      "sourceIds" => [source_id],
      "template" => "text-list@1",
      "title" => "Unsupported"
    }
  end
end
