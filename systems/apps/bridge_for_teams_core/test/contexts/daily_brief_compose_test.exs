defmodule BridgeForTeams.DailyBriefComposeTest do
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{Accounts, DailyBrief, Memberships, Orgs, Projects, Repo}
  alias BridgeForTeams.DailyBrief.{Compose, People}

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

    {:ok, _member} =
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

    %{settings: settings}
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

  test "a team brief mentions at most three people" do
    people =
      People.build(
        [],
        Enum.map(~w(UA1 UB1 UC1 UD1), &"slack:#{&1}") ++ ["meeting:alice", "meeting:bob"]
      )

    assert Compose.few_mentions("@alice 修，@alice 再看；@UB1、@UC1 和 @bob 定，@UA1 跟进", people) ==
             "@alice 修，@alice 再看；@UB1、@UC1 和 bob 定，某人 跟进"
  end

  test "a known address in backticks stays whole" do
    request = %{"items" => [%{"text" => "拒绝了 `<http://host.docker.internal:11434>` 这类地址"}]}

    assert Compose.finish(
             "拒绝了 `http://host.docker.internal:11434` 这类地址",
             request,
             %{},
             People.build([], [])
           ) =~
             "`http://host.docker.internal:11434` 这类地址"
  end
end
