defmodule BridgeForTeams.DailyBriefDeliveryTest do
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{Accounts, DailyBrief, Memberships, Orgs, Projects, Repo}
  alias BridgeForTeams.DailyBrief.{Delivery, RunLease}
  alias BridgeForTeams.DailyBrief.Sources.Slack
  alias BridgeForTeams.Schema.DailyBriefRun

  # 10:00 in Shanghai, a Friday.
  @now ~U[2026-10-23 02:00:00.000000Z]

  # One public channel the bot is in: Bob asks Alice for a price, inside any
  # recent window, in a thread that started the week before.
  defmodule FakeSalix do
    def daily_brief_channels(_request),
      do:
        {:ok,
         %{workspace_id: "T1", complete?: true, channels: [%{id: "C1", name: "sales"}], gaps: %{}}}

    def daily_brief_read_window(%{channel_id: "C1", after_us: after_us, before_us: before_us}) do
      extra = SystemsRuntime.get_env(:bridge_for_teams_core, :daily_brief_test_window, [])

      messages =
        for {ts, text} <- [{"1792720000.000100", "<@UALICE1> 这个报价怎么算？"}],
            us = trunc(String.to_float(ts) * 1_000_000),
            us > after_us and us < before_us,
            do:
              Map.put(message(ts, "1792600000.000100", "UBOB1", text), :reactions, [
                %{name: "eyes", users: ["UALICE1"]}
              ])

      messages =
        messages ++
          for %{ts: ts} = m <- extra,
              us = trunc(String.to_float(ts) * 1_000_000),
              us > after_us and us < before_us,
              do:
                Map.merge(
                  message(ts, m.thread, m.author, m.text),
                  Map.take(m, [:actor_kind, :reactions])
                )

      {:ok, %{messages: messages, has_more?: false, next_cursor: nil}}
    end

    def daily_brief_member_threads(_request), do: {:ok, %{threads: [], complete?: true}}

    def daily_brief_active_channels(_request), do: {:ok, %{}}

    def daily_brief_issue_states(request) do
      owner = SystemsRuntime.get_env(:bridge_for_teams_core, :daily_brief_test_owner)
      SystemsRuntime.Proc.send(owner, {:issue_states, request})
      {:ok, %{"acme/app#42" => "draft"}}
    end

    def daily_brief_member_login(request) do
      owner = SystemsRuntime.get_env(:bridge_for_teams_core, :daily_brief_test_owner)
      SystemsRuntime.Proc.send(owner, {:member_login, request})
      {:ok, "alice-gh"}
    end

    def daily_brief_member_pulls(request) do
      owner = SystemsRuntime.get_env(:bridge_for_teams_core, :daily_brief_test_owner)
      SystemsRuntime.Proc.send(owner, {:member_pulls, request})

      {:ok,
       [
         %{
           repo: "acme/app",
           number: "77",
           title: "报价单导出",
           state: "merged",
           closed_at: "2026-10-23T12:00:00Z",
           others: ["UZAN"]
         },
         %{
           repo: "acme/app",
           number: "70",
           title: "上个月的",
           state: "merged",
           closed_at: "2026-09-01T01:00:00Z",
           others: []
         }
       ]}
    end

    def daily_brief_direct_messages(request) do
      owner = SystemsRuntime.get_env(:bridge_for_teams_core, :daily_brief_test_owner)
      SystemsRuntime.Proc.send(owner, {:direct_messages, request})

      SystemsRuntime.get_env(
        :bridge_for_teams_core,
        :daily_brief_test_direct,
        {:ok,
         %{
           messages: [
             %{
               channel_id: "D9",
               kind: "im",
               ts: "1792720100.000100",
               thread_ts: nil,
               author: "UBOB1",
               bot?: false,
               text: "私下说：报价先别发",
               permalink: "https://acme.slack.com/archives/D9/p1792720100000100"
             }
           ],
           complete?: true
         }}
      )
    end

    def daily_brief_permalinks(%{messages: messages}) do
      SystemsRuntime.get_env(
        :bridge_for_teams_core,
        :daily_brief_test_links,
        {:ok,
         Map.new(messages, fn %{channel_id: channel, ts: ts} ->
           {{channel, ts},
            "https://acme.slack.com/archives/#{channel}/p#{String.replace(ts, ".", "")}"}
         end)}
      )
    end

    def daily_brief_user_names(%{user_ids: ids}),
      do: {:ok, Map.new(ids, &{&1, "Name " <> &1}) |> Map.delete("UBOB1")}

    def daily_brief_messages(%{channel_id: channel, ts: ts}),
      do:
        {:ok,
         %{
           messages: for(t <- ts, do: %{message(t, t, "UALICE1", "上周的报价单") | channel_id: channel})
         }}

    def daily_brief_post(request) do
      owner = SystemsRuntime.get_env(:bridge_for_teams_core, :daily_brief_test_owner)
      SystemsRuntime.Proc.send(owner || SystemsRuntime.Proc.self(), {:posted, request})

      SystemsRuntime.get_env(
        :bridge_for_teams_core,
        :daily_brief_test_post,
        {:ok, %{channel_id: "D_BOT", ts: "1792720000.000100"}}
      )
    end

    defp message(ts, thread, author, text),
      do: %{
        channel_id: "C1",
        ts: ts,
        thread_ts: thread,
        actor_kind: "user",
        actor_id: author,
        subtype: nil,
        text: text
      }
  end

  # Writes what the test says, and reports what it was given.
  defmodule WritingModel do
    def compose(%{view: :team, input: input}) do
      report({:team_compose, input})

      SystemsRuntime.get_env(
        :bridge_for_teams_core,
        :daily_brief_test_team_compose,
        {:ok,
         %{text: "团队：报价的事 @UBOB1 在跟。[原消息](m2)", usage: %{input_tokens: 40, output_tokens: 10}}}
      )
    end

    def compose(%{view: :mine, input: input}) do
      report({:mine, input})

      SystemsRuntime.get_env(
        :bridge_for_teams_core,
        :daily_brief_test_mine,
        {:ok, %{text: ~s({"items": []}), usage: %{input_tokens: 0, output_tokens: 0}}}
      )
    end

    def compose(%{input: input}) do
      report({:compose, input})

      SystemsRuntime.get_env(
        :bridge_for_teams_core,
        :daily_brief_test_compose,
        {:ok, %{text: "先回 @UBOB1 的报价。[原消息](m2)", usage: %{input_tokens: 7, output_tokens: 3}}}
      )
    end

    defp report(message) do
      owner = SystemsRuntime.get_env(:bridge_for_teams_core, :daily_brief_test_owner)
      SystemsRuntime.Proc.send(owner, message)
    end
  end

  setup tags do
    :ok = SystemsClock.manual(epoch: tags[:clock] || @now)
    on_exit(&SystemsClock.reset/0)
    previous = SystemsRuntime.get_env(:bridge_for_teams_core, :salix_client)
    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, FakeSalix)

    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :daily_brief_test_owner,
      SystemsRuntime.Proc.self()
    )

    on_exit(fn ->
      SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, previous)

      for key <- ~w(daily_brief_test_owner daily_brief_test_post daily_brief_test_compose
                    daily_brief_test_team_compose daily_brief_test_links
                    daily_brief_test_direct daily_brief_test_mine
                    daily_brief_test_window)a,
          do: SystemsRuntime.delete_env(:bridge_for_teams_core, key)
    end)

    suffix = SystemsRuntime.Proc.unique_integer([:positive])
    {:ok, org} = Orgs.create_org(%{"name" => "Del #{suffix}", "slug" => "brief-del-#{suffix}"})

    [alice, bob] =
      for name <- ["alice", "bob"] do
        {:ok, user} =
          Accounts.create_user(%{"email" => "#{name}-del-#{suffix}@example.test", "name" => name})

        {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")

        {:ok, member} =
          DailyBrief.put_member(%{
            org_id: org.id,
            user_id: user.id,
            slack_workspace_id: "T1",
            slack_user_id: "U#{String.upcase(name)}1",
            timezone: "Asia/Shanghai",
            deliver_at: ~T[09:00:00]
          })

        member
      end

    {:ok, project} =
      Projects.create_project(org.id, %{"name" => "Del", "slug" => "brief-del-#{suffix}"},
        creator_user_id: alice.user_id
      )

    Repo.update_all(from(p in BridgeForTeams.Schema.Project, where: p.id == ^project.id),
      set: [salix_group_id: "grp-del-#{suffix}"]
    )

    {:ok, settings} =
      DailyBrief.put_settings(org.id, %{
        project_id: project.id,
        slack_connect_id: "imc_del",
        enabled: true
      })

    %{settings: settings, alice: alice, bob: bob}
  end

  @opts [model: WritingModel, agent_id: "agt"]

  test "what the brief lists as the member's is carried to the next brief until done", ctx do
    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :daily_brief_test_mine,
      {:ok,
       %{
         text: """
         ```json
         {"items": [
           {"kind": "promise", "what": "回报价", "owner": "me", "waiting": "@UBOB1 等你",
            "due": "周五", "status": "open", "evidence": "m2"},
           {"kind": "watch", "what": "合同", "owner": "@UBOB1", "status": "done 已签", "evidence": "m2"},
           {"kind": "gossip", "what": "不认识的类型"}
         ]}
         ```
         """,
         usage: %{input_tokens: 5, output_tokens: 2}
       }}
    )

    assert {:ok, run} = Delivery.deliver(ctx.settings, ctx.alice, @opts)
    assert_received {:mine, %{"followups" => []}}
    assert_received {:compose, %{"mine" => [%{"what" => "回报价", "owner" => "me"}, _done]}}
    assert run.input_tokens == 12
    assert [%{"what" => "回报价"}, %{"what" => "合同"}] = run.notes["mine"]

    # The next brief starts from the open ones.
    tomorrow = DateTime.add(@now, 86_400)
    member = Repo.reload!(ctx.alice) |> Repo.preload(:aliases)
    assert {:ok, _} = Delivery.deliver(ctx.settings, member, Keyword.put(@opts, :now, tomorrow))

    assert_received {:mine,
                     %{
                       "followups" => [%{"what" => "回报价", "due" => "周五"}],
                       "closed" => [%{"what" => "合同", "on" => "2026-10-23"}]
                     }}

    # What was closed is kept for a week, then let go.
    later = DateTime.add(@now, 9 * 86_400)
    member = Repo.reload!(ctx.alice) |> Repo.preload(:aliases)
    assert {:ok, _} = Delivery.deliver(ctx.settings, member, Keyword.put(@opts, :now, later))
    # Nor does a follow-up with no news for a week stay on the list.
    assert_received {:mine, %{"closed" => [], "followups" => []}}
  end

  test "the pull requests a follow-up names are looked up, by the links briefs have seen",
       ctx do
    assert {:ok, first} = Delivery.deliver(ctx.settings, ctx.alice, @opts)
    assert_received {:mine, %{"issues" => []}}

    first
    |> Ecto.Changeset.change(
      notes:
        Map.merge(first.notes, %{
          "mine" => [
            %{"kind" => "decide", "what" => "合并 #42", "owner" => "me", "status" => "open"}
          ],
          "issues" => %{"42" => "https://github.com/acme/app/pull/42"}
        })
    )
    |> Repo.update!()

    tomorrow = DateTime.add(@now, 86_400)
    member = Repo.reload!(ctx.alice) |> Repo.preload(:aliases)
    assert {:ok, run} = Delivery.deliver(ctx.settings, member, Keyword.put(@opts, :now, tomorrow))

    assert_received {:issue_states,
                     %{agent_id: "agt", issues: [%{repo: "acme/app", number: "42"}]}}

    assert_received {:mine, %{"issues" => [%{"ref" => "#42", "state" => "draft"}]}}
    assert_received {:compose, %{"issues" => [%{"ref" => "#42", "state" => "draft"}]}}
    assert run.notes["issues"] == %{"42" => "https://github.com/acme/app/pull/42"}
  end

  test "a member with a GitHub login gets the pull requests it closed in the window", ctx do
    assert {:ok, _} = Delivery.deliver(ctx.settings, ctx.alice, @opts)
    refute_received {:member_pulls, _}
    assert_received {:mine, %{"my_prs" => []}}

    Repo.insert!(%BridgeForTeams.Schema.DailyBriefAlias{
      member_id: ctx.alice.id,
      term: "alice-dev",
      kind: "github"
    })

    member = Repo.reload!(ctx.alice) |> Repo.preload(:aliases, force: true)
    tomorrow = DateTime.add(@now, 86_400)

    SystemsRuntime.put_env(:bridge_for_teams_core, :daily_brief_test_window, [])
    {:ok, _} = Delivery.deliver(ctx.settings, member, Keyword.put(@opts, :now, tomorrow))
    assert_received {:member_pulls, %{agent_id: "agt", login: "alice-dev"}}
    assert_received {:mine, %{"my_prs" => prs}}
    assert [%{"ref" => "#77", "state" => "merged", "others" => "UZAN"}] = prs
  end

  test "the member's own words are \"你\"; an ask with no answer from them is marked", ctx do
    SystemsRuntime.put_env(:bridge_for_teams_core, :daily_brief_test_window, [
      %{ts: "1792719000.000100", thread: nil, author: "UBOB1", text: "<@UALICE1> 合同签了吗？"},
      %{ts: "1792719100.000100", thread: nil, author: "UBOB1", text: "<@UALICE1> 发票呢？"},
      %{ts: "1792719200.000100", thread: "1792719100.000100", author: "UALICE1", text: "发票我来开"},
      %{
        ts: "1792719300.000100",
        thread: "1792719100.000100",
        author: "UBOB1",
        text: "抬头用哪个主体？"
      },
      %{
        ts: "1792719400.000100",
        thread: "1792719100.000100",
        author: "UBOB1",
        text: "<@UCAROL1> 税号发一下？"
      },
      %{
        ts: "1792719500.000100",
        thread: nil,
        author: "UBOB1",
        text: "<@UALICE1> 周五能发版吗？",
        reactions: [%{name: "+1", users: ["UALICE1"]}]
      }
    ])

    assert {:ok, _run} = Delivery.deliver(ctx.settings, ctx.alice, @opts)
    assert_received {:compose, %{"items" => items}}
    by_text = Map.new(items, &{&1["text"], &1})

    assert by_text["发票我来开"]["by"] == "你"
    assert by_text["@UALICE1 合同签了吗？"]["to_me"] == true
    # A follow-up question in a thread the member already spoke in waits on them,
    # unless it mentions someone else.
    assert by_text["抬头用哪个主体？"]["to_me"] == true
    refute by_text["@UCAROL1 税号发一下？"]["to_me"]
    # An "eyes" reaction only means the member is looking at it, not that they answered;
    # a confirming reaction ("+1") or a later reply in the thread answers it.
    assert by_text["@UALICE1 这个报价怎么算？"]["to_me"] == true
    refute by_text["@UALICE1 发票呢？"]["to_me"]
    refute by_text["@UALICE1 周五能发版吗？"]["to_me"]
  end

  test "the last word of the member's thread that turns to them waits on them", ctx do
    SystemsRuntime.put_env(:bridge_for_teams_core, :daily_brief_test_window, [
      %{ts: "1792719000.000100", thread: nil, author: "UALICE1", text: "Windows 上聊天页没滚到底"},
      %{
        ts: "1792719100.000100",
        thread: "1792719000.000100",
        author: "UBOT1",
        actor_kind: "bot",
        text: "复现不了。下面两个任选一个就能继续：装 station，或者告诉我版本号"
      },
      %{ts: "1792719200.000100", thread: nil, author: "UALICE1", text: "pin-shot 发了"},
      %{
        ts: "1792719300.000100",
        thread: "1792719200.000100",
        author: "UBOB1",
        text: "想加自动更新，但是跟你说的不联网冲突了"
      },
      %{ts: "1792719400.000100", thread: nil, author: "UALICE1", text: "报价单做完了"},
      %{ts: "1792719500.000100", thread: "1792719400.000100", author: "UBOB1", text: "你看下格式"},
      %{ts: "1792719600.000100", thread: "1792719400.000100", author: "UBOB1", text: "好像没问题了"}
    ])

    assert {:ok, _run} = Delivery.deliver(ctx.settings, ctx.alice, @opts)
    assert_received {:compose, %{"items" => items}}
    by_text = Map.new(items, &{&1["text"], &1})

    assert by_text["复现不了。下面两个任选一个就能继续：装 station，或者告诉我版本号"]["to_me"] == true
    assert by_text["想加自动更新，但是跟你说的不联网冲突了"]["to_me"] == true
    # Only the thread's last word: a later message moved on.
    refute by_text["你看下格式"]["to_me"]
  end

  test "a bot's meeting notes that name the member reach their brief whole", ctx do
    Repo.insert!(%BridgeForTeams.Schema.DailyBriefAlias{
      member_id: ctx.alice.id,
      term: "Alice Wang",
      kind: "name"
    })

    notes =
      "Meeting Summary: 全员会\nAttendees: Bob, Alice Wang\n" <>
        String.duplicate("议题讨论。", 200) <> "\n决定：TestFlight 渠道停掉。"

    SystemsRuntime.put_env(:bridge_for_teams_core, :daily_brief_test_window, [
      %{
        ts: "1792719000.000100",
        thread: "1792718000.000100",
        author: "UBOT1",
        actor_kind: "bot",
        text: notes
      }
    ])

    member = Repo.reload!(ctx.alice) |> Repo.preload(:aliases, force: true)
    assert {:ok, _run} = Delivery.deliver(ctx.settings, member, @opts)
    assert_received {:compose, %{"items" => items}}
    assert Enum.any?(items, &String.ends_with?(&1["text"], "决定：TestFlight 渠道停掉。"))
  end

  test "the team brief looks up the state of pull requests and issues in the window", ctx do
    SystemsRuntime.put_env(:bridge_for_teams_core, :daily_brief_test_window, [
      %{
        ts: "1792719000.000100",
        thread: nil,
        author: "UBOB1",
        text: "修好了 <https://github.com/acme/app/pull/10|github.com/acme/app/pull/10>"
      },
      %{
        ts: "1792719100.000100",
        thread: nil,
        author: "UBOB1",
        text: "顺手看下裸编号 #42 状态"
      }
    ])

    assert {:ok, _run} = Delivery.deliver(ctx.settings, ctx.alice, @opts)

    assert_received {:team_compose, %{"issues" => [%{"ref" => "#42", "state" => "draft"}]}}
  end

  test "a member's GitHub login is found by their name once and kept", ctx do
    assert {:ok, first} = Delivery.deliver(ctx.settings, ctx.alice, @opts)

    first
    |> Ecto.Changeset.change(
      notes: Map.put(first.notes, "issues", %{"42" => "https://github.com/acme/app/pull/42"})
    )
    |> Repo.update!()

    Repo.insert!(%BridgeForTeams.Schema.DailyBriefAlias{
      member_id: ctx.alice.id,
      term: "Alice Wang",
      kind: "name"
    })

    member = Repo.reload!(ctx.alice) |> Repo.preload(:aliases, force: true)
    tomorrow = DateTime.add(@now, 86_400)
    assert {:ok, run} = Delivery.deliver(ctx.settings, member, Keyword.put(@opts, :now, tomorrow))
    assert_received {:member_login, %{orgs: ["acme"], names: ["Alice Wang"]}}
    assert_received {:member_pulls, %{login: "alice-gh"}}
    assert run.notes["github"] == "alice-gh"

    later = DateTime.add(@now, 2 * 86_400)
    assert {:ok, _} = Delivery.deliver(ctx.settings, member, Keyword.put(@opts, :now, later))
    refute_received {:member_login, _}
    assert_received {:member_pulls, %{login: "alice-gh"}}
  end

  test "a draft that leaves out where the member said a lot is written again", ctx do
    SystemsRuntime.put_env(:bridge_for_teams_core, :daily_brief_test_window, [
      %{ts: "1792720050.000100", thread: "1792720050.000100", author: "UALICE1", text: "配货一"},
      %{ts: "1792720100.000100", thread: "1792720050.000100", author: "UALICE1", text: "配货二"},
      %{ts: "1792720150.000100", thread: "1792720050.000100", author: "UALICE1", text: "配货三"}
    ])

    assert {:ok, run} = Delivery.deliver(ctx.settings, ctx.alice, @opts)
    assert_received {:compose, %{"my_talk" => [%{"refs" => refs} | _]} = first}
    refute Map.has_key?(first, "draft")
    assert length(String.split(refs)) == 3
    assert_received {:compose, %{"draft" => _, "missing" => [%{"refs" => ^refs}]}}
    assert run.input_tokens == 14
  end

  test "a thread the briefs tell brings the replies that ended it", ctx do
    SystemsRuntime.put_env(:bridge_for_teams_core, :daily_brief_test_window, [
      %{
        ts: "1792720100.000100",
        thread: "1792600000.000100",
        author: "UBOTX",
        actor_kind: "bot",
        text: "报价单已经发给客户了"
      },
      %{ts: "1792720050.000100", thread: nil, author: "UBOB1", text: "<@UALICE1> 网络怎么配？"},
      %{
        ts: "1792720080.000100",
        thread: "1792720050.000100",
        author: "UBOTX",
        actor_kind: "bot",
        text: "方案写完了：先查哪一层饱和"
      },
      # Someone answering the plan does not hide it.
      %{
        ts: "1792720090.000100",
        thread: "1792720050.000100",
        author: "UBOB1",
        text: "<@UALICE1> 好，按这个方案先测"
      }
    ])

    assert {:ok, _run} = Delivery.deliver(ctx.settings, ctx.alice, @opts)

    for items <- [
          receive(do: ({:team_compose, %{"items" => items}} -> items)),
          receive(do: ({:compose, %{"items" => items}} -> items))
        ] do
      question = Enum.find(items, &(&1["text"] =~ "报价怎么算"))
      ending = Enum.find(items, &(&1["text"] == "报价单已经发给客户了"))
      assert ending["t"] == question["t"]
      refute ending["earlier"]
      # A thread's first message carries no thread; its replies still end it.
      root = Enum.find(items, &(&1["text"] =~ "网络怎么配"))
      plan = Enum.find(items, &(&1["text"] =~ "方案写完了"))
      assert plan["t"] && plan["t"] == root["t"]
    end
  end

  test "a member who turned direct messages on gets them read into their brief", ctx do
    {:ok, alice} = BridgeForTeams.DailyBrief.DirectMessages.enable(ctx.alice, "conn-1")
    assert {:ok, run} = Delivery.deliver(ctx.settings, alice, @opts)

    assert_received {:direct_messages, %{connection_id: "conn-1", slack_user_id: "UALICE1"}}
    assert_received {:compose, %{"items" => items}}
    assert %{"in" => "私信", "text" => "私下说：报价先别发"} = Enum.find(items, &(&1["in"] == "私信"))
    assert run.coverage["direct_messages"] == "read"
    assert_received {:posted, %{blocks: blocks}}
    refute inspect(blocks) =~ "direct-messages/connect"
  end

  test "the member's own words in a channel shared with another company are read", ctx do
    {:ok, alice} = BridgeForTeams.DailyBrief.DirectMessages.enable(ctx.alice, "conn-1")

    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :daily_brief_test_direct,
      {:ok,
       %{
         messages: [
           %{
             channel_id: "CEXT1",
             channel_name: "pm-tool",
             kind: "shared",
             ts: "1792720100.000100",
             thread_ts: nil,
             author: "UALICE1",
             bot?: false,
             text: "看板要给 agent 留 CLI",
             permalink: "https://acme.slack.com/archives/CEXT1/p1792720100000100"
           }
         ],
         complete?: true
       }}
    )

    assert {:ok, _run} = Delivery.deliver(ctx.settings, alice, @opts)
    assert_received {:compose, %{"items" => items}}

    # Others' answers there are not read, so the model is told.
    assert %{"by" => "你", "text" => "看板要给 agent 留 CLI", "only_mine" => true} =
             Enum.find(items, &(&1["in"] == "#pm-tool"))
  end

  test "earlier briefs are not read back as news; the member's replies to them are", ctx do
    {:ok, alice} = BridgeForTeams.DailyBrief.DirectMessages.enable(ctx.alice, "conn-1")
    assert {:ok, _first} = Delivery.deliver(ctx.settings, alice, @opts)
    assert_received {:compose, _}

    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :daily_brief_test_direct,
      {:ok,
       %{
         messages: [
           %{
             channel_id: "D_BOT",
             kind: "im",
             ts: "1792806500.000100",
             thread_ts: nil,
             author: "UBRIEFBOT",
             bot?: false,
             text: "一句话：#4973 还等你点合并",
             permalink: nil
           },
           %{
             channel_id: "D_BOT",
             kind: "im",
             ts: "1792806550.000100",
             thread_ts: nil,
             author: "UALICE1",
             bot?: false,
             text: "声音那条修了吧",
             permalink: nil
           },
           %{
             channel_id: "D9",
             kind: "im",
             ts: "1792806600.000100",
             thread_ts: nil,
             author: "UBOB1",
             bot?: false,
             text: "私下说：报价先别发",
             permalink: nil
           }
         ],
         complete?: true
       }}
    )

    tomorrow = DateTime.add(@now, 86_400)
    member = Repo.reload!(alice) |> Repo.preload(:aliases)
    assert {:ok, _} = Delivery.deliver(ctx.settings, member, Keyword.put(@opts, :now, tomorrow))
    assert_received {:compose, %{"items" => items}}
    texts = Enum.map(items, & &1["text"])
    assert "私下说：报价先别发" in texts
    assert %{"in" => "回复简报"} = Enum.find(items, &(&1["text"] == "声音那条修了吧"))
    refute Enum.any?(texts, &(&1 =~ "#4973"))
  end

  test "a revoked grant turns direct messages off and the brief is still sent", ctx do
    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :daily_brief_test_direct,
      {:error, :grant_revoked}
    )

    {:ok, alice} = BridgeForTeams.DailyBrief.DirectMessages.enable(ctx.alice, "conn-1")
    assert {:ok, run} = Delivery.deliver(ctx.settings, alice, @opts)

    assert run.coverage["direct_messages"] == "failed"
    assert Repo.reload!(alice).dm_status == "off"
  end

  test "a member who has not turned direct messages on is offered the switch", ctx do
    previous = SystemsRuntime.get_env(:bridge_for_teams_web, :public_base_url)
    SystemsRuntime.put_env(:bridge_for_teams_web, :public_base_url, "https://bft.test/")

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:bridge_for_teams_web, :public_base_url, previous),
        else: SystemsRuntime.delete_env(:bridge_for_teams_web, :public_base_url)
    end)

    assert {:ok, run} = Delivery.deliver(ctx.settings, ctx.alice, @opts)

    refute_received {:direct_messages, _}
    assert run.coverage["direct_messages"] == "off"
    assert_received {:posted, %{blocks: blocks}}
    assert %{"type" => "context", "elements" => [%{"text" => offer}]} = List.last(blocks)
    assert offer =~ "<https://bft.test/orgs/"
    assert offer =~ "/daily-brief/direct-messages/connect|开启>"
  end

  # 08:58 in Shanghai.
  @tag clock: ~U[2026-10-23 00:58:00.000000Z]
  test "the worker sends each member's brief once, after 09:00 in their zone", _ctx do
    start_supervised!(
      {BridgeForTeams.DailyBrief.DeliveryWorker, interval_ms: 60_000, run_opts: @opts}
    )

    SystemsClock.await_timers()

    SystemsClock.advance(60_000)
    SystemsClock.settle()
    refute_received {:posted, _}

    SystemsClock.advance(60_000)

    SystemsClock.settle(
      until: fn -> Repo.aggregate(DailyBriefRun |> where(kind: "personal_brief"), :count) == 2 end
    )

    assert_received {:posted, %{slack_user_id: first}}
    assert_received {:posted, %{slack_user_id: second}}
    assert Enum.sort([first, second]) == ["UALICE1", "UBOB1"]

    # Later the same day nothing is sent again.
    SystemsClock.advance(3 * 3_600_000)
    SystemsClock.settle()
    refute_received {:posted, %{slack_user_id: _}}
    assert Repo.aggregate(DailyBriefRun |> where(kind: "personal_brief"), :count) == 2
  end

  test "no brief is due on a weekend unless an admin asks; Monday's is", ctx do
    saturday = ~U[2026-10-24 02:00:00.000000Z]
    monday = ~U[2026-10-26 02:00:00.000000Z]

    refute Delivery.due?(ctx.settings, ctx.alice, saturday)
    refute Delivery.due?(ctx.settings, ctx.alice, DateTime.add(saturday, 86_400))
    assert Delivery.due?(ctx.settings, %{ctx.alice | brief_requested_at: saturday}, saturday)
    assert Delivery.due?(ctx.settings, ctx.alice, monday)
  end

  test "the organization's days off and make-up workdays move the brief", ctx do
    {:ok, settings} =
      DailyBrief.put_settings(ctx.settings.org_id, %{
        off_days: ["2026-10-26", "2026-10-26"],
        work_days: ["2026-10-24"]
      })

    assert settings.off_days == [~D[2026-10-26]]
    assert Delivery.due?(settings, ctx.alice, ~U[2026-10-24 02:00:00.000000Z])
    refute Delivery.due?(settings, ctx.alice, ~U[2026-10-26 02:00:00.000000Z])
    assert Delivery.due?(settings, ctx.alice, ~U[2026-10-27 02:00:00.000000Z])

    for bad <- [
          %{off_days: ["10/26"]},
          %{off_days: nil},
          %{off_days: [nil, "2026-10-01"]},
          %{off_days: ["2026-10-24"]}
        ] do
      assert {:error, %Ecto.Changeset{}} = DailyBrief.put_settings(ctx.settings.org_id, bad)
    end
  end

  test "a brief is written from the member's messages, the team brief, and their last one",
       ctx do
    # Yesterday's brief.
    Repo.insert!(%DailyBriefRun{
      org_id: ctx.settings.org_id,
      project_id: ctx.settings.project_id,
      member_id: ctx.alice.id,
      kind: "personal_brief",
      window_after: DateTime.add(@now, -2 * 86_400),
      window_before: DateTime.add(@now, -86_400),
      status: "completed",
      notes: %{"brief" => "<@UBOB1> 问了报价，你还没回。"}
    })

    assert {:ok, run} = Delivery.deliver(ctx.settings, ctx.alice, [now: @now] ++ @opts)

    # The team brief comes first, from the stream with nobody picked out.
    assert_received {:team_compose, team_input}
    assert Enum.any?(team_input["items"], &(&1["text"] == "@UALICE1 这个报价怎么算？"))
    assert team_input["previous_brief"] == nil

    assert_received {:compose, input}
    assert input["me"]["label"] == "@UALICE1"
    assert input["team_brief"] == "团队：报价的事 某人 在跟。"
    assert input["previous_brief"] == "@UBOB1 问了报价，你还没回。"

    # Bob's question, after the first message of its thread as context.
    assert [
             %{"ref" => "m1", "earlier" => true, "text" => "上周的报价单", "t" => thread},
             %{
               "ref" => "m2",
               "by" => "@UBOB1",
               "in" => "#sales",
               "t" => thread,
               "re" => "eyes @UALICE1"
             }
           ] = input["items"]

    assert_received {:posted, %{slack_user_id: "UALICE1", text: text, blocks: blocks}}
    assert text == "先回 <@UBOB1> 的报价。"

    # Where and when the message was said, linked, in small print; then the
    # offer to read direct messages too.
    {blocks, [%{"type" => "context"}]} = Enum.split(blocks, -1)

    assert [
             %{"type" => "header"},
             %{"type" => "section", "text" => %{"text" => "先回 <@UBOB1> 的报价。"}},
             %{
               "type" => "context",
               "elements" => [
                 %{
                   "text" =>
                     "<https://acme.slack.com/archives/C1/p1792720000000100|#sales · 10/23 09:46> · <slack://channel?team=T1&id=C1&thread_ts=1792600000.000100&message=1792720000.000100|打开>"
                 }
               ]
             }
           ] = blocks

    # The sent brief keeps what the model wrote, for tomorrow's.
    assert %{status: "completed", slack_ts: "1792720000.000100", input_tokens: 7} = run

    assert run.notes == %{
             "brief" =>
               "先回 <@UBOB1> 的报价。<https://acme.slack.com/archives/C1/p1792720000000100|#sales · 10/23 09:46> · <slack://channel?team=T1&id=C1&thread_ts=1792600000.000100&message=1792720000.000100|打开>",
             "mine" => [],
             "closed" => [],
             "issues" => %{},
             "github" => nil
           }
  end

  test "a permalink failure keeps the brief's native source link", ctx do
    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :daily_brief_test_links,
      {:error, :rate_limited}
    )

    assert {:ok, _run} = Delivery.deliver(ctx.settings, ctx.alice, [now: @now] ++ @opts)
    assert_received {:posted, %{slack_user_id: "UALICE1", blocks: blocks}}
    assert %{"elements" => [%{"text" => source}]} = Enum.find(blocks, &(&1["type"] == "context"))

    assert source ==
             "<slack://channel?team=T1&id=C1&thread_ts=1792600000.000100&message=1792720000.000100|#sales · 10/23 09:46>"
  end

  test "a brief Slack did not take is sent again as written, without another model run", ctx do
    limited = "Slack API error: rate_limited; retry_after=30"
    SystemsRuntime.put_env(:bridge_for_teams_core, :daily_brief_test_post, {:error, limited})

    assert {:error, ^limited} = Delivery.deliver(ctx.settings, ctx.alice, [now: @now] ++ @opts)
    assert_received {:posted, %{text: text, blocks: blocks}}
    assert_received {:compose, _}

    SystemsRuntime.delete_env(:bridge_for_teams_core, :daily_brief_test_post)
    later = DateTime.add(@now, 3_600)
    assert {:ok, run} = Delivery.deliver(ctx.settings, ctx.alice, [now: later] ++ @opts)

    assert_received {:posted, %{text: ^text, blocks: ^blocks}}
    refute_received {:compose, _}
    # The brief's window ended where late mirror writes had settled.
    settled = DateTime.add(@now, -600)
    assert %{status: "completed", window_before: ^settled} = run
    refute Map.has_key?(run.notes, "blocks")
  end

  test "only a passing failure is retried within the day", ctx do
    [{_, _} | _] = Delivery.claim_due(SystemsClock.utc_now(), 5)

    # Slack refuses this member for good: the brief waits for tomorrow.
    refused = "Slack API error: cannot_dm_bot"
    SystemsRuntime.put_env(:bridge_for_teams_core, :daily_brief_test_post, {:error, refused})
    assert {:error, ^refused} = Delivery.deliver(ctx.settings, ctx.alice, @opts)
    SystemsClock.advance(3_600_000)

    refute Enum.any?(Delivery.claim_due(SystemsClock.utc_now(), 5), fn {_, m} ->
             m.id == ctx.alice.id
           end)

    # A Slack rate limit, as the Slack provider reports it, is tried again
    # about an hour later.
    limited = "Slack API error: rate_limited; retry_after=30"
    SystemsRuntime.put_env(:bridge_for_teams_core, :daily_brief_test_post, {:error, limited})
    assert {:error, ^limited} = Delivery.deliver(ctx.settings, ctx.bob, @opts)
    SystemsClock.advance(3_660_000)

    assert Enum.any?(Delivery.claim_due(SystemsClock.utc_now(), 5), fn {_, m} ->
             m.id == ctx.bob.id
           end)
  end

  test "a brief the model cannot write is not sent; it is tried again over the same window",
       ctx do
    [{_, claimed}] =
      @now |> Delivery.claim_due(5) |> Enum.filter(&(elem(&1, 1).id == ctx.alice.id))

    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :daily_brief_test_compose,
      {:error, {:invalid_model_response, %{input_tokens: 900, output_tokens: 50}}}
    )

    assert {:error, :invalid_model_response} =
             Delivery.deliver(ctx.settings, claimed, [now: @now] ++ @opts)

    refute_received {:posted, %{slack_user_id: _}}

    assert %{status: "failed", error: ":invalid_model_response", input_tokens: 900} =
             failed = Repo.get_by!(DailyBriefRun, member_id: ctx.alice.id)

    later = DateTime.add(@now, 3_660)
    assert Enum.any?(Delivery.claim_due(later, 5), &(elem(&1, 1).id == ctx.alice.id))

    SystemsRuntime.delete_env(:bridge_for_teams_core, :daily_brief_test_compose)
    assert {:ok, sent} = Delivery.deliver(ctx.settings, ctx.alice, [now: later] ++ @opts)
    assert sent.window_after == failed.window_after
  end

  test "a team brief that is running keeps a second one out until it is given up", ctx do
    window = %{after: DateTime.add(@now, -86_400), before: @now}
    {:ok, running} = RunLease.claim(ctx.settings, "team_brief", window, @now)

    assert {:ok, _} = Delivery.deliver(ctx.settings, ctx.alice, [now: @now] ++ @opts)
    refute_received {:team_compose, _}

    team_briefs = fn ->
      Repo.all(
        from(r in DailyBriefRun,
          where: r.kind == "team_brief",
          order_by: r.created_at,
          select: {r.id, r.status, r.error}
        )
      )
    end

    assert [{running.id, "running", nil}] == team_briefs.()

    SystemsClock.advance(31 * 60_000)
    later = SystemsClock.utc_now()
    assert {:ok, _} = Delivery.deliver(ctx.settings, ctx.bob, [now: later] ++ @opts)

    running_id = running.id
    assert [{^running_id, "failed", "abandoned"}, {_, "completed", nil}] = team_briefs.()

    # The one given up finishes late: it does not take its run back.
    assert {:error, :abandoned} = RunLease.finish(running, "completed", %{})
  end

  test "the team brief names people only when the organization shows names", ctx do
    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :daily_brief_test_team_compose,
      {:ok,
       %{
         text: "@UBOB1 在跟报价，@UBOB1 明天给答复。[原消息](m1)",
         usage: %{input_tokens: 40, output_tokens: 10}
       }}
    )

    assert {:ok, _} = Delivery.deliver(ctx.settings, ctx.alice, [now: @now] ++ @opts)
    assert_received {:team_compose, %{"names" => "none"}}
    hidden = Repo.one(from(r in DailyBriefRun, where: r.kind == "team_brief"))
    assert hidden.notes["brief"] == "某人 在跟报价，某人 明天给答复。"

    {:ok, settings} = DailyBrief.put_settings(ctx.settings.org_id, %{team_names: "shown"})
    Repo.delete!(hidden)
    assert {:ok, _} = Delivery.deliver(settings, ctx.bob, [now: @now] ++ @opts)
    assert_received {:team_compose, %{"names" => "important"}}
    shown = Repo.one(from(r in DailyBriefRun, where: r.kind == "team_brief"))
    assert shown.notes["brief"] == "<@UBOB1> 在跟报价，<@UBOB1> 明天给答复。"
  end

  test "the team brief goes to the team's channel once, at its time", ctx do
    {:ok, settings} = DailyBrief.put_settings(ctx.settings.org_id, %{team_channel_id: "CTEAM1"})

    # Before 10:20 in Shanghai nothing is posted.
    :ok = Delivery.post_team_briefs(~U[2026-10-23 02:15:00.000000Z], @opts)
    refute_received {:posted, _}

    :ok = Delivery.post_team_briefs(~U[2026-10-23 02:25:00.000000Z], @opts)
    assert_received {:team_compose, _}
    assert_received {:posted, %{channel_id: "CTEAM1", text: "团队：报价的事 某人 在跟。", blocks: blocks}}

    assert [
             %{"type" => "header", "text" => %{"text" => "团队简报 · 10月23日"}},
             %{"type" => "context", "elements" => [%{"text" => "读了 1 条公开频道消息"}]},
             %{"type" => "section", "text" => %{"text" => "团队：报价的事 某人 在跟。"}},
             %{"type" => "context", "elements" => [%{"text" => source}]}
           ] = blocks

    assert source =~
             "<https://acme.slack.com/archives/C1/p1792720000000100|#sales · "

    :ok = Delivery.post_team_briefs(~U[2026-10-23 02:30:00.000000Z], @opts)
    refute_received {:posted, _}

    team_run = Repo.one(from(r in DailyBriefRun, where: r.kind == "team_brief"))
    assert team_run.coverage["team_brief_ts"] == "1792720000.000100"

    # The members' briefs that day use it and do not write another.
    assert {:ok, _} =
             Delivery.deliver(
               settings,
               ctx.alice,
               [now: ~U[2026-10-23 02:40:00.000000Z]] ++ @opts
             )

    refute_received {:team_compose, _}
  end

  test "the team brief is laid out by its parts, each with where its message was said" do
    text = """
    今天主要在发版。<https://s.test/1|#release · 10/23 09:10>

    ​*其他进展*​

    ​*小程序*​：iOS 在做。<https://s.test/2|#apps · 10/23 11:02> <https://s.test/3|#ios · 10/23 12:30>

    需要大家注意：镜像发布失败。

    顺带一提：Zork 关了。
    """

    assert %{blocks: blocks} = BridgeForTeams.DailyBrief.Sinks.Slack.render_team("团队简报", text)

    assert [
             %{"type" => "header"},
             %{"type" => "section", "text" => %{"text" => "今天主要在发版。"}},
             %{
               "type" => "context",
               "elements" => [%{"text" => "<https://s.test/1|#release · 10/23 09:10>"}]
             },
             %{"type" => "divider"},
             # Sources stay below the plain title.
             %{"type" => "section", "text" => %{"text" => "*小程序*\niOS 在做。"}},
             %{
               "type" => "context",
               "elements" => [
                 %{
                   "text" =>
                     "<https://s.test/2|#apps · 10/23 11:02>  /  <https://s.test/3|#ios · 10/23 12:30>"
                 }
               ]
             },
             %{"type" => "section", "text" => %{"text" => ":warning: *需要大家注意*\n镜像发布失败。"}},
             %{"type" => "context", "elements" => [%{"text" => "顺带一提：Zork 关了。"}]}
           ] = blocks
  end

  # Thursday 22:00 in Shanghai.
  @tag clock: ~U[2026-10-22 14:00:00.000000Z]
  test "the team's channel gets a brief written that day, not one from the evening before",
       ctx do
    {:ok, settings} = DailyBrief.put_settings(ctx.settings.org_id, %{team_channel_id: "CTEAM1"})

    # Thursday evening in Shanghai, an admin's request writes a team brief.
    assert {:ok, _} =
             Delivery.deliver(
               settings,
               ctx.alice,
               [now: ~U[2026-10-22 14:00:00.000000Z]] ++ @opts
             )

    assert_received {:team_compose, _}

    # Friday 10:25: less than a day later, but the channel gets Friday's.
    SystemsClock.advance((12 * 3600 + 25 * 60) * 1000)
    :ok = Delivery.post_team_briefs(SystemsClock.utc_now(), @opts)
    assert_received {:team_compose, _}
    assert_received {:posted, %{channel_id: "CTEAM1"}}
  end

  test "only cited links, people as mentions, and no keys reach Slack", ctx do
    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :daily_brief_test_compose,
      {:ok,
       %{
         text: """
         先回 @UBOB1 的报价问题，他在等你。

         ### 需要你处理
         1. **@UBOB1 在等你的报价**：还没人回。[原消息](m2)
         2. **轮换贴出来的 key**：sk-proj-abcdefghijklmnop 在群里。[原消息](m99) 见 [PR](https://github.com/x/y/pull/1)
         3. **@UBOB1说要登录**：[https://evil.test/login](x) 或 www.evil.test。
         """,
         usage: %{input_tokens: 700, output_tokens: 300}
       }}
    )

    assert {:ok, _run} = Delivery.deliver(ctx.settings, ctx.alice, [now: @now] ++ @opts)

    assert_received {:posted, %{slack_user_id: "UALICE1", blocks: blocks, text: text}}
    assert text == "先回 <@UBOB1> 的报价问题，他在等你。"
    rendered = blocks |> Enum.map(&get_in(&1, ["text", "text"])) |> Enum.join("\n")
    assert rendered =~ "*需要你处理*"
    # A title that holds a mention keeps it; its message is linked in small
    # print instead of behind the title.
    assert rendered =~ "*<@UBOB1> 在等你的报价*"

    assert %{"elements" => [%{"text" => source}]} =
             Enum.find(blocks, &(&1["type"] == "context"))

    assert source ==
             "<https://acme.slack.com/archives/C1/p1792720000000100|#sales · 10/23 09:46> · <slack://channel?team=T1&id=C1&thread_ts=1792600000.000100&message=1792720000.000100|打开>"

    assert rendered =~ "sk-proj-…"
    refute rendered =~ "abcdefgh"
    refute rendered =~ "github.com"
    refute rendered =~ "evil.test"
    assert rendered =~ "<@UBOB1>说要登录"
  end

  test "an entry title that already holds a link keeps it and names its source below" do
    text =
      "1. \u200B*修复 <https://github.com/o/r/pull/4321|#4321>*\u200B：已合。<slack://channel?team=T1&id=C1&message=1.2|#eng · 10/27 22:14>"

    assert %{blocks: [_header, entry, small]} =
             BridgeForTeams.DailyBrief.Sinks.Slack.render_personal("每日简报", text)

    assert entry["text"]["text"] ==
             "1. \u200B*修复 <https://github.com/o/r/pull/4321|#4321>*\u200B：已合。"

    assert small["elements"] == [
             %{
               "type" => "mrkdwn",
               "text" => "<slack://channel?team=T1&id=C1&message=1.2|#eng · 10/27 22:14>"
             }
           ]
  end

  test "a thread that continued in the window brings its first message as context", ctx do
    reply =
      Slack.shared_item(%{
        channel_id: "C1",
        ts: "1792700000.000300",
        thread_ts: "1792600000.000100",
        actor_kind: "user",
        actor_id: "UBOB1",
        text: "按上次的价"
      })

    assert [%{id: "1792600000.000100", text: "上周的报价单"}] =
             Slack.thread_roots(ctx.settings, [reply], ~U[2026-10-22 00:00:00.000000Z])

    # A thread that started inside the window needs none.
    assert [] = Slack.thread_roots(ctx.settings, [reply], ~U[2026-10-19 00:00:00.000000Z])
  end
end
