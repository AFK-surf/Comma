defmodule SalixStore.StationTaskSessionsMultiTest do
  use ExUnit.Case, async: false

  alias SalixStore.{Ids, StationReadiness, StationTaskSessions}

  setup do
    tenant = Ids.new_tenant_id()
    group = Ids.new_group_id(tenant)
    conv = Ids.new_conversation_id()
    agent = Ids.new_agent_id(group)
    device = "dev-multi-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    {:ok, tenant: tenant, group: group, conv: conv, agent: agent, device: device}
  end

  test "StationReadiness.multi_session_ready?/1 and check_multi_session/1 enforce capability gate" do
    assert StationReadiness.multi_session_ready?(%{"tasks" => 2, "multi_session_tasks" => true})
    refute StationReadiness.multi_session_ready?(%{"tasks" => 2})
    refute StationReadiness.multi_session_ready?(%{"tasks" => 2, "multi_session_tasks" => false})
    refute StationReadiness.multi_session_ready?(nil)

    assert :ready =
             StationReadiness.check_multi_session(%{"tasks" => 2, "multi_session_tasks" => true})

    assert {:station_outdated, %{"required_capability" => "multi_session_tasks"}} =
             StationReadiness.check_multi_session(%{"tasks" => 2})
  end

  test "rejoin_slot/5 enforces transactional fencing: A->B succeeds, idempotent retry returns :already_current, stale A->A cannot resurrect A",
       ctx do
    lead_start = %{"slot" => "lead", "is_primary" => true, "requester" => "u1"}
    rev_start = %{"slot" => "reviewer", "is_primary" => false, "requester" => "u1"}

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: ctx.conv,
        device_id: ctx.device,
        session: "ses_A",
        agent_id: ctx.agent,
        start: lead_start
      })

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: ctx.conv,
        device_id: ctx.device,
        session: "ses_rev",
        agent_id: ctx.agent,
        start: rev_start
      })

    {:ok, rows} = StationTaskSessions.of_task(ctx.group, ctx.conv)
    old_lead = Enum.find(rows, &(&1.session == "ses_A"))

    # Normal A -> B rejoin
    assert {:ok, :rejoined} =
             StationTaskSessions.rejoin_slot(old_lead, "ses_B", "run_2", lead_start, 5)

    # Idempotent retry with same (ses_B, run_2) returns :already_current without writing
    assert {:ok, :already_current} =
             StationTaskSessions.rejoin_slot(old_lead, "ses_B", "run_2", lead_start, 5)

    # Stale retry A -> A arriving after A -> B returns {:error, :stale} and NEVER resurrects A
    assert {:error, :stale} =
             StationTaskSessions.rejoin_slot(old_lead, "ses_A", "run_1", lead_start, 3)

    # Verify ses_B and ses_rev are intact and ses_A is gone
    {:ok, after_rows} = StationTaskSessions.of_task(ctx.group, ctx.conv)
    sessions = after_rows |> Enum.map(& &1.session) |> Enum.sort()
    assert sessions == ["ses_B", "ses_rev"]
  end

  test "sent/5 fences against concurrent hello reset via expected_sent", ctx do
    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: ctx.conv,
        device_id: ctx.device,
        session: "ses_1",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true}
      })

    assert :ok =
             StationTaskSessions.sent(ctx.group, ctx.conv, ctx.device, 10, expected_sent: 0)

    # Simulate hello resetting fetched to 4
    assert :ok = StationTaskSessions.fetched(ctx.group, ctx.conv, ctx.device, 4)

    # Stale put expecting sent == 10 is fenced and returns :stale
    assert :stale =
             StationTaskSessions.sent(ctx.group, ctx.conv, ctx.device, 15, expected_sent: 10)

    {:ok, [row]} = StationTaskSessions.of_task(ctx.group, ctx.conv)
    assert row.sent == 4
  end

  test "ended_turn/6 updates only the target (device_id, session) and is not truncated by lagged sent",
       ctx do
    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: ctx.conv,
        device_id: ctx.device,
        session: "ses_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true}
      })

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: ctx.conv,
        device_id: ctx.device,
        session: "ses_rev",
        agent_id: ctx.agent,
        start: %{"slot" => "reviewer", "is_primary" => false}
      })

    # Even with sent == 0 (lagged), ended_turn with post_seq=12, answered_through_seq=10 advances lead to 10
    assert :ok =
             StationTaskSessions.ended_turn(ctx.group, ctx.conv, ctx.device, "ses_lead", 12, 10)

    {:ok, rows} = StationTaskSessions.of_task(ctx.group, ctx.conv)
    lead = Enum.find(rows, &(&1.session == "ses_lead"))
    rev = Enum.find(rows, &(&1.session == "ses_rev"))
    assert lead.answered == 10
    assert rev.answered == 0
  end

  test "R1-4/5: sent_sessions leaves newly joined secondary at 0, fetched bumps run_id to fence stale puts, leave_sessions/append_pending_multi_start/delete_non_primary",
       ctx do
    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: ctx.conv,
        device_id: ctx.device,
        session: "ses_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => "run_1"}
      })

    # Snapshot lead at sent=0, then concurrently join secondary ses_rev at sent=0
    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: ctx.conv,
        device_id: ctx.device,
        session: "ses_rev",
        agent_id: ctx.agent,
        start: %{"slot" => "reviewer", "is_primary" => false, "connector_run_id" => "run_1"}
      })

    # sent_sessions for snapshot [{"ses_lead", 0}] advances ONLY ses_lead, leaving ses_rev at 0!
    assert :ok =
             StationTaskSessions.sent_sessions(
               ctx.group,
               ctx.conv,
               ctx.device,
               [{"ses_lead", 0}],
               12,
               "run_1"
             )

    {:ok, rows} = StationTaskSessions.of_task(ctx.group, ctx.conv)
    assert Enum.find(rows, &(&1.session == "ses_lead")).sent == 12
    assert Enum.find(rows, &(&1.session == "ses_rev")).sent == 0

    # hello with new run_id ("run_2") bumps connector_run_id on DB rows, fencing stale run_1 put ACK!
    assert :ok = StationTaskSessions.fetched(ctx.group, ctx.conv, ctx.device, 12, "run_2")

    assert :stale =
             StationTaskSessions.sent_sessions(
               ctx.group,
               ctx.conv,
               ctx.device,
               [{"ses_lead", 12}],
               20,
               "run_1"
             )

    # Stale leave_sessions from run_1 does NOT delete run_2 rows
    assert :ok =
             StationTaskSessions.leave_sessions(
               ctx.group,
               ctx.conv,
               ctx.device,
               ["ses_lead", "ses_rev"],
               "run_1"
             )

    {:ok, still_there} = StationTaskSessions.of_task(ctx.group, ctx.conv)
    assert length(still_there) == 2

    # append_pending_multi_start attaches entry to primary row and dedups by slot
    entry = %{"slot" => "qa", "is_primary" => false, "start" => %{"slot" => "qa"}}

    assert {:ok, _} =
             StationTaskSessions.append_pending_multi_start(
               ctx.group,
               ctx.conv,
               ctx.device,
               entry
             )

    assert {:ok, _} =
             StationTaskSessions.append_pending_multi_start(
               ctx.group,
               ctx.conv,
               ctx.device,
               entry
             )

    {:ok, rows_with_pending} = StationTaskSessions.of_task(ctx.group, ctx.conv)
    lead_row = Enum.find(rows_with_pending, &(&1.session == "ses_lead"))
    assert length(lead_row.start["pending_multi_starts"]) == 1

    # delete_non_primary cleans secondary rows while keeping primary
    assert :ok =
             StationTaskSessions.delete_non_primary(ctx.group, ctx.conv, ctx.device, "ses_lead")

    {:ok, only_lead} = StationTaskSessions.of_task(ctx.group, ctx.conv)
    assert Enum.map(only_lead, & &1.session) == ["ses_lead"]
  end

  test "R2-2/3/4: single-txn recover_device_primary preserves concurrent new secondary & answered, strict run_id fencing on legacy primary, JSONB partial pending_multi_starts",
       ctx do
    # Legacy single-session primary (NO "slot" key in start)
    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: ctx.conv,
        device_id: ctx.device,
        session: "ses_legacy_lead",
        agent_id: ctx.agent,
        answered: 3,
        start: %{"requester" => "u1"}
      })

    # R2-4: hello with run_2 refreshes connector_run_id even on legacy primary without "slot"!
    assert :ok = StationTaskSessions.fetched(ctx.group, ctx.conv, ctx.device, 5, "run_2")

    # Stale gone from run_1 MUST NOT delete the active legacy primary!
    assert :ok =
             StationTaskSessions.leave_sessions(
               ctx.group,
               ctx.conv,
               ctx.device,
               ["ses_legacy_lead"],
               "run_1"
             )

    {:ok, [legacy_alive]} = StationTaskSessions.of_task(ctx.group, ctx.conv)
    assert legacy_alive.session == "ses_legacy_lead"
    assert legacy_alive.start["connector_run_id"] == "run_2"

    # Join an old secondary ("ses_old_rev", answered: 4) and a concurrently added new secondary ("ses_new_qa")
    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: ctx.conv,
        device_id: ctx.device,
        session: "ses_old_rev",
        agent_id: ctx.agent,
        answered: 4,
        start: %{"slot" => "reviewer", "is_primary" => false, "connector_run_id" => "run_2"}
      })

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: ctx.conv,
        device_id: ctx.device,
        session: "ses_new_qa",
        agent_id: ctx.agent,
        answered: 0,
        start: %{"slot" => "qa", "is_primary" => false, "connector_run_id" => "run_2"}
      })

    # R2-3: recover_device_primary deletes ONLY exact snapshot stale secondary ["ses_old_rev"],
    # preserving concurrently added "ses_new_qa" in a single DB transaction!
    pending = [%{"slot" => "reviewer", "answered" => 4, "start" => %{"slot" => "reviewer"}}]

    assert {:ok, :rejoined, committed_pending} =
             StationTaskSessions.recover_device_primary(
               legacy_alive,
               "ses_lead_v2",
               "run_2",
               %{"slot" => "lead", "is_primary" => true, "pending_multi_starts" => pending},
               3,
               ["ses_old_rev"]
             )

    assert [%{"slot" => "reviewer", "answered" => 4}] = committed_pending

    {:ok, after_rec} = StationTaskSessions.of_task(ctx.group, ctx.conv)
    assert Enum.sort(Enum.map(after_rec, & &1.session)) == ["ses_lead_v2", "ses_new_qa"]

    # R2-4: concurrent hello bumps connector_run_id to run_3; remove_pending_multi_starts MUST preserve run_3!
    assert :ok = StationTaskSessions.fetched(ctx.group, ctx.conv, ctx.device, 0, "run_3")

    assert {:ok, 1} =
             StationTaskSessions.remove_pending_multi_starts(
               ctx.group,
               ctx.conv,
               ctx.device,
               ["reviewer"]
             )

    {:ok, after_rm} = StationTaskSessions.of_task(ctx.group, ctx.conv)
    lead_v2 = Enum.find(after_rm, &(&1.session == "ses_lead_v2"))
    assert lead_v2.start["connector_run_id"] == "run_3"
    refute Map.has_key?(lead_v2.start, "pending_multi_starts")
  end

  test "R3-B2: recover_device_primary FOR UPDATE fences stale expected_old_run_id and merges live answered & concurrent pending_multi_starts",
       ctx do
    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: ctx.conv,
        device_id: ctx.device,
        session: "ses_p_live",
        agent_id: ctx.agent,
        answered: 10,
        start: %{
          "slot" => "lead",
          "is_primary" => true,
          "connector_run_id" => "run_live",
          "pending_multi_starts" => [
            %{"slot" => "qa", "answered" => 2, "start" => %{"slot" => "qa"}}
          ]
        }
      })

    {:ok, [live_row]} = StationTaskSessions.of_task(ctx.group, ctx.conv)

    # Stale expected_old_run_id ("run_old" != "run_live") MUST roll back :stale!
    assert {:error, :stale} =
             StationTaskSessions.recover_device_primary(
               %{live_row | answered: 3},
               "ses_p_stale",
               "run_old",
               %{"slot" => "lead", "is_primary" => true},
               3,
               [],
               "run_old"
             )

    # Matching expected_old_run_id merges max(snapshot=3, live=10)=10 AND merges live pending "qa" with incoming "reviewer"!
    # Also verify committed_pending returned directly from recover_device_primary carries upgraded live answered!
    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: ctx.conv,
        device_id: ctx.device,
        session: "ses_rev_live",
        agent_id: ctx.agent,
        answered: 9,
        start: %{"slot" => "reviewer", "is_primary" => false, "connector_run_id" => "run_live"}
      })

    assert {:ok, :rejoined, committed_pending} =
             StationTaskSessions.recover_device_primary(
               %{live_row | answered: 3},
               "ses_p_v2",
               "run_next",
               %{
                 "slot" => "lead",
                 "is_primary" => true,
                 "pending_multi_starts" => [
                   %{"slot" => "reviewer", "answered" => 4, "start" => %{"slot" => "reviewer"}}
                 ]
               },
               3,
               ["ses_rev_live"],
               "run_live"
             )

    rev_committed = Enum.find(committed_pending, &(&1["slot"] == "reviewer"))
    assert rev_committed["answered"] == 9

    {:ok, [rejoined]} = StationTaskSessions.of_task(ctx.group, ctx.conv)
    assert rejoined.session == "ses_p_v2"
    assert rejoined.answered == 10
    assert rejoined.start["connector_run_id"] == "run_next"

    pending_slots =
      rejoined.start["pending_multi_starts"] |> Enum.map(& &1["slot"]) |> Enum.sort()

    assert pending_slots == ["qa", "reviewer"]

    # R4-9: Custom primary alias ("captain", is_primary: true) with lexicographically larger session id
    # is still selected as the pending_multi_starts holder over secondary "reviewer"!
    conv_alias = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_alias,
        device_id: ctx.device,
        session: "zzz_captain",
        agent_id: ctx.agent,
        start: %{"slot" => "captain", "is_primary" => true, "connector_run_id" => "run_cap"}
      })

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_alias,
        device_id: ctx.device,
        session: "aaa_reviewer",
        agent_id: ctx.agent,
        start: %{"slot" => "reviewer", "is_primary" => false, "connector_run_id" => "run_cap"}
      })

    assert {:ok, _} =
             StationTaskSessions.append_pending_multi_start(
               ctx.group,
               conv_alias,
               ctx.device,
               %{"slot" => "qa", "start" => %{"slot" => "qa"}}
             )

    {:ok, alias_rows} = StationTaskSessions.of_task(ctx.group, conv_alias)
    captain_row = Enum.find(alias_rows, &(&1.session == "zzz_captain"))
    rev_row = Enum.find(alias_rows, &(&1.session == "aaa_reviewer"))
    assert [%{"slot" => "qa"}] = captain_row.start["pending_multi_starts"]
    refute Map.has_key?(rev_row.start, "pending_multi_starts")

    # R5-3/4: join ON CONFLICT monotonically upgrades answered (0 -> 9, never 9 -> 2) & rebind_run_id fences old run!
    assert :ok =
             StationTaskSessions.join(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_alias,
               device_id: ctx.device,
               session: "aaa_reviewer",
               agent_id: ctx.agent,
               answered: 9,
               start: %{
                 "slot" => "reviewer",
                 "is_primary" => false,
                 "connector_run_id" => "run_cap"
               }
             })

    assert :ok =
             StationTaskSessions.join(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_alias,
               device_id: ctx.device,
               session: "aaa_reviewer",
               agent_id: ctx.agent,
               answered: 2,
               start: %{
                 "slot" => "reviewer",
                 "is_primary" => false,
                 "connector_run_id" => "run_cap"
               }
             })

    {:ok, alias_rows2} = StationTaskSessions.of_task(ctx.group, conv_alias)
    assert Enum.find(alias_rows2, &(&1.session == "aaa_reviewer")).answered == 9

    assert :stale =
             StationTaskSessions.rebind_run_id(
               ctx.group,
               conv_alias,
               ctx.device,
               "aaa_reviewer",
               "run_wrong",
               "run_new"
             )

    assert :ok =
             StationTaskSessions.rebind_run_id(
               ctx.group,
               conv_alias,
               ctx.device,
               "aaa_reviewer",
               "run_cap",
               "run_new"
             )

    {:ok, alias_rows3} = StationTaskSessions.of_task(ctx.group, conv_alias)

    assert Enum.find(alias_rows3, &(&1.session == "aaa_reviewer")).start["connector_run_id"] ==
             "run_new"

    # R6-2: join ON CONFLICT monotonically upgrades answered WITHOUT overwriting existing connector_run_id or pending_multi_starts!
    assert {:ok, _} =
             StationTaskSessions.append_pending_multi_start(
               ctx.group,
               conv_alias,
               ctx.device,
               %{"slot" => "reviewer", "start" => %{"slot" => "reviewer"}}
             )

    assert :ok =
             StationTaskSessions.join(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_alias,
               device_id: ctx.device,
               session: "zzz_captain",
               agent_id: ctx.agent,
               answered: 9,
               start: %{
                 "slot" => "captain",
                 "is_primary" => true,
                 "connector_run_id" => "run_old_stale",
                 "pending_multi_starts" => [%{"slot" => "reviewer"}]
               }
             })

    {:ok, alias_rows4} = StationTaskSessions.of_task(ctx.group, conv_alias)
    cap_after = Enum.find(alias_rows4, &(&1.session == "zzz_captain"))
    assert cap_after.answered == 9
    assert cap_after.start["connector_run_id"] == "run_cap"

    assert Enum.sort(Enum.map(cap_after.start["pending_multi_starts"], & &1["slot"])) == [
             "qa",
             "reviewer"
           ]

    # R7-2: demote_missing_secondaries atomically moves absent secondary (with locked highest answered)
    # into primary's pending_multi_starts and deletes ONLY that absent secondary row.
    assert :ok =
             StationTaskSessions.ended_turn(
               ctx.group,
               conv_alias,
               ctx.device,
               "aaa_reviewer",
               15,
               15
             )

    {:ok, rows_before_demote} = StationTaskSessions.of_task(ctx.group, conv_alias)

    rev_stale_snap = %{
      Enum.find(rows_before_demote, &(&1.session == "aaa_reviewer"))
      | answered: 2
    }

    assert :ok =
             StationTaskSessions.demote_missing_secondaries(
               ctx.group,
               conv_alias,
               ctx.device,
               [rev_stale_snap]
             )

    {:ok, [only_cap]} = StationTaskSessions.of_task(ctx.group, conv_alias)
    assert only_cap.session == "zzz_captain"

    rev_pending =
      Enum.find(only_cap.start["pending_multi_starts"], &(&1["slot"] == "reviewer"))

    assert rev_pending["answered"] == 15

    # If primary is missing, demote_missing_secondaries rolls back :primary_missing and keeps secondary row intact!
    conv_no_prim = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_no_prim,
        device_id: ctx.device,
        session: "ses_orphan_rev",
        agent_id: ctx.agent,
        answered: 7,
        start: %{"slot" => "reviewer", "is_primary" => false}
      })

    {:ok, [orphan_rev]} = StationTaskSessions.of_task(ctx.group, conv_no_prim)

    assert {:error, :primary_missing} =
             StationTaskSessions.demote_missing_secondaries(
               ctx.group,
               conv_no_prim,
               ctx.device,
               [orphan_rev]
             )

    {:ok, [still_orphan]} = StationTaskSessions.of_task(ctx.group, conv_no_prim)
    assert still_orphan.session == "ses_orphan_rev"

    # R8 P0-2: demote_missing_secondaries/5 fences against stale expected_run_id
    # so a stale generation B cannot delete a session already taken over by generation C!
    conv_fence = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_fence,
        device_id: ctx.device,
        session: "ses_fence_lead",
        agent_id: ctx.agent,
        answered: 0,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => "run_c"}
      })

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_fence,
        device_id: ctx.device,
        session: "ses_fence_rev",
        agent_id: ctx.agent,
        answered: 3,
        start: %{"slot" => "reviewer", "is_primary" => false, "connector_run_id" => "run_c"}
      })

    {:ok, fence_rows} = StationTaskSessions.of_task(ctx.group, conv_fence)

    rev_snap = %{
      Enum.find(fence_rows, &(&1.session == "ses_fence_rev"))
      | start: %{"slot" => "reviewer", "is_primary" => false, "connector_run_id" => "run_a"}
    }

    assert {:error, :stale} =
             StationTaskSessions.demote_missing_secondaries(
               ctx.group,
               conv_fence,
               ctx.device,
               [rev_snap],
               "run_b"
             )

    {:ok, fence_after} = StationTaskSessions.of_task(ctx.group, conv_fence)
    assert length(fence_after) == 2

    assert Enum.find(fence_after, &(&1.session == "ses_fence_lead")).start["pending_multi_starts"] ==
             nil

    # R9 P0-2: replace_awaited atomically inherits concurrently appended pending_multi_starts
    # from the deleted awaited row and returns {:ok, :rejoined, merged_pending}!
    conv_aw = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.expect(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_aw,
        device_id: ctx.device,
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true}
      })

    {:ok, [aw_snap]} = StationTaskSessions.of_task(ctx.group, conv_aw)

    assert {:ok, _} =
             StationTaskSessions.append_pending_multi_start(ctx.group, conv_aw, ctx.device, %{
               "slot" => "qa",
               "is_primary" => false,
               "agent_id" => ctx.agent,
               "start" => %{"slot" => "qa", "is_primary" => false}
             })

    assert {:ok, :rejoined, [%{"slot" => "qa"}]} =
             StationTaskSessions.replace_awaited(
               aw_snap,
               "ses_aw_lead_live",
               "run_aw_1",
               %{"slot" => "lead", "is_primary" => true},
               0
             )

    {:ok, [live_aw]} = StationTaskSessions.of_task(ctx.group, conv_aw)
    assert live_aw.session == "ses_aw_lead_live"
    assert Enum.any?(live_aw.start["pending_multi_starts"] || [], &(&1["slot"] == "qa"))

    # R10 P0-2: join_with_token preserves existing binding_token on conflict and fills when absent;
    # demote_missing_secondaries updates demoted_binding_token when merging into existing pending slot.
    conv_tok = Ids.new_conversation_id()

    assert {:ok, "tok_first"} =
             StationTaskSessions.join_with_token(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_tok,
               device_id: ctx.device,
               session: "ses_tok_lead",
               agent_id: ctx.agent,
               answered: 0,
               start: %{
                 "slot" => "lead",
                 "is_primary" => true,
                 "connector_run_id" => "run_tok",
                 "binding_token" => "tok_first"
               }
             })

    assert {:ok, "tok_first"} =
             StationTaskSessions.join_with_token(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_tok,
               device_id: ctx.device,
               session: "ses_tok_lead",
               agent_id: ctx.agent,
               answered: 2,
               start: %{
                 "slot" => "lead",
                 "is_primary" => true,
                 "connector_run_id" => "run_tok",
                 "binding_token" => "tok_second_ignored"
               }
             })

    # Pre-populate a pending entry for reviewer with stale token, then join + demote with new token
    assert {:ok, _} =
             StationTaskSessions.append_pending_multi_start(ctx.group, conv_tok, ctx.device, %{
               "slot" => "reviewer",
               "is_primary" => false,
               "agent_id" => ctx.agent,
               "answered" => 1,
               "demoted_session" => "ses_rev_old",
               "demoted_binding_token" => "tok_rev_old",
               "start" => %{"slot" => "reviewer", "is_primary" => false}
             })

    assert {:ok, "tok_rev_new"} =
             StationTaskSessions.join_with_token(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_tok,
               device_id: ctx.device,
               session: "ses_rev_new",
               agent_id: ctx.agent,
               answered: 4,
               start: %{
                 "slot" => "reviewer",
                 "is_primary" => false,
                 "connector_run_id" => "run_tok",
                 "binding_token" => "tok_rev_new"
               }
             })

    {:ok, tok_rows} = StationTaskSessions.of_task(ctx.group, conv_tok)
    rev_row = Enum.find(tok_rows, &(&1.session == "ses_rev_new"))

    assert :ok =
             StationTaskSessions.demote_missing_secondaries(
               ctx.group,
               conv_tok,
               ctx.device,
               [rev_row],
               "run_tok"
             )

    {:ok, [lead_after_demote]} = StationTaskSessions.of_task(ctx.group, conv_tok)

    pending_rev =
      Enum.find(lead_after_demote.start["pending_multi_starts"], &(&1["slot"] == "reviewer"))

    assert pending_rev["demoted_session"] == "ses_rev_new"
    assert pending_rev["demoted_binding_token"] == "tok_rev_new"
    assert pending_rev["answered"] == 4

    # R10 P0-3: leave_awaited deletes ONLY awaited rows and never touches active sessions
    conv_la = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.expect(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_la,
        device_id: ctx.device,
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true}
      })

    assert {:ok, :deleted} = StationTaskSessions.leave_awaited(ctx.group, conv_la, ctx.device)
    assert {:ok, []} = StationTaskSessions.of_task(ctx.group, conv_la)
    assert {:ok, :stale} = StationTaskSessions.leave_awaited(ctx.group, conv_la, ctx.device)

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_la,
        device_id: ctx.device,
        session: "ses_la_active",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true}
      })

    assert {:ok, :stale} = StationTaskSessions.leave_awaited(ctx.group, conv_la, ctx.device)
    assert {:ok, [%{session: "ses_la_active"}]} = StationTaskSessions.of_task(ctx.group, conv_la)
  end

  test "R16 P0-1: same-session conflict monotonically preserves GREATEST(old_start_seq, new_start_seq) so late lower-seq session is rejected",
       ctx do
    conv = Ids.new_conversation_id()

    # S joins at seq=1
    assert {:ok, "tok_s1"} =
             StationTaskSessions.join_with_token(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv,
               device_id: ctx.device,
               session: "S",
               agent_id: ctx.agent,
               start: %{
                 "slot" => "reviewer",
                 "is_primary" => false,
                 "binding_token" => "tok_s1",
                 "start_seq" => 1
               }
             })

    # B (seq=3) re-confirms the SAME session S -> start_seq monotonically advances to 3
    assert {:ok, "tok_s1"} =
             StationTaskSessions.join_with_token(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv,
               device_id: ctx.device,
               session: "S",
               agent_id: ctx.agent,
               start: %{
                 "slot" => "reviewer",
                 "is_primary" => false,
                 "binding_token" => "tok_s3",
                 "start_seq" => 3
               }
             })

    {:ok, [s_row]} = StationTaskSessions.of_task(ctx.group, conv)
    assert s_row.session == "S"
    assert s_row.start["start_seq"] == 3

    # Even a lower-seq re-confirm on S (seq=2) must NOT regress start_seq below 3
    assert {:ok, "tok_s1"} =
             StationTaskSessions.join_with_token(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv,
               device_id: ctx.device,
               session: "S",
               agent_id: ctx.agent,
               start: %{
                 "slot" => "reviewer",
                 "is_primary" => false,
                 "binding_token" => "tok_s2",
                 "start_seq" => 2
               }
             })

    {:ok, [s_row_after]} = StationTaskSessions.of_task(ctx.group, conv)
    assert s_row_after.start["start_seq"] == 3

    # Late A (seq=2, session SA) MUST be rejected with {:stale_slot_binding, "S"} and DB stays S!
    assert {:error, {:stale_slot_binding, "S"}} =
             StationTaskSessions.join_with_token(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv,
               device_id: ctx.device,
               session: "SA",
               agent_id: ctx.agent,
               start: %{
                 "slot" => "reviewer",
                 "is_primary" => false,
                 "binding_token" => "tok_sa",
                 "start_seq" => 2
               }
             })

    {:ok, [final_row]} = StationTaskSessions.of_task(ctx.group, conv)
    assert final_row.session == "S"
    assert final_row.start["start_seq"] == 3
  end

  test "R16 P0-3: pg_advisory_xact_lock serializes concurrent zero-row first binds on two Postgres connections",
       ctx do
    for i <- 1..5 do
      conv = Ids.new_conversation_id()

      t1 =
        Task.async(fn ->
          StationTaskSessions.join_with_token(%{
            tenant_id: ctx.tenant,
            group_id: ctx.group,
            conversation_id: conv,
            device_id: ctx.device,
            session: "ses_race_a_#{i}",
            agent_id: ctx.agent,
            start: %{
              "slot" => "reviewer",
              "is_primary" => false,
              "binding_token" => "tok_a_#{i}",
              "start_seq" => 1
            }
          })
        end)

      t2 =
        Task.async(fn ->
          StationTaskSessions.join_with_token(%{
            tenant_id: ctx.tenant,
            group_id: ctx.group,
            conversation_id: conv,
            device_id: ctx.device,
            session: "ses_race_b_#{i}",
            agent_id: ctx.agent,
            start: %{
              "slot" => "reviewer",
              "is_primary" => false,
              "binding_token" => "tok_b_#{i}",
              "start_seq" => 1
            }
          })
        end)

      results = [Task.await(t1, :infinity), Task.await(t2, :infinity)]

      ok_count = Enum.count(results, &match?({:ok, _}, &1))
      stale_count = Enum.count(results, &match?({:error, {:stale_slot_binding, _}}, &1))

      assert ok_count == 1, "expected exactly 1 winner, got: #{inspect(results)}"
      assert stale_count == 1, "expected exactly 1 stale loser, got: #{inspect(results)}"

      {:ok, rows} = StationTaskSessions.of_task(ctx.group, conv)
      assert length(rows) == 1
    end
  end

  test "R17 P0-2: device-level pg_advisory_xact_lock serializes recover_device_primary and join_with_token with strictly 1 primary row",
       ctx do
    for i <- 1..5 do
      conv = Ids.new_conversation_id()

      :ok =
        StationTaskSessions.join(%{
          tenant_id: ctx.tenant,
          group_id: ctx.group,
          conversation_id: conv,
          device_id: ctx.device,
          session: "O_#{i}",
          agent_id: ctx.agent,
          start: %{
            "slot" => "lead",
            "is_primary" => true,
            "connector_run_id" => "run_old_#{i}",
            "start_seq" => 1
          }
        })

      {:ok, [old_primary]} = StationTaskSessions.of_task(ctx.group, conv)

      t_recover =
        Task.async(fn ->
          StationTaskSessions.recover_device_primary(
            old_primary,
            "N_#{i}",
            "run_new_#{i}",
            %{"slot" => "lead", "is_primary" => true, "start_seq" => 2},
            0,
            [],
            "run_old_#{i}"
          )
        end)

      t_join =
        Task.async(fn ->
          StationTaskSessions.join_with_token(%{
            tenant_id: ctx.tenant,
            group_id: ctx.group,
            conversation_id: conv,
            device_id: ctx.device,
            session: "X_#{i}",
            agent_id: ctx.agent,
            start: %{
              "slot" => "lead",
              "is_primary" => true,
              "binding_token" => "tok_x_#{i}",
              "start_seq" => 1
            }
          })
        end)

      rec_res = Task.await(t_recover, :infinity)
      join_res = Task.await(t_join, :infinity)

      assert {:ok, :rejoined, _} = rec_res
      assert {:error, {:stale_slot_binding, winner}} = join_res
      assert winner in ["O_#{i}", "N_#{i}"]

      {:ok, rows} = StationTaskSessions.of_task(ctx.group, conv)
      assert Enum.map(rows, & &1.session) == ["N_#{i}"]
    end
  end

  test "R19 P0-2: with_device_lock + advance_slot_seq_hwm + tx_guard serialize version allocation and join_with_token with zero race window",
       ctx do
    conv = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv,
        device_id: ctx.device,
        session: "ses_r19_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true}
      })

    # Online B(2) advances authoritative slot_seq_hwm to 2 under lock_device_tx
    assert :ok =
             StationTaskSessions.with_device_lock(ctx.group, conv, ctx.device, fn ->
               StationTaskSessions.advance_slot_seq_hwm(
                 ctx.group,
                 conv,
                 ctx.device,
                 "reviewer",
                 2
               )
             end)

    # Late A(1) is rejected inside join_with_token transaction by authoritative device_hwm (1 < 2)!
    assert {:error, {:stale_slot_binding, :superseded}} =
             StationTaskSessions.join_with_token(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv,
               device_id: ctx.device,
               session: "SA_1",
               agent_id: ctx.agent,
               start: %{
                 "slot" => "reviewer",
                 "is_primary" => false,
                 "binding_token" => "tok_sa1",
                 "start_seq" => 1
               }
             })

    # tx_guard returning error inside lock_device_tx also blocks write cleanly
    assert {:error, {:stale_slot_binding, :superseded}} =
             StationTaskSessions.join_with_token(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv,
               device_id: ctx.device,
               session: "SA_guard",
               agent_id: ctx.agent,
               tx_guard: fn -> {:error, {:stale_slot_binding, :superseded}} end,
               start: %{
                 "slot" => "reviewer",
                 "is_primary" => false,
                 "binding_token" => "tok_guard",
                 "start_seq" => 2
               }
             })

    # DB still has ONLY lead (0 reviewer rows)
    {:ok, mid_rows} = StationTaskSessions.of_task(ctx.group, conv)
    assert Enum.map(mid_rows, & &1.session) == ["ses_r19_lead"]

    # B(2) with passing tx_guard succeeds cleanly!
    assert {:ok, "tok_sb2"} =
             StationTaskSessions.join_with_token(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv,
               device_id: ctx.device,
               session: "SB_2",
               agent_id: ctx.agent,
               tx_guard: fn -> :ok end,
               start: %{
                 "slot" => "reviewer",
                 "is_primary" => false,
                 "binding_token" => "tok_sb2",
                 "start_seq" => 2
               }
             })

    {:ok, final_rows} = StationTaskSessions.of_task(ctx.group, conv)
    assert final_rows |> Enum.map(& &1.session) |> Enum.sort() == ["SB_2", "ses_r19_lead"]
  end

  test "R20 P0-2 & P1-2: recover_device_primary preserves slot_seq_hwm=2, nil-seq join_with_token rejected when device_hwm > 0, append_pending_multi_start reuses existing invite_id & ensure_pending_invite_id backfills",
       ctx do
    conv = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv,
        device_id: ctx.device,
        session: "ses_r20_lead_old",
        agent_id: ctx.agent,
        start: %{
          "slot" => "lead",
          "is_primary" => true,
          "connector_run_id" => "run_old",
          "slot_seq_hwm" => %{"reviewer" => 1}
        }
      })

    # Snapshot generation 1 BEFORE B advances slot_seq_hwm to 2
    {:ok, [snap_lead_v1]} = StationTaskSessions.of_task(ctx.group, conv)
    assert snap_lead_v1.start["slot_seq_hwm"] == %{"reviewer" => 1}

    assert :ok =
             StationTaskSessions.advance_slot_seq_hwm(ctx.group, conv, ctx.device, "reviewer", 2)

    # Disk-loss recovery using stale snap_lead_v1 MUST preserve live slot_seq_hwm == 2!
    assert {:ok, :rejoined, _} =
             StationTaskSessions.recover_device_primary(
               snap_lead_v1,
               "ses_r20_lead_new",
               "run_new",
               snap_lead_v1.start,
               0,
               [],
               "run_old"
             )

    {:ok, [new_lead]} = StationTaskSessions.of_task(ctx.group, conv)
    assert new_lead.session == "ses_r20_lead_new"
    assert new_lead.start["slot_seq_hwm"]["reviewer"] == 2

    # Both stale SA(1) AND nil-seq recovery join_with_token MUST be rejected when device_hwm == 2!
    assert {:error, {:stale_slot_binding, :superseded}} =
             StationTaskSessions.join_with_token(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv,
               device_id: ctx.device,
               session: "SA_1",
               agent_id: ctx.agent,
               start: %{"slot" => "reviewer", "is_primary" => false, "start_seq" => 1}
             })

    assert {:error, {:stale_slot_binding, :superseded}} =
             StationTaskSessions.join_with_token(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv,
               device_id: ctx.device,
               session: "SA_nil_seq",
               agent_id: ctx.agent,
               start: %{"slot" => "reviewer", "is_primary" => false}
             })

    # P1-2: append_pending_multi_start returns persisted entry with stable invite_id and reuses it on duplicate slot!
    assert {:ok, first_entry} =
             StationTaskSessions.append_pending_multi_start(ctx.group, conv, ctx.device, %{
               "slot" => "qa",
               "is_primary" => false,
               "invite_id" => "inv_qa_A",
               "start" => %{"slot" => "qa"}
             })

    assert first_entry["invite_id"] == "inv_qa_A"

    assert {:ok, dup_entry} =
             StationTaskSessions.append_pending_multi_start(ctx.group, conv, ctx.device, %{
               "slot" => "qa",
               "is_primary" => false,
               "invite_id" => "inv_qa_B_must_not_replace",
               "start" => %{"slot" => "qa"}
             })

    assert dup_entry["invite_id"] == "inv_qa_A"

    # Legacy pending entry without invite_id gets backfilled by ensure_pending_invite_id!
    {:ok, _} =
      SalixStore.Repo.query(
        """
        UPDATE station_task_sessions
        SET start = jsonb_set(start, '{pending_multi_starts}', $4::jsonb, true)
        WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3
        """,
        [
          ctx.group,
          conv,
          ctx.device,
          [
            %{
              "slot" => "legacy_slot",
              "is_primary" => false,
              "start" => %{"slot" => "legacy_slot"}
            }
          ]
        ]
      )

    assert {:ok, %{"invite_id" => filled_id}} =
             StationTaskSessions.ensure_pending_invite_id(
               ctx.group,
               conv,
               ctx.device,
               "legacy_slot"
             )

    assert is_binary(filled_id) and filled_id != ""

    assert {:ok, %{"invite_id" => ^filled_id}} =
             StationTaskSessions.ensure_pending_invite_id(
               ctx.group,
               conv,
               ctx.device,
               "legacy_slot"
             )
  end

  test "R21 P0-2: recover_device_primary preserves live demoted invite_id/answered over stale primary snapshot",
       ctx do
    conv = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv,
        device_id: ctx.device,
        session: "sess_lead_r21_p0_2",
        agent_id: ctx.agent,
        start: %{
          "slot" => "lead",
          "is_primary" => true,
          "connector_run_id" => "run_r21_old",
          "pending_multi_starts" => [
            %{
              "slot" => "reviewer",
              "is_primary" => false,
              "invite_id" => "snapshot_id_old",
              "answered" => 0,
              "start" => %{"slot" => "reviewer", "participant_id" => "p_rev_r21"}
            }
          ]
        }
      })

    # Freeze stale primary snapshot (answered=0, snapshot_id_old) BEFORE reviewer joins & demotes
    {:ok, [snap_lead]} = StationTaskSessions.of_task(ctx.group, conv)

    # Secondary reviewer joins and advances answered to 14
    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv,
        device_id: ctx.device,
        session: "sess_rev_r21_p0_2",
        agent_id: ctx.agent,
        start: %{
          "slot" => "reviewer",
          "is_primary" => false,
          "participant_id" => "p_rev_r21",
          "binding_token" => "tok_r21_rev",
          "connector_run_id" => "run_r21_old"
        }
      })

    assert :ok =
             StationTaskSessions.ended_turn(
               ctx.group,
               conv,
               ctx.device,
               "sess_rev_r21_p0_2",
               14,
               14
             )

    {:ok, rows_before_demote} = StationTaskSessions.of_task(ctx.group, conv)
    rev_row = Enum.find(rows_before_demote, &(&1.session == "sess_rev_r21_p0_2"))

    # Demote missing secondary: moves reviewer into live primary pending_multi_starts with answered=14 and demoted_binding_token
    assert :ok =
             StationTaskSessions.demote_missing_secondaries(
               ctx.group,
               conv,
               ctx.device,
               [rev_row]
             )

    {:ok, [live_primary]} = StationTaskSessions.of_task(ctx.group, conv)
    live_rev = Enum.find(live_primary.start["pending_multi_starts"], &(&1["slot"] == "reviewer"))
    persisted_id = live_rev["invite_id"]
    assert is_binary(persisted_id) and persisted_id != ""
    assert live_rev["answered"] == 14
    assert live_rev["demoted_binding_token"] == "tok_r21_rev"

    # Run recover_device_primary using the stale snapshot (which carries stale pending_multi_starts)
    assert {:ok, :rejoined, _} =
             StationTaskSessions.recover_device_primary(
               snap_lead,
               "sess_lead_r21_p0_2_new",
               "run_r21_new",
               snap_lead.start,
               0,
               [],
               "run_r21_old"
             )

    # Live pending_multi_starts entry must win over stale snapshot:
    # persisted_id, answered=14, and demoted_binding_token are all preserved!
    {:ok, [after_primary]} = StationTaskSessions.of_task(ctx.group, conv)

    merged_rev =
      Enum.find(after_primary.start["pending_multi_starts"], &(&1["slot"] == "reviewer"))

    assert merged_rev["invite_id"] == persisted_id
    assert merged_rev["answered"] == 14
    assert merged_rev["demoted_binding_token"] == "tok_r21_rev"
  end

  test "R27 P0-2 & P1-3: committed_invite_ids accumulates on shared session conflict so repeat Y succeeds idempotently; pending_orphan_leaves persists, survives recovery, and clears on exact match",
       ctx do
    conv = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv,
        device_id: ctx.device,
        session: "ses_r27_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => "run_r27_1"}
      })

    # X binds session S with invite_id "inv_X"
    assert {:ok, _} =
             StationTaskSessions.append_pending_multi_start(ctx.group, conv, ctx.device, %{
               "slot" => "reviewer",
               "is_primary" => false,
               "invite_id" => "inv_X",
               "start" => %{"slot" => "reviewer", "is_primary" => false}
             })

    assert {:ok, "tok_X"} =
             StationTaskSessions.join_with_token(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv,
               device_id: ctx.device,
               session: "ses_r27_shared_S",
               agent_id: ctx.agent,
               expected_pending_invite_id: "inv_X",
               start: %{
                 "slot" => "reviewer",
                 "is_primary" => false,
                 "binding_token" => "tok_X",
                 "invite_id" => "inv_X",
                 "committed_invite_ids" => ["inv_X"]
               }
             })

    {:ok, 1} =
      StationTaskSessions.remove_pending_multi_starts(ctx.group, conv, ctx.device, [
        {"reviewer", "inv_X"}
      ])

    # Later Y (new invite_id "inv_Y") reuses the exact same session S while pending
    assert {:ok, _} =
             StationTaskSessions.append_pending_multi_start(ctx.group, conv, ctx.device, %{
               "slot" => "reviewer",
               "is_primary" => false,
               "invite_id" => "inv_Y",
               "start" => %{"slot" => "reviewer", "is_primary" => false}
             })

    assert {:ok, "tok_X"} =
             StationTaskSessions.join_with_token(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv,
               device_id: ctx.device,
               session: "ses_r27_shared_S",
               agent_id: ctx.agent,
               expected_pending_invite_id: "inv_Y",
               start: %{
                 "slot" => "reviewer",
                 "is_primary" => false,
                 "binding_token" => "tok_Y_ignored",
                 "invite_id" => "inv_Y",
                 "committed_invite_ids" => ["inv_Y"]
               }
             })

    {:ok, rows_after_y1} = StationTaskSessions.of_task(ctx.group, conv)
    s_row = Enum.find(rows_after_y1, &(&1.session == "ses_r27_shared_S"))
    assert s_row.start["invite_id"] == "inv_X"
    assert "inv_X" in s_row.start["committed_invite_ids"]
    assert "inv_Y" in s_row.start["committed_invite_ids"]

    # Background clears pending for Y; online Y receipt arrives with pending empty -> STILL idempotent {:ok, "tok_X"}!
    {:ok, 1} =
      StationTaskSessions.remove_pending_multi_starts(ctx.group, conv, ctx.device, [
        {"reviewer", "inv_Y"}
      ])

    assert {:ok, "tok_X"} =
             StationTaskSessions.join_with_token(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv,
               device_id: ctx.device,
               session: "ses_r27_shared_S",
               agent_id: ctx.agent,
               expected_pending_invite_id: "inv_Y",
               start: %{
                 "slot" => "reviewer",
                 "is_primary" => false,
                 "binding_token" => "tok_Y_second",
                 "invite_id" => "inv_Y",
                 "committed_invite_ids" => ["inv_Y"]
               }
             })

    # P1-3: record_pending_orphan_leave persists & deduplicates, survives recover_device_primary, and removes cleanly
    entry = %{"slot" => "qa", "session" => "ses_r27_orphan", "claim_token" => "inv_orphan_1"}

    assert :ok =
             StationTaskSessions.record_pending_orphan_leave(ctx.group, conv, ctx.device, entry)

    assert :ok =
             StationTaskSessions.record_pending_orphan_leave(ctx.group, conv, ctx.device, entry)

    {:ok, rows_with_orphan} = StationTaskSessions.of_task(ctx.group, conv)
    lead_row = Enum.find(rows_with_orphan, &(&1.session == "ses_r27_lead"))
    assert lead_row.start["pending_orphan_leaves"] == [entry]

    assert {:ok, :rejoined, _} =
             StationTaskSessions.recover_device_primary(
               lead_row,
               "ses_r27_lead_new",
               "run_r27_2",
               %{"slot" => "lead", "is_primary" => true},
               0,
               [],
               "run_r27_1"
             )

    {:ok, rows_after_rec} = StationTaskSessions.of_task(ctx.group, conv)
    new_lead = Enum.find(rows_after_rec, &(&1.session == "ses_r27_lead_new"))
    assert new_lead.start["pending_orphan_leaves"] == [entry]

    assert :ok =
             StationTaskSessions.remove_pending_orphan_leave(
               ctx.group,
               conv,
               ctx.device,
               "qa",
               "ses_r27_orphan",
               "inv_orphan_1"
             )

    {:ok, rows_cleared} = StationTaskSessions.of_task(ctx.group, conv)
    cleared_lead = Enum.find(rows_cleared, &(&1.session == "ses_r27_lead_new"))
    assert cleared_lead.start["pending_orphan_leaves"] == nil

    # R28 P1-3: record_pending_orphan_leave MUST return {:error, :primary_missing} when no carrier row exists!
    conv_empty = Ids.new_conversation_id()

    assert {:error, :primary_missing} =
             StationTaskSessions.record_pending_orphan_leave(
               ctx.group,
               conv_empty,
               ctx.device,
               %{
                 "slot" => "reviewer",
                 "session" => "ses_orphan_no_carrier",
                 "claim_token" => "inv_no_carrier"
               }
             )

    # R29 P0-2 & P1-5: demote_missing_secondaries strips old binding lifecycle keys (claim_token/claim_confirmed);
    # remove_pending_multi_starts(..., record_orphan_claim?: true) atomically persists {slot, "", invite_id} in pending_orphan_leaves!
    conv_r29 = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_r29,
        device_id: ctx.device,
        session: "ses_r29_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => "run_r29"}
      })

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_r29,
        device_id: ctx.device,
        session: "ses_r29_rev_old",
        agent_id: ctx.agent,
        start: %{
          "slot" => "reviewer",
          "is_primary" => false,
          "connector_run_id" => "run_r29",
          "binding_token" => "tok_old",
          "claim_token" => "old_claim_A",
          "claim_confirmed" => true,
          "invite_id" => "old_claim_A",
          "committed_invite_ids" => ["old_claim_A"]
        }
      })

    {:ok, rows_r29} = StationTaskSessions.of_task(ctx.group, conv_r29)
    rev_old = Enum.find(rows_r29, &(&1.session == "ses_r29_rev_old"))

    assert :ok =
             StationTaskSessions.demote_missing_secondaries(
               ctx.group,
               conv_r29,
               ctx.device,
               [rev_old],
               "run_r29"
             )

    {:ok, [lead_r29]} = StationTaskSessions.of_task(ctx.group, conv_r29)
    [demoted_entry] = lead_r29.start["pending_multi_starts"]
    assert demoted_entry["slot"] == "reviewer"
    refute Map.has_key?(demoted_entry["start"], "claim_token")
    refute Map.has_key?(demoted_entry["start"], "claim_confirmed")
    refute Map.has_key?(demoted_entry["start"], "binding_token")
    refute Map.has_key?(demoted_entry["start"], "invite_id")
    refute Map.has_key?(demoted_entry["start"], "committed_invite_ids")

    new_inv_id = demoted_entry["invite_id"]

    assert {:ok, 1} =
             StationTaskSessions.remove_pending_multi_starts(
               ctx.group,
               conv_r29,
               ctx.device,
               [{"reviewer", new_inv_id}],
               record_orphan_claim?: true
             )

    {:ok, [lead_r29_after]} = StationTaskSessions.of_task(ctx.group, conv_r29)
    assert lead_r29_after.start["pending_multi_starts"] == nil

    assert lead_r29_after.start["pending_orphan_leaves"] == [
             %{"slot" => "reviewer", "session" => "", "claim_token" => new_inv_id}
           ]
  end
end
