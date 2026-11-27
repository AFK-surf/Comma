defmodule BridgeForTeams.DailyBriefReplayTest do
  use ExUnit.Case, async: false

  alias BridgeForTeams.DailyBrief.Replay

  test "replays a personal brief offline and enforces tombstone, terminal PR, followup retention and partial shared-channel gates" do
    kase = %{
      "name" => "personal_kernel_gates",
      "window_after" => "2026-11-18T01:00:00Z",
      "now" => "2026-11-19T01:00:00Z",
      "member" => %{
        "slack_user_id" => "UPENG1",
        "name" => "Peng Xiao",
        "timezone" => "Asia/Shanghai",
        "aliases" => [%{"kind" => "name", "term" => "Peng Xiao"}],
        "focus_channels" => ["C_STILLFAIL"]
      },
      "channels" => %{"C_STILLFAIL" => "still-fail"},
      "messages" => [
        %{
          "channel_id" => "C_STILLFAIL",
          "ts" => "1795020000.000100",
          "actor_kind" => "user",
          "actor_id" => "UPENG1",
          "text" => "Windows 聊天页打开不滚到底，同时见 <https://github.com/AFK-surf/monoid/pull/7196|#7196>"
        },
        %{
          "channel_id" => "C_STILLFAIL",
          "ts" => "1795020600.000100",
          "thread_ts" => "1795020000.000100",
          "actor_kind" => "bot",
          "actor_id" => "SCLAUDE",
          "text" => "本地 8 种组合没复现，下面两个任选一个就能继续：1. 装 station；2. 告诉我版本号？"
        }
      ],
      "direct_messages" => [
        %{
          "channel_id" => "C_PMTOOL",
          "channel_name" => "pm-tool",
          "kind" => "shared",
          "ts" => "1795010000.000100",
          "actor_kind" => "user",
          "actor_id" => "UPENG1",
          "text" => "要一个 agent 干活时的 POV html 报告"
        }
      ],
      "followups" => [
        %{
          "kind" => "watch",
          "what" => "#5286 名片等 Photon 项目 ID",
          "owner" => "other",
          "status" => "open",
          "evidence" => ""
        }
      ],
      "closed" => [
        %{"what" => "定 #4612 默认橙色", "status" => "done", "on" => "2026-11-11"}
      ],
      "issues" => %{
        "7196" => "https://github.com/AFK-surf/monoid/pull/7196"
      },
      "issue_states" => %{
        "AFK-surf/monoid#7196" => "merged"
      },
      "expect" => %{
        "mine_open_contains" => ["Windows", "#5286"],
        "mine_open_excludes" => ["POV", "#4612", "#7196"],
        "text_contains" => ["Windows"]
      }
    }

    judge = fn
      %{view: :mine, input: input} ->
        shared_ref =
          input["items"]
          |> Enum.find(&(&1["only_mine"] == true))
          |> Map.fetch!("ref")

        win_ref =
          input["items"]
          |> Enum.find(&(&1["to_me"] == true))
          |> Map.fetch!("ref")

        # Model omits #5286, tries to resurrect #4612, marks merged #7196 open,
        # and fabricates an unanswered ask from an `only_mine` shared-channel message.
        {:ok,
         Jason.encode!(%{
           "items" => [
             %{
               "kind" => "asked",
               "what" => "Windows 不滚到底选排障方式",
               "owner" => "me",
               "status" => "open",
               "evidence" => win_ref
             },
             %{
               "kind" => "asked",
               "what" => "agent 工作 POV 还没发",
               "owner" => "me",
               "status" => "open",
               "evidence" => shared_ref
             },
             %{
               "kind" => "decide",
               "what" => "定 #4612 默认橙色",
               "owner" => "me",
               "status" => "open",
               "evidence" => ""
             },
             %{
               "kind" => "decide",
               "what" => "合入 #7196",
               "owner" => "me",
               "status" => "open",
               "evidence" => ""
             }
           ]
         })}

      %{view: :brief, input: input} ->
        assert Enum.any?(input["mine"], &(&1["what"] =~ "#5286"))
        refute Enum.any?(input["mine"], &(&1["what"] =~ "POV"))
        {:ok, "*一句话*：Windows 聊天页不滚到底还等你二选一；#7196 已合。"}
    end

    assert [report] = Replay.run(kase, judge)
    assert Enum.all?(report["checks"], & &1["pass"]), inspect(report["checks"])
  end

  test "replays the golden regression fixture corpus with all invariant checks green" do
    fixture_dir = Path.expand("../fixtures/daily_brief", __DIR__)
    paths = Path.wildcard(Path.join(fixture_dir, "*.json")) |> Enum.sort()
    assert length(paths) == 4

    for path <- paths do
      kase = Replay.load!(path)

      judge =
        case kase["name"] do
          "shared_channel_partial_visibility" ->
            fn
              %{view: :mine, input: input} ->
                shared_ref =
                  input["items"] |> Enum.find(&(&1["only_mine"] == true)) |> Map.fetch!("ref")

                win_ref =
                  input["items"] |> Enum.find(&(&1["to_me"] == true)) |> Map.fetch!("ref")

                {:ok,
                 Jason.encode!(%{
                   "items" => [
                     %{
                       "kind" => "asked",
                       "what" => "Windows 聊天页不滚到底选排障方式",
                       "owner" => "me",
                       "status" => "open",
                       "evidence" => win_ref
                     },
                     %{
                       "kind" => "asked",
                       "what" => "agent 工作 POV 报告还没回",
                       "owner" => "me",
                       "status" => "open",
                       "evidence" => shared_ref
                     }
                   ]
                 })}

              %{view: :brief, input: input} ->
                refute Enum.any?(input["mine"], &(&1["what"] =~ "POV"))
                {:ok, "*一句话*：Windows 聊天页不滚到底还等你选排障方式。"}
            end

          "tombstone_and_terminal_pr" ->
            fn
              %{view: :mine, input: _input} ->
                {:ok,
                 Jason.encode!(%{
                   "items" => [
                     %{
                       "kind" => "decide",
                       "what" => "定 #4612 默认橙色",
                       "owner" => "me",
                       "status" => "open",
                       "evidence" => ""
                     },
                     %{
                       "kind" => "decide",
                       "what" => "合入 #7196",
                       "owner" => "me",
                       "status" => "open",
                       "evidence" => ""
                     }
                   ]
                 })}

              %{view: :brief, input: input} ->
                assert Enum.any?(input["mine"], &(&1["what"] =~ "#5286"))
                refute Enum.any?(input["mine"], &(&1["what"] =~ "#4612"))
                {:ok, "*一句话*：#5286 仍在等 Photon 项目 ID；#7196 已合并。"}
            end

          "bare_issue_number_and_my_pr" ->
            fn
              %{view: :mine, input: _input} ->
                {:ok,
                 Jason.encode!(%{
                   "items" => [
                     %{
                       "kind" => "decide",
                       "what" => "合入 #5438 分页改动",
                       "owner" => "me",
                       "status" => "open",
                       "evidence" => ""
                     }
                   ]
                 })}

              %{view: :brief, input: input} ->
                refute Enum.any?(
                         input["mine"],
                         &(&1["what"] =~ "#5438" and &1["status"] == "open")
                       )

                {:ok, "*一句话*：#5438 分页改动已合并，无待办。"}
            end

          "new_channel_focus_day_one" ->
            fn
              %{view: :mine, input: input} ->
                bob_item =
                  Enum.find(input["items"], &String.contains?(&1["text"] || "", "0.3 正式版"))

                assert bob_item != nil

                {:ok,
                 Jason.encode!(%{
                   "items" => [
                     %{
                       "kind" => "decide",
                       "what" => "确认 PinShot 0.3 明天是否直接发正式版",
                       "owner" => "me",
                       "status" => "open",
                       "evidence" => bob_item["ref"]
                     }
                   ]
                 })}

              %{view: :brief, input: input} ->
                assert Enum.any?(input["mine"], &(&1["what"] =~ "PinShot 0.3"))
                {:ok, "*一句话*：#proj-pinshot 问你 PinShot 0.3 明天能否发正式版。"}
            end
        end

      assert [report] = Replay.run(kase, judge)

      assert Enum.all?(report["checks"], & &1["pass"]),
             "fixture #{kase["name"]} failed: #{inspect(report["checks"])}"
    end
  end
end
