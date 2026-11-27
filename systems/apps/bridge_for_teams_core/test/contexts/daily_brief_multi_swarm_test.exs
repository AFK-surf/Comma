defmodule BridgeForTeams.DailyBriefMultiSwarmTest do
  @moduledoc """
  One organization, three Agent Swarms with Feishu bots of their own: R&D
  (`cli_rd`), finance (`cli_fin`), and the CXO Swarm (`cli_cxo`), which may
  search the other two. Each Swarm keeps its own settings and team brief; a
  person in several Swarms is one member with one personal brief, sent once
  through the bot of the Swarm that sends it.
  """

  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{Accounts, DailyBrief, Memberships, Orgs, Projects, Repo}

  alias BridgeForTeams.DailyBrief.{
    ChatSettings,
    Compose,
    Delivery,
    DeliveryWorker,
    Members,
    Scope,
    SharedSource,
    Sources
  }

  alias BridgeForTeams.Schema.{DailyBriefMember, DailyBriefRun, Project, SearchGrant}

  # 10:00 in Shanghai, a Friday.
  @now ~U[2026-10-23 02:00:00.000000Z]
  @window %{after: ~U[2026-10-22 00:00:00Z], before: @now}
  @opts [model: __MODULE__.WritingModel, agent_id: "agt"]

  # The groups each bot is in. All-hands (`oc_shared`) has the CXO and the
  # R&D bots; each bot names its people by its own app's open ids.
  defmodule FakeSalix do
    @groups %{
      "cnx_cxo" => [%{id: "oc_cxo", name: "经营组"}, %{id: "oc_shared", name: "全员群"}],
      "cnx_rd" => [%{id: "oc_rd", name: "研发群"}, %{id: "oc_shared", name: "全员群"}],
      "cnx_fin" => [%{id: "oc_fin", name: "财务群"}]
    }

    # {chat, id, author, text, mentions}
    @messages [
      {"oc_cxo", "om_cxo", "ou_cxo_ceo", "下周经营会改到周三", []},
      {"oc_shared", "om_shared", "ou_cxo_ceo", "全员：年会报名开始了", []},
      {"oc_rd", "om_rd", "ou_rd_dev", "@Lead 2.4 发版要你确认", ["ou_rd_lead"]},
      {"oc_fin", "om_fin", "ou_fin_cfo", "Q4 预算已批", []}
    ]

    # Who each app knows, by email prefix.
    @people %{
      "cnx_cxo" => %{"lead" => "ou_cxo_lead"},
      "cnx_rd" => %{"lead" => "ou_rd_lead", "dev" => "ou_rd_dev"},
      "cnx_fin" => %{}
    }

    @apps %{"cnx_cxo" => "cli_cxo", "cnx_rd" => "cli_rd", "cnx_fin" => "cli_fin"}

    def daily_brief_channels(%{connect_id: connect} = request) do
      note({:channels, request})

      {:ok, %{app_id: @apps[connect], complete?: true, channels: @groups[connect], gaps: %{}}}
    end

    def daily_brief_read_window(%{
          connect_id: connect,
          channel_id: chat,
          after_us: after_us,
          before_us: before_us
        }) do
      note({:read_window, connect, chat})
      true = Enum.any?(@groups[connect], &(&1.id == chat))

      messages =
        for {^chat, id, author, text, mentions} <- @messages,
            us = 1_792_720_000_000_000,
            us > after_us and us < before_us,
            do: %{
              channel_id: chat,
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

    def daily_brief_lookup_members(%{connect_id: connect, emails: emails}) do
      {:ok,
       for email <- emails,
           [prefix | _] = String.split(email, "-"),
           open_id = @people[connect][prefix],
           open_id,
           into: %{} do
         {email,
          %{
            open_id: open_id,
            app_id: @apps[connect],
            timezone: "Asia/Shanghai",
            names: [String.capitalize(prefix)]
          }}
       end}
    end

    def daily_brief_user_names(%{user_ids: ids}), do: {:ok, Map.new(ids, &{&1, "Name_" <> &1})}

    def daily_brief_permalinks(%{messages: messages}) do
      {:ok,
       Map.new(messages, fn %{channel_id: chat, ts: id} ->
         {{chat, id}, "https://applink.feishu.cn/client/chat/open?openChatId=#{chat}"}
       end)}
    end

    def daily_brief_messages(_request), do: {:ok, %{messages: []}}
    def daily_brief_direct_messages(_request), do: {:ok, %{messages: [], complete?: true}}

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
      do: {:ok, %{text: "团队：发版在推进。", usage: %{input_tokens: 4, output_tokens: 2}}}

    def compose(%{view: :mine}),
      do: {:ok, %{text: ~s({"items": []}), usage: %{input_tokens: 0, output_tokens: 0}}}

    # The member's brief names the member themself, by their label.
    def compose(%{input: input}) do
      owner = SystemsRuntime.get_env(:bridge_for_teams_core, :daily_brief_test_owner)
      SystemsRuntime.Proc.send(owner, {:compose, input})
      me = input["me"]["label"]
      {:ok, %{text: "**先回** #{me}：确认 2.4 发版。", usage: %{input_tokens: 7, output_tokens: 3}}}
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

    {:ok, org} =
      Orgs.create_org(%{"name" => "Multi #{suffix}", "slug" => "brief-multi-#{suffix}"})

    [lead, dev] =
      for {name, role} <- [{"lead", "admin"}, {"dev", "member"}] do
        {:ok, user} =
          Accounts.create_user(%{"email" => "#{name}-#{suffix}@example.test", "name" => name})

        {:ok, _} = Memberships.put_org_member(org.id, user.id, role)
        user
      end

    projects =
      Map.new(["cxo", "rd", "fin"], fn key ->
        {:ok, project} =
          Projects.create_project(
            org.id,
            %{"name" => key, "slug" => "brief-#{key}-#{suffix}"},
            creator_user_id: lead.id
          )

        Repo.update_all(from(p in Project, where: p.id == ^project.id),
          set: [salix_group_id: "grp-#{key}-#{suffix}"]
        )

        {key, %{project | salix_group_id: "grp-#{key}-#{suffix}"}}
      end)

    # The CXO Swarm may search R&D and finance.
    for target <- ["rd", "fin"] do
      Repo.insert!(
        SearchGrant.changeset(%SearchGrant{}, %{
          org_id: org.id,
          subject_kind: "project",
          subject_id: projects["cxo"].id,
          target_kind: "project",
          target_id: projects[target].id
        })
      )
    end

    {:ok, _} = Memberships.put_project_member(projects["rd"].id, lead.id, "user")
    {:ok, _} = Memberships.put_project_member(projects["rd"].id, dev.id, "user")

    # Saved CXO first, then R&D, then finance.
    settings =
      Map.new(["cxo", "rd", "fin"], fn key ->
        {:ok, settings} =
          DailyBrief.put_settings(org.id, %{
            project_id: projects[key].id,
            provider: "feishu",
            connect_id: "cnx_#{key}",
            enabled: true
          })

        {key, settings}
      end)

    %{org: org, lead: lead, dev: dev, projects: projects, settings: settings, suffix: suffix}
  end

  test "each Swarm keeps its own settings; saving one never changes another", ctx do
    assert ctx.org.id |> DailyBrief.list_settings() |> Enum.map(& &1.connect_id) ==
             ["cnx_cxo", "cnx_rd", "cnx_fin"]

    {:ok, _} =
      DailyBrief.put_settings(ctx.org.id, %{
        project_id: ctx.projects["rd"].id,
        team_channel_id: "oc_rd",
        team_post_at: ~T[09:30:00]
      })

    assert DailyBrief.get_settings(ctx.org.id, ctx.projects["rd"].id).team_channel_id == "oc_rd"
    cxo = DailyBrief.get_settings(ctx.org.id, ctx.projects["cxo"].id)
    assert cxo.team_channel_id == nil and cxo.team_post_at == ~T[10:20:00]
    assert DailyBrief.get_settings(ctx.org.id, ctx.projects["fin"].id).connect_id == "cnx_fin"
    # A page that names no Swarm shows the first saved.
    assert DailyBrief.get_settings(ctx.org.id).id == cxo.id
  end

  test "the CXO team brief reads the Swarms it may search, a shared group once", ctx do
    assert Scope.key(Scope.team(ctx.settings["cxo"])) ==
             Enum.map(["cxo", "rd", "fin"], &ctx.settings[&1].id)

    # R&D may search nobody: its brief reads its own groups only.
    assert Scope.key(Scope.team(ctx.settings["rd"])) == [ctx.settings["rd"].id]

    assert {:ok, shared} =
             SharedSource.read(Scope.team(ctx.settings["cxo"]), @window, members: [])

    reads = collect_reads()

    assert Enum.sort(reads) ==
             Enum.sort([
               {"cnx_cxo", "oc_cxo"},
               {"cnx_cxo", "oc_shared"},
               {"cnx_rd", "oc_rd"},
               {"cnx_fin", "oc_fin"}
             ])

    assert shared.messages |> Enum.map(& &1.ts) |> Enum.sort() ==
             ["om_cxo", "om_fin", "om_rd", "om_shared"]

    assert shared.coverage.channels_total == 4 and shared.coverage.channels_read == 4
    assert SharedSource.complete?(shared.coverage)
    assert shared.app_id == "cli_cxo"
  end

  test "a lead in two Swarms is one member and gets one brief, through the bot that sends it",
       ctx do
    # The CXO bot links them first; R&D's bot then finds them too.
    assert {:ok, %{linked: 1}} = Members.sync(ctx.settings["cxo"])
    assert {:ok, %{linked: 2}} = Members.sync(ctx.settings["rd"])

    assert [lead] =
             Repo.all(from(m in DailyBriefMember, where: m.user_id == ^ctx.lead.id))

    assert lead.project_id == ctx.projects["cxo"].id
    assert {lead.app_id, lead.open_id} == {"cli_cxo", "ou_cxo_lead"}
    assert lead.app_open_ids == %{"cli_cxo" => "ou_cxo_lead", "cli_rd" => "ou_rd_lead"}

    dev = Repo.get_by!(DailyBriefMember, user_id: ctx.dev.id)
    assert dev.project_id == ctx.projects["rd"].id

    # A mention in R&D's group, by R&D's open id, reaches the lead's brief.
    assert {:ok, shared} =
             SharedSource.read(Scope.personal(ctx.settings["cxo"], lead), @window,
               members: Repo.preload([lead], :aliases)
             )

    assert [%{message: message, reasons: reasons}] =
             Enum.filter(shared.relevant[lead.id], &(&1.message.ts == "om_rd"))

    assert :mention in reasons
    # Written as the CXO app knows them.
    assert message.mentions == ["ou_cxo_lead"]

    assert {:ok, 2} = DeliveryWorker.run_once([now: @now, batch: 10] ++ @opts)

    posted = collect_posts()

    personal = for {:posted, %{open_id: id} = request} <- posted, do: {id, request.connect_id}
    assert Enum.sort(personal) == [{"ou_cxo_lead", "cnx_cxo"}, {"ou_rd_dev", "cnx_rd"}]

    assert {:posted, %{card: card}} =
             Enum.find(posted, &match?({:posted, %{open_id: "ou_cxo_lead"}}, &1))

    markdown = inspect(card)
    assert markdown =~ "<at id=ou_cxo_lead></at>"
    refute markdown =~ "ou_rd_lead"

    assert [run] =
             Repo.all(
               from(r in DailyBriefRun,
                 where: r.member_id == ^lead.id and r.kind == "personal_brief"
               )
             )

    assert run.project_id == ctx.projects["cxo"].id and run.status == "completed"
  end

  test "a member changes their one brief through any Swarm's bot; team time stays its own",
       ctx do
    {:ok, _} = Members.sync(ctx.settings["cxo"])
    {:ok, _} = Members.sync(ctx.settings["rd"])

    group = "grp-rd-#{ctx.suffix}"
    rd_lead = origin(group, "ou_rd_lead", "cnx_rd")

    assert {:ok, %{"time" => "08:30"}} = ChatSettings.set_time(group, rd_lead, "mine", "08:30")
    assert Repo.get_by!(DailyBriefMember, user_id: ctx.lead.id).deliver_at == ~T[08:30:00]

    assert {:ok, %{"brief" => "team", "time" => "09:45"}} =
             ChatSettings.set_time(group, rd_lead, "team", "09:45")

    assert DailyBrief.get_settings(ctx.org.id, ctx.projects["rd"].id).team_post_at ==
             ~T[09:45:00]

    assert DailyBrief.get_settings(ctx.org.id, ctx.projects["cxo"].id).team_post_at ==
             ~T[10:20:00]
  end

  test "an admin moves a member's brief to another Swarm's bot", ctx do
    {:ok, _} = Members.sync(ctx.settings["cxo"])
    lead = Repo.get_by!(DailyBriefMember, user_id: ctx.lead.id)

    assert {:ok, moved} =
             DailyBrief.assign_member_project(ctx.org.id, lead.id, ctx.projects["rd"].id)

    assert moved.project_id == ctx.projects["rd"].id
    assert {moved.app_id, moved.open_id} == {"cli_rd", "ou_rd_lead"}
    assert moved.app_open_ids == %{"cli_cxo" => "ou_cxo_lead", "cli_rd" => "ou_rd_lead"}

    # Finance's bot cannot find them.
    assert {:error, :member_not_in_app} =
             DailyBrief.assign_member_project(ctx.org.id, lead.id, ctx.projects["fin"].id)
  end

  # What the fake Salix noted so far, oldest first; taken out of the mailbox.
  defp noted do
    receive do
      message -> [message | noted()]
    after
      0 -> []
    end
  end

  defp collect_reads, do: for({:read_window, connect, chat} <- noted(), do: {connect, chat})
  defp collect_posts, do: for({:posted, _} = posted <- noted(), do: posted)

  defp origin(group, user_id, connect_id) do
    %{
      "provider" => "feishu",
      "source_actor_type" => "provider_user",
      "agent_group_id" => group,
      "provider_context" => %{"sender_open_id" => user_id, "connect_id" => connect_id}
    }
  end

  defp origin(group, provider, user_id, connect_id) do
    %{
      "provider" => provider,
      "source_actor_type" => "provider_user",
      "agent_group_id" => group,
      "provider_context" => %{"sender_open_id" => user_id, "connect_id" => connect_id}
    }
  end

  defmodule StrictSalix do
    @groups %{
      "cnx_cxo" => [%{id: "oc_cxo", name: "经营组"}, %{id: "oc_shared", name: "全员群"}],
      "cnx_rd" => [%{id: "oc_rd", name: "研发群"}, %{id: "oc_shared", name: "全员群"}],
      "cnx_fin" => [%{id: "oc_fin", name: "财务群"}]
    }

    @apps %{"cnx_cxo" => "cli_cxo", "cnx_rd" => "cli_rd", "cnx_fin" => "cli_fin"}

    @people %{
      "cnx_cxo" => %{"lead" => "ou_cxo_lead"},
      "cnx_rd" => %{"lead" => "ou_rd_lead", "dev" => "ou_rd_dev"},
      "cnx_fin" => %{}
    }

    @user_names %{
      "cnx_cxo" => %{"ou_cxo_ceo" => "王总"},
      "cnx_rd" => %{"ou_rd_outsider" => "张三"},
      "cnx_fin" => %{"ou_fin_cfo" => "赵总"}
    }

    def daily_brief_channels(%{connect_id: connect} = request) do
      note({:channels, request})

      if fail?(connect, :channels) do
        {:error, :timeout}
      else
        {:ok, %{app_id: @apps[connect], complete?: true, channels: @groups[connect], gaps: %{}}}
      end
    end

    def daily_brief_read_window(%{
          connect_id: connect,
          channel_id: chat,
          after_us: after_us,
          before_us: before_us
        }) do
      note({:read_window, connect, chat})
      true = Enum.any?(@groups[connect], &(&1.id == chat))

      all = [
        %{
          channel_id: "oc_cxo",
          ts: "om_cxo_1",
          thread_ts: nil,
          at_us: 1_792_720_000_000_000,
          actor_kind: "user",
          actor_id: "ou_cxo_ceo",
          subtype: nil,
          text: "经营组：请 @Lead 确认下周评审",
          mentions: ["ou_cxo_lead"],
          reactions: []
        },
        %{
          channel_id: "oc_rd",
          ts: "om_rd_reply",
          thread_ts: "om_rd_root",
          at_us: 1_792_720_100_000_000,
          actor_kind: "user",
          actor_id: "ou_rd_outsider",
          subtype: nil,
          text: "研发群：<@ou_rd_lead> 和 <@ou_rd_dev> 看下 2.4 发版阻塞",
          mentions: ["ou_rd_lead", "ou_rd_dev"],
          reactions: []
        }
      ]

      messages =
        Enum.filter(all, fn m ->
          m.channel_id == chat and m.at_us > after_us and m.at_us < before_us
        end)

      {:ok, %{messages: messages, has_more?: false, next_cursor: nil}}
    end

    def daily_brief_member_threads(_request), do: {:ok, %{threads: [], complete?: true}}
    def daily_brief_active_channels(_request), do: {:ok, %{}}

    def daily_brief_lookup_members(%{connect_id: connect, emails: emails} = request) do
      note({:lookup_members, request})

      if fail?(connect, :lookup_members) do
        {:error, :timeout}
      else
        {:ok,
         for email <- emails,
             [prefix | _] = String.split(email, "-"),
             open_id = @people[connect][prefix],
             open_id,
             into: %{} do
           {email,
            %{
              open_id: open_id,
              app_id: @apps[connect],
              timezone: "Asia/Shanghai",
              names: [String.capitalize(prefix)]
            }}
         end}
      end
    end

    # Only resolves open_ids belonging to this app's connect_id (simulating Feishu/Lark 99992361).
    def daily_brief_user_names(%{connect_id: connect, user_ids: ids} = request) do
      note({:user_names, request})
      known = Map.get(@user_names, connect, %{})

      {:ok,
       for id <- ids, name = known[id], is_binary(name), into: %{} do
         {id, name}
       end}
    end

    # Only returns permalinks for chats the connect's bot is actually in.
    def daily_brief_permalinks(%{connect_id: connect, provider: provider, messages: messages}) do
      note({:permalinks, connect, Enum.map(messages, & &1.channel_id)})
      readable = MapSet.new(@groups[connect] || [], & &1.id)
      host = if provider == "lark", do: "applink.larksuite.com", else: "applink.feishu.cn"

      {:ok,
       for %{channel_id: chat, ts: id} <- messages,
           MapSet.member?(readable, chat),
           into: %{} do
         {{chat, id}, "https://#{host}/client/chat/open?openChatId=#{chat}"}
       end}
    end

    # Only returns thread roots when queried via the Swarm whose bot is in the chat.
    def daily_brief_messages(%{connect_id: connect, channel_id: chat, ts: ids}) do
      note({:messages, connect, chat, ids})

      if connect == "cnx_rd" and chat == "oc_rd" and "om_rd_root" in ids do
        {:ok,
         %{
           messages: [
             %{
               channel_id: "oc_rd",
               ts: "om_rd_root",
               thread_ts: nil,
               at_us: 1_792_600_000_000_000,
               actor_kind: "user",
               actor_id: "ou_rd_lead",
               subtype: nil,
               text: "2.4 发版主帖 <@ou_rd_dev>",
               mentions: ["ou_rd_dev"],
               reactions: []
             }
           ]
         }}
      else
        {:error, :channel_ineligible}
      end
    end

    def daily_brief_direct_messages(_request), do: {:ok, %{messages: [], complete?: true}}

    def daily_brief_post(request) do
      note({:posted, request})
      {:ok, %{channel_id: "oc_dm", ts: "om_sent"}}
    end

    defp fail?(connect, op) do
      fails =
        SystemsRuntime.get_env(:bridge_for_teams_core, :daily_brief_test_fails) || MapSet.new()

      MapSet.member?(fails, {connect, op})
    end

    defp note(message) do
      owner = SystemsRuntime.get_env(:bridge_for_teams_core, :daily_brief_test_owner)
      SystemsRuntime.Proc.send(owner || SystemsRuntime.Proc.self(), message)
    end
  end

  defmodule CrossSwarmModel do
    def compose(%{view: :team, input: input}) do
      owner = SystemsRuntime.get_env(:bridge_for_teams_core, :daily_brief_test_owner)
      SystemsRuntime.Proc.send(owner, {:compose_team, input})
      refs = Enum.map(input["items"], & &1["ref"])
      cited = Enum.map_join(refs, " ", &"[原消息](#{&1})")

      {:ok,
       %{
         text: "团队：@张三 和 @Dev 跟进发版，@王总 和 @Lead 确认评审。#{cited}",
         usage: %{input_tokens: 4, output_tokens: 2}
       }}
    end

    def compose(%{view: :mine}),
      do: {:ok, %{text: ~s({"items": []}), usage: %{input_tokens: 0, output_tokens: 0}}}

    def compose(%{input: input}) do
      owner = SystemsRuntime.get_env(:bridge_for_teams_core, :daily_brief_test_owner)
      SystemsRuntime.Proc.send(owner, {:compose, input})
      refs = Enum.map(input["items"], & &1["ref"])
      cited = Enum.map_join(refs, " ", &"[原消息](#{&1})")

      {:ok,
       %{
         text: "**先回** @王总 和 @Lead 评审，@张三 和 @Dev 阻塞。#{cited}",
         usage: %{input_tokens: 7, output_tokens: 3}
       }}
    end
  end

  for provider <- ["feishu", "lark"] do
    describe "cross-app multi-swarm fixes (#{provider})" do
      @provider provider

      setup ctx do
        SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, StrictSalix)
        SystemsRuntime.delete_env(:bridge_for_teams_core, :daily_brief_test_fails)

        on_exit(fn ->
          SystemsRuntime.delete_env(:bridge_for_teams_core, :daily_brief_test_fails)
        end)

        settings =
          Map.new(["cxo", "rd", "fin"], fn key ->
            {:ok, s} =
              DailyBrief.put_settings(ctx.org.id, %{
                project_id: ctx.projects[key].id,
                provider: @provider,
                connect_id: "cnx_#{key}",
                team_names: "shown",
                enabled: true
              })

            {key, s}
          end)

        %{ctx | settings: settings}
      end

      test "1-3: cross-swarm permalinks, thread_roots, user_names and no cross-app at tags",
           ctx do
        assert {:ok, %{linked: 1}} = Members.sync(ctx.settings["cxo"])
        assert {:ok, %{linked: 2}} = Members.sync(ctx.settings["rd"])

        lead = Repo.get_by!(DailyBriefMember, user_id: ctx.lead.id, provider: @provider)

        assert {:ok, run} =
                 Delivery.deliver(
                   ctx.settings["cxo"],
                   lead,
                   now: @now,
                   model: CrossSwarmModel,
                   agent_id: "agt"
                 )

        assert run.status == "completed"

        events = noted()

        # Fix 2: thread_roots queried via cnx_rd and author ou_rd_lead renamed to "你"
        assert {:compose, input} = Enum.find(events, &match?({:compose, _}, &1))
        earlier = Enum.find(input["items"], &(&1["earlier"] == true))
        assert earlier != nil
        assert earlier["in"] == "研发群"
        assert earlier["by"] == "你"
        assert Enum.any?(events, &match?({:messages, "cnx_rd", "oc_rd", ["om_rd_root"]}, &1))

        # Fix 3a: non-member ou_rd_outsider resolved via cnx_rd to @张三 (not raw @ou_rd_outsider)
        rd_reply = Enum.find(input["items"], &(&1["in"] == "研发群" and not (&1["earlier"] == true)))
        assert rd_reply["by"] == "@张三"
        assert Enum.any?(events, &match?({:user_names, %{connect_id: "cnx_rd"}}, &1))

        # Fix 1: permalinks queried per source Swarm so both oc_cxo and oc_rd links appear
        assert Enum.any?(events, fn
                 {:permalinks, "cnx_rd", chats} -> "oc_rd" in chats
                 _ -> false
               end)

        assert {:posted, %{open_id: "ou_cxo_lead", card: card}} =
                 Enum.find(events, &match?({:posted, %{open_id: "ou_cxo_lead"}}, &1))

        markdown = inspect(card)
        assert markdown =~ "openChatId=oc_cxo"
        assert markdown =~ "openChatId=oc_rd"

        # Fix 3b: same-app open_ids render <at id=...>, cross-app open_ids degrade to plain names
        assert markdown =~ "<at id=ou_cxo_lead></at>"
        assert markdown =~ "<at id=ou_cxo_ceo></at>"
        assert markdown =~ "张三"
        assert markdown =~ "Dev"
        refute markdown =~ "ou_rd_outsider"
        refute markdown =~ "ou_rd_dev"
        refute markdown =~ "ou_rd_lead"
      end

      test "4: Compose mine_marks and me use shared.app_id", ctx do
        {:ok, member} =
          DailyBrief.put_member(%{
            org_id: ctx.org.id,
            user_id: ctx.lead.id,
            provider: @provider,
            project_id: ctx.projects["cxo"].id,
            app_id: "cli_rd",
            open_id: "ou_rd_lead",
            app_open_ids: %{"cli_rd" => "ou_rd_lead", "cli_cxo" => "ou_cxo_lead"},
            timezone: "Asia/Shanghai"
          })

        {:ok, _} = DailyBrief.put_aliases(member, [%{term: "Lead", kind: "name"}])
        member = Repo.preload(member, :aliases)

        own_msg = %{
          channel_id: "oc_cxo",
          ts: "om_own",
          thread_ts: nil,
          at_us: 1_792_719_000_000_000,
          actor_kind: "user",
          actor_id: "ou_cxo_lead",
          subtype: nil,
          text: "我来跟进",
          mentions: [],
          reactions: []
        }

        ask_msg = %{
          channel_id: "oc_cxo",
          ts: "om_ask",
          thread_ts: nil,
          at_us: 1_792_720_000_000_000,
          actor_kind: "user",
          actor_id: "ou_cxo_ceo",
          subtype: nil,
          text: "<@ou_cxo_lead> 今天能出结论吗？",
          mentions: ["ou_cxo_lead"],
          reactions: []
        }

        shared = %{
          window: @window,
          app_id: "cli_cxo",
          messages: [own_msg, ask_msg],
          relevant: %{
            member.id => [
              %{message: own_msg, reasons: [:author], tier: :p0},
              %{message: ask_msg, reasons: [:mention], tier: :p0}
            ]
          },
          channel_names: %{"oc_cxo" => "经营组"},
          channel_sources: %{
            "oc_cxo" => %{settings: ctx.settings["cxo"], app_id: "cli_cxo"}
          },
          coverage: %{complete?: true}
        }

        assert {:ok, _written} =
                 Compose.write(
                   %{settings: ctx.settings["cxo"], member: member, shared: shared, now: @now},
                   model: CrossSwarmModel,
                   agent_id: "agt",
                   members: [member]
                 )

        assert_received {:compose, input}
        assert input["me"]["label"] == "@Lead"

        own_item = Enum.find(input["items"], &(&1["text"] == "我来跟进"))
        ask_item = Enum.find(input["items"], &(&1["text"] =~ "今天能出结论吗"))
        assert own_item["by"] == "你"
        assert ask_item["to_me"] == true
      end

      test "5: ChatSettings.set_channel covers cross-swarm Scope.personal groups and tolerates failing sibling",
           ctx do
        {:ok, _} = Members.sync(ctx.settings["cxo"])
        cxo_group = "grp-cxo-#{ctx.suffix}"
        cxo_lead = origin(cxo_group, @provider, "ou_cxo_lead", "cnx_cxo")

        # Simulate fin Swarm temporarily unavailable.
        SystemsRuntime.put_env(
          :bridge_for_teams_core,
          :daily_brief_test_fails,
          MapSet.new([{"cnx_fin", :channels}])
        )

        assert {:ok, %{"main_channels" => ["研发群"], "with_bot_messages" => []}} =
                 ChatSettings.set_channel(cxo_group, cxo_lead, "研发群", "follow")

        assert {:ok, %{"main_channels" => ["研发群", "经营组"], "with_bot_messages" => []}} =
                 ChatSettings.set_channel(cxo_group, cxo_lead, "oc_cxo", "follow")
      end

      test "6: Delivery.transient? treats Feishu/Lark permanent errors as non-transient" do
        for permanent <- [
              "230001",
              "Feishu error 230002: bot not in chat",
              "code=230013 no availability",
              "99991668 invalid token",
              "99991672 missing scope",
              "99992361 open_id cross app",
              "channel_ineligible",
              :channel_ineligible,
              {:api_error, 230_013, "no availability"},
              %{code: 99_992_361}
            ] do
          refute Delivery.transient?(permanent), "expected permanent: #{inspect(permanent)}"
        end

        assert Delivery.transient?({:rate_limited, 10})
        assert Delivery.transient?("502 bad gateway")
        assert Delivery.transient?(:timeout)
      end

      test "7: Members.sync auto-populates sibling app_open_ids (best-effort) and Sources.personal_post uses app_id",
           ctx do
        # Simulate fin Swarm lookup failing; sync on cxo should still succeed and populate rd's open_id.
        SystemsRuntime.put_env(
          :bridge_for_teams_core,
          :daily_brief_test_fails,
          MapSet.new([{"cnx_fin", :lookup_members}])
        )

        assert {:ok, %{linked: 1}} = Members.sync(ctx.settings["cxo"])

        lead = Repo.get_by!(DailyBriefMember, user_id: ctx.lead.id, provider: @provider)
        assert lead.project_id == ctx.projects["cxo"].id
        assert {lead.app_id, lead.open_id} == {"cli_cxo", "ou_cxo_lead"}
        assert lead.app_open_ids == %{"cli_cxo" => "ou_cxo_lead", "cli_rd" => "ou_rd_lead"}

        # dev is only in rd and must not be linked by cxo's sync.
        assert Repo.get_by(DailyBriefMember, user_id: ctx.dev.id, provider: @provider) == nil

        # Sources.personal_post prefers ActorRef.member_actor_id(member, app_id) over stale member.open_id.
        stale_member = %DailyBriefMember{
          provider: @provider,
          app_id: "cli_rd",
          open_id: "ou_rd_lead",
          app_open_ids: %{"cli_rd" => "ou_rd_lead", "cli_cxo" => "ou_cxo_lead"}
        }

        post =
          Sources.personal_post(
            %{provider: @provider, app_id: "cli_cxo"},
            stale_member,
            %{card: %{}}
          )

        assert post.open_id == "ou_cxo_lead"
      end
    end
  end
end
