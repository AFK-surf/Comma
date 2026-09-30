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

  test "runtime reservation is stable across duplicate retries" do
    {profile, workspace} = profile_fixture!()

    first_ids = runtime_ids(workspace.salix_group_id)
    second_ids = runtime_ids(workspace.salix_group_id)

    assert {:ok, first} = Recommendations.reserve_runtime(profile.id, first_ids)
    assert {:ok, second} = Recommendations.reserve_runtime(profile.id, second_ids)

    assert {second.agent_id, second.session_id, second.schedule_id} ==
             {first.agent_id, first.session_id, first.schedule_id}
  end

  test "discovering a disabled source preserves the current snapshot and source revision" do
    {profile, _workspace} = profile_fixture!()

    {:ok, profile} =
      profile
      |> RecommendationProfile.settings_changeset(%{
        schedule_enabled: profile.schedule_enabled,
        schedule_hour: profile.schedule_hour,
        schedule_minute: profile.schedule_minute,
        timezone: profile.timezone,
        auto_enable_new_sources: false,
        sources: [],
        source_revision: 3,
        snapshot: %{"generation" => 2},
        snapshot_source_revision: 3
      })
      |> Repo.update()

    assert {:ok, updated} =
             Recommendations.reconcile_discovered_sources(profile.id, [
               source("account-notion", "notion", "composio")
             ])

    assert updated.source_revision == 3
    assert updated.snapshot == %{"generation" => 2}
    assert [%{"enabled" => false}] = updated.sources
  end

  test "updating schedule settings preserves the published snapshot metadata" do
    {profile, workspace} = profile_fixture!()
    user = %{"id" => profile.user_id}
    github = source("account-github", "github", "composio") |> Map.put("enabled", true)
    published_at = DateTime.utc_now()

    {:ok, profile} =
      profile
      |> RecommendationProfile.settings_changeset(%{
        schedule_enabled: true,
        schedule_hour: 8,
        schedule_minute: 0,
        timezone: "Asia/Singapore",
        auto_enable_new_sources: true,
        sources: [github],
        source_revision: 4,
        snapshot: %{"generation" => 7},
        snapshot_source_revision: 4
      })
      |> Ecto.Changeset.change(%{
        requested_generation: 7,
        published_generation: 7,
        last_published_at: published_at
      })
      |> Repo.update()

    assert {:ok, _envelope} =
             Recommendations.update_settings(user, %{}, workspace.id, %{
               "autoEnableNewSources" => true,
               "schedule" => %{
                 "enabled" => true,
                 "hour" => 9,
                 "minute" => 30,
                 "timezone" => "Asia/Singapore"
               },
               "sources" => [%{"connectionId" => "account-github", "enabled" => true}]
             })

    updated = Repo.get!(RecommendationProfile, profile.id)
    assert updated.snapshot == %{"generation" => 7}
    assert updated.snapshot_source_revision == 4
    assert updated.published_generation == 7
    assert updated.last_published_at == published_at
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

  test "native source choices survive repeated empty syncs with the opposite auto-enable default" do
    for enabled <- [false, true] do
      {profile, workspace} = profile_fixture!()
      old = source("old-github", "github", "composio") |> Map.put("enabled", enabled)

      # Existing rows have choices only in sources before the additive migration.
      profile
      |> Ecto.Changeset.change(sources: [old], auto_enable_new_sources: not enabled)
      |> Repo.update!()

      assert {:ok, _} = Recommendations.reconcile_discovered_sources(profile.id, [])
      assert {:ok, _} = Recommendations.reconcile_discovered_sources(profile.id, [])
      assert Repo.get!(RecommendationProfile, profile.id).sources == []

      assert {:ok, _} =
               Recommendations.sync_sources(%{"id" => profile.user_id}, %{}, workspace.id, [
                 source("new-github", "github")
               ])

      assert [%{"enabled" => ^enabled}] = Repo.get!(RecommendationProfile, profile.id).sources

      assert {:ok, _} =
               Recommendations.update_settings(%{"id" => profile.user_id}, %{}, workspace.id, %{
                 "autoEnableNewSources" => enabled,
                 "schedule" => %{
                   "enabled" => true,
                   "hour" => 8,
                   "minute" => 0,
                   "timezone" => "Asia/Singapore"
                 },
                 "sources" => [%{"connectionId" => "new-github", "enabled" => not enabled}]
               })

      assert {:ok, _} = Recommendations.reconcile_discovered_sources(profile.id, [])

      assert {:ok, changed} =
               Recommendations.reconcile_discovered_sources(profile.id, [
                 source("newer-github", "github")
               ])

      assert hd(changed.sources)["enabled"] == not enabled
    end
  end

  test "a schedule change is applied while the source list drifts underneath the settings form" do
    {profile, workspace} = profile_fixture!()
    user = %{"id" => profile.user_id}

    assert {:ok, profile} =
             Recommendations.reconcile_discovered_sources(profile.id, [
               source("account-github", "github", "composio"),
               source("account-linear", "linear", "composio")
             ])

    assert Enum.all?(profile.sources, &(&1["enabled"] == true))

    # The form loaded before Linear was discovered and never saw it.
    assert {:ok, envelope} =
             Recommendations.update_settings(user, %{}, workspace.id, %{
               "autoEnableNewSources" => true,
               "schedule" => %{
                 "enabled" => true,
                 "hour" => 9,
                 "minute" => 0,
                 "timezone" => "Asia/Singapore"
               },
               "sources" => [
                 %{"connectionId" => "account-github", "enabled" => false},
                 %{"connectionId" => "account-disconnected", "enabled" => true}
               ]
             })

    assert get_in(envelope, ["settings", "schedule", "hour"]) == 9

    assert Enum.map(envelope["settings"]["sources"], &{&1["connectionId"], &1["enabled"]}) ==
             [{"account-github", false}, {"account-linear", true}]

    # A schedule-only write leaves every source flag alone.
    assert {:ok, envelope} =
             Recommendations.update_settings(user, %{}, workspace.id, %{
               "autoEnableNewSources" => true,
               "schedule" => %{
                 "enabled" => false,
                 "hour" => 9,
                 "minute" => 0,
                 "timezone" => "Asia/Singapore"
               }
             })

    assert get_in(envelope, ["settings", "schedule", "enabled"]) == false

    assert Enum.map(envelope["settings"]["sources"], &{&1["connectionId"], &1["enabled"]}) ==
             [{"account-github", false}, {"account-linear", true}]

    assert {:error, :invalid_recommendation_settings} =
             Recommendations.update_settings(user, %{}, workspace.id, %{
               "autoEnableNewSources" => true,
               "schedule" => %{
                 "enabled" => true,
                 "hour" => 9,
                 "minute" => 0,
                 "timezone" => "Asia/Singapore"
               },
               "sources" => [%{"connectionId" => "account-github", "enabled" => "yes"}]
             })
  end

  test "a projection read keeps the schedule timezone the settings own" do
    {profile, workspace} = profile_fixture!()
    user = %{"id" => profile.user_id}
    assert profile.timezone == "Asia/Singapore"

    assert {:ok, envelope} = Recommendations.get(user, %{}, workspace.id, "America/New_York")
    assert get_in(envelope, ["settings", "schedule", "timezone"]) == "Asia/Singapore"
    assert envelope["lastError"] == nil
  end

  test "the envelope names the failure class of a failed generation" do
    {profile, workspace} = profile_fixture!()
    user = %{"id" => profile.user_id}

    assert {:ok, _profile} =
             Recommendations.reconcile_discovered_sources(profile.id, [
               source("mpb-github", "github")
             ])

    for {reason, code} <- [
          {{:invalid_snapshot, :invalid_recommendation_cards}, "invalid_projection"},
          {{:agent_failed, "No usable items"}, "renderer_declined"},
          {:source_collection_failed, "source_collection_failed"},
          {{:delivery_failed, {:error, :boom}}, "delivery_failed"},
          {:recommendation_run_timed_out, "timed_out"},
          {:something_else, "failed"}
        ] do
      assert {:ok, %{run: run}} =
               Recommendations.request_refresh(user, %{}, workspace.id, "schedule")

      assert {:ok, envelope} = Recommendations.fail(run["id"], reason)
      assert envelope["state"] == "error"
      assert envelope["lastError"] == code
    end
  end

  test "publication keeps the first six routine cards and eighteen rows instead of failing" do
    {profile, workspace} = profile_fixture!()
    user = %{"id" => profile.user_id}

    assert {:ok, _profile} =
             Recommendations.reconcile_discovered_sources(profile.id, [
               source("mpb-github", "github")
             ])

    assert {:ok, %{run: run}} =
             Recommendations.request_refresh(user, %{}, workspace.id, "manual")

    assert {:ok, _recorded} =
             Recommendations.record_source_evidence(run["id"], [
               %{"sourceId" => "mpb-github", "data" => %{"notifications" => []}}
             ])

    oversized =
      Map.put(
        summary_snapshot(run),
        "cards",
        Enum.map(1..7, fn card_index ->
          text_card("mpb-github")
          |> Map.put("id", "routine-#{card_index}")
          |> Map.put(
            "items",
            Enum.map(1..5, fn item_index ->
              text_card("mpb-github")
              |> hd_item()
              |> Map.put("id", "item-#{card_index}-#{item_index}")
            end)
          )
        end)
      )

    assert {:ok, {:published, envelope}} = Recommendations.publish(run["id"], oversized)

    # Publication no longer leaves a conversational context to compact.
    refute_enqueued(
      worker: Comma.Workers.RecommendationContextSeal,
      args: %{"profile_id" => profile.id}
    )

    cards = envelope["snapshot"]["cards"]
    assert Enum.map(cards, & &1["id"]) == Enum.map(1..6, &"routine-#{&1}")
    # Rows are granted one per card per pass, so six full cards keep three each.
    assert Enum.map(cards, &length(&1["items"])) == [3, 3, 3, 3, 3, 3]
    assert Enum.map(hd(cards)["items"], & &1["id"]) == ["item-1-1", "item-1-2", "item-1-3"]

    stored = Repo.get!(RecommendationProfile, profile.id)
    assert stored.snapshot == envelope["snapshot"]
    assert stored.last_error == nil
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

  test "publication without a durable evidence-recorded marker fails the active run" do
    {profile, workspace} = profile_fixture!()
    user = %{"id" => profile.user_id}

    assert {:ok, _profile} =
             Recommendations.reconcile_discovered_sources(profile.id, [
               source("mpb-github", "github")
             ])

    assert {:ok, %{run: run}} =
             Recommendations.request_refresh(user, %{}, workspace.id, "manual")

    assert {:error, :recommendation_source_evidence_not_recorded} =
             Recommendations.publish(run["id"], summary_snapshot(run))

    failed = Repo.get!(RecommendationRun, run["id"])
    assert failed.status == "failed"
    assert failed.finished_at
    assert failed.error =~ "recommendation_source_evidence_not_recorded"
    assert failed.source_evidence == %{}
    assert failed.source_evidence_recorded == false
  end

  test "a valid result arriving after the run budget cannot publish before the timeout job runs" do
    {profile, workspace} = profile_fixture!()

    assert {:ok, _} =
             Recommendations.reconcile_discovered_sources(profile.id, [
               source("account-github", "github")
             ])

    assert {:ok, %{run: run}} =
             Recommendations.request_refresh(%{"id" => profile.user_id}, %{}, workspace.id)

    assert {:ok, _} =
             Recommendations.record_source_evidence(run["id"], [
               %{"sourceId" => "account-github", "data" => %{}}
             ])

    Repo.get!(RecommendationRun, run["id"])
    |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(), -481, :second))
    |> Repo.update!()

    assert {:ok, {:expired, %{"lastError" => "timed_out", "snapshot" => nil}}} =
             Recommendations.publish(run["id"], summary_snapshot(run))

    assert Repo.get!(RecommendationRun, run["id"]).status == "failed"
  end

  test "publication for an unknown run returns not found" do
    assert {:error, :not_found} =
             Recommendations.publish(
               Ecto.UUID.generate(),
               summary_snapshot(%{"generation" => 1, "sourceRevision" => 0})
             )
  end

  test "recording a no-URL fact allows an evidence-free summary publication" do
    {profile, workspace} = profile_fixture!()
    user = %{"id" => profile.user_id}

    assert {:ok, _profile} =
             Recommendations.reconcile_discovered_sources(profile.id, [
               source("mpb-github", "github")
             ])

    assert {:ok, %{run: run}} =
             Recommendations.request_refresh(user, %{}, workspace.id, "manual")

    assert {:ok, recorded} =
             Recommendations.record_source_evidence(run["id"], [
               %{
                 "sourceId" => "mpb-github",
                 "data" => %{"notifications" => []}
               }
             ])

    assert recorded.source_evidence == %{"mpb-github" => []}
    assert recorded.source_evidence_recorded == true

    assert {:ok, {:published, _envelope}} =
             Recommendations.publish(run["id"], summary_snapshot(run))

    published = Repo.get!(RecommendationRun, run["id"])
    assert published.status == "published"
    assert published.source_evidence == %{}
    assert published.source_evidence_recorded == false
  end

  test "publication drops partial_sources warnings that no recorded failure backs" do
    {profile, workspace} = profile_fixture!()
    user = %{"id" => profile.user_id}

    assert {:ok, _profile} =
             Recommendations.reconcile_discovered_sources(profile.id, [
               source("mpb-github", "github")
             ])

    assert {:ok, %{run: run}} =
             Recommendations.request_refresh(user, %{}, workspace.id, "manual")

    assert {:ok, recorded} =
             Recommendations.record_source_evidence(run["id"], [
               %{"sourceId" => "mpb-github", "data" => %{"notifications" => []}}
             ])

    assert recorded.source_failure_ids == []

    snapshot =
      Map.put(summary_snapshot(run), "warnings", [
        %{
          "code" => "partial_sources",
          "message" => "Some connected sources did not return displayable items."
        },
        %{"code" => "stale", "message" => "Snapshot may be out of date."}
      ])

    assert {:ok, {:published, envelope}} = Recommendations.publish(run["id"], snapshot)

    assert envelope["snapshot"]["warnings"] == [
             %{"code" => "stale", "message" => "Snapshot may be out of date."}
           ]
  end

  test "publication keeps partial_sources warnings backed by a recorded failure" do
    {profile, workspace} = profile_fixture!()
    user = %{"id" => profile.user_id}

    assert {:ok, _profile} =
             Recommendations.reconcile_discovered_sources(profile.id, [
               source("mpb-github", "github"),
               source("mpb-linear", "linear")
             ])

    assert {:ok, %{run: run}} =
             Recommendations.request_refresh(user, %{}, workspace.id, "manual")

    assert {:ok, recorded} =
             Recommendations.record_source_evidence(
               run["id"],
               [%{"sourceId" => "mpb-github", "data" => %{"notifications" => []}}],
               [%{"sourceId" => "mpb-linear", "appId" => "linear", "message" => "timeout"}]
             )

    assert recorded.source_failure_ids == ["mpb-linear"]

    warning = %{
      "code" => "partial_sources",
      "message" => "Linear could not be read for this briefing.",
      "sourceIds" => ["mpb-linear"]
    }

    snapshot = Map.put(summary_snapshot(run), "warnings", [warning])

    assert {:ok, {:published, envelope}} = Recommendations.publish(run["id"], snapshot)
    assert envelope["snapshot"]["warnings"] == [warning]
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

  test "publication keeps sourceId-free partial_sources warnings when any failure exists" do
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

    warning = %{
      "code" => "partial_sources",
      "message" => "One connected source could not be read."
    }

    snapshot = Map.put(summary_snapshot(run), "warnings", [warning])

    assert {:ok, {:published, envelope}} = Recommendations.publish(run["id"], snapshot)
    assert envelope["snapshot"]["warnings"] == [warning]
  end

  test "a repeated manual refresh atomically supersedes the active run and clears its evidence" do
    {profile, workspace} = profile_fixture!()
    user = %{"id" => profile.user_id}

    assert {:ok, _profile} =
             Recommendations.reconcile_discovered_sources(profile.id, [
               source("mpb-github", "github")
             ])

    assert {:ok, %{run: first_run}} =
             Recommendations.request_refresh(user, %{}, workspace.id, "manual")

    evidence_url = "https://github.com/AFK-surf/Comma/pull/884"

    assert {:ok, recorded} =
             Recommendations.record_source_evidence(first_run["id"], [
               %{
                 "sourceId" => "mpb-github",
                 "data" => %{"url" => evidence_url}
               }
             ])

    assert recorded.source_evidence == %{"mpb-github" => [evidence_url]}
    assert recorded.source_evidence_recorded == true

    assert {:ok, %{run: second_run}} =
             Recommendations.request_refresh(user, %{}, workspace.id, "manual")

    assert second_run["generation"] == first_run["generation"] + 1

    superseded = Repo.get!(RecommendationRun, first_run["id"])
    assert superseded.status == "superseded"
    assert superseded.finished_at
    assert superseded.source_evidence == %{}
    assert superseded.source_evidence_recorded == false

    old_jobs =
      Repo.all(
        from(j in Oban.Job, where: fragment("? @> ?", j.args, ^%{"run_id" => first_run["id"]}))
      )

    assert length(old_jobs) == 2
    assert Enum.all?(old_jobs, &(&1.state == "cancelled"))

    active = Repo.get!(RecommendationRun, second_run["id"])
    assert active.status == "pending"
    assert active.source_evidence == %{}
    assert active.source_evidence_recorded == false

    assert Repo.aggregate(
             from(run in RecommendationRun,
               where: run.profile_id == ^profile.id and run.status in ["pending", "running"]
             ),
             :count
           ) == 1
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

  test "source changes supersede an active run and stop exposing refreshing state" do
    {profile, workspace} = profile_fixture!()
    user = %{"id" => profile.user_id}

    assert {:ok, _profile} =
             Recommendations.reconcile_discovered_sources(profile.id, [
               source("account-notion", "notion", "composio")
             ])

    assert {:ok, %{run: run}} =
             Recommendations.request_refresh(user, %{}, workspace.id, "manual")

    assert Repo.get!(RecommendationRun, run["id"]).status == "pending"

    assert {:ok, recorded} =
             Recommendations.record_source_evidence(run["id"], [
               %{
                 "sourceId" => "account-notion",
                 "data" => %{"url" => "https://notion.so/comma/recommendations"}
               }
             ])

    assert recorded.source_evidence != %{}
    assert recorded.source_evidence_recorded == true
    assert {:ok, _profile} = Recommendations.reconcile_discovered_sources(profile.id, [])

    superseded = Repo.get!(RecommendationRun, run["id"])
    assert superseded.status == "superseded"
    assert superseded.finished_at
    assert superseded.source_evidence == %{}
    assert superseded.source_evidence_recorded == false

    assert {:ok, envelope} = Recommendations.get(user, %{}, workspace.id, "UTC")
    assert envelope["state"] == "empty"
    assert envelope["snapshot"] == nil
    assert envelope["settings"]["sources"] == []
  end

  test "a discovered source addition keeps the valid briefing through its replacement run" do
    {profile, workspace} = profile_fixture!()
    user = %{"id" => profile.user_id}
    github = source("mpb-github", "github")
    slack = source("account-slack", "slack", "composio")

    assert {:ok, _profile} = Recommendations.reconcile_discovered_sources(profile.id, [github])
    assert {:ok, %{run: run}} = Recommendations.request_refresh(user, %{}, workspace.id, "manual")

    assert {:ok, _recorded} =
             Recommendations.record_source_evidence(run["id"], [
               %{"sourceId" => "mpb-github", "data" => %{}}
             ])

    assert {:ok, {:published, %{"snapshot" => published}}} =
             Recommendations.publish(run["id"], summary_snapshot(run))

    assert {:ok, added} =
             Recommendations.reconcile_discovered_sources(profile.id, [github, slack])

    assert {:ok, %{"state" => "fresh", "snapshot" => ^published}} =
             Recommendations.get(user, %{}, workspace.id)

    assert {:ok, %{run: replacement}} =
             Recommendations.begin_source_refresh(profile.id, added.source_revision)

    assert {:ok, %{"state" => "refreshing", "snapshot" => ^published}} =
             Recommendations.get(user, %{}, workspace.id)

    assert {:ok,
            %{"state" => "stale", "snapshot" => ^published, "lastError" => "invalid_projection"}} =
             Recommendations.fail(replacement["id"], :invalid_briefing_content)

    # Removing a source the briefing read invalidates it.
    assert {:ok, removed} = Recommendations.reconcile_discovered_sources(profile.id, [slack])
    assert removed.snapshot == nil
    assert {:ok, %{"snapshot" => nil}} = Recommendations.get(user, %{}, workspace.id)
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

  test "a member's fresh rail read emits one exposure with the published variant" do
    {profile, workspace} = profile_fixture!()
    user = %{"id" => profile.user_id}
    handler = "recommendation-exposure-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler,
      [:comma_product, :recommendation, :exposure],
      fn _event, _measurements, metadata, _config -> send(parent, {:exposure, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, _profile} =
             Recommendations.reconcile_discovered_sources(profile.id, [
               source("mpb-github", "github")
             ])

    # Nothing is published yet: a read of an empty rail is not an exposure.
    assert {:ok, %{"state" => "empty"}} =
             Recommendations.get(user, %{}, workspace.id, "UTC", nil, exposure: true)

    refute_received {:exposure, _}

    assert {:ok, %{run: run}} =
             Recommendations.request_refresh(user, %{}, workspace.id, "manual")

    assert {:ok, _recorded} =
             Recommendations.record_source_evidence(run["id"], [
               %{"sourceId" => "mpb-github", "data" => %{"notifications" => []}}
             ])

    assert {:ok, {:published, _envelope}} =
             Recommendations.publish(run["id"], summary_snapshot(run), %{"variant" => "generic"})

    # Settings and refresh preparation read the same envelope without exposure.
    assert {:ok, %{"state" => "fresh"}} = Recommendations.get(user, %{}, workspace.id, "UTC")
    refute_received {:exposure, _}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{"state" => "fresh"}} =
                 Recommendations.get(user, %{}, workspace.id, "UTC", nil, exposure: true)
      end)

    assert_received {:exposure, %{variant: "generic"}}
    refute_received {:exposure, _}

    assert [_, json] = Regex.run(~r/routine_exposure (\{.*\})/, log)

    assert Jason.decode!(json) == %{
             "userId" => profile.user_id,
             "workspaceId" => workspace.id,
             "generation" => run["generation"],
             "variant" => "generic"
           }
  end

  test "unset mode hides a legacy generic snapshot and fences a queued generic result" do
    {profile, workspace} = profile_fixture!()
    user = %{"id" => profile.user_id}

    {:ok, profile} =
      Recommendations.reconcile_discovered_sources(profile.id, [source("legacy-github", "github")])

    {:ok, %{run: run}} = Recommendations.request_refresh(user, %{}, workspace.id, "manual")

    {:ok, _} =
      Recommendations.record_source_evidence(run["id"], [
        %{"sourceId" => "legacy-github", "data" => %{}}
      ])

    profile
    |> Ecto.Changeset.change(
      relevance_mode: nil,
      snapshot: summary_snapshot(run),
      snapshot_source_revision: profile.source_revision,
      published_metrics: %{"variant" => "generic"}
    )
    |> Repo.update!()

    assert {:ok, envelope} = Recommendations.get(user, %{}, workspace.id)
    assert envelope["settings"]["relevanceMode"] == "member"
    assert envelope["snapshot"] == nil
    assert {:ok, {:superseded, _}} = Recommendations.publish(run["id"], summary_snapshot(run))
  end

  defp profile_fixture! do
    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "recommendation-#{System.unique_integer([:positive])}@comma.test"
      })

    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)

    workspace =
      %Workspace{}
      |> Workspace.changeset(%{
        id: "wsp-recommendation-#{System.unique_integer([:positive])}",
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
      "generatedAt" => System.system_time(:millisecond),
      "generation" => run["generation"],
      "protocolVersion" => 1,
      "sourceRevision" => run["sourceRevision"],
      "summary" => [%{"kind" => "markdown", "text" => "No urgent items today."}],
      "templateCatalogVersion" => 1,
      "warnings" => []
    }
  end

  defp hd_item(%{"items" => [item | _]}), do: item

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
