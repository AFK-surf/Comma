defmodule CommaWeb.ProactiveExecutionTest do
  use SystemsClock.Case, async: true

  alias CommaWeb.ProactiveExecution
  alias SalixIM.ConversationQuestion

  @now_ms DateTime.to_unix(~U[2026-11-25 06:00:00Z], :millisecond)

  @stations [
    %{
      "id" => "dev_mini",
      "name" => "Pengs-Mac-Mini-2",
      "connected" => true,
      "workspace" => %{"name" => "Peng", "station" => "Pengs-Mac-Mini-2"}
    },
    %{
      "id" => "dev_offline",
      "name" => "Offline-Win",
      "connected" => false,
      "workspace" => %{"name" => "Peng", "station" => "Offline-Win"}
    }
  ]

  @station_rows [
    %{
      station_id: "stn_mini",
      device_id: "dev_mini",
      thread: "CHAT/1795577429.312000",
      title: "Fix Cue PR #5590 billing sandbox allowlist",
      status: "in_progress",
      created_by: "kai@example.com",
      last_activity_at: @now_ms - 600_000,
      waits_for: [],
      note: "Investigating AFK-surf/Cue PR #5590 staging smoke-test allowlist",
      url: "https://still.fail/chats/c_pr5590"
    },
    %{
      station_id: "stn_offline",
      device_id: "dev_offline",
      thread: "CHAT/offline_1",
      title: "Cue PR #5590 old thread",
      status: "in_progress",
      created_by: "kai@example.com",
      last_activity_at: @now_ms - 300_000,
      waits_for: [],
      note: "Offline machine chat",
      url: "https://still.fail/chats/c_offline"
    },
    %{
      station_id: "stn_mini",
      device_id: "dev_mini",
      thread: "CHAT/other_user",
      title: "Fix Cue PR #5590 billing sandbox",
      status: "in_progress",
      created_by: "teammate@example.com",
      last_activity_at: @now_ms - 100_000,
      waits_for: [],
      note: "Another person's chat must not leak",
      url: "https://still.fail/chats/c_other"
    },
    %{
      station_id: "stn_mini",
      device_id: "dev_mini",
      thread: "CHAT/archived",
      title: "Fix Cue PR #5590 billing sandbox",
      status: "archived",
      created_by: "kai@example.com",
      last_activity_at: @now_ms - 100_000,
      waits_for: [],
      note: "Archived chat must not be suggested",
      url: "https://still.fail/chats/c_archived"
    }
  ]

  describe "ProactiveExecution.extract_github_target/3" do
    test "uses canonical item URL, structured GitHub linked/research URLs, or portrait-watched repos; ignores arbitrary body links" do
      # Arbitrary third-party GitHub URL inside email body or web_page must NOT be adopted as a repo target.
      random_body = %{
        "url" => "https://mail.google.com/mail/u/0/#inbox/m1",
        "excerpt" => "Check vendor library https://github.com/vendor/lib/pull/99"
      }

      assert ProactiveExecution.extract_github_target(random_body, %{}) == nil

      # Structured GitHub linked PR is accepted.
      linked_ev = %{
        "linked" => [
          %{
            "kind" => "github_pull_request",
            "url" => "https://github.com/AFK-surf/Cue/pull/5590"
          }
        ]
      }

      assert ProactiveExecution.extract_github_target(random_body, linked_ev) == %{
               "owner" => "AFK-surf",
               "name" => "Cue",
               "pull_request" => 5590
             }

      # Portrait-watched repo in excerpt IS accepted.
      assert ProactiveExecution.extract_github_target(
               %{
                 "url" => "https://example.slack.com/archives/C1/p1",
                 "excerpt" => "Check https://github.com/AFK-surf/Cue/pull/5590"
               },
               %{},
               ["AFK-surf/Cue"]
             ) == %{"owner" => "AFK-surf", "name" => "Cue", "pull_request" => 5590}

      repo_only = %{
        "url" => "https://github.com/motion-space/medalsmith/issues/42"
      }

      assert ProactiveExecution.extract_github_target(repo_only, %{}) == %{
               "owner" => "motion-space",
               "name" => "medalsmith"
             }

      assert ProactiveExecution.extract_github_target(
               %{"url" => "https://github.com/notifications"},
               %{}
             ) ==
               nil
    end
  end

  describe "ProactiveExecution.build/3" do
    test "matches connected owner station chat and GitHub PR sandbox in priority order" do
      item = %{
        "decision" => "interrupt",
        "role" => "act",
        "toolkit" => "github",
        "title" => "Alex asked about staging smoke-test allowlist on PR #5590",
        "url" => "https://github.com/AFK-surf/Cue/pull/5590",
        "excerpt" => "Can we allowlist staging bot accounts in Cue PR #5590?",
        "assessment" => %{"role" => "act", "code" => false, "cost" => "Blocks 1.0.4 release"}
      }

      exec =
        ProactiveExecution.build(item, %{}, %{
          stations: @stations,
          station_rows: @station_rows,
          owner_email: "kai@example.com",
          now_ms: @now_ms
        })

      assert exec["actionable"] == true

      assert exec["github_repo"] == %{
               "owner" => "AFK-surf",
               "name" => "Cue",
               "pull_request" => 5590
             }

      assert [%{"device_id" => "dev_mini", "name" => "Pengs-Mac-Mini-2"}] =
               exec["connected_stations"]

      # Connected owner chat ranks first; other user and archived rows are excluded.
      task_ids = Enum.map(exec["station_tasks"], & &1["task_id"])
      assert hd(task_ids) == "station:stn_mini:CHAT/1795577429.312000"
      refute Enum.any?(task_ids, &String.contains?(&1, "other_user"))
      refute Enum.any?(task_ids, &String.contains?(&1, "archived"))

      # Suggested actions never offer an offline station; they offer continue_station_task + sandbox_pr.
      assert [
               %{
                 "kind" => "continue_station_task",
                 "tool" => "im_api.internal.send_message",
                 "conversation_id" => "station:stn_mini:CHAT/1795577429.312000"
               },
               %{
                 "kind" => "sandbox_pr",
                 "tool" => "im_api.internal.task.create",
                 "runs_on" => %{"kind" => "sandbox"},
                 "repo" => %{"owner" => "AFK-surf", "name" => "Cue", "pull_request" => 5590}
               }
             ] = exec["suggested_actions"]
    end

    test "falls back to sandbox_pr and new_station_task when no active station chat matches" do
      item = %{
        "decision" => "interrupt",
        "role" => "act",
        "toolkit" => "github",
        "title" => "PR #12 failing Android shader test",
        "url" => "https://github.com/motion-space/medalsmith/pull/12",
        "assessment" => %{"role" => "act", "code" => false, "cost" => "Release blocked"}
      }

      exec =
        ProactiveExecution.build(item, %{}, %{
          stations: @stations,
          station_rows: @station_rows,
          owner_email: "kai@example.com",
          now_ms: @now_ms
        })

      assert exec["actionable"] == true
      assert exec["station_tasks"] == nil

      assert [
               %{
                 "kind" => "sandbox_pr",
                 "repo" => %{
                   "owner" => "motion-space",
                   "name" => "medalsmith",
                   "pull_request" => 12
                 }
               },
               %{
                 "kind" => "new_station_task",
                 "runs_on" => %{"kind" => "station", "device_id" => "dev_mini"}
               }
             ] = exec["suggested_actions"]
    end

    test "returns nil for pure read-only product praise signal (including '无'/'none' cost) without leaking stations" do
      for cost <- ["", "无", "none", "N/A"] do
        item = %{
          "decision" => "signal",
          "role" => "reference",
          "relationship" => "web_mention_of_your_work",
          "title" => "DEX #373 features Medalsmith",
          "url" => "https://dexweekly.example/issues/373",
          "assessment" => %{
            "role" => "reference",
            "signal" => true,
            "code" => false,
            "cost" => cost
          }
        }

        assert ProactiveExecution.build(item, %{}, %{
                 stations: @stations,
                 station_rows: [],
                 owner_email: "kai@example.com",
                 now_ms: @now_ms
               }) == nil
      end
    end

    test "fails closed on nil owner/creator, excludes done chats, and does not substring-match short repo names" do
      item = %{
        "decision" => "interrupt",
        "role" => "act",
        "toolkit" => "github",
        "title" => "Cue PR #5590 needs allowlist review",
        "url" => "https://github.com/AFK-surf/Cue/pull/5590",
        "assessment" => %{"role" => "act", "code" => false, "cost" => "Blocks release"}
      }

      extra_rows = [
        %{
          station_id: "stn_mini",
          device_id: "dev_mini",
          thread: "CHAT/done_row",
          title: "Fix AFK-surf/Cue PR #5590",
          status: "done",
          created_by: "kai@example.com",
          last_activity_at: @now_ms - 60_000,
          note: "Already completed"
        },
        %{
          station_id: "stn_mini",
          device_id: "dev_mini",
          thread: "CHAT/nil_creator",
          title: "Fix AFK-surf/Cue PR #5590",
          status: "in_progress",
          created_by: nil,
          last_activity_at: @now_ms - 60_000,
          note: "Missing creator must fail closed"
        },
        %{
          station_id: "stn_mini",
          device_id: "dev_mini",
          thread: "CHAT/rescue_false_pos",
          title: "Mountain rescue checklist",
          status: "in_progress",
          created_by: "kai@example.com",
          last_activity_at: @now_ms - 60_000,
          note: "Prepare rescue gear"
        }
      ]

      # Unknown owner_email fails closed (no station tasks matched).
      exec_nil_owner =
        ProactiveExecution.build(item, %{}, %{
          stations: @stations,
          station_rows: @station_rows,
          owner_email: nil
        })

      assert exec_nil_owner["station_tasks"] == nil

      # Done row, nil-creator row, and substring "rescue" row are all excluded.
      exec =
        ProactiveExecution.build(item, %{}, %{
          stations: @stations,
          station_rows: extra_rows,
          owner_email: "kai@example.com"
        })

      assert exec["station_tasks"] == nil

      # Bound device owner email is matched fail-closed.
      bound_row = %{
        station_id: "stn_mini",
        device_id: "dev_mini",
        thread: "CHAT/bound_owner",
        title: "Fix AFK-surf/Cue PR #5590 allowlist",
        status: "in_progress",
        created_by: "peng@stillfail.example",
        last_activity_at: @now_ms - 60_000,
        note: "Working on AFK-surf/Cue PR #5590"
      }

      exec_bound =
        ProactiveExecution.build(item, %{}, %{
          stations: @stations,
          station_rows: [bound_row],
          owner_email: "kai@example.com",
          device_owner_emails: %{"dev_mini" => "peng@stillfail.example"}
        })

      assert [%{"task_id" => "station:stn_mini:CHAT/bound_owner"}] = exec_bound["station_tasks"]
    end

    test "marks pre-meeting brief signal and cross-source draft conflict signal as actionable" do
      meeting = %{
        "decision" => "signal",
        "role" => "calendar",
        "relationship" => "upcoming_meeting_prep",
        "title" => "Medalsmith x Acme sync",
        "url" => "https://calendar.google.com/event/evt_acme_sync",
        "assessment" => %{"role" => "calendar", "signal" => true, "code" => false, "cost" => ""}
      }

      exec_meeting =
        ProactiveExecution.build(meeting, %{}, %{stations: [], station_rows: [], now_ms: @now_ms})

      assert exec_meeting["actionable"] == true

      assert [%{"kind" => "draft_task", "tool" => "proactive.act", "action" => "draft"}] =
               exec_meeting["suggested_actions"]

      conflict = %{
        "decision" => "signal",
        "role" => "act",
        "title" => "Webhook auth changed from Bearer to HMAC",
        "url" => "https://example.slack.com/archives/C1/p123",
        "assessment" => %{
          "role" => "act",
          "signal" => true,
          "code" => false,
          "cost" => "Invalidates draft"
        }
      }

      exec_conflict =
        ProactiveExecution.build(conflict, %{}, %{stations: [], station_rows: [], now_ms: @now_ms})

      assert exec_conflict["actionable"] == true
      assert [%{"kind" => "draft_task"}] = exec_conflict["suggested_actions"]
    end

    test "returns nil for verification codes" do
      otp = %{
        "decision" => "interrupt",
        "role" => "act",
        "title" => "Your sign-in code is 849201",
        "assessment" => %{"role" => "act", "code" => true, "cost" => "Expires in 10 minutes"}
      }

      assert ProactiveExecution.build(otp, %{}, %{
               stations: @stations,
               station_rows: @station_rows,
               now_ms: @now_ms
             }) ==
               nil
    end

    test "ConversationQuestion validates a Router-authored one-tap execution card" do
      content = [
        %{"type" => "text", "text" => "Alex 在 PR #5590 问是否把 staging bot 加入白名单。"},
        %{
          "type" => "question",
          "prompt" => "要怎么推进 PR #5590？",
          "choices" => [
            %{
              "label" => "继续 Mac Mini 会话处理",
              "description" => "发到现有 still.fail 会话 Fix Cue PR #5590",
              "recommended" => true
            },
            %{
              "label" => "云端 Sandbox 修 PR",
              "description" => "在 AFK-surf/Cue PR #5590 分支起编码任务"
            },
            %{
              "label" => "先不用",
              "action" => "close"
            }
          ],
          "multi_select" => false,
          "allow_other" => true,
          "skip_behavior" => "dismiss"
        }
      ]

      assert {:ok, normalized} = ConversationQuestion.normalize_agent_content(content)
      assert :ok = ConversationQuestion.validate_blocks(normalized)
    end

    test "strict URI-parsed GitHub target rejects embedded non-GitHub redirect URLs, userinfo, and invalid path suffixes" do
      for bad_url <- [
            "https://evil.example/redirect/https://github.com/attacker/repo/pull/123",
            "https://user@github.com/AFK-surf/Cue/pull/5590",
            "https://github.com/AFK-surf/Cue/pull/5590/evil",
            "http://github.com/AFK-surf/Cue/pull/5590",
            "https://github.com/settings/tokens"
          ] do
        item = %{
          "decision" => "interrupt",
          "role" => "act",
          "toolkit" => "github",
          "title" => "Check PR",
          "url" => bad_url,
          "excerpt" => "Review #{bad_url}",
          "assessment" => %{"role" => "act", "code" => false, "cost" => "Blocks release"}
        }

        assert ProactiveExecution.extract_github_target(item, %{}, ["attacker/repo"]) == nil
      end

      # Canonical GitHub PR subpaths (/files) and trailing-dot host parse cleanly.
      good = %{
        "url" => "https://github.com/AFK-surf/Cue/pull/5590/files?w=1#diff-1"
      }

      assert ProactiveExecution.extract_github_target(good, %{}, []) == %{
               "owner" => "AFK-surf",
               "name" => "Cue",
               "pull_request" => 5590
             }
    end

    test "rejects station chats naming a conflicting repo owner even when repo name and PR number collide" do
      item = %{
        "decision" => "interrupt",
        "role" => "act",
        "toolkit" => "github",
        "title" => "Medalsmith PR #12 blocked on shader export regression",
        "url" => "https://github.com/motion-space/medalsmith/pull/12",
        "excerpt" => "Fix transparent PNG export in motion-space/medalsmith PR #12.",
        "assessment" => %{"role" => "act", "code" => false, "cost" => "Blocks demo"}
      }

      conflicting_row = %{
        station_id: "stn_mini",
        device_id: "dev_mini",
        thread: "CHAT/conflict-1",
        title: "Fix otherorg/medalsmith PR #12 shader export",
        status: "in_progress",
        created_by: "kai@example.com",
        last_activity_at: @now_ms - 10_000,
        note: "Working on otherorg/medalsmith PR #12",
        url: "https://still.fail/chats/c_conflict"
      }

      exec =
        ProactiveExecution.build(item, %{}, %{
          stations: @stations,
          station_rows: [conflicting_row],
          owner_email: "kai@example.com",
          now_ms: @now_ms
        })

      refute Map.has_key?(exec, "station_tasks")
    end
  end
end
