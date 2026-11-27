defmodule BridgeForTeams.DailyBriefSharedSourceTest do
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{Accounts, DailyBrief, Memberships, Orgs, Projects, Repo}
  alias BridgeForTeams.DailyBrief.{Classifier, Members, SharedSource}

  defmodule FakeSalix do
    def daily_brief_lookup_members(request), do: reply(:lookup_members, request)
    def daily_brief_channels(request), do: reply(:channels, request)
    def daily_brief_read_window(request), do: reply(:read_window, request)
    def daily_brief_member_threads(request), do: reply(:member_threads, request)

    def daily_brief_active_channels(request) do
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:salix, :active_channels, request})
      SystemsRuntime.get_env(:bridge_for_teams_core, :daily_brief_test_active, {:ok, %{}})
    end

    def daily_brief_jev_recall(request) do
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:salix, :jev_recall, request})

      case SystemsRuntime.get_env(:bridge_for_teams_core, :daily_brief_test_jev_recall) do
        fun when is_function(fun, 1) -> fun.(request)
        other when not is_nil(other) -> other
        nil -> {:ok, %{}}
      end
    end

    defp reply(name, request) do
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:salix, name, request})
      SystemsRuntime.fetch_env!(:bridge_for_teams_core, :daily_brief_fake).(name, request)
    end
  end

  @window %{after: ~U[2026-10-22 01:00:00Z], before: ~U[2026-10-23 01:00:00Z]}

  setup do
    previous = SystemsRuntime.get_env(:bridge_for_teams_core, :salix_client)
    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, FakeSalix)

    on_exit(fn ->
      SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, previous)
      SystemsRuntime.delete_env(:bridge_for_teams_core, :daily_brief_fake)
      SystemsRuntime.delete_env(:bridge_for_teams_core, :daily_brief_test_active)
      SystemsRuntime.delete_env(:bridge_for_teams_core, :daily_brief_test_jev_recall)
    end)

    suffix = SystemsRuntime.Proc.unique_integer([:positive])
    {:ok, org} = Orgs.create_org(%{"name" => "Brief #{suffix}", "slug" => "brief-src-#{suffix}"})

    users =
      for name <- ["alice", "bob", "carol"] do
        {:ok, user} =
          Accounts.create_user(%{"email" => "#{name}-#{suffix}@example.test", "name" => name})

        {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")
        user
      end

    {:ok, project} =
      Projects.create_project(org.id, %{"name" => "Brief", "slug" => "brief-src-#{suffix}"},
        creator_user_id: hd(users).id
      )

    {:ok, settings} =
      DailyBrief.put_settings(org.id, %{project_id: project.id, slack_connect_id: "imc_brief"})

    %{org: org, project: project, settings: settings, users: users, suffix: suffix}
  end

  describe "member sync" do
    test "links resolved users, seeds aliases once, and lists the rest", ctx do
      [alice, bob, carol] = ctx.users

      fake(fn :lookup_members, %{emails: emails} = request ->
        assert request.connect_id == "imc_brief"
        assert carol.email in emails

        {:ok,
         %{
           alice.email => slack("UALICE1", ["XP", "鹏哥"]),
           bob.email => slack("UBOB1", ["Bob"])
         }}
      end)

      assert {:ok, %{linked: 2, unresolved: [unresolved]}} = Members.sync(ctx.settings)
      assert unresolved == carol.email

      [alice_member] = Enum.filter(Members.enabled(ctx.org.id), &(&1.user_id == alice.id))
      assert alice_member.slack_user_id == "UALICE1"
      assert alice_member.timezone == "Asia/Shanghai"
      assert Enum.map(alice_member.aliases, & &1.term) |> Enum.sort() == ["XP", "鹏哥"]

      {:ok, _} = DailyBrief.put_aliases(alice_member, [%{term: "肖鹏", kind: "name"}])
      assert {:ok, %{linked: 2}} = Members.sync(ctx.settings)

      [alice_member] = Enum.filter(Members.enabled(ctx.org.id), &(&1.user_id == alice.id))
      assert Enum.map(alice_member.aliases, & &1.term) == ["肖鹏"]
      _ = bob
    end
  end

  describe "reading a window" do
    setup ctx do
      [alice, bob, _carol] = ctx.users
      alice_member = member(ctx, alice, "UALICE1", [{"XP", "name"}, {"Photon", "project"}])
      bob_member = member(ctx, bob, "UBOB1", [])
      Map.merge(ctx, %{alice: alice_member, bob: bob_member})
    end

    test "classifies every readable channel and reports what it could not read", ctx do
      fake(fn
        :channels, _request ->
          {:ok,
           %{
             workspace_id: "T1",
             complete?: true,
             channels: [
               %{id: "C_MAIN", name: "main"},
               %{id: "C_DOWN", name: "down"}
             ],
             gaps: %{}
           }}

        :read_window, %{channel_id: "C_MAIN", cursor: nil} = request ->
          assert request.after_us == DateTime.to_unix(@window.after, :microsecond)

          {:ok,
           %{
             messages: [
               msg("C_MAIN", "1.0", "UBOB1", "<@UALICE1> please review"),
               msg("C_MAIN", "2.0", "UBOB1", "export the logs")
             ],
             next_cursor: %{ts_us: 2_000_000, channel_id: "C_MAIN"},
             has_more?: true
           }}

        :read_window, %{channel_id: "C_MAIN"} ->
          {:ok,
           %{
             messages: [
               msg("C_MAIN", "3.0", "UCAROL1", "done", "0.5"),
               msg("C_MAIN", "4.0", "UCAROL1", "Photon is blocked"),
               msg("C_MAIN", "5.0", "BDEPLOY1", "XP deployed", nil, "bot")
             ],
             next_cursor: nil,
             has_more?: false
           }}

        :read_window, %{channel_id: "C_DOWN"} ->
          {:error, :source_unavailable}

        :member_threads, %{slack_user_id: "UALICE1", threads: threads} ->
          # Only the window's threads are asked about.
          assert threads == [%{channel_id: "C_MAIN", thread_ts: "0.5"}]
          {:ok, %{threads: threads, complete?: true}}

        :member_threads, _request ->
          {:error, :source_unavailable}
      end)

      assert {:ok, result} = SharedSource.read(ctx.settings, @window)

      assert length(result.messages) == 5

      assert picked(result, ctx.alice) == [
               {"1.0", [:mention], :p0},
               {"3.0", [:thread], :p0},
               {"4.0", [:project], :p1}
             ]

      assert picked(result, ctx.bob) == [{"1.0", [:own], :p0}, {"2.0", [:own], :p0}]

      coverage = result.coverage
      assert coverage.channels_total == 2
      assert coverage.channels_read == 1
      assert [%{id: "C_DOWN", reason: :source_unavailable}] = coverage.failed
      assert coverage.threads_complete == %{ctx.alice.id => true, ctx.bob.id => false}
      refute SharedSource.complete?(coverage)
    end

    test "a channel Slack asks to wait for is read after the wait", ctx do
      fake(fn
        :channels, _request ->
          {:ok,
           %{
             workspace_id: "T1",
             complete?: true,
             channels: [%{id: "C_MAIN", name: "main"}],
             gaps: %{}
           }}

        :read_window, %{channel_id: "C_MAIN"} ->
          if Process.put(:rate_limited, true) do
            {:ok,
             %{
               messages: [msg("C_MAIN", "1.0", "UBOB1", "export the logs")],
               next_cursor: nil,
               has_more?: false
             }}
          else
            {:error, {:rate_limited, 1}}
          end
      end)

      assert {:ok, result} = SharedSource.read(ctx.settings, @window, members: [])
      assert [%{ts: "1.0"}] = result.messages
      assert result.coverage.failed == []
      assert_received {:salix, :read_window, %{channel_id: "C_MAIN"}}
      assert_received {:salix, :read_window, %{channel_id: "C_MAIN"}}
    end

    test "a member's main channels bring in what people said there", ctx do
      # Bob wrote most in C_MAIN lately, so he follows it by default; Alice
      # follows C_OPS with its bot messages, and dropped C_MAIN.
      SystemsRuntime.put_env(
        :bridge_for_teams_core,
        :daily_brief_test_active,
        {:ok,
         %{
           "UBOB1" => [%{channel_id: "C_MAIN", count: 9}, %{channel_id: "C_OPS", count: 2}],
           "UALICE1" => [%{channel_id: "C_MAIN", count: 30}]
         }}
      )

      {:ok, _} =
        DailyBrief.put_aliases(ctx.alice, [
          %{term: "C_OPS", kind: "channel_bots"},
          %{term: "C_MAIN", kind: "channel_off"}
        ])

      fake(fn
        :channels, _request ->
          {:ok,
           %{
             workspace_id: "T1",
             complete?: true,
             channels: [%{id: "C_MAIN", name: "main"}, %{id: "C_OPS", name: "ops"}],
             gaps: %{}
           }}

        :read_window, %{channel_id: "C_MAIN"} ->
          {:ok,
           %{
             messages: [
               msg("C_MAIN", "1.0", "UCAROL1", "shipping today"),
               msg("C_MAIN", "2.0", "BDEPLOY1", "deployed", nil, "bot")
             ],
             next_cursor: nil,
             has_more?: false
           }}

        :read_window, %{channel_id: "C_OPS"} ->
          {:ok,
           %{
             messages: [
               msg("C_OPS", "3.0", "BALERT1", "P1: replicas below 1", nil, "bot"),
               msg("C_OPS", "4.0", "UCAROL1", "looking")
             ],
             next_cursor: nil,
             has_more?: false
           }}

        :member_threads, _request ->
          {:ok, %{threads: [], complete?: true}}
      end)

      members = Members.enabled(ctx.org.id)
      assert {:ok, result} = SharedSource.read(ctx.settings, @window, members: members)

      assert_received {:salix, :active_channels, %{channel_ids: ["C_MAIN", "C_OPS"]} = asked}
      assert Enum.sort(asked.slack_user_ids) == ["UALICE1", "UBOB1"]

      assert picked(result, ctx.bob) == [{"1.0", [:channel], :p1}]

      assert picked(result, ctx.alice) == [
               {"3.0", [:channel], :p1},
               {"4.0", [:channel], :p1}
             ]
    end

    test "a member gets at most 250 main-channel messages, the newest", ctx do
      SystemsRuntime.put_env(
        :bridge_for_teams_core,
        :daily_brief_test_active,
        {:ok, %{"UBOB1" => [%{channel_id: "C_MAIN", count: 9}]}}
      )

      fake(fn
        :channels, _request ->
          {:ok,
           %{
             workspace_id: "T1",
             complete?: true,
             channels: [%{id: "C_MAIN", name: "main"}],
             gaps: %{}
           }}

        :read_window, %{channel_id: "C_MAIN"} ->
          talk = for i <- 1..300, do: msg("C_MAIN", "#{1000 + i}.0", "UCAROL1", "talk #{i}")
          mention = msg("C_MAIN", "1.0", "UCAROL1", "<@UBOB1> look")
          {:ok, %{messages: [mention | talk], next_cursor: nil, has_more?: false}}

        :member_threads, _request ->
          {:ok, %{threads: [], complete?: true}}
      end)

      assert {:ok, result} =
               SharedSource.read(ctx.settings, @window,
                 members: [Repo.preload(ctx.bob, :aliases)]
               )

      picked = picked(result, ctx.bob)
      assert length(picked) == 251
      assert {"1.0", [:mention, :channel], :p0} in picked
      refute Enum.any?(picked, fn {ts, _, _} -> ts == "1050.0" end)
      assert Enum.any?(picked, fn {ts, _, _} -> ts == "1051.0" end)
    end

    test "names channels left unread when the page budget runs out", ctx do
      fake(fn
        :channels, _request ->
          {:ok,
           %{
             workspace_id: "T1",
             complete?: true,
             channels: [%{id: "C_A", name: "a"}, %{id: "C_B", name: "b"}],
             gaps: %{}
           }}

        :read_window, %{channel_id: channel} ->
          {:ok,
           %{
             messages: [msg(channel, "1.0", "UBOB1", "hi")],
             next_cursor: %{ts_us: 1, channel_id: channel},
             has_more?: true
           }}

        :member_threads, _request ->
          {:ok, %{threads: [], complete?: true}}
      end)

      assert {:ok, result} = SharedSource.read(ctx.settings, @window, page_budget: 2)
      assert Enum.map(result.coverage.truncated, & &1.id) == ["C_A", "C_B"]
      assert result.coverage.channels_read == 0
      refute SharedSource.complete?(result.coverage)
    end

    test "sends lightweight human P2 candidates to daily_brief_jev_recall, promotes >= 2500 to P1, drops low scores, and skips bots",
         ctx do
      SystemsRuntime.put_env(
        :bridge_for_teams_core,
        :daily_brief_test_jev_recall,
        {:ok, %{{"C_EDGE", "10.0"} => 3_500, {"C_EDGE", "11.0"} => 1_200}}
      )

      fake(fn
        :channels, _request ->
          {:ok,
           %{
             workspace_id: "T1",
             complete?: true,
             channels: [%{id: "C_EDGE", name: "edge"}],
             gaps: %{}
           }}

        :read_window, %{channel_id: "C_EDGE"} ->
          {:ok,
           %{
             messages: [
               msg("C_EDGE", "10.0", "UCAROL1", "Release freeze at 18:00 today")
               |> Map.put(:actor_label, "Carol")
               |> Map.put(:extra_blob, String.duplicate("x", 500)),
               msg("C_EDGE", "11.0", "UCAROL1", "Anyone want boba?")
               |> Map.put(:actor_label, "Carol"),
               msg("C_EDGE", "12.0", "BDEPLOY1", "CI build passed", nil, "bot")
             ],
             next_cursor: nil,
             has_more?: false
           }}

        :member_threads, _request ->
          {:ok, %{threads: [], complete?: true}}
      end)

      assert {:ok, result} =
               SharedSource.read(ctx.settings, @window,
                 members: [Repo.preload(ctx.alice, :aliases)]
               )

      assert_received {:salix, :jev_recall, %{messages: sent_messages}}
      assert Enum.map(sent_messages, & &1.ts) == ["10.0", "11.0"]

      for item <- sent_messages do
        assert Enum.sort(Map.keys(item)) == [:actor_label, :channel_id, :text, :ts]
      end

      assert picked(result, ctx.alice) == [{"10.0", [:jev_recall], :p1}]
    end
  end

  describe "classifier" do
    test "main channels choose from activity, and choices override it" do
      member = %{
        aliases: [
          %{term: "C_B", kind: "channel_off"},
          %{term: "C_X", kind: "channel"},
          %{term: "C_GONE", kind: "channel"}
        ]
      }

      activity =
        for {id, n} <-
              [{"C_A", 40}, {"C_B", 30}, {"C_C", 4}, {"C_D", 9}, {"C_E", 8}] ++
                for(i <- 1..6, do: {"C_F#{i}", 6}),
            do: %{channel_id: id, count: n}

      readable = MapSet.new(~w(C_A C_B C_C C_D C_E C_X) ++ for(i <- 1..6, do: "C_F#{i}"))
      focus = BridgeForTeams.DailyBrief.Focus.of(member, activity, readable)

      # The six busiest with five or more messages, less the dropped one, plus
      # the added one that the bot can read.
      assert focus.humans == MapSet.new(~w(C_A C_D C_E C_F1 C_F2 C_X))
      assert focus.bots == MapSet.new()

      # A newly created channel where the member wrote three or more messages in
      # the current window enters focus on its first day, unless muted.
      day_one =
        BridgeForTeams.DailyBrief.Focus.of(
          member,
          activity,
          MapSet.put(readable, "C_NEW"),
          %{"C_NEW" => 3, "C_B" => 4, "C_C" => 2}
        )

      assert MapSet.member?(day_one.humans, "C_NEW")
      refute MapSet.member?(day_one.humans, "C_B")
      refute MapSet.member?(day_one.humans, "C_C")
    end

    test "matches ASCII aliases as words and other aliases as text" do
      member =
        Classifier.member(
          "UME1",
          [%{term: "XP", kind: "name"}, %{term: "鹏哥", kind: "name"}],
          []
        )

      assert Classifier.reasons(msg("C", "1", "UX1", "ask XP first"), member) == [:alias]
      assert Classifier.reasons(msg("C", "2", "UX1", "export it"), member) == []
      assert Classifier.reasons(msg("C", "3", "UX1", "找鹏哥确认"), member) == [:alias]
    end

    test "a bot counts when it mentions the member or replies in their thread" do
      member =
        Classifier.member("UME1", [%{term: "XP", kind: "name"}], [
          %{channel_id: "C", thread_ts: "1.0"}
        ])

      assert Classifier.reasons(msg("C", "2.0", "B1", "deployed", "1.0", "bot"), member) ==
               [:thread]

      assert Classifier.reasons(msg("C", "3.0", "B1", "ping <@UME1>", nil, "bot"), member) ==
               [:mention]

      assert Classifier.reasons(msg("C", "4.0", "B1", "XP deployed", nil, "bot"), member) == []
      assert Classifier.reasons(msg("C", "5.0", "B1", "deployed", "9.0", "bot"), member) == []
    end

    test "a bot's meeting notes count for a member they name" do
      member = Classifier.member("UME1", [%{term: "XP", kind: "name"}], [])
      notes = "Meeting Summary\nAttendees: Bob, XP\n" <> String.duplicate("决定：先做 agent 机。", 80)

      assert Classifier.reasons(msg("C", "6.0", "B1", notes, "5.0", "bot"), member) == [:alias]
    end

    test "promotes P2 human edge messages to P1 when jev_recall_bp meets the recall threshold" do
      member = Classifier.member("UME1", [%{term: "XP", kind: "name"}], [])

      promoted =
        msg("C_EDGE", "7.0", "UX1", "Release freeze starts at 18:00")
        |> Map.put(:jev_recall_bp, 3_200)

      dropped =
        msg("C_EDGE", "8.0", "UX1", "Lunch at 12:30")
        |> Map.put(:jev_recall_bp, 1_200)

      assert Classifier.reasons(promoted, member) == [:jev_recall]
      assert Classifier.tier(Classifier.reasons(promoted, member)) == :p1

      assert Classifier.reasons(dropped, member) == []
      assert Classifier.tier(Classifier.reasons(dropped, member)) == nil
    end
  end

  defp fake(fun), do: SystemsRuntime.put_env(:bridge_for_teams_core, :daily_brief_fake, fun)

  defp slack(id, names),
    do: %{slack_user_id: id, workspace_id: "T1", timezone: "Asia/Shanghai", names: names}

  defp member(ctx, user, slack_id, aliases) do
    {:ok, member} =
      DailyBrief.put_member(%{
        org_id: ctx.org.id,
        user_id: user.id,
        slack_workspace_id: "T1",
        slack_user_id: slack_id
      })

    {:ok, _} =
      DailyBrief.put_aliases(member, Enum.map(aliases, fn {t, k} -> %{term: t, kind: k} end))

    Repo.preload(member, :aliases, force: true)
  end

  defp msg(channel, ts, actor, text, thread_ts \\ nil, kind \\ "user"),
    do: %{
      channel_id: channel,
      ts: ts,
      thread_ts: thread_ts,
      actor_kind: kind,
      actor_id: actor,
      subtype: nil,
      text: text
    }

  defp picked(result, member),
    do: Enum.map(result.relevant[member.id], &{&1.message.ts, &1.reasons, &1.tier})
end
