defmodule BridgeForTeams.DailyBriefComposeTest do
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{Accounts, DailyBrief, Memberships, Orgs, Projects, Repo}
  alias BridgeForTeams.DailyBrief.{Compose, People}
  alias BridgeForTeams.DailyBrief.Sources.Slack

  @now ~U[2026-10-23 02:00:00.000000Z]
  @window_after ~U[2026-10-22 02:00:00.000000Z]

  defmodule RootSalix do
    # Threads that started before the window open with long proposals.
    def daily_brief_messages(%{channel_id: channel, ts: ts}),
      do:
        {:ok,
         %{
           messages:
             for(
               t <- ts,
               do: %{
                 channel_id: channel,
                 ts: t,
                 thread_ts: t,
                 actor_kind: "user",
                 actor_id: "UALICE1",
                 subtype: nil,
                 text: String.duplicate("方案说明", 100)
               }
             )
         }}

    def daily_brief_user_names(_request), do: {:ok, %{}}

    def daily_brief_channels(_request),
      do: {:ok, %{workspace_id: "T1", complete?: true, channels: [], gaps: %{}}}
  end

  # Refuses input above the Salix binding's 450 KB, as the binding does.
  defmodule SizedModel do
    def compose(%{input: input}) do
      size = byte_size(Jason.encode!(input))
      owner = SystemsRuntime.get_env(:bridge_for_teams_core, :daily_brief_test_owner)
      SystemsRuntime.Proc.send(owner, {:size, size, length(input["items"])})

      if size <= 450_000,
        do: {:ok, %{text: "ok", usage: %{input_tokens: 1, output_tokens: 1}}},
        else: {:error, :input_too_large}
    end
  end

  defmodule ItemsModel do
    def compose(%{input: input}) do
      owner = SystemsRuntime.get_env(:bridge_for_teams_core, :daily_brief_test_owner)
      SystemsRuntime.Proc.send(owner, {:team_items, input["items"]})
      {:ok, %{text: "ok", usage: %{input_tokens: 1, output_tokens: 1}}}
    end
  end

  setup do
    :ok = SystemsClock.manual(epoch: @now)
    on_exit(&SystemsClock.reset/0)
    previous = SystemsRuntime.get_env(:bridge_for_teams_core, :salix_client)
    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, RootSalix)

    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :daily_brief_test_owner,
      SystemsRuntime.Proc.self()
    )

    on_exit(fn ->
      SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, previous)
      SystemsRuntime.delete_env(:bridge_for_teams_core, :daily_brief_test_owner)
    end)

    suffix = SystemsRuntime.Proc.unique_integer([:positive])
    {:ok, org} = Orgs.create_org(%{"name" => "Cmp #{suffix}", "slug" => "brief-cmp-#{suffix}"})

    {:ok, user} =
      Accounts.create_user(%{"email" => "a-cmp-#{suffix}@example.test", "name" => "alice"})

    {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")

    {:ok, member} =
      DailyBrief.put_member(%{
        org_id: org.id,
        user_id: user.id,
        slack_workspace_id: "T1",
        slack_user_id: "UALICE1",
        timezone: "Asia/Shanghai",
        deliver_at: ~T[09:00:00]
      })

    {:ok, project} =
      Projects.create_project(org.id, %{"name" => "Cmp", "slug" => "brief-cmp-#{suffix}"},
        creator_user_id: user.id
      )

    Repo.update_all(from(p in BridgeForTeams.Schema.Project, where: p.id == ^project.id),
      set: [salix_group_id: "grp-cmp-#{suffix}"]
    )

    {:ok, settings} =
      DailyBrief.put_settings(org.id, %{
        project_id: project.id,
        slack_connect_id: "imc_cmp",
        enabled: true
      })

    %{settings: settings, member: Repo.preload(member, :aliases)}
  end

  test "a busy day's team brief, with earlier thread context, stays within 450 KB", ctx do
    base = DateTime.to_unix(@window_after)

    new =
      for i <- 1..800 do
        message("C#{rem(i, 5)}", "#{base + 1000 + i}.000100", nil, String.duplicate("进展", 100))
      end

    # Replies in threads that started before the window bring their long first messages.
    replies =
      for i <- 1..80 do
        message("C#{rem(i, 5)}", "#{base + 5000 + i}.000100", "#{base - 86_400 + i}.000100", "好的")
      end

    assert {:ok, %{text: "ok"}} =
             Compose.write_team(
               %{
                 settings: ctx.settings,
                 shared: %{
                   messages: new ++ replies,
                   window: %{after: @window_after, before: @now}
                 },
                 previous: String.duplicate("昨天的简报", 2000),
                 now: @now
               },
               model: SizedModel,
               agent_id: "agt"
             )

    assert_received {:size, size, _items}
    assert size <= 450_000
  end

  test "a window of thousands of short messages stays within 450 KB", ctx do
    base = DateTime.to_unix(@window_after)

    messages =
      for i <- 1..6_300 do
        message("C#{rem(i, 9)}", "#{base + 1000 + i}.000100", nil, "好的")
      end

    assert {:ok, _} =
             Compose.write_team(
               %{
                 settings: ctx.settings,
                 shared: %{messages: messages, window: %{after: @window_after, before: @now}},
                 now: @now
               },
               model: SizedModel,
               agent_id: "agt"
             )

    assert_received {:size, size, _items}
    assert size <= 450_000
  end

  test "a day of a thousand short messages reaches the model whole", ctx do
    base = DateTime.to_unix(@window_after)

    messages =
      for i <- 1..1_000 do
        message("C#{rem(i, 9)}", "#{base + 1000 + i}.000100", nil, String.duplicate("进", 100))
      end

    assert {:ok, _} =
             Compose.write_team(
               %{
                 settings: ctx.settings,
                 shared: %{messages: messages, window: %{after: @window_after, before: @now}},
                 now: @now
               },
               model: SizedModel,
               agent_id: "agt"
             )

    assert_received {:size, _size, 1_000}
  end

  defp message(channel, ts, thread, text),
    do: %{
      channel_id: channel,
      ts: ts,
      thread_ts: thread,
      actor_kind: "user",
      actor_id: "UALICE1",
      subtype: nil,
      text: text
    }

  test "an open follow-up the model leaves out stays on the list" do
    followups = [
      %{
        "kind" => "watch",
        "what" => "#5286 名片等 Photon 项目 ID",
        "status" => "open",
        "evidence" => "m1"
      },
      %{"kind" => "promise", "what" => "回报价", "status" => "open", "evidence" => "m2"}
    ]

    # Given again under other words for the same pull request, done.
    listed = [
      %{"kind" => "watch", "what" => "名片 #5286 已合", "status" => "done 已合", "evidence" => "m9"}
    ]

    assert [
             %{"what" => "名片 #5286 已合"},
             %{"what" => "回报价", "status" => "open", "evidence" => ""}
           ] = Compose.keep_followups(listed, followups)

    # A failed call keeps them all, with no news.
    assert [%{"evidence" => ""}, %{"evidence" => ""}] = Compose.keep_followups([], followups)
  end

  test "a team brief mentions at most three people and never pings a bare bot id" do
    people =
      People.build(
        [],
        Enum.map(~w(B01234 UA1 UB1 UC1 UD1), &"slack:#{&1}") ++ ["meeting:alice", "meeting:bob"]
      )

    reduced =
      Compose.few_mentions("@B01234 告警，@alice 修，@alice 再看；@UB1、@UC1 和 @bob 定，@UA1 跟进", people)

    assert reduced == "机器人 告警，@alice 修，@alice 再看；@UB1、@UC1 和 bob 定，某人 跟进"

    assert Compose.finish("@B01234发了通知，@UB1 已看", %{"items" => []}, %{}, people) ==
             "机器人发了通知，<@UB1> 已看"
  end

  test "a known address in backticks stays whole" do
    request = %{"items" => [%{"text" => "拒绝了 `<http://host.docker.internal:11434>` 这类地址"}]}

    assert Compose.finish(
             "拒绝了 `http://host.docker.internal:11434` 这类地址",
             request,
             %{},
             People.build([], [])
           ) =~
             "\u200B`http://host.docker.internal:11434`\u200B 这类地址"
  end

  test "a pull request number links to the one the window's messages carry" do
    issues =
      Compose.issue_links([
        %{text: "<https://github.com/acme/app/pull/4255|#4255> merged"},
        %{text: "see https://github.com/acme/app/issues/77"},
        %{text: "https://github.com/acme/app/pull/12 and https://github.com/other/lib/pull/12"}
      ])

    assert issues == %{
             "4255" => "https://github.com/acme/app/pull/4255",
             "77" => "https://github.com/acme/app/issues/77"
           }

    assert Compose.link_issues(
             "#4255 合了，#77 还开着，#12 不确定，#999 没有链接；<https://x.test|#4255> 和 `#77` 不动",
             issues
           ) ==
             "<https://github.com/acme/app/pull/4255|#4255> 合了，<https://github.com/acme/app/issues/77|#77> 还开着，#12 不确定，#999 没有链接；<https://x.test|#4255> 和 `#77` 不动"
  end

  test "code next to Chinese text is set as code in Slack" do
    request = %{"items" => []}

    assert Compose.finish("看起来，`SEARCH_GENERATION` 没生效", request, %{}, People.build([], [])) ==
             "看起来，\u200B`SEARCH_GENERATION`\u200B 没生效"
  end

  test "a ref written outside a link becomes a link to its message" do
    request = %{
      "items" => [
        %{"ref" => "m1", "in" => "#dev", "at" => "10-29 17:14", "text" => "a"},
        %{"ref" => "m2", "in" => "#dev", "at" => "10-29 18:45", "text" => "b"}
      ]
    }

    links = %{"m1" => "https://x.test/1", "m2" => "https://x.test/2"}

    assert Compose.finish("合了。[原消息](m1)(m2) 你说不用恢复（m2）", request, links, People.build([], [])) ==
             "合了。<https://x.test/1|#dev · 10/29 17:14> <https://x.test/2|#dev · 10/29 18:45> 你说不用恢复 <https://x.test/2|#dev · 10/29 18:45>"
  end

  test "another app's mention chip reads as its name, not as a person" do
    people = People.build([], ["slack:UBOB12345"], %{"slack:UBOB12345" => "Bob"})

    assert Slack.label_text("在 <@USLACK> 菜单里问 <@UBOB12345>", people) ==
             "在 @Slack 菜单里问 @Bob"

    assert Slack.mentions("<@USLACK> 和 <@UBOB12345>") == ["slack:UBOB12345"]
  end

  test "a host Slack linked reads as the host someone typed while path links stay links" do
    people = People.build([], [])

    labeled =
      Slack.label_text(
        "转发到 <http://youdid.wtf|youdid.wtf> 和 <mailto:ops@youdid.wtf|ops@youdid.wtf>，" <>
          "见 <https://github.com/acme/app/pull/42|github.com/acme/app/pull/42> 与 <https://x.test/a|文档>",
        people
      )

    assert labeled ==
             "转发到 youdid.wtf 和 ops@youdid.wtf，" <>
               "见 <https://github.com/acme/app/pull/42|github.com/acme/app/pull/42> 与 <https://x.test/a|文档>"

    assert Compose.finish(
             "见 [PR](https://github.com/acme/app/pull/42)",
             %{"items" => [%{"text" => labeled}]},
             %{},
             people
           ) == "见 <https://github.com/acme/app/pull/42|PR>"
  end

  test "a long window keeps every told thread's final reply before earlier replies", ctx do
    base = DateTime.to_unix(@window_after)

    messages =
      Enum.flat_map(1..120, fn i ->
        root_ts = "#{base + i * 10}.000100"

        [
          message("C1", root_ts, nil, "线程 #{i}")
          | for j <- 1..3 do
              %{
                channel_id: "C1",
                ts: "#{base + i * 10 + j}.000100",
                thread_ts: root_ts,
                actor_kind: "bot",
                actor_id: "B01234",
                subtype: "bot_message",
                text: "回复 #{i}-#{j}"
              }
            end
        ]
      end)

    assert {:ok, _} =
             Compose.write_team(
               %{
                 settings: ctx.settings,
                 shared: %{messages: messages, window: %{after: @window_after, before: @now}},
                 now: @now
               },
               model: ItemsModel,
               agent_id: "agt"
             )

    assert_received {:team_items, items}
    assert length(items) == 120 + 300
    by_text = Map.new(items, &{&1["text"], &1})

    for i <- 1..120 do
      assert by_text["回复 #{i}-3"]["t"] == by_text["线程 #{i}"]["t"]
    end

    refute Map.has_key?(by_text, "回复 1-1")
    assert Map.has_key?(by_text, "回复 120-1")
  end

  test "includes connected still.fail station_tasks in brief inputs and preserves their URLs",
       ctx do
    stillfail_url = "https://still.fail/o/acme/mac/c-abc123"
    invented_url = "https://still.fail/o/acme/mac/c-invented"

    defmodule StationBriefModel do
      def compose(%{view: :mine, input: input}) do
        owner = SystemsRuntime.get_env(:bridge_for_teams_core, :daily_brief_test_owner)
        SystemsRuntime.Proc.send(owner, {:mine_station_tasks, input["station_tasks"]})

        {:ok,
         %{
           text:
             Jason.encode!(%{
               "items" => [
                 %{
                   "kind" => "decide",
                   "what" => "确认部署 staging",
                   "owner" => "me",
                   "status" => "open",
                   "evidence" => ""
                 }
               ]
             }),
           usage: %{input_tokens: 1, output_tokens: 1}
         }}
      end

      def compose(%{input: input}) do
        owner = SystemsRuntime.get_env(:bridge_for_teams_core, :daily_brief_test_owner)
        SystemsRuntime.Proc.send(owner, {:brief_station_tasks, input["station_tasks"]})

        {:ok,
         %{
           text:
             "待确认：[上线单](https://still.fail/o/acme/mac/c-abc123) 与 [编造链接](https://still.fail/o/acme/mac/c-invented)",
           usage: %{input_tokens: 1, output_tokens: 1}
         }}
      end
    end

    assert {:ok, written} =
             Compose.write(
               %{
                 settings: ctx.settings,
                 member: ctx.member,
                 shared: %{
                   messages: [message("C1", "1792720800.000100", nil, "早会同步")],
                   relevant: %{
                     ctx.member.id => [
                       %{
                         message: message("C1", "1792720800.000100", nil, "早会同步"),
                         reasons: [:mention],
                         tier: :p0
                       }
                     ]
                   },
                   channel_names: %{"C1" => "general"},
                   window: %{after: @window_after, before: @now}
                 },
                 station_tasks: [
                   %{
                     "title" => "Proactive 架构深扒",
                     "state" => "need",
                     "note" => "CI 已过，是否合并并部署 staging",
                     "url" => stillfail_url,
                     "last_activity_at" => DateTime.to_unix(@now, :millisecond) - 60_000
                   }
                 ],
                 now: @now
               },
               model: StationBriefModel,
               agent_id: "agt",
               members: [ctx.member]
             )

    assert_received {:mine_station_tasks,
                     [%{"title" => "Proactive 架构深扒", "state" => "need", "url" => ^stillfail_url}]}

    assert_received {:brief_station_tasks,
                     [%{"title" => "Proactive 架构深扒", "state" => "need", "url" => ^stillfail_url}]}

    assert written.text =~ stillfail_url
    refute written.text =~ invented_url
  end
end
