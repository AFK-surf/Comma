defmodule BridgeForTeams.DailyBriefAcceptanceTest do
  @moduledoc """
  The daily brief end to end on the manual clock.

  Real BFT and Salix code runs in this node: the Slack source, the delivery
  worker, and the Slack surface. Only the edges are stand-ins: Slack's Web
  API (a local HTTP stub), the ClickHouse mirror reader, and the model. The clock starts at 08:58 in Shanghai on a working
  day and moves only when the test moves it.
  """
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{Accounts, DailyBrief, Memberships, Orgs, Projects, Repo}
  alias BridgeForTeams.DailyBrief.DeliveryWorker
  alias BridgeForTeams.Schema.{DailyBriefRun, Organization}
  alias SalixStore.{CasRecord, Keys, SlackMirrorBackfillLedger}

  @start ~U[2026-10-23 00:58:00.000000Z]
  @ask_ts "1792690000.000100"

  defmodule Mirror do
    @moduledoc "The ClickHouse mirror reader, serving Slack-shaped messages."
    def search(_scope, opts) do
      messages =
        SystemsRuntime.fetch_env!(:bridge_for_teams_core, :acceptance_mirror)
        |> Enum.filter(fn m ->
          us = m["ts"] |> String.to_float() |> Kernel.*(1_000_000) |> trunc()

          (is_nil(opts[:channel_id]) or m["channel"] == opts[:channel_id]) and
            (is_nil(opts[:actor_id]) or m["user"] == opts[:actor_id]) and
            (is_nil(opts[:after_us]) or us >= opts[:after_us]) and
            (is_nil(opts[:before_us]) or us < opts[:before_us])
        end)

      {:ok, %{messages: messages, next_cursor: nil, has_more?: false}}
    end

    # The mirror's current rows by key, as named messages are read.
    def latest_states(_scope, keys) do
      rows =
        for m <- SystemsRuntime.fetch_env!(:bridge_for_teams_core, :acceptance_mirror),
            us = m["ts"] |> String.to_float() |> Kernel.*(1_000_000) |> round(),
            us in keys,
            into: %{} do
          {us,
           %{
             "channel_id" => m["channel"],
             "message_ts" => m["ts"],
             "message_ts_us" => us,
             "thread_ts" => "",
             "deleted" => false,
             "actor_kind" => "user",
             "actor_id" => m["user"],
             "subtype" => "",
             "text" => m["text"]
           }}
        end

      {:ok, rows}
    end
  end

  defmodule Model do
    @moduledoc "The model: tells the ask it was given, and reports what it saw."
    def compose(%{view: :team, input: input}) do
      report({:team_input, input})
      ask = Enum.find(input["items"], &(&1["text"] =~ "报价"))
      {:ok, %{text: "客户在等报价，#{label(ask)} 在跟。[原消息](#{ask["ref"]})", usage: usage()}}
    end

    def compose(%{input: input}) do
      report({:personal_input, input})

      text =
        case Enum.find(input["items"], &(&1["text"] =~ "报价")) do
          nil -> "今天没有等你处理的事。"
          ask -> "先回客户的报价，#{label(ask)} 在等。[原消息](#{ask["ref"]})"
        end

      {:ok, %{text: text, usage: usage()}}
    end

    defp label(item), do: item["by"]

    defp report(message) do
      owner = SystemsRuntime.fetch_env!(:bridge_for_teams_core, :acceptance_owner)
      SystemsRuntime.Proc.send(owner, message)
    end

    defp usage, do: %{input_tokens: 1_000, output_tokens: 100}
  end

  defmodule Slack do
    @moduledoc "Slack's Web API for the bot."
    use Plug.Builder

    plug(Plug.Parsers, parsers: [:urlencoded, :json], json_decoder: Jason)
    plug(:dispatch)

    def dispatch(conn, _opts) do
      conn = Plug.Conn.fetch_query_params(conn)
      token = conn |> Plug.Conn.get_req_header("authorization") |> List.first() |> to_string()
      owner = SystemsRuntime.fetch_env!(:bridge_for_teams_core, :acceptance_owner)
      body = answer(conn.request_path, conn.params, token, owner)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end

    defp answer("/api/conversations.info", %{"channel" => id}, _token, _owner),
      do: %{"ok" => true, "channel" => public(id) |> Map.put("is_member", true)}

    defp answer("/api/users.conversations", _params, _bot, _owner),
      do: %{"ok" => true, "channels" => [public("CMAIN1")]}

    defp answer("/api/conversations.history", _params, _token, _owner),
      do: %{"ok" => true, "messages" => []}

    defp answer("/api/search.messages", _params, _token, _owner),
      do: %{"ok" => true, "messages" => %{"matches" => [], "paging" => %{"pages" => 1}}}

    defp answer("/api/chat.getPermalink", %{"channel" => channel, "message_ts" => ts}, _t, _o),
      do: %{"ok" => true, "permalink" => "https://acme.slack.com/archives/#{channel}/p#{ts}"}

    defp answer("/api/conversations.open", %{"users" => user}, _token, _owner),
      do: %{"ok" => true, "channel" => %{"id" => "DBOT_" <> user}}

    defp answer("/api/chat.postMessage", params, _token, owner) do
      SystemsRuntime.Proc.send(owner, {:posted, params["channel"], blocks(params)})
      %{"ok" => true, "channel" => params["channel"], "ts" => "1792720000.000100"}
    end

    defp answer(_path, _params, _token, _owner), do: %{"ok" => true}

    defp blocks(%{"blocks" => blocks}) when is_binary(blocks), do: Jason.decode!(blocks)
    defp blocks(%{"blocks" => blocks}) when is_list(blocks), do: blocks
    defp blocks(_params), do: []

    defp public(id),
      do: %{
        "id" => id,
        "name" => "main",
        "is_private" => false,
        "is_archived" => false,
        "is_shared" => false,
        "is_ext_shared" => false,
        "is_org_shared" => false
      }
  end

  setup do
    :ok = SystemsClock.manual(epoch: @start)

    previous =
      for {app, key} <- [
            {:salix_im, :slack_api_base_url},
            {:salix_im, :slack_triage_clickhouse_reader_mod},
            {:salix_im, :slack_message_mirror_mod}
          ],
          do: {app, key, SystemsRuntime.get_env(app, key)}

    on_exit(fn ->
      SystemsClock.reset()

      Enum.each(previous, fn
        {app, key, nil} -> SystemsRuntime.delete_env(app, key)
        {app, key, value} -> SystemsRuntime.put_env(app, key, value)
      end)

      SystemsRuntime.delete_env(:bridge_for_teams_core, :acceptance_mirror)
      SystemsRuntime.delete_env(:bridge_for_teams_core, :acceptance_owner)
    end)

    bandit =
      start_supervised!(
        {Bandit, plug: Slack, scheme: :http, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    base = "http://127.0.0.1:#{port}"

    SystemsRuntime.put_env(:salix_im, :slack_api_base_url, base <> "/api")
    SystemsRuntime.put_env(:salix_im, :slack_triage_clickhouse_reader_mod, Mirror)
    SystemsRuntime.put_env(:salix_im, :slack_message_mirror_mod, Mirror)

    SystemsRuntime.put_env(:bridge_for_teams_core, :acceptance_owner, SystemsRuntime.Proc.self())

    SystemsRuntime.put_env(:bridge_for_teams_core, :acceptance_mirror, [
      %{
        "type" => "message",
        "channel" => "CMAIN1",
        "ts" => @ask_ts,
        "user" => "UBOB1",
        "text" => "<@UALICE1> 客户在问报价，今天能回吗"
      }
    ])

    world(base)
  end

  test "one working day of the daily brief", ctx do
    start_supervised!(
      {DeliveryWorker, interval_ms: 60_000, run_opts: [model: Model, agent_id: "agt"]}
    )

    SystemsClock.await_timers()

    # 08:59: nobody is due yet, and the stream is not read.
    SystemsClock.advance(60_000)
    SystemsClock.settle()
    refute_received {:team_input, _}
    refute_received {:posted, _, _}

    # 09:00: the team brief is written once from the stream, then both
    # members' briefs go out from the bot.
    SystemsClock.advance(60_000)
    SystemsClock.settle(until: fn -> briefs() == 2 end)
    assert_received {:team_input, team_input}
    assert Enum.any?(team_input["items"], &(&1["text"] =~ "客户在问报价"))
    refute_received {:team_input, _}

    assert_received {:posted, "DBOT_UALICE1", alice_blocks}
    assert_received {:posted, "DBOT_UBOB1", bob_blocks}

    # Alice was asked: her brief tells it, linked to the message, and says who
    # waits; it also has the team brief.
    assert_received {:personal_input, %{"me" => %{"label" => "@UALICE1"}} = alice_input}
    assert alice_input["team_brief"] =~ "客户在等报价"
    alice_text = Jason.encode!(alice_blocks)
    assert alice_text =~ "先回客户的报价，<@UBOB1> 在等。"
    assert alice_text =~ "https://acme.slack.com/archives/CMAIN1/p#{@ask_ts}"

    # Bob wrote the ask, so his brief reads it too.
    assert Jason.encode!(bob_blocks) =~ "先回客户的报价"

    # 10:20: the team brief goes to the team's channel, once.
    {:ok, _} = DailyBrief.put_settings(ctx.org.id, %{team_channel_id: "CMAIN1"})
    SystemsClock.advance(80 * 60_000)
    SystemsClock.settle(until: fn -> team_posted?() end)
    assert_received {:posted, "CMAIN1", team_blocks}
    assert Jason.encode!(team_blocks) =~ "客户在等报价"
    SystemsClock.advance(10 * 60_000)
    SystemsClock.settle()
    refute_received {:posted, "CMAIN1", _}

    # The next workday (a make-up Saturday) Alice's brief gets yesterday's,
    # and reads only what came after it.
    {:ok, _} = DailyBrief.put_settings(ctx.org.id, %{work_days: ["2026-10-24"]})
    SystemsClock.advance(23 * 3_600_000)
    SystemsClock.settle(until: fn -> briefs() == 4 end)
    assert_received {:personal_input, %{"me" => %{"label" => "@UALICE1"}} = next}
    assert next["previous_brief"] =~ "先回客户的报价"
    assert next["items"] == []
  end

  defp world(base) do
    suffix = SystemsRuntime.Proc.unique_integer([:positive])

    {:ok, org} =
      Orgs.create_org(%{"name" => "Acceptance #{suffix}", "slug" => "brief-acc-#{suffix}"})

    [alice_user, bob_user] =
      for name <- ["alice", "bob"] do
        {:ok, user} =
          Accounts.create_user(%{"email" => "#{name}-acc-#{suffix}@example.test", "name" => name})

        {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")
        user
      end

    {:ok, project} =
      Projects.create_project(org.id, %{"name" => "Acceptance", "slug" => "brief-acc-#{suffix}"},
        creator_user_id: alice_user.id
      )

    tenant_id = Repo.get!(Organization, org.id).salix_tenant_id
    connect_id = "imc-acc-#{suffix}"

    connect = %{
      "provider" => "slack",
      "tenant_id" => tenant_id,
      "group_id" => project.salix_group_id,
      "connect_id" => connect_id,
      "connect_generation" => "generation-1",
      "workspace_id" => "T1",
      "app_id" => "A_BOT",
      "bot_token" => "xoxb-bot",
      "client_id" => "bot-client",
      "client_secret" => "bot-secret",
      "oauth_completed_at" => 1,
      "created_at" => 1,
      "updated_at" => 1
    }

    {:ok, _} = CasRecord.create(Keys.ctl_im_connect(project.salix_group_id, connect_id), connect)

    scope = %{"tenant_id" => tenant_id, "workspace_id" => "T1", "channel_id" => "CMAIN1"}
    {:ok, _} = SlackMirrorBackfillLedger.claim_channel(scope, 120_000)
    :ok = SlackMirrorBackfillLedger.lower_watermark(scope, 0, 1_792_600_000_000_000)

    {:ok, settings} =
      DailyBrief.put_settings(org.id, %{
        project_id: project.id,
        slack_connect_id: connect_id,
        enabled: true
      })

    [alice, bob] =
      for {user, slack_id} <- [{alice_user, "UALICE1"}, {bob_user, "UBOB1"}] do
        {:ok, member} =
          DailyBrief.put_member(%{
            org_id: org.id,
            user_id: user.id,
            slack_workspace_id: "T1",
            slack_user_id: slack_id,
            timezone: "Asia/Shanghai",
            deliver_at: ~T[09:00:00]
          })

        member
      end

    _ = base

    %{
      org: org,
      settings: settings,
      alice: alice,
      bob: bob,
      group_id: project.salix_group_id,
      connect: connect
    }
  end

  defp briefs,
    do: Repo.aggregate(from(r in DailyBriefRun, where: r.kind == "personal_brief"), :count)

  defp team_posted? do
    Repo.exists?(
      from(r in DailyBriefRun,
        where: r.kind == "team_brief" and fragment("? \\? 'team_brief_ts'", r.coverage)
      )
    )
  end
end
