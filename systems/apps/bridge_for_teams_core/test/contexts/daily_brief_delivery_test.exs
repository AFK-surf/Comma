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
      messages =
        for {ts, text} <- [{"1792720000.000100", "<@UALICE1> 这个报价怎么算？"}],
            us = trunc(String.to_float(ts) * 1_000_000),
            us > after_us and us < before_us,
            do: message(ts, "1792600000.000100", "UBOB1", text)

      {:ok, %{messages: messages, has_more?: false, next_cursor: nil}}
    end

    def daily_brief_member_threads(_request), do: {:ok, %{threads: [], complete?: true}}

    def daily_brief_user_names(%{user_ids: ids}),
      do: {:ok, Map.new(ids, &{&1, "Name " <> &1}) |> Map.delete("UBOB1")}

    def daily_brief_messages(%{channel_id: channel, ts: ts}),
      do:
        {:ok,
         %{
           messages: for(t <- ts, do: %{message(t, t, "UALICE1", "上周的报价单") | channel_id: channel})
         }}

    def daily_brief_permalinks(%{messages: messages}),
      do:
        {:ok,
         Map.new(messages, &{{&1.channel_id, &1.ts}, "https://s.test/#{&1.channel_id}/#{&1.ts}"})}

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
                    daily_brief_test_team_compose)a,
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
             %{"ref" => "m2", "by" => "@UBOB1", "in" => "#sales", "t" => thread}
           ] = input["items"]

    assert_received {:posted, %{slack_user_id: "UALICE1", text: text, blocks: blocks}}
    assert text == "先回 <@UBOB1> 的报价。原消息"

    assert [%{"type" => "header"}, %{"type" => "section", "text" => %{"text" => written}}] =
             blocks

    assert written == "先回 <@UBOB1> 的报价。<https://s.test/C1/1792720000.000100|原消息>"

    # The sent brief keeps what the model wrote, for tomorrow's.
    assert %{status: "completed", slack_ts: "1792720000.000100", input_tokens: 7} = run
    assert run.notes == %{"brief" => written}
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
    assert_received {:posted, %{channel_id: "CTEAM1", text: "团队：报价的事 某人 在跟。原消息", blocks: blocks}}

    assert [
             %{"type" => "header", "text" => %{"text" => "团队简报 · 10月23日"}},
             %{"type" => "context", "elements" => [%{"text" => "读了 1 条公开频道消息"}]},
             %{"type" => "section", "text" => %{"text" => opening}}
           ] = blocks

    assert opening =~ "<https://s.test/C1/1792720000.000100|原消息>"

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

  test "the team brief is laid out by its parts" do
    text = """
    今天主要在发版。<https://s.test/1|原消息>

    ​*其他进展*​

    ​*小程序*​：iOS 在做。<https://s.test/2|原消息>

    需要大家注意：镜像发布失败。

    顺带一提：Zork 关了。
    """

    assert %{blocks: blocks} = BridgeForTeams.DailyBrief.Sinks.Slack.render_team("团队简报", text)

    assert [
             %{"type" => "header"},
             %{"type" => "section", "text" => %{"text" => "今天主要在发版。<https://s.test/1|原消息>"}},
             %{"type" => "divider"},
             %{
               "type" => "section",
               "text" => %{"text" => "*小程序*\niOS 在做。"},
               "accessory" => %{"type" => "button", "url" => "https://s.test/2"}
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
    # Each entry's message is a button beside it.
    assert Enum.any?(
             blocks,
             &(get_in(&1, ["accessory", "url"]) == "https://s.test/C1/1792720000.000100")
           )

    assert rendered =~ "*需要你处理*"
    assert rendered =~ "*<@UBOB1> 在等你的报价*"
    assert rendered =~ "sk-proj-…"
    refute rendered =~ "abcdefgh"
    refute rendered =~ "github.com"
    refute rendered =~ "evil.test"
    assert rendered =~ "<@UBOB1>说要登录"
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
