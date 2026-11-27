defmodule SalixStore.ProactiveKernelPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SalixStore.ProactiveKernel

  @anchor_pool [
    "slack:C01/1700000001.000100",
    "slack:C02/1700000002.000200",
    "github:acme/cue/5286",
    "github:acme/cue/5432",
    "linear:ENG-101"
  ]

  defp gen_anchor, do: member_of(@anchor_pool)

  defp gen_anchors do
    list_of(gen_anchor(), min_length: 1, max_length: 2) |> map(&MapSet.new/1)
  end

  defp gen_completeness do
    member_of([:complete, {:partial, :truncated}, {:partial, :only_mine}])
  end

  defp gen_event do
    one_of([
      gen all(
            anchors <- gen_anchors(),
            at <- integer(1..500),
            role <- member_of([:act, :waiting, :reference]),
            completeness <- gen_completeness(),
            witness_ok <- boolean(),
            due_at <- one_of([constant(nil), integer(100..1_000)]),
            reserve <- boolean()
          ) do
        {:arrive,
         %{
           anchors: anchors,
           at: at,
           role: role,
           completeness: completeness,
           witness_ok: witness_ok,
           due_at: due_at,
           reserve_eligible: reserve,
           summary: "arrival-#{at}"
         }}
      end,
      gen all(
            anchors <- gen_anchors(),
            at <- integer(1..500),
            decision <- member_of([:interrupt, :ask, :briefing, :quiet, :resolved]),
            role <- member_of([:act, :waiting, :reference]),
            completeness <- gen_completeness(),
            witness_ok <- boolean()
          ) do
        {:sensor_claim,
         %{
           anchors: anchors,
           at: at,
           decision: decision,
           role: role,
           completeness: completeness,
           witness_ok: witness_ok
         }}
      end,
      gen all(
            anchors <- gen_anchors(),
            at <- integer(1..500),
            status <- member_of([:closed, :merged, :answered, :draft, :open])
          ) do
        {:provider_truth, %{anchors: anchors, at: at, status: status}}
      end,
      gen all(
            anchors <- gen_anchors(),
            at <- integer(1..500),
            choice <- member_of([:quiet, :notify, :defer]),
            prob_bp <- integer(0..10_000)
          ) do
        {:jev_screen, %{anchors: anchors, at: at, choice: choice, probability_bp: prob_bp}}
      end,
      gen all(
            anchors <- gen_anchors(),
            at <- integer(1..500),
            action <- member_of([:resolve, :dismiss, :reopen])
          ) do
        {:user_action, %{anchors: anchors, at: at, action: action}}
      end
    ])
  end

  property "routine projection and terminal matters are strictly disjoint across arbitrary traces" do
    check all(events <- list_of(gen_event(), max_length: 40)) do
      ledger = ProactiveKernel.reduce(events)
      routine = ProactiveKernel.routine_matters(ledger)
      terminal = ProactiveKernel.terminal_matters(ledger)

      routine_ids = MapSet.new(routine, & &1.id)
      terminal_ids = MapSet.new(terminal, & &1.id)
      assert MapSet.disjoint?(routine_ids, terminal_ids)

      routine_anchors =
        Enum.reduce(routine, MapSet.new(), &MapSet.union(&2, &1.anchors))

      terminal_anchors =
        Enum.reduce(terminal, MapSet.new(), &MapSet.union(&2, &1.anchors))

      assert MapSet.disjoint?(routine_anchors, terminal_anchors)
    end
  end

  property "no silent drop: an open matter stays open across unrelated, unverified or partial-close events" do
    target = MapSet.new(["github:acme/cue/9999"])

    noise_gen =
      one_of([
        # Events on other matters
        gen_event(),
        # Unverified claims on the target itself
        gen all(
              at <- integer(1..1_000),
              decision <- member_of([:resolved, :quiet, :interrupt])
            ) do
          {:sensor_claim,
           %{anchors: target, at: at, decision: decision, role: :act, witness_ok: false}}
        end,
        # Partial-evidence close claims on the target itself
        gen all(
              at <- integer(1..1_000),
              partial <- member_of([{:partial, :truncated}, {:partial, :only_mine}])
            ) do
          {:sensor_claim,
           %{
             anchors: target,
             at: at,
             decision: :resolved,
             role: :act,
             completeness: partial,
             witness_ok: true
           }}
        end,
        # Sub-threshold Jev quiet verdicts on the target itself
        gen all(
              at <- integer(1..1_000),
              prob_bp <- integer(0..8_999)
            ) do
          {:jev_screen, %{anchors: target, at: at, choice: :quiet, probability_bp: prob_bp}}
        end
      ])

    check all(
            opened_at <- integer(10..200),
            noise <- list_of(noise_gen, max_length: 30)
          ) do
      seed =
        {:arrive,
         %{anchors: target, at: opened_at, role: :act, completeness: :complete, witness_ok: true}}

      ledger = ProactiveKernel.reduce([seed | noise])

      open_anchors =
        ledger
        |> ProactiveKernel.open_matters()
        |> Enum.reduce(MapSet.new(), &MapSet.union(&2, &1.anchors))

      assert MapSet.subset?(target, open_anchors)
    end
  end

  property "anti-resurrection: stale timestamps or partial reads never reopen a resolved tombstone, and user lock absorbs automatic events" do
    target = MapSet.new(["slack:C99/1750000000.000100"])

    check all(
            t_close <- integer(100..500),
            stale_times <- list_of(integer(1..500), max_length: 20),
            later_times <- list_of(integer(501..1_000), max_length: 15),
            lock_action <- member_of([:resolve, :dismiss])
          ) do
      # 1. Uncorrected resolved tombstone blocks any event at ts <= t_close or partial completeness
      base =
        ProactiveKernel.reduce([
          {:arrive, %{anchors: target, at: 10, role: :act}},
          {:provider_truth, %{anchors: target, at: t_close, status: :merged}}
        ])

      stale_events =
        Enum.flat_map(stale_times, fn ts ->
          ts = min(ts, t_close)

          [
            {:arrive, %{anchors: target, at: ts, role: :act, completeness: :complete}},
            {:sensor_claim,
             %{anchors: target, at: ts, decision: :interrupt, role: :act, completeness: :complete}},
            {:arrive,
             %{
               anchors: target,
               at: t_close + 50,
               role: :act,
               completeness: {:partial, :only_mine}
             }}
          ]
        end)

      after_stale = ProactiveKernel.reduce(base, stale_events)
      [matter] = Map.values(after_stale.matters)
      assert matter.phase == :resolved
      assert matter.closed_at == t_close

      # 2. User-locked resolve/dismiss absorbs automatic events even at ts > t_close
      locked =
        ProactiveKernel.reduce([
          {:arrive, %{anchors: target, at: 10, role: :act}},
          {:user_action, %{anchors: target, at: t_close, action: lock_action}}
        ])

      auto_events =
        Enum.map(later_times, fn ts ->
          {:arrive,
           %{anchors: target, at: ts, role: :act, completeness: :complete, witness_ok: true}}
        end)

      after_auto = ProactiveKernel.reduce(locked, auto_events)
      [locked_matter] = Map.values(after_auto.matters)
      assert locked_matter.phase in [:resolved, :dismissed]
      assert locked_matter.user_locked == true

      # Explicit user reopen unlocks and restores :open
      reopened =
        ProactiveKernel.reduce(after_auto, [
          {:user_action, %{anchors: target, at: t_close + 1_000, action: :reopen}}
        ])

      [reopened_matter] = Map.values(reopened.matters)
      assert reopened_matter.phase == :open
      assert reopened_matter.user_locked == false
    end
  end

  property "bounded deferral: next_at always advances past now and wakes at reserve window entry when sooner than budget reopen" do
    check all(
            now_ms <- integer(1_000_000..9_000_000),
            opens_delta <- integer(-5_000..500_000),
            reserve_delta <- one_of([constant(nil), integer(-5_000..500_000)]),
            due_delta <- one_of([constant(nil), integer(-5_000..800_000)]),
            busy_delta <- one_of([constant(nil), integer(-5_000..400_000)]),
            role <- member_of(["act", "waiting"])
          ) do
      opens_at = now_ms + opens_delta
      reserve_window_at = reserve_delta && now_ms + reserve_delta
      due_ms = due_delta && now_ms + due_delta
      busy_until_ms = busy_delta && now_ms + busy_delta

      scheduled =
        ProactiveKernel.schedule_deferral(
          %{
            opens_at: opens_at,
            busy_until_ms: busy_until_ms,
            role: role,
            due_ms: due_ms,
            reserve_window_at: reserve_window_at,
            lead_ms: 60_000
          },
          now_ms
        )

      assert scheduled.next_at > now_ms

      effective_open =
        if is_integer(busy_until_ms) and busy_until_ms > opens_at,
          do: busy_until_ms,
          else: opens_at

      if role == "act" and is_integer(reserve_window_at) and reserve_window_at > now_ms and
           effective_open > reserve_window_at do
        assert scheduled.next_at == reserve_window_at
      end

      if is_integer(scheduled.due_at) do
        assert scheduled.due_at > now_ms
      end
    end
  end

  property "two-tier grouping keeps busy strong anchors together while preventing shared-email cross-PR contamination" do
    check all(
            reply_count <- integer(7..16),
            noise_count <- integer(7..14)
          ) do
      # > 6 messages in the same Slack thread (including its root permalink) stay one matter
      root = %{
        "id" => "root",
        "url" => "https://acme.slack.com/archives/C01ABC/p1795000000000100",
        "excerpt" => "Deploy broke",
        "facts" => %{"ts" => "1795000000.000100"}
      }

      replies =
        for n <- 1..reply_count do
          %{
            "id" => "r#{n}",
            "url" =>
              "https://acme.slack.com/archives/C01ABC/p17950000#{10 + n}000100?thread_ts=1795000000.000100&cid=C01ABC",
            "excerpt" => "Reply #{n}",
            "facts" => %{"ts" => "17950000#{10 + n}.000100"}
          }
        end

      assert [single_thread] = ProactiveKernel.group_candidates([root | replies])
      assert length(single_thread["members"]) == reply_count + 1

      # > 6 notifications sharing only a weak email address never collapse
      burst =
        for n <- 1..noise_count do
          %{
            "id" => "m#{n}",
            "url" => "https://mail.example/#{n}",
            "excerpt" => "From notifications@github.com",
            "facts" => %{"ts" => "#{n}.0"}
          }
        end

      assert length(ProactiveKernel.group_candidates(burst)) == noise_count

      # Two distinct PRs mentioning the same email never merge
      pr_a = %{
        "id" => "pa",
        "url" => "https://github.com/acme/cue/pull/101",
        "excerpt" => "cc reviewer@acme.com",
        "facts" => %{"ts" => "1.0"}
      }

      pr_b = %{
        "id" => "pb",
        "url" => "https://github.com/acme/cue/pull/102",
        "excerpt" => "cc reviewer@acme.com",
        "facts" => %{"ts" => "2.0"}
      }

      assert length(ProactiveKernel.group_candidates([pr_a, pr_b])) == 2
    end
  end

  property "daily brief mine reconciliation preserves open followups, blocks closed resurrection, and drops partial only_mine asks" do
    check all(
            keep_open? <- boolean(),
            emit_only_mine_ask? <- boolean(),
            resurrect_closed? <- boolean(),
            emit_merged_open? <- boolean()
          ) do
      followup = %{
        "kind" => "promise",
        "what" => "补 #5286 名片测试",
        "owner" => "me",
        "status" => "open",
        "evidence" => ""
      }

      closed = [%{"what" => "默认橙色 #4612", "status" => "done", "on" => "2026-11-11"}]
      issues = [%{"ref" => "#7196", "state" => "merged"}]

      items = [
        %{
          "ref" => "m1",
          "in" => "#pm-tool",
          "by" => "你",
          "text" => "要个 agent POV",
          "only_mine" => true
        },
        %{
          "ref" => "m2",
          "in" => "#still-fail",
          "by" => "Alice",
          "text" => "Windows 挂了",
          "earlier" => true
        }
      ]

      listed =
        []
        |> then(&if(keep_open?, do: [Map.put(followup, "what", "跟进 #5286") | &1], else: &1))
        |> then(
          &if(emit_only_mine_ask?,
            do: [
              %{
                "kind" => "asked",
                "what" => "agent 工作 POV 还没发",
                "owner" => "me",
                "status" => "open",
                "evidence" => "m1"
              }
              | &1
            ],
            else: &1
          )
        )
        |> then(
          &if(resurrect_closed?,
            do: [
              %{
                "kind" => "decide",
                "what" => "定 #4612 橙色",
                "owner" => "me",
                "status" => "open",
                "evidence" => "m2"
              }
              | &1
            ],
            else: &1
          )
        )
        |> then(
          &if(emit_merged_open?,
            do: [
              %{
                "kind" => "decide",
                "what" => "回「合」合入 #7196",
                "owner" => "me",
                "status" => "open",
                "evidence" => ""
              }
              | &1
            ],
            else: &1
          )
        )

      reconciled =
        ProactiveKernel.reconcile_brief_mine(listed, %{
          "followups" => [followup],
          "closed" => closed,
          "issues" => issues,
          "items" => items
        })

      # 1. Open followup #5286 is never silently dropped
      assert Enum.any?(reconciled, &ProactiveKernel.same_matter?(&1, followup))

      # 2. Invented ask citing only an `only_mine` partial item is dropped
      refute Enum.any?(reconciled, &(&1["what"] == "agent 工作 POV 还没发"))

      # 3. Closed tombstone #4612 cannot resurrect without fresh non-earlier, non-only_mine ref
      refute Enum.any?(reconciled, fn e ->
               ProactiveKernel.same_matter?(e, hd(closed)) and
                 not String.starts_with?(e["status"] || "", "done")
             end)

      # 4. Merged PR #7196 cannot stay open without a fresh to_me ask
      if emit_merged_open? do
        merged_entry = Enum.find(reconciled, &String.contains?(&1["what"], "#7196"))
        assert merged_entry["status"] == "done (merged)"
      end
    end
  end

  test "active_meeting_end_ms bounds active meetings, ignores all-day/declined/cancelled/>=8h events, and composes with schedule_deferral" do
    now_ms = 1_795_000_000_000
    min_ms = 60_000
    hour_ms = 60 * min_ms

    # 30m active meeting ending in 20m -> busy until end + 2m
    active_30m = %{
      "start" => now_ms - 10 * min_ms,
      "end" => now_ms + 20 * min_ms,
      "status" => "confirmed"
    }

    assert {:busy, busy_until} = ProactiveKernel.active_meeting_end_ms([active_30m], now_ms)
    assert busy_until == now_ms + 22 * min_ms

    # Google Calendar & Microsoft Graph nested start/end shapes work identically
    gcal_iso = %{
      "start" => %{
        "dateTime" =>
          DateTime.from_unix!(now_ms - 5 * min_ms, :millisecond) |> DateTime.to_iso8601()
      },
      "end" => %{
        "dateTime" =>
          DateTime.from_unix!(now_ms + 25 * min_ms, :millisecond) |> DateTime.to_iso8601()
      }
    }

    graph_iso = %{
      "start" => %{
        "dateTime" =>
          now_ms
          |> Kernel.-(5 * min_ms)
          |> DateTime.from_unix!(:millisecond)
          |> DateTime.to_naive()
          |> NaiveDateTime.to_iso8601(),
        "timeZone" => "UTC"
      },
      "end" => %{
        "dateTime" =>
          now_ms
          |> Kernel.+(15 * min_ms)
          |> DateTime.from_unix!(:millisecond)
          |> DateTime.to_naive()
          |> NaiveDateTime.to_iso8601(),
        "timeZone" => "UTC"
      }
    }

    assert {:busy, max_busy} =
             ProactiveKernel.active_meeting_end_ms([gcal_iso, graph_iso], now_ms)

    assert max_busy == now_ms + 27 * min_ms

    # Ignored non-blocking calendar banners and statuses
    ignored = [
      %{"start" => now_ms - 10 * min_ms, "end" => now_ms + 20 * min_ms, "status" => "cancelled"},
      %{
        "start" => now_ms - 10 * min_ms,
        "end" => now_ms + 20 * min_ms,
        "responseStatus" => "declined"
      },
      %{"start" => now_ms - 10 * min_ms, "end" => now_ms + 20 * min_ms, "allDay" => true},
      %{"start" => "2026-11-18", "end" => "2026-11-19"},
      %{"start" => %{"date" => "2026-11-18"}, "end" => %{"date" => "2026-11-19"}},
      # 8-hour OOO / focus banner (>= 8h)
      %{"start" => now_ms - hour_ms, "end" => now_ms + 7 * hour_ms},
      # Past meeting (end == now_ms) and future meeting (start > now_ms)
      %{"start" => now_ms - 30 * min_ms, "end" => now_ms},
      %{"start" => now_ms + 5 * min_ms, "end" => now_ms + 35 * min_ms}
    ]

    assert ProactiveKernel.active_meeting_end_ms(ignored, now_ms) == :free

    # Marathon 4h meeting is capped at now_ms + max_defer_ms (default 2h)
    marathon = %{start: now_ms - 15 * min_ms, end: now_ms + 225 * min_ms}
    assert {:busy, capped} = ProactiveKernel.active_meeting_end_ms([marathon], now_ms)
    assert capped == now_ms + 2 * hour_ms

    # Feeds cleanly into schedule_deferral while waking early if reserve_window_at < busy_until
    deferred_after_meeting =
      ProactiveKernel.schedule_deferral(
        %{opens_at: now_ms, busy_until_ms: busy_until, role: "act"},
        now_ms
      )

    assert deferred_after_meeting.next_at == busy_until

    reserve_wake = now_ms + 8 * min_ms

    deferred_with_deadline =
      ProactiveKernel.schedule_deferral(
        %{
          opens_at: now_ms,
          busy_until_ms: busy_until,
          role: "act",
          reserve_window_at: reserve_wake,
          due_ms: now_ms + 68 * min_ms
        },
        now_ms
      )

    assert deferred_with_deadline.next_at == reserve_wake
  end

  property "active_meeting_end_ms never defers past now_ms + max_defer_ms for arbitrary event schedules" do
    check all(
            now_ms <- integer(1_000_000_000..9_000_000_000),
            offsets <-
              list_of(
                tuple({
                  integer((-10 * 3_600_000)..(4 * 3_600_000)),
                  integer(60_000..(12 * 3_600_000)),
                  member_of(["confirmed", "cancelled"]),
                  member_of(["accepted", "declined"]),
                  boolean()
                }),
                max_length: 15
              ),
            buffer_ms <- integer(0..600_000),
            max_defer_ms <- integer(60_000..7_200_000)
          ) do
      events =
        for {start_delta, duration, status, resp, all_day} <- offsets do
          start_ms = now_ms + start_delta

          %{
            "start" => start_ms,
            "end" => start_ms + duration,
            "status" => status,
            "responseStatus" => resp,
            "allDay" => all_day
          }
        end

      case ProactiveKernel.active_meeting_end_ms(events, now_ms,
             buffer_ms: buffer_ms,
             max_defer_ms: max_defer_ms
           ) do
        :free ->
          :ok

        {:busy, until_ms} ->
          assert until_ms > now_ms
          assert until_ms <= now_ms + max_defer_ms
      end
    end
  end

  property "coalesce_bursts collapses >= threshold workflow/template bursts while preserving items_of conservation and keeping PRs/threads distinct" do
    check all(
            run_count <- integer(3..8),
            alert_count <- integer(3..7),
            pr_count <- integer(3..6),
            slack_count <- integer(3..6)
          ) do
      runs =
        for n <- 1..run_count do
          %{
            "id" => "run-#{n}",
            "toolkit" => "github",
            "title" => "[acme/cue] Run failed: Systems CI - main (#{1_000_000 + n}abcdef)",
            "url" => "https://github.com/acme/cue/actions/runs/#{90_000 + n}",
            "excerpt" => "Workflow run ##{n} failed",
            "facts" => %{"ts" => "#{100 + n}.0"}
          }
        end

      alerts =
        for n <- 1..alert_count do
          %{
            "id" => "alert-#{n}",
            "toolkit" => "outlook",
            "title" => "APPLE-MACOS-#{n} - App Hanging for 2000 ms",
            "url" => "https://outlook.office.com/mail/id/alert-#{n}",
            "excerpt" => "Alert digest on 2026-11-19T0#{rem(n, 9)}:10:00Z",
            "facts" => %{"ts" => "#{200 + n}.0", "sender" => "Sentry Alerts"}
          }
        end

      prs =
        for n <- 1..pr_count do
          %{
            "id" => "pr-#{n}",
            "toolkit" => "github",
            "title" => "Bump dependency group ##{n}",
            "url" => "https://github.com/acme/cue/pull/#{500 + n}",
            "excerpt" => "Please review",
            "facts" => %{"ts" => "#{300 + n}.0"}
          }
        end

      threads =
        for n <- 1..slack_count do
          %{
            "id" => "slack-#{n}",
            "toolkit" => "slack",
            "title" => "Customer escalation ##{n}",
            "url" => "https://acme.slack.com/archives/C01ABC/p17950000#{10 + n}000100",
            "excerpt" => "Can someone take a look?",
            "facts" => %{"ts" => "17950000#{10 + n}.000100"}
          }
        end

      all_items = runs ++ alerts ++ prs ++ threads
      grouped = ProactiveKernel.group_candidates(all_items)
      # Before burst coalescing, every item has a distinct run/mail/PR/thread anchor
      assert length(grouped) == length(all_items)

      coalesced = ProactiveKernel.coalesce_bursts(grouped)

      # Runs collapse to 1 matter, alerts collapse to 1 matter, PRs and Slack threads stay distinct!
      assert length(coalesced) == 2 + pr_count + slack_count

      # Conservation invariant: every input item remains accounted for in items_of/1
      assert MapSet.new(ProactiveKernel.items_of(coalesced), & &1["id"]) ==
               MapSet.new(all_items, & &1["id"])

      run_matter = Enum.find(coalesced, &(&1["id"] == "run-#{run_count}"))
      assert run_matter["burst_count"] == run_count
      assert length(run_matter["members"]) == run_count

      alert_matter = Enum.find(coalesced, &(&1["id"] == "alert-#{alert_count}"))
      assert alert_matter["burst_count"] == alert_count
      assert length(alert_matter["members"]) == alert_count

      # Below threshold (2 runs), matters stay separate
      two_runs = ProactiveKernel.group_candidates(Enum.take(runs, 2))
      assert length(ProactiveKernel.coalesce_bursts(two_runs)) == 2
    end
  end
end
