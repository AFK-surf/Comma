defmodule BridgeForTeams.DailyBriefLarkSuiteTest do
  @moduledoc """
  The daily brief through a Feishu or a Lark bot: members linked per
  provider, the shared read of public groups, a member's brief and the team
  brief as cards, changes asked in chat, and no direct messages. Each test
  runs for both providers.
  """

  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{Accounts, DailyBrief, Memberships, Orgs, Projects, Repo}

  alias BridgeForTeams.DailyBrief.{
    ChatSettings,
    Delivery,
    DirectMessages,
    Members,
    SharedSource,
    Sinks
  }

  alias BridgeForTeams.Schema.{DailyBriefMember, DailyBriefRun}

  # 10:00 in Shanghai, a Friday.
  @now ~U[2026-10-23 02:00:00.000000Z]
  @opts [model: __MODULE__.WritingModel, agent_id: "agt"]

  # One public group the bot is in: Bob asks Alice for a price. Feishu names
  # the mention apart from the text.
  defmodule FakeSalix do
    def daily_brief_channels(request) do
      note({:channels, request})

      {:ok,
       %{
         app_id: "cli_app",
         complete?: true,
         channels: [%{id: "oc_sales", name: "销售"}],
         gaps: %{}
       }}
    end

    def daily_brief_read_window(
          %{channel_id: "oc_sales", after_us: after_us, before_us: before_us} = request
        ) do
      note({:read_window, request})

      messages =
        for {id, us, author, text, mentions} <- [
              {"om_ask", 1_792_720_000_000_000, "ou_bob", "@Alice 这个报价怎么算？", ["ou_alice"]}
            ],
            us > after_us and us < before_us,
            do: %{
              channel_id: "oc_sales",
              ts: id,
              thread_ts: nil,
              at_us: us,
              actor_kind: "user",
              actor_id: author,
              subtype: nil,
              text: text,
              mentions: mentions,
              reactions: []
            }

      {:ok, %{messages: messages, has_more?: false, next_cursor: nil}}
    end

    def daily_brief_member_threads(request) do
      note({:member_threads, request})
      {:ok, %{threads: [], complete?: true}}
    end

    def daily_brief_active_channels(request) do
      note({:active_channels, request})
      {:ok, %{}}
    end

    def daily_brief_lookup_members(%{emails: emails} = request) do
      note({:lookup_members, request})

      {:ok,
       for email <- emails, String.starts_with?(email, "alice"), into: %{} do
         {email,
          %{open_id: "ou_alice", app_id: "cli_app", timezone: "Asia/Shanghai", names: ["Alice"]}}
       end}
    end

    def daily_brief_user_names(%{user_ids: ids}), do: {:ok, Map.new(ids, &{&1, "Name " <> &1})}

    def daily_brief_permalinks(%{messages: messages}) do
      {:ok,
       Map.new(messages, fn %{channel_id: chat, ts: id} ->
         {{chat, id}, "https://applink.feishu.cn/client/chat/open?openChatId=#{chat}"}
       end)}
    end

    def daily_brief_messages(_request), do: {:ok, %{messages: []}}

    def daily_brief_direct_messages(request) do
      note({:direct_messages, request})
      {:ok, %{messages: [], complete?: true}}
    end

    def daily_brief_post(request) do
      note({:posted, request})
      {:ok, %{channel_id: "oc_dm", ts: "om_sent"}}
    end

    defp note(message) do
      owner = SystemsRuntime.get_env(:bridge_for_teams_core, :daily_brief_test_owner)
      SystemsRuntime.Proc.send(owner || SystemsRuntime.Proc.self(), message)
    end
  end

  defmodule WritingModel do
    def compose(%{view: :team}),
      do: {:ok, %{text: "团队：报价的事 @Bob 在跟。[原消息](m1)", usage: %{input_tokens: 4, output_tokens: 2}}}

    def compose(%{view: :mine}),
      do: {:ok, %{text: ~s({"items": []}), usage: %{input_tokens: 0, output_tokens: 0}}}

    def compose(%{input: input}) do
      owner = SystemsRuntime.get_env(:bridge_for_teams_core, :daily_brief_test_owner)
      SystemsRuntime.Proc.send(owner, {:compose, input})
      {:ok, %{text: "**先回** @Bob 的报价。[原消息](m1)", usage: %{input_tokens: 7, output_tokens: 3}}}
    end
  end

  setup do
    :ok = SystemsClock.manual(epoch: @now)
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
      SystemsRuntime.delete_env(:bridge_for_teams_core, :daily_brief_test_owner)
    end)

    suffix = SystemsRuntime.Proc.unique_integer([:positive])
    group = "grp-lark-#{suffix}"
    {:ok, org} = Orgs.create_org(%{"name" => "Lark #{suffix}", "slug" => "brief-lark-#{suffix}"})

    users =
      for {name, role} <- [{"alice", "admin"}, {"bob", "member"}] do
        {:ok, user} =
          Accounts.create_user(%{
            "email" => "#{name}-lark-#{suffix}@example.test",
            "name" => name
          })

        {:ok, _} = Memberships.put_org_member(org.id, user.id, role)
        user
      end

    {:ok, project} =
      Projects.create_project(org.id, %{"name" => "Lark", "slug" => "brief-lark-#{suffix}"},
        creator_user_id: hd(users).id
      )

    Repo.update_all(from(p in BridgeForTeams.Schema.Project, where: p.id == ^project.id),
      set: [salix_group_id: group]
    )

    %{org: org, project: project, users: users, group: group}
  end

  for provider <- ["feishu", "lark"] do
    describe provider do
      @provider provider

      setup ctx do
        [alice, bob] = ctx.users

        # Alice was a Slack member before the organization moved to this provider.
        {:ok, slack_alice} =
          DailyBrief.put_member(%{
            org_id: ctx.org.id,
            user_id: alice.id,
            slack_workspace_id: "T1",
            slack_user_id: "UALICE1",
            timezone: "Asia/Shanghai"
          })

        {:ok, settings} =
          DailyBrief.put_settings(ctx.org.id, %{
            project_id: ctx.project.id,
            provider: @provider,
            connect_id: "cnx_#{@provider}",
            enabled: true
          })

        members =
          for {user, open_id} <- [{alice, "ou_alice"}, {bob, "ou_bob"}] do
            {:ok, member} =
              DailyBrief.put_member(%{
                org_id: ctx.org.id,
                user_id: user.id,
                provider: @provider,
                app_id: "cli_app",
                open_id: open_id,
                timezone: "Asia/Shanghai"
              })

            {:ok, _} =
              DailyBrief.put_aliases(member, [
                %{term: String.capitalize(to_string(user.name)), kind: "name"}
              ])

            member
          end

        Map.merge(ctx, %{settings: settings, slack_alice: slack_alice, members: members})
      end

      test "a member is linked once per provider and only this provider's members get briefs",
           ctx do
        assert ctx.settings.slack_connect_id == nil
        assert {:ok, source} = Members.source(ctx.settings)
        assert source.provider == @provider and source.connect_id == "cnx_#{@provider}"

        assert {:ok, %{linked: 1}} = Members.sync(ctx.settings)
        assert_received {:lookup_members, %{provider: @provider}}

        enabled = Members.enabled(ctx.settings)
        assert Enum.map(enabled, & &1.open_id) |> Enum.sort() == ["ou_alice", "ou_bob"]
        assert Enum.all?(enabled, &(&1.provider == @provider))
        assert Repo.get!(DailyBriefMember, ctx.slack_alice.id).slack_user_id == "UALICE1"

        # The Slack link of the same user is not due: it is not this provider's.
        claimed = Delivery.claim_due(~U[2026-10-23 02:00:00.000000Z], 10)

        assert claimed |> Enum.map(&elem(&1, 1).id) |> Enum.sort() ==
                 ctx.members |> Enum.map(& &1.id) |> Enum.sort()
      end

      test "the shared read names people by open id and finds a mention Feishu named apart",
           ctx do
        [alice, _bob] = ctx.members

        assert {:ok, shared} =
                 SharedSource.read(ctx.settings, %{after: ~U[2026-10-22 00:00:00Z], before: @now},
                   members: Repo.preload(ctx.members, :aliases)
                 )

        assert_received {:channels, %{provider: @provider, member_open_ids: []}}
        assert_received {:active_channels, %{open_ids: open_ids}}
        assert Enum.sort(open_ids) == ["ou_alice", "ou_bob"]
        refute_received {:channels, %{member_slack_ids: _}}

        assert [%{message: %{ts: "om_ask"}, reasons: reasons, tier: :p0}] =
                 shared.relevant[alice.id]

        assert :mention in reasons
        assert shared.channel_names == %{"oc_sales" => "销售"}
      end

      test "a member's brief is a card sent to their open id, without a direct-message offer",
           ctx do
        [alice, _bob] = ctx.members

        assert {:ok, run} = Delivery.deliver(ctx.settings, alice, [now: @now] ++ @opts)
        assert run.status == "completed"
        assert run.provider_chat_id == "oc_dm" and run.provider_message_id == "om_sent"
        assert run.slack_ts == nil
        refute Map.has_key?(run.notes, "card")
        assert run.coverage["direct_messages"] == "off"

        refute_received {:direct_messages, _}
        assert_received {:compose, %{"items" => [item | _]}}
        assert item["in"] == "销售" and item["by"] == "@Bob"

        assert_received {:posted,
                         %{provider: @provider, open_id: "ou_alice", card: card} = request}

        refute Map.has_key?(request, :blocks)

        assert %{"header" => %{"title" => %{"content" => "每日简报 · 10月23日"}}} = card
        markdown = Enum.map_join(card["elements"], "\n", &element_text/1)
        assert markdown =~ "**先回** <at id=ou_bob></at> 的报价。"

        assert markdown =~
                 "[销售 · 10/23 09:46](https://applink.feishu.cn/client/chat/open?openChatId=oc_sales)"

        refute markdown =~ "私信"
        refute markdown =~ "<@"
      end

      test "the team brief goes to the team's group as a card", ctx do
        {:ok, settings} = DailyBrief.put_settings(ctx.org.id, %{team_channel_id: "oc_team"})
        assert settings.provider == @provider

        :ok = Delivery.post_team_briefs(~U[2026-10-23 02:25:00.000000Z], @opts)

        assert_received {:posted, %{channel_id: "oc_team", card: card}}
        assert %{"header" => %{"title" => %{"content" => "团队简报 · 10月23日"}}} = card
        markdown = Enum.map_join(card["elements"], "\n", &element_text/1)
        assert markdown =~ "读了 1 条公开群消息"
        # Names are hidden unless the organization shows them.
        assert markdown =~ "团队：报价的事 某人 在跟。"
        refute markdown =~ "<at"

        team_run =
          Repo.one(
            from(r in DailyBriefRun, where: r.kind == "team_brief" and r.org_id == ^ctx.org.id)
          )

        assert team_run.coverage["team_brief_ts"] == "om_sent"
      end

      test "a member changes their own brief by asking the bot that sends it", ctx do
        alice = origin(ctx.group, @provider, "ou_alice", "cnx_#{@provider}")

        assert {:ok, %{"projects" => ["Photon"]}} =
                 ChatSettings.set_project(ctx.group, alice, "Photon", "add")

        assert {:ok, %{"main_channels" => ["销售"]}} =
                 ChatSettings.set_channel(
                   ctx.group,
                   alice,
                   "https://applink.feishu.cn/client/chat/open?openChatId=oc_sales",
                   "follow"
                 )

        assert {:ok, %{"brief" => "mine", "time" => "08:30"}} =
                 ChatSettings.set_time(ctx.group, alice, "mine", "08:30")

        assert {:error, :not_a_brief_member} =
                 ChatSettings.set_time(
                   ctx.group,
                   origin(ctx.group, @provider, "ou_nobody", "cnx_#{@provider}"),
                   "mine",
                   "08:00"
                 )

        # Another bot, or the Slack identity of the same person, changes nothing.
        assert {:error, :daily_brief_not_set_up} =
                 ChatSettings.set_time(
                   ctx.group,
                   origin(ctx.group, @provider, "ou_alice", "cnx_other"),
                   "mine",
                   "08:00"
                 )

        slack = %{
          origin(ctx.group, "slack", "UALICE1", "cnx_#{@provider}")
          | "provider_context" => %{
              "user_id" => "UALICE1",
              "connect_id" => "cnx_#{@provider}",
              "workspace_id" => "T1"
            }
        }

        assert {:error, :daily_brief_not_set_up} =
                 ChatSettings.set_time(ctx.group, slack, "mine", "07:00")

        assert Repo.get!(DailyBriefMember, ctx.slack_alice.id).deliver_at == ~T[09:00:00]
      end

      test "direct messages are never read or offered", ctx do
        [alice, _bob] = ctx.members

        assert DirectMessages.start_connect(ctx.settings, alice, "https://bft.test/back") ==
                 {:error, :direct_messages_slack_only}

        assert DirectMessages.read(ctx.settings, alice, %{after: @now, before: @now}) ==
                 {:ok, %{messages: [], complete?: true}}

        refute_received {:direct_messages, _}
      end

      test "the team group is a group id of this provider", ctx do
        assert {:error, changeset} =
                 DailyBrief.put_settings(ctx.org.id, %{team_channel_id: "CTEAM1"})

        assert Keyword.has_key?(changeset.errors, :team_channel_id)

        # Moving back to Slack needs a Slack channel, not the group.
        {:ok, _} = DailyBrief.put_settings(ctx.org.id, %{team_channel_id: "oc_team"})

        assert {:error, changeset} =
                 DailyBrief.put_settings(ctx.org.id, %{
                   provider: "slack",
                   slack_connect_id: "imc_x"
                 })

        assert Keyword.has_key?(changeset.errors, :team_channel_id)

        assert {:ok, slack} =
                 DailyBrief.put_settings(ctx.org.id, %{
                   provider: "slack",
                   slack_connect_id: "imc_x",
                   team_channel_id: nil
                 })

        assert slack.connect_id == "imc_x" and slack.slack_connect_id == "imc_x"
      end
    end
  end

  test "card Markdown keeps mentions, links and bold from the checked brief" do
    %{card: card} =
      Sinks.Feishu.render_personal(
        "每日简报",
        "开场\n\n*待你*\n1. 回 <@ou_bob> 的报价 ​*今天*​ <https://applink.feishu.cn/x|销售 · 10/23 10:26>"
      )

    assert [%{"tag" => "markdown", "content" => "开场"}, %{"tag" => "hr"}, body, source] =
             card["elements"]

    assert body["content"] == "**待你**\n1. 回 <at id=ou_bob></at> 的报价 **今天**"

    assert source == %{
             "tag" => "note",
             "elements" => [
               %{
                 "tag" => "lark_md",
                 "content" => "[销售 · 10/23 10:26](https://applink.feishu.cn/x)"
               }
             ]
           }
  end

  defp element_text(%{"tag" => "markdown", "content" => content}), do: content

  defp element_text(%{"tag" => "note", "elements" => elements}),
    do: Enum.map_join(elements, " ", & &1["content"])

  defp element_text(_element), do: ""

  defp origin(group, provider, user_id, connect_id) do
    %{
      "provider" => provider,
      "source_actor_type" => "provider_user",
      "agent_group_id" => group,
      "provider_context" => %{"sender_open_id" => user_id, "connect_id" => connect_id}
    }
  end
end
