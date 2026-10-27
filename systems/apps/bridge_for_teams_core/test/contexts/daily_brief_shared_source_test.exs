defmodule BridgeForTeams.DailyBriefSharedSourceTest do
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{Accounts, DailyBrief, Memberships, Orgs, Projects, Repo}
  alias BridgeForTeams.DailyBrief.{Classifier, Members, SharedSource}

  defmodule FakeSalix do
    def daily_brief_lookup_members(request), do: reply(:lookup_members, request)
    def daily_brief_channels(request), do: reply(:channels, request)
    def daily_brief_read_window(request), do: reply(:read_window, request)
    def daily_brief_member_threads(request), do: reply(:member_threads, request)

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

        :member_threads, %{slack_user_id: "UALICE1"} ->
          {:ok, %{threads: [%{channel_id: "C_MAIN", thread_ts: "0.5"}], complete?: true}}

        :member_threads, _request ->
          {:ok, %{threads: [], complete?: false}}
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
  end

  describe "classifier" do
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
