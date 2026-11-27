defmodule BridgeForTeams.StationTaskNotifierTest do
  use BridgeForTeams.DataCase, async: false

  import Ecto.Query

  alias BridgeForTeams.{Accounts, DailyBrief, Memberships, Orgs, Projects, Repo}
  alias BridgeForTeams.DailyBrief.StationTaskNotifier

  @now ~U[2026-11-19 10:00:00.000000Z]

  defmodule FakeSalix do
    def daily_brief_station_tasks(group_id) do
      owner = SystemsRuntime.get_env(:bridge_for_teams_core, :station_notifier_test_owner)
      SystemsRuntime.Proc.send(owner, {:queried_station_tasks, group_id})

      {:ok, SystemsRuntime.get_env(:bridge_for_teams_core, :station_notifier_test_rows, [])}
    end

    def stillfail_stations(_group_id) do
      case SystemsRuntime.get_env(:bridge_for_teams_core, :station_notifier_test_stations, []) do
        {:error, _} = error -> error
        stations when is_list(stations) -> {:ok, stations}
      end
    end

    def daily_brief_post(request) do
      owner = SystemsRuntime.get_env(:bridge_for_teams_core, :station_notifier_test_owner)
      SystemsRuntime.Proc.send(owner, {:posted_dm, request})

      SystemsRuntime.get_env(
        :bridge_for_teams_core,
        :station_notifier_test_post,
        {:ok, %{channel_id: "D_BOT", ts: "1795082400.000100"}}
      )
    end
  end

  setup do
    :ok = SystemsClock.manual(epoch: @now)
    on_exit(&SystemsClock.reset/0)

    previous = SystemsRuntime.get_env(:bridge_for_teams_core, :salix_client)
    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, FakeSalix)

    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :station_notifier_test_owner,
      SystemsRuntime.Proc.self()
    )

    on_exit(fn ->
      SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, previous)

      for key <- ~w(station_notifier_test_owner station_notifier_test_rows
                    station_notifier_test_stations station_notifier_test_post)a,
          do: SystemsRuntime.delete_env(:bridge_for_teams_core, key)
    end)

    suffix = SystemsRuntime.Proc.unique_integer([:positive])
    {:ok, org} = Orgs.create_org(%{"name" => "Stf #{suffix}", "slug" => "stf-not-#{suffix}"})

    {:ok, alice_user} =
      Accounts.create_user(%{
        "email" => "alice-stf-#{suffix}@example.test",
        "name" => "Alice"
      })

    {:ok, _} = Memberships.put_org_member(org.id, alice_user.id, "member")

    {:ok, alice_slack} =
      DailyBrief.put_member(%{
        org_id: org.id,
        user_id: alice_user.id,
        provider: "slack",
        slack_workspace_id: "T1",
        slack_user_id: "UALICESTF01",
        timezone: "Asia/Shanghai",
        deliver_at: ~T[09:00:00]
      })

    {:ok, project} =
      Projects.create_project(org.id, %{"name" => "StfProj", "slug" => "stf-proj-#{suffix}"},
        creator_user_id: alice_user.id
      )

    group_id = "grp-stf-#{suffix}"

    Repo.update_all(from(p in BridgeForTeams.Schema.Project, where: p.id == ^project.id),
      set: [salix_group_id: group_id]
    )

    {:ok, settings} =
      DailyBrief.put_settings(org.id, %{
        project_id: project.id,
        provider: "slack",
        slack_connect_id: "imc_slack",
        enabled: true
      })

    %{
      org: org,
      project: project,
      group_id: group_id,
      alice_user: alice_user,
      alice_slack: alice_slack,
      settings: settings
    }
  end

  test "delivers Slack and Feishu DMs once per live stop, highlights system cards, and skips stale stops",
       ctx do
    now_ms = DateTime.to_unix(@now, :millisecond)

    SystemsRuntime.put_env(:bridge_for_teams_core, :station_notifier_test_rows, [
      %{
        station_id: "st_mac",
        thread: "c-login",
        title: "Deploy pipeline",
        status: "needs_review",
        attention: "need",
        waits_for: [String.upcase(ctx.alice_user.email)],
        labels: ["card:login"],
        note: "gh auth login needed",
        url: "https://still.fail/c/c-login",
        last_activity_at: now_ms - 60_000
      },
      %{
        station_id: "st_mac",
        thread: "c-stale",
        title: "Yesterday chat",
        status: "needs_review",
        attention: "need",
        waits_for: [ctx.alice_user.email],
        note: "Old question",
        url: "https://still.fail/c/c-stale",
        last_activity_at: now_ms - 3 * 3_600_000
      }
    ])

    assert {:ok, 1} = StationTaskNotifier.run_once(now: @now)

    assert_received {:posted_dm,
                     %{
                       provider: "slack",
                       slack_user_id: "UALICESTF01",
                       text: text,
                       blocks: blocks
                     }}

    assert text =~ "Deploy pipeline"
    assert text =~ "请在页面卡片中完成登录授权"
    assert inspect(blocks) =~ "Monoid 需要确认授权"
    assert inspect(blocks) =~ "https://still.fail/c/c-login"

    # Second run on the same stop sends nothing.
    assert {:ok, 0} = StationTaskNotifier.run_once(now: @now)
    refute_received {:posted_dm, _}

    # Switch org to Feishu and advance the chat to `done` at a newer timestamp.
    {:ok, _alice_feishu} =
      DailyBrief.put_member(%{
        org_id: ctx.org.id,
        user_id: ctx.alice_user.id,
        provider: "feishu",
        app_id: "cli_app1",
        open_id: "ou_alice_1",
        timezone: "Asia/Shanghai",
        deliver_at: ~T[09:00:00]
      })

    {:ok, _feishu_settings} =
      DailyBrief.put_settings(ctx.org.id, %{
        project_id: ctx.project.id,
        provider: "feishu",
        connect_id: "imc_feishu",
        enabled: true
      })

    SystemsRuntime.put_env(:bridge_for_teams_core, :station_notifier_test_rows, [
      %{
        station_id: "st_mac",
        thread: "c-login",
        title: "Deploy pipeline",
        status: "done",
        attention: "done",
        waits_for: [ctx.alice_user.email],
        note: "Merged PR #88",
        url: "https://still.fail/c/c-login",
        last_activity_at: now_ms - 4 * 60_000
      }
    ])

    assert {:ok, 1} = StationTaskNotifier.run_once(now: @now)

    assert_received {:posted_dm,
                     %{
                       provider: "feishu",
                       open_id: "ou_alice_1",
                       card: card
                     }}

    assert inspect(card) =~ "Monoid 任务已完成"
    assert inspect(card) =~ "Merged PR #88"
  end

  test "seeds baseline done tasks silently on first scan, then delivers subsequent done transitions and option card labels",
       ctx do
    now_ms = DateTime.to_unix(@now, :millisecond)

    SystemsRuntime.put_env(:bridge_for_teams_core, :station_notifier_test_rows, [
      %{
        station_id: "st_mac",
        thread: "c-already-done",
        title: "Earlier finished task",
        status: "done",
        attention: "done",
        waits_for: [ctx.alice_user.email],
        note: "Finished before notifier boot",
        url: "https://still.fail/c/c-already-done",
        last_activity_at: now_ms - 120_000
      }
    ])

    # First-ever scan on a member with empty station_task_notified seeds baseline done silently.
    assert {:ok, 0} = StationTaskNotifier.run_once(now: @now)
    refute_received {:posted_dm, _}

    # Subsequent done transition on a task after baseline is initialized delivers a DM,
    # and an options card includes its option labels.
    SystemsRuntime.put_env(:bridge_for_teams_core, :station_notifier_test_rows, [
      %{
        station_id: "st_mac",
        thread: "c-already-done",
        title: "Earlier finished task",
        status: "done",
        attention: "done",
        waits_for: [ctx.alice_user.email],
        note: "Finished before notifier boot",
        url: "https://still.fail/c/c-already-done",
        last_activity_at: now_ms - 120_000
      },
      %{
        station_id: "st_mac",
        thread: "c-new-done",
        title: "Fresh completion",
        status: "done",
        attention: "done",
        waits_for: [ctx.alice_user.email],
        note: "All tests green",
        url: "https://still.fail/c/c-new-done",
        last_activity_at: now_ms - 4 * 60_000
      },
      %{
        station_id: "st_mac",
        thread: "c-options",
        title: "Choose deploy target",
        status: "needs_review",
        attention: "need",
        waits_for: [ctx.alice_user.email],
        labels: ["card:options"],
        card: %{"type" => "options", "options" => [%{"label" => "Staging"}, %{"label" => "Prod"}]},
        note: "Which environment?",
        url: "https://still.fail/c/c-options",
        last_activity_at: now_ms - 2_000
      }
    ])

    assert {:ok, 2} = StationTaskNotifier.run_once(now: @now)

    assert_received {:posted_dm, %{text: opt_text}}
    assert opt_text =~ "包含选项卡片，可直接点选"

    assert_received {:posted_dm, %{text: done_text}}
    assert done_text =~ "Fresh completion"
  end

  test "silently baselines all historical done tasks beyond @max_per_member_per_tick while delivering need tasks",
       ctx do
    now_ms = DateTime.to_unix(@now, :millisecond)

    done_rows =
      for i <- 1..8 do
        %{
          station_id: "st_mac",
          thread: "c-done-#{i}",
          title: "Historical done #{i}",
          status: "done",
          attention: "done",
          waits_for: [ctx.alice_user.email],
          note: "Done #{i}",
          url: "https://still.fail/c/c-done-#{i}",
          last_activity_at: now_ms - (100 + i) * 1_000
        }
      end

    need_rows =
      for i <- 1..2 do
        %{
          station_id: "st_mac",
          thread: "c-need-#{i}",
          title: "Active need #{i}",
          status: "needs_review",
          attention: "need",
          waits_for: [ctx.alice_user.email],
          note: "Need #{i}",
          url: "https://still.fail/c/c-need-#{i}",
          last_activity_at: now_ms - (10 + i) * 1_000
        }
      end

    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :station_notifier_test_rows,
      done_rows ++ need_rows
    )

    # First tick: 8 historical done tasks are baselined silently, only 2 need tasks are delivered.
    assert {:ok, 2} = StationTaskNotifier.run_once(now: @now)
    assert_received {:posted_dm, %{text: text1}}
    assert_received {:posted_dm, %{text: text2}}
    refute_received {:posted_dm, _}
    assert Enum.sort([text1, text2]) |> Enum.all?(&String.contains?(&1, "Active need"))

    # Second tick: none of the remaining historical done tasks leak.
    assert {:ok, 0} = StationTaskNotifier.run_once(now: @now)
    refute_received {:posted_dm, _}

    # New done task after baseline is delivered normally.
    fresh_done = %{
      station_id: "st_mac",
      thread: "c-done-fresh",
      title: "Brand new completion",
      status: "done",
      attention: "done",
      waits_for: [ctx.alice_user.email],
      note: "Just finished",
      url: "https://still.fail/c/c-done-fresh",
      last_activity_at: now_ms - 4 * 60_000
    }

    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :station_notifier_test_rows,
      done_rows ++ need_rows ++ [fresh_done]
    )

    assert {:ok, 1} = StationTaskNotifier.run_once(now: @now)
    assert_received {:posted_dm, %{text: fresh_text}}
    assert fresh_text =~ "Brand new completion"
  end

  test "debounces real-time invalidation signals for 1s and queries only the invalidated group",
       ctx do
    suffix = SystemsRuntime.Proc.unique_integer([:positive])
    {:ok, org_b} = Orgs.create_org(%{"name" => "StfB #{suffix}", "slug" => "stf-not-b-#{suffix}"})

    {:ok, bob_user} =
      Accounts.create_user(%{
        "email" => "bob-stf-#{suffix}@example.test",
        "name" => "Bob"
      })

    {:ok, _} = Memberships.put_org_member(org_b.id, bob_user.id, "member")

    {:ok, _bob_slack} =
      DailyBrief.put_member(%{
        org_id: org_b.id,
        user_id: bob_user.id,
        provider: "slack",
        slack_workspace_id: "T2",
        slack_user_id: "UBOBSTF01",
        timezone: "Asia/Shanghai",
        deliver_at: ~T[09:00:00]
      })

    {:ok, project_b} =
      Projects.create_project(org_b.id, %{"name" => "StfProjB", "slug" => "stf-proj-b-#{suffix}"},
        creator_user_id: bob_user.id
      )

    group_b = "grp-stf-b-#{suffix}"

    Repo.update_all(from(p in BridgeForTeams.Schema.Project, where: p.id == ^project_b.id),
      set: [salix_group_id: group_b]
    )

    {:ok, _settings_b} =
      DailyBrief.put_settings(org_b.id, %{
        project_id: project_b.id,
        provider: "slack",
        slack_connect_id: "imc_slack_b",
        enabled: true
      })

    now_ms = DateTime.to_unix(@now, :millisecond)

    SystemsRuntime.put_env(:bridge_for_teams_core, :station_notifier_test_rows, [
      %{
        station_id: "st_mac",
        thread: "c-realtime",
        title: "Urgent review",
        status: "needs_review",
        attention: "need",
        waits_for: [ctx.alice_user.email],
        note: "Please approve",
        url: "https://still.fail/c/c-realtime",
        last_activity_at: now_ms - 5_000
      }
    ])

    {:ok, pid} =
      start_supervised(
        {StationTaskNotifier,
         name: :"station_task_notifier_test_#{suffix}",
         interval_ms: 60_000,
         debounce_ms: 1_000,
         run_opts: [now: @now]}
      )

    # Burst 3 invalidation signals for group A only.
    for _ <- 1..3 do
      SystemsRuntime.Proc.send(pid, {:station_tasks_invalidated, ctx.group_id})
    end

    # Synchronize with the GenServer mailbox before advancing virtual time.
    _ = :sys.get_state(pid)

    # At 500ms, debounce has not fired yet.
    SystemsClock.advance(500)
    _ = :sys.get_state(pid)
    refute_received {:queried_station_tasks, _}
    refute_received {:posted_dm, _}

    # At 1_000ms total, debounce fires once and queries ONLY group A (never group B).
    SystemsClock.advance(500)
    _ = :sys.get_state(pid)

    group_a = ctx.group_id
    assert_received {:queried_station_tasks, ^group_a}
    refute_received {:queried_station_tasks, ^group_a}
    refute_received {:queried_station_tasks, ^group_b}

    assert_received {:posted_dm, %{slack_user_id: "UALICESTF01", text: rt_text}}
    assert rt_text =~ "Urgent review"
  end

  test "defers unread done notifications for 3 minutes without recording dedupe, then delivers once grace elapses",
       ctx do
    now_ms = DateTime.to_unix(@now, :millisecond)

    # Seed baseline first so subsequent done transitions are eligible.
    SystemsRuntime.put_env(:bridge_for_teams_core, :station_notifier_test_rows, [])
    assert {:ok, 0} = StationTaskNotifier.run_once(now: @now)

    done_at = now_ms - 60_000

    SystemsRuntime.put_env(:bridge_for_teams_core, :station_notifier_test_rows, [
      %{
        station_id: "st_mac",
        thread: "c-grace-done",
        title: "Grace period task",
        status: "done",
        attention: "done",
        waits_for: [ctx.alice_user.email],
        note: "Finished 1m ago",
        url: "https://still.fail/c/c-grace-done",
        last_activity_at: done_at
      }
    ])

    # Within 3 minutes: deferred, not sent, not recorded in station_task_notified.
    assert {:ok, 0} = StationTaskNotifier.run_once(now: @now)
    refute_received {:posted_dm, _}

    reloaded = Repo.get!(BridgeForTeams.Schema.DailyBriefMember, ctx.alice_slack.id)
    refute Map.has_key?(reloaded.station_task_notified, "st_mac:c-grace-done")

    # Still within 3 minutes at +119s (total 179s since done_at).
    assert {:ok, 0} = StationTaskNotifier.run_once(now: DateTime.add(@now, 119, :second))
    refute_received {:posted_dm, _}

    # At +120s (total 180s == 3m since done_at): delivered once.
    later = DateTime.add(@now, 120, :second)
    assert {:ok, 1} = StationTaskNotifier.run_once(now: later)
    assert_received {:posted_dm, %{slack_user_id: "UALICESTF01", text: text}}
    assert text =~ "Grace period task"

    # Subsequent tick does not re-send.
    assert {:ok, 0} = StationTaskNotifier.run_once(now: DateTime.add(later, 30, :second))
    refute_received {:posted_dm, _}
  end

  test "defers ordinary need/failed only for the active member's matching email while system auth cards deliver immediately",
       ctx do
    suffix = SystemsRuntime.Proc.unique_integer([:positive])
    now_ms = DateTime.to_unix(@now, :millisecond)

    # Add Bob to the same org & Daily Brief.
    {:ok, bob_user} =
      Accounts.create_user(%{
        "email" => "bob-presence-#{suffix}@example.test",
        "name" => "Bob"
      })

    {:ok, _} = Memberships.put_org_member(ctx.org.id, bob_user.id, "member")

    {:ok, _bob_slack} =
      DailyBrief.put_member(%{
        org_id: ctx.org.id,
        user_id: bob_user.id,
        provider: "slack",
        slack_workspace_id: "T1",
        slack_user_id: "UBOBPRES01",
        timezone: "Asia/Shanghai",
        deliver_at: ~T[09:00:00]
      })

    # Seed baseline for both Alice and Bob.
    SystemsRuntime.put_env(:bridge_for_teams_core, :station_notifier_test_rows, [])
    assert {:ok, 0} = StationTaskNotifier.run_once(now: @now)

    # Alice is actively using Monoid (30s ago) on a connected station; Bob is not.
    SystemsRuntime.put_env(:bridge_for_teams_core, :station_notifier_test_stations, [
      %{
        "id" => "dev_alice",
        "connected" => true,
        "owner_email" => String.upcase(ctx.alice_user.email),
        "owner_active_at" => now_ms - 30_000
      }
    ])

    SystemsRuntime.put_env(:bridge_for_teams_core, :station_notifier_test_rows, [
      %{
        station_id: "st_mac",
        thread: "c-alice-need",
        title: "Alice ordinary question",
        status: "needs_review",
        attention: "need",
        waits_for: [ctx.alice_user.email],
        note: "Pick approach",
        url: "https://still.fail/c/c-alice-need",
        last_activity_at: now_ms - 30_000
      },
      %{
        station_id: "st_mac",
        thread: "c-alice-failed",
        title: "Alice failed build",
        status: "in_progress",
        attention: "failed",
        waits_for: [ctx.alice_user.email],
        note: "Compile error",
        url: "https://still.fail/c/c-alice-failed",
        last_activity_at: now_ms - 45_000
      },
      %{
        station_id: "st_mac",
        thread: "c-alice-login",
        title: "Alice urgent login",
        status: "needs_review",
        attention: "need",
        labels: ["card:login"],
        waits_for: [ctx.alice_user.email],
        note: "gh auth login",
        url: "https://still.fail/c/c-alice-login",
        last_activity_at: now_ms - 10_000
      },
      %{
        station_id: "st_mac",
        thread: "c-bob-need",
        title: "Bob ordinary question",
        status: "needs_review",
        attention: "need",
        waits_for: [bob_user.email],
        note: "Approve deploy",
        url: "https://still.fail/c/c-bob-need",
        last_activity_at: now_ms - 20_000
      }
    ])

    # Tick 1: Alice's urgent login card + Bob's ordinary need deliver immediately (2 total);
    # Alice's ordinary need and failed are deferred because Alice is active.
    assert {:ok, 2} = StationTaskNotifier.run_once(now: @now)

    assert_received {:posted_dm, %{slack_user_id: "UALICESTF01", text: alice_login_text}}
    assert alice_login_text =~ "Alice urgent login"

    assert_received {:posted_dm, %{slack_user_id: "UBOBPRES01", text: bob_text}}
    assert bob_text =~ "Bob ordinary question"
    refute_received {:posted_dm, _}

    # Tick 2 (+90s, so Alice's need is 120s old and failed is 135s old, past 2m defer window):
    # even if Alice is still active, both deferred stops now deliver.
    later = DateTime.add(@now, 90, :second)
    later_ms = DateTime.to_unix(later, :millisecond)

    SystemsRuntime.put_env(:bridge_for_teams_core, :station_notifier_test_stations, [
      %{
        "id" => "dev_alice",
        "connected" => true,
        "owner_email" => ctx.alice_user.email,
        "owner_active_at" => later_ms - 10_000
      }
    ])

    assert {:ok, 2} = StationTaskNotifier.run_once(now: later)
    assert_received {:posted_dm, %{slack_user_id: "UALICESTF01", text: t1}}
    assert_received {:posted_dm, %{slack_user_id: "UALICESTF01", text: t2}}
    assert Enum.sort([t1, t2]) |> Enum.any?(&String.contains?(&1, "Alice ordinary question"))
    assert Enum.sort([t1, t2]) |> Enum.any?(&String.contains?(&1, "Alice failed build"))
    refute_received {:posted_dm, _}
  end

  test "matches participants for failed, done, unassigned need, and legacy needs_review while isolating assigned need cards and unrelated members",
       ctx do
    suffix = SystemsRuntime.Proc.unique_integer([:positive])
    now_ms = DateTime.to_unix(@now, :millisecond)

    {:ok, bob_user} =
      Accounts.create_user(%{
        "email" => "bob-part-#{suffix}@example.test",
        "name" => "Bob"
      })

    {:ok, carol_user} =
      Accounts.create_user(%{
        "email" => "carol-unrel-#{suffix}@example.test",
        "name" => "Carol"
      })

    for {user, slack_id} <- [{bob_user, "UBOBPART01"}, {carol_user, "UCAROLUNR01"}] do
      {:ok, _} = Memberships.put_org_member(ctx.org.id, user.id, "member")

      {:ok, _} =
        DailyBrief.put_member(%{
          org_id: ctx.org.id,
          user_id: user.id,
          provider: "slack",
          slack_workspace_id: "T1",
          slack_user_id: slack_id,
          timezone: "Asia/Shanghai",
          deliver_at: ~T[09:00:00]
        })
    end

    # Seed baseline for Alice, Bob, and Carol.
    SystemsRuntime.put_env(:bridge_for_teams_core, :station_notifier_test_rows, [])
    assert {:ok, 0} = StationTaskNotifier.run_once(now: @now)

    SystemsRuntime.put_env(:bridge_for_teams_core, :station_notifier_test_rows, [
      # 1. Failed task: Bob is only in participants -> Bob and Alice (creator) both receive it.
      %{
        station_id: "st_mac",
        thread: "c-part-failed",
        title: "Participant failed build",
        status: "in_progress",
        attention: "failed",
        created_by: ctx.alice_user.email,
        waits_for: [],
        participants: [String.upcase(bob_user.email)],
        note: "CI red",
        url: "https://still.fail/c/c-part-failed",
        last_activity_at: now_ms - 60_000
      },
      # 2. Done task past 3m grace: Bob is only in participants -> Bob and Alice (creator) both receive it.
      %{
        station_id: "st_mac",
        thread: "c-part-done",
        title: "Participant finished deploy",
        status: "done",
        attention: "done",
        created_by: ctx.alice_user.email,
        waits_for: [],
        participants: [bob_user.email],
        note: "Deployed",
        url: "https://still.fail/c/c-part-done",
        last_activity_at: now_ms - 4 * 60_000
      },
      # 3. Unassigned need (waits_for == []): Bob is in participants -> Bob and Alice receive it.
      %{
        station_id: "st_mac",
        thread: "c-part-need-open",
        title: "Open need question",
        status: "needs_review",
        attention: "need",
        created_by: ctx.alice_user.email,
        waits_for: [],
        participants: [bob_user.email],
        note: "Any preference?",
        url: "https://still.fail/c/c-part-need-open",
        last_activity_at: now_ms - 30_000
      },
      # 4. Assigned need (waits_for == [alice]): ONLY Alice receives it, NOT Bob even though Bob is in participants.
      %{
        station_id: "st_mac",
        thread: "c-part-need-assigned",
        title: "Alice-only approval card",
        status: "needs_review",
        attention: "need",
        created_by: ctx.alice_user.email,
        waits_for: [ctx.alice_user.email],
        participants: [bob_user.email],
        labels: ["card:options"],
        note: "Assigned to Alice",
        url: "https://still.fail/c/c-part-need-assigned",
        last_activity_at: now_ms - 20_000
      },
      # 5. Legacy row missing :participants key altogether -> still works without error for Alice.
      %{
        station_id: "st_mac",
        thread: "c-no-part-key",
        title: "Legacy row without participants",
        status: "needs_review",
        attention: nil,
        created_by: ctx.alice_user.email,
        waits_for: [],
        note: "Old station",
        url: "https://still.fail/c/c-no-part-key",
        last_activity_at: now_ms - 10_000
      }
    ])

    # Expected: Alice gets all 5; Bob gets 3 (failed, done, open need; NOT Alice-only approval);
    # Carol (unrelated) gets 0 -> total 8.
    assert {:ok, 8} = StationTaskNotifier.run_once(now: @now)

    posted =
      for _ <- 1..8 do
        assert_received {:posted_dm, dm}
        dm
      end

    refute_received {:posted_dm, _}

    by_user = Enum.group_by(posted, & &1.slack_user_id, & &1.text)

    bob_texts = Map.get(by_user, "UBOBPART01", [])
    assert length(bob_texts) == 3
    assert Enum.any?(bob_texts, &(&1 =~ "Participant failed build"))
    assert Enum.any?(bob_texts, &(&1 =~ "Participant finished deploy"))
    assert Enum.any?(bob_texts, &(&1 =~ "Open need question"))
    refute Enum.any?(bob_texts, &(&1 =~ "Alice-only approval card"))

    alice_texts = Map.get(by_user, "UALICESTF01", [])
    assert length(alice_texts) == 5
    assert Enum.any?(alice_texts, &(&1 =~ "Alice-only approval card"))
    assert Enum.any?(alice_texts, &(&1 =~ "Legacy row without participants"))

    assert Map.get(by_user, "UCAROLUNR01", []) == []
  end
end
