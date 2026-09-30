defmodule SalixIM.SlackTriageCallbackRouteTest do
  use ExUnit.Case, async: false

  alias SalixIM.Provider.Slack.ThreadRouteOwner
  alias SalixIM.TestSupport.BanditServer
  alias SalixIM.{ProviderHTTP, SlackMessageMirror}
  alias SalixStore.{CasRecord, Ids, Keys, Repo, S3, TriageRecords, ULID}

  defmodule TestAgentDelivery do
    @behaviour SalixIM.Ports.AgentDelivery

    @impl true
    def notify_conversation(agent, source),
      do: SalixIM.TestSupport.ConversationDelivery.notify(__MODULE__, agent, source)

    def deliver(agent_id, payload, opts) do
      send(
        Application.fetch_env!(:salix_im, :triage_route_test_pid),
        {:explicit_mention_delivery, agent_id, payload, opts}
      )

      {:ok, :created}
    end

    @impl true
    def get_session(_agent_id, _session_id, _opts), do: {:error, :not_supported}

    @impl true
    def get_session_messages(_agent_id, _session_id), do: {:error, :not_supported}
  end

  defmodule TestMirror do
    @behaviour SlackMessageMirror

    @impl true
    def record_batch(_rows), do: :ok

    @impl true
    def record_reaction_batch(_rows), do: :ok

    @impl true
    def record_pin_batch(_rows), do: :ok

    @impl true
    def record_metadata_batch(_rows), do: :ok

    @impl true
    def record_event_triggers(_rows), do: :ok
  end

  defmodule TestSlack do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      body =
        case conn.request_path do
          "/api/conversations.replies" ->
            %{"ok" => true, "messages" => [], "has_more" => false}

          "/api/users.info" ->
            %{"ok" => true, "user" => %{"profile" => %{"display_name" => "Test participant"}}}

          _ ->
            send(
              Application.fetch_env!(:salix_im, :triage_route_test_pid),
              {:unexpected_slack_request, conn.request_path}
            )

            %{"ok" => false, "error" => "unexpected_test_request"}
        end

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))
    end
  end

  defmodule TestOutbox do
    def append(row, kind \\ "message", _context \\ %{}) do
      event = if kind == "reaction", do: :reaction_mirrored, else: :mirrored
      send(Application.fetch_env!(:salix_im, :triage_route_test_pid), {event, row})
      :ok
    end
  end

  setup do
    previous = %{
      s3_backend: Application.get_env(:salix_store, :s3_backend),
      triage_backend: Application.get_env(:salix_store, :triage_record_backend),
      delivery: Application.get_env(:salix_im, :agent_delivery_mod),
      mirror: Application.get_env(:salix_im, :slack_message_mirror_mod),
      outbox: Application.get_env(:salix_im, :slack_message_mirror_outbox),
      slack_api: Application.get_env(:salix_im, :slack_api_base_url),
      test_pid: Application.get_env(:salix_im, :triage_route_test_pid)
    }

    Application.put_env(:salix_store, :s3_backend, S3.Fake)
    Application.put_env(:salix_store, :triage_record_backend, TriageRecords)
    Application.put_env(:salix_im, :agent_delivery_mod, TestAgentDelivery)
    Application.put_env(:salix_im, :slack_message_mirror_mod, TestMirror)
    Application.put_env(:salix_im, :slack_message_mirror_outbox, TestOutbox)
    Application.put_env(:salix_im, :triage_route_test_pid, self())
    port = BanditServer.start!(fn port -> {Bandit, plug: TestSlack, port: port} end)
    Application.put_env(:salix_im, :slack_api_base_url, "http://127.0.0.1:#{port}/api")
    use_legacy_channel_authority!()

    if Process.whereis(S3.Fake), do: S3.Fake.reset(), else: start_supervised!(S3.Fake)

    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    agent_id = Ids.new_agent_id(group_id)
    connect_id = Ids.new_connect_id()

    group = %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "router_agent_id" => agent_id,
      "router_conversation_id" => Ids.new_conversation_id()
    }

    agent = %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "agent_id" => agent_id,
      "role" => "router",
      "router_session_id" => Ids.new_session_id(),
      "heartbeat_schedule_id" => Ids.new_schedule_id()
    }

    connect = %{
      "provider" => "slack",
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "connect_id" => connect_id,
      "connect_generation" => ULID.generate(),
      "workspace_id" => "T_TRIAGE_CALLBACK",
      "approved_channel_id" => "C_TRIAGE_CALLBACK",
      "inbound_agent_id" => agent_id,
      "app_id" => "A_TRIAGE_CALLBACK",
      "bot_user_id" => "U_TRIAGE_BOT",
      "bot_id" => "B_TRIAGE_BOT",
      "bot_token" => "xoxb-private-test-token",
      "signing_secret" => "triage-callback-signing-secret",
      "oauth_completed_at" => 1,
      "triage_provisioned_at" => 1,
      "triage_enabled" => true,
      "disabled_at" => nil,
      "deleted_at" => nil
    }

    assert {:ok, _} = CasRecord.create(Keys.ctl_group(group_id), group)
    assert {:ok, _} = CasRecord.create(Keys.ctl_agent(agent_id), agent)
    assert {:ok, _} = CasRecord.create(Keys.ctl_im_connect(group_id, connect_id), connect)

    on_exit(fn ->
      restore_projected_channel_authority!()
      restore_env(:salix_store, :s3_backend, previous.s3_backend)
      restore_env(:salix_store, :triage_record_backend, previous.triage_backend)
      restore_env(:salix_im, :agent_delivery_mod, previous.delivery)
      restore_env(:salix_im, :slack_message_mirror_mod, previous.mirror)
      restore_env(:salix_im, :slack_message_mirror_outbox, previous.outbox)
      restore_env(:salix_im, :slack_api_base_url, previous.slack_api)
      restore_env(:salix_im, :triage_route_test_pid, previous.test_pid)
    end)

    {:ok, connect: connect}
  end

  test "an ambient callback is mirrored but cannot create Triage authority or a receipt", %{
    connect: connect
  } do
    envelope = root_envelope(connect, "Ev-ambient-observation-only")

    assert callback(connect, envelope) == {:error, :ignored}
    assert_receive {:mirrored, %{"message_ts" => "1787019000.000001"}}
    assert ThreadRouteOwner.lookup(route_scope(connect, envelope)) == :unbound
    assert CasRecord.get(receipt_key(connect, envelope)) == {:error, :not_found}
    refute_received {:triage_consumer_called, _, _}
    refute_received {:explicit_mention_delivery, _, _, _}
  end

  test "an ambient reply stays observation-only even on a CH-owned Triage thread", %{
    connect: connect
  } do
    root = root_envelope(connect, "Ev-clickhouse-owner-root")
    scope = route_scope(connect, root)
    root_ts_us = 1_787_019_000_000_001

    assert {:ok, identity} = ThreadRouteOwner.clickhouse_root_claim_identity(scope, root_ts_us)
    assert {:ok, :triage} = ThreadRouteOwner.claim_triage(scope, identity)

    reply =
      root_envelope(connect, "Ev-ambient-reply")
      |> put_in(["event", "ts"], "1787019001.000001")
      |> put_in(["event", "event_ts"], "1787019001.000001")
      |> put_in(["event", "thread_ts"], root["event"]["ts"])

    assert callback(connect, reply) == {:error, :ignored}
    assert_receive {:mirrored, %{"message_ts" => "1787019001.000001"}}
    assert ThreadRouteOwner.verify_claim(scope, :triage, identity) == {:ok, :triage}
    assert CasRecord.get(receipt_key(connect, reply)) == {:error, :not_found}
    refute_received {:triage_consumer_called, _, _}
  end

  test "a human app mention remains an explicit command callback", %{connect: connect} do
    envelope = human_mention_envelope(connect, "Ev-human-command", "1787019010.000001")

    assert callback(connect, envelope) == {:ok, :accepted}
    assert_receive {:explicit_mention_delivery, agent_id, _payload, _opts}
    assert agent_id == connect["inbound_agent_id"]
    assert ThreadRouteOwner.lookup(route_scope(connect, envelope)) == {:ok, :legacy}
    refute_received {:triage_consumer_called, _, _}
  end

  test "an explicit agent mention is mirrored but waits for the CH patrol", %{connect: connect} do
    envelope = agent_mention_envelope(connect, "Ev-agent-directed", "1787019020.000001")

    assert callback(connect, envelope) == {:error, :ignored}
    assert_receive {:mirrored, %{"message_ts" => "1787019020.000001"}}
    assert ThreadRouteOwner.lookup(route_scope(connect, envelope)) == :unbound
    assert CasRecord.get(receipt_key(connect, envelope)) == {:error, :not_found}
    refute_received {:triage_consumer_called, _, _}
    refute_received {:explicit_mention_delivery, _, _, _}
  end

  test "another app's reply in a command thread reaches the Router", %{connect: connect} do
    root = human_mention_envelope(connect, "Ev-peer-agent-root", "1787019040.000001")
    assert callback(connect, root) == {:ok, :accepted}
    assert_receive {:explicit_mention_delivery, _, _, _}

    # The shape a Slack app posts under its own name or icon: no `user`, the
    # `bot_message` subtype, and its identity only in `bot_id`/`app_id`.
    reply =
      bot_reply_envelope(connect, "Ev-peer-agent-reply", "1787019041.000001", root["event"]["ts"])

    assert callback(connect, reply) == {:ok, :accepted}
    assert_receive {:mirrored, %{"message_ts" => "1787019041.000001"}}
    assert_receive {:explicit_mention_delivery, agent_id, _payload, _opts}
    assert agent_id == connect["inbound_agent_id"]
    assert ThreadRouteOwner.lookup(route_scope(connect, root)) == {:ok, :legacy}
    refute_received {:triage_consumer_called, _, _}
  end

  for subtype <- ["", "bot_message", "file_share"] do
    test "a peer's #{inspect(subtype)} file reply continues a human command on a projected Triage thread",
         %{connect: connect} do
      {root, scope, identity} = projected_triage_thread!(connect)

      command =
        human_mention_envelope(connect, "Ev-human-enlists-router", "1787019001.000001")
        |> put_in(["event", "thread_ts"], root["event"]["ts"])

      assert callback(connect, command) == {:ok, :accepted}
      assert_receive {:explicit_mention_delivery, _, _, _}

      reply =
        bot_reply_envelope(connect, "Ev-peer-patch", "1787019002.000001", root["event"]["ts"])
        |> put_in(["event", "subtype"], unquote(subtype))
        |> put_in(["event", "text"], "<@#{connect["bot_user_id"]}> apply the attached patch")
        |> put_in(["event", "files"], [%{"id" => "F_PATCH", "name" => "change.patch"}])

      assert callback(connect, reply) == {:ok, :accepted}
      assert_receive {:explicit_mention_delivery, _, payload, delivery_opts}
      assert inspect(payload) =~ "change.patch"
      assert payload.trusted_origin["provider_context"]["app_authored"] == true
      assert ThreadRouteOwner.verify_claim(scope, :triage, identity) == {:ok, :triage}

      # Slack also sends app_mention for the same message. Admission must not
      # use a second source identity at the Agent's durable deduplication seam.
      mention =
        reply
        |> Map.put("event_id", "Ev-peer-patch-mention")
        |> put_in(["event", "type"], "app_mention")

      assert callback(connect, mention) == {:ok, :accepted}
      {:ok, conversation} = SalixIM.RouterConversationInput.ensure(connect["group_id"])

      {:ok, messages} =
        SalixIM.Conversations.list_group_conversation_messages(
          connect["group_id"],
          conversation["conversation_id"]
        )

      assert Enum.count(messages, &(&1["source_message_id"] == delivery_opts[:source_message_id])) ==
               1

      refute_receive {:explicit_mention_delivery, _, _, _}, 100
    end
  end

  test "peer file-only messages are delivered as content, and own file echoes stay inert", %{
    connect: connect
  } do
    root = human_mention_envelope(connect, "Ev-file-only-root", "1787019040.000001")
    assert callback(connect, root) == {:ok, :accepted}
    assert_receive {:explicit_mention_delivery, _, _, _}

    reply =
      bot_reply_envelope(connect, "Ev-file-only", "1787019041.000001", root["event"]["ts"])
      |> put_in(["event", "subtype"], "file_share")
      |> put_in(["event", "text"], "")
      |> put_in(["event", "files"], [%{"id" => "F_ONLY", "name" => "result.txt"}])

    assert callback(connect, reply) == {:ok, :accepted}
    assert_receive {:explicit_mention_delivery, _, payload, _}
    assert inspect(payload) =~ "result.txt"

    own_reply =
      reply
      |> Map.put("event_id", "Ev-own-file-only")
      |> put_in(["event", "ts"], "1787019042.000001")
      |> put_in(["event", "bot_id"], connect["bot_id"])
      |> put_in(["event", "app_id"], connect["app_id"])

    assert callback(connect, own_reply) == {:error, :ignored}
    refute_received {:explicit_mention_delivery, _, _, _}
  end

  test "a projected Triage subscription admits a peer without Router participation", %{
    connect: connect
  } do
    {root, scope, identity} = projected_triage_thread!(connect)
    subscription_scope = Map.put(scope, "agent_id", connect["inbound_agent_id"])

    assert {:ok, _} =
             SalixStore.SlackTriageThreadSubscriptions.activate(subscription_scope, %{
               "obligation_id" => "triage-product-" <> String.duplicate("a", 64),
               "provider_message_ref" => "slack:1787019001.000001"
             })

    reply =
      bot_reply_envelope(connect, "Ev-subscribed-peer", "1787019002.000001", root["event"]["ts"])

    assert callback(connect, reply) == {:ok, :accepted}
    assert_receive {:explicit_mention_delivery, _, _, _}
    assert ThreadRouteOwner.verify_claim(scope, :triage, identity) == {:ok, :triage}

    # Channel admission revocation cannot reuse the old subscription. This
    # unmentioned input did not establish a separate human command lane.
    assert :ok =
             SalixStore.SlackTriageChannels.set_enabled(
               connect["tenant_id"],
               connect["group_id"],
               connect["connect_id"],
               connect["approved_channel_id"],
               connect["connect_generation"],
               false
             )

    later =
      reply
      |> Map.put("event_id", "Ev-disabled-channel-peer")
      |> put_in(["event", "ts"], "1787019003.000001")

    assert callback(connect, later) == {:error, :ignored}
    refute_received {:explicit_mention_delivery, _, _, _}
  end

  test "Router participation is scoped to the exact channel", %{connect: connect} do
    root = human_mention_envelope(connect, "Ev-participation-scope", "1787019040.000001")
    assert callback(connect, root) == {:ok, :accepted}
    assert_receive {:explicit_mention_delivery, _, _, _}

    other_channel =
      bot_reply_envelope(
        connect,
        "Ev-other-channel-peer",
        "1787019041.000001",
        root["event"]["ts"]
      )
      |> put_in(["event", "channel"], "C_OTHER_CHANNEL")

    assert callback(connect, other_channel) == {:error, :ignored}
    refute_received {:explicit_mention_delivery, _, _, _}
  end

  test "an unjoined projected Triage thread does not admit peer files", %{connect: connect} do
    {root, _scope, _identity} = projected_triage_thread!(connect)

    reply =
      bot_reply_envelope(connect, "Ev-unjoined-file", "1787019002.000001", root["event"]["ts"])
      |> put_in(["event", "files"], [%{"id" => "F_PATCH"}])

    assert callback(connect, reply) == {:error, :ignored}
    refute_received {:explicit_mention_delivery, _, _, _}
  end

  test "this app's own reply never continues its own thread", %{connect: connect} do
    root = human_mention_envelope(connect, "Ev-self-reply-root", "1787019050.000001")
    assert callback(connect, root) == {:ok, :accepted}
    assert_receive {:explicit_mention_delivery, _, _, _}

    own_reply =
      connect
      |> bot_reply_envelope("Ev-self-reply", "1787019051.000001", root["event"]["ts"])
      |> put_in(["event", "bot_id"], connect["bot_id"])
      |> put_in(["event", "app_id"], connect["app_id"])

    assert callback(connect, own_reply) == {:error, :ignored}
    assert_receive {:mirrored, %{"message_ts" => "1787019051.000001"}}
    refute_received {:explicit_mention_delivery, _, _, _}
  end

  test "another app's reply stays observation-only on a thread this app never joined", %{
    connect: connect
  } do
    root = root_envelope(connect, "Ev-unjoined-root")

    reply =
      bot_reply_envelope(connect, "Ev-unjoined-reply", "1787019061.000001", root["event"]["ts"])

    assert callback(connect, reply) == {:error, :ignored}
    assert_receive {:mirrored, %{"message_ts" => "1787019061.000001"}}
    assert CasRecord.get(receipt_key(connect, reply)) == {:error, :not_found}
    refute_received {:explicit_mention_delivery, _, _, _}
  end

  test "another app's reply waits for a confirmed reply on a CH-owned Triage thread", %{
    connect: connect
  } do
    root = root_envelope(connect, "Ev-ch-owned-peer-root")
    scope = route_scope(connect, root)

    assert {:ok, identity} =
             ThreadRouteOwner.clickhouse_root_claim_identity(scope, 1_787_019_000_000_001)

    assert {:ok, :triage} = ThreadRouteOwner.claim_triage(scope, identity)

    reply =
      bot_reply_envelope(
        connect,
        "Ev-ch-owned-peer-reply",
        "1787019071.000001",
        root["event"]["ts"]
      )

    assert callback(connect, reply) == {:error, :ignored}
    assert_receive {:mirrored, %{"message_ts" => "1787019071.000001"}}
    assert ThreadRouteOwner.verify_claim(scope, :triage, identity) == {:ok, :triage}
    assert CasRecord.get(receipt_key(connect, reply)) == {:error, :not_found}
    refute_received {:explicit_mention_delivery, _, _, _}
  end

  test "ordinary replies to an explicit human command remain command continuations", %{
    connect: connect
  } do
    root = human_mention_envelope(connect, "Ev-command-root", "1787019030.000001")
    assert callback(connect, root) == {:ok, :accepted}
    assert_receive {:explicit_mention_delivery, _, _, _}

    reply =
      root_envelope(connect, "Ev-command-continuation")
      |> put_in(["event", "text"], "再补充一个条件")
      |> put_in(["event", "ts"], "1787019031.000001")
      |> put_in(["event", "event_ts"], "1787019031.000001")
      |> put_in(["event", "thread_ts"], root["event"]["ts"])

    assert callback(connect, reply) == {:ok, :accepted}
    assert_receive {:mirrored, %{"message_ts" => "1787019031.000001"}}
    assert_receive {:explicit_mention_delivery, _, _payload, _opts}
    assert ThreadRouteOwner.lookup(route_scope(connect, root)) == {:ok, :legacy}
    refute_received {:triage_consumer_called, _, _}
  end

  test "an explicit human command does not move a CH-owned ambient route", %{connect: connect} do
    root = root_envelope(connect, "Ev-ch-owned")
    scope = route_scope(connect, root)

    assert {:ok, identity} =
             ThreadRouteOwner.clickhouse_root_claim_identity(scope, 1_787_019_000_000_001)

    assert {:ok, :triage} = ThreadRouteOwner.claim_triage(scope, identity)

    command = human_mention_envelope(connect, "Ev-command-on-ch-owned", root["event"]["ts"])

    assert callback(connect, command) == {:ok, :accepted}
    assert_receive {:explicit_mention_delivery, _, _, _}
    assert ThreadRouteOwner.verify_claim(scope, :triage, identity) == {:ok, :triage}
    refute_received {:triage_consumer_called, _, _}
  end

  for name <- ["notion_owner_table", "jenkins_mcp"] do
    fixture_path = Path.join([__DIR__, "fixtures", "slack_recipient_incident", name <> ".json"])
    @external_resource fixture_path
    fixture = fixture_path |> File.read!() |> Jason.decode!()

    @tag incident_replay: true
    test "sanitized #{name} conversation cannot wake a previously participating Bridge", %{
      connect: connect
    } do
      fixture = unquote(Macro.escape(fixture))
      connect = incident_connect!(connect, fixture["route_evidence"])

      # The archive and incident-time SQL prove this state. Rehydrate it in
      # PostgreSQL; recorded bot replies are context, not a new LLM execution.
      assert :ok =
               SalixStore.SlackRouterThreadParticipations.mark_participating(
                 connect["group_id"],
                 connect["connect_id"],
                 connect["workspace_id"],
                 connect["bot_user_id"],
                 fixture["trigger"]["channel"],
                 fixture["root_thread_ts"]
               )

      for {event, index} <- Enum.with_index(fixture["history"]) do
        envelope = incident_envelope(connect, event, "#{fixture["name"]}-history-#{index}")
        result = callback(connect, envelope)
        assert result in [{:ok, :accepted}, {:error, :ignored}]
        assert_receive {:mirrored, %{"message_ts" => message_ts}}
        assert message_ts == event["ts"]

        if result == {:ok, :accepted} do
          assert_receive {:explicit_mention_delivery, _, _, _}
        end
      end

      assert_incident_ignored(connect, fixture)

      # A synthetic positive control: an unaddressed continuation is still
      # admitted. Drop blocks too, so this is genuinely an unmentioned message.
      continuation =
        fixture["trigger"]
        |> Map.put("text", "继续整理刚才的内容")
        |> Map.delete("blocks")
        |> Map.put("ts", "1700200000.000001")
        |> Map.put("event_ts", "1700200000.000001")
        |> then(&incident_envelope(connect, &1, "#{fixture["name"]}-ordinary-continuation"))

      assert callback(connect, continuation) == {:ok, :accepted}
      assert_receive {:explicit_mention_delivery, _, _, _}
    end

    for enabled <- [false, true] do
      @tag incident_replay: true
      test "sanitized #{name} trigger cannot take over a command with Triage enabled=#{enabled}",
           %{
             connect: connect
           } do
        fixture = unquote(Macro.escape(fixture))
        connect = incident_connect!(connect, %{"triage_enabled" => unquote(enabled)})

        # Supplemental route coverage, not a claim about the production route:
        # establish a command owner, then replay the same real trigger payload.
        root =
          human_mention_envelope(connect, "Ev-incident-command-root", fixture["root_thread_ts"])

        assert callback(connect, root) == {:ok, :accepted}
        assert_receive {:explicit_mention_delivery, _, _, _}

        assert_incident_ignored(connect, fixture)
        assert ThreadRouteOwner.lookup(route_scope(connect, root)) == {:ok, :legacy}
      end
    end
  end

  test "rich-text recipients cannot bypass the shared admission rule", %{connect: connect} do
    root = human_mention_envelope(connect, "Ev-rich-root", "1787019030.000001")
    assert callback(connect, root) == {:ok, :accepted}
    assert_receive {:explicit_mention_delivery, _, _, _}

    reply =
      root_envelope(connect, "Ev-rich-other")
      |> put_in(["event", "thread_ts"], root["event"]["ts"])
      |> put_in(["event", "ts"], "1787019031.000001")
      |> put_in(["event", "text"], "请你创建文档")
      |> put_in(["event", "blocks"], mention_blocks("U_PERSONAL_AGENT"))

    assert callback(connect, reply) == {:error, :ignored}
    assert_receive {:mirrored, %{"message_ts" => "1787019031.000001"}}
    refute_received {:explicit_mention_delivery, _, _, _}
  end

  test "sender attribution does not redirect a continuation or erase body recipients", %{
    connect: connect
  } do
    root = human_mention_envelope(connect, "Ev-attribution-root", "1787019030.000001")
    assert callback(connect, root) == {:ok, :accepted}
    assert_receive {:explicit_mention_delivery, _, _, _}

    for {text, blocks, expected, index} <- [
          {"继续检查 *Sent using* <@U_TOOL>", [], :accepted, 1},
          {"<@U_TOOL> 请检查\n*Sent using* <@U_TOOL>", [], :ignored, 2},
          {"继续检查 *Sent using* <@U_TOOL>", mention_blocks("U_TOOL"), :ignored, 3},
          {"<@#{connect["bot_user_id"]}> <@U_TOOL> 请一起检查 *Sent using* <@U_TOOL>", [], :accepted,
           4},
          {"*Sent using* <@U_TOOL> 请回答", [], :ignored, 5},
          {"> *Sent using* <@U_TOOL>", [], :ignored, 6},
          {"`*Sent using* <@U_TOOL>", [], :ignored, 7}
        ] do
      reply =
        root_envelope(connect, "Ev-attribution-#{index}")
        |> put_in(["event", "type"], if(index == 4, do: "app_mention", else: "message"))
        |> put_in(["event", "thread_ts"], root["event"]["ts"])
        |> put_in(["event", "ts"], "178701903#{index}.000001")
        |> put_in(["event", "text"], text)
        |> put_in(["event", "blocks"], blocks)

      case expected do
        :accepted ->
          assert callback(connect, reply) == {:ok, :accepted}, "case #{index}: #{text}"
          assert_receive {:explicit_mention_delivery, _, _, _}

        :ignored ->
          assert callback(connect, reply) == {:error, :ignored}
          refute_received {:explicit_mention_delivery, _, _, _}
      end
    end
  end

  test "non-ID mention-like text does not suppress a command continuation", %{connect: connect} do
    root = human_mention_envelope(connect, "Ev-literal-root", "1787019030.000001")
    assert callback(connect, root) == {:ok, :accepted}
    assert_receive {:explicit_mention_delivery, _, _, _}

    reply =
      root_envelope(connect, "Ev-literal-continuation")
      |> put_in(["event", "thread_ts"], root["event"]["ts"])
      |> put_in(["event", "ts"], "1787019031.000001")
      |> put_in(["event", "text"], "解释一下代码里的 <@abc-def> 和 <@U-not-a-provider-id>")

    assert callback(connect, reply) == {:ok, :accepted}
    assert_receive {:explicit_mention_delivery, _, _, _}
  end

  test "a mixed text and rich-text command still addresses Bridge exactly once", %{
    connect: connect
  } do
    command =
      human_mention_envelope(connect, "Ev-mixed-command", "1787019030.000001")
      |> put_in(["event", "text"], "<@U_PERSONAL_AGENT> 请一起检查文档")
      |> put_in(["event", "blocks"], mention_blocks(connect["bot_user_id"]))

    assert callback(connect, command) == {:ok, :accepted}
    assert_receive {:explicit_mention_delivery, _, _, _}

    copy =
      command
      |> Map.put("event_id", "Ev-mixed-message-copy")
      |> put_in(["event", "type"], "message")

    assert callback(connect, copy) == {:error, :ignored}
    refute_received {:explicit_mention_delivery, _, _, _}
  end

  test "a forwarded attachment cannot redirect an unmentioned command continuation", %{
    connect: connect
  } do
    root = human_mention_envelope(connect, "Ev-forward-root", "1787019030.000001")
    assert callback(connect, root) == {:ok, :accepted}
    assert_receive {:explicit_mention_delivery, _, _, _}

    reply =
      root_envelope(connect, "Ev-forward-context")
      |> put_in(["event", "thread_ts"], root["event"]["ts"])
      |> put_in(["event", "ts"], "1787019031.000001")
      |> put_in(["event", "text"], "继续做吧，参考这条转发")
      |> put_in(["event", "attachments"], [%{"text" => "<@U_PERSONAL_AGENT> old request"}])

    assert callback(connect, reply) == {:ok, :accepted}
    assert_receive {:explicit_mention_delivery, _, _, _}
  end

  test "App Home DM remains addressed to Bridge when it mentions a person", %{connect: connect} do
    dm =
      root_envelope(connect, "Ev-dm-person")
      |> put_in(["event", "channel_type"], "im")
      |> put_in(["event", "channel"], "D_TRIAGE_CALLBACK")
      |> put_in(["event", "text"], "帮我找一下 <@U_PERSONAL_AGENT> 的相关资料")

    assert callback(connect, dm) == {:ok, :accepted}
    assert_receive {:explicit_mention_delivery, _, _, _}
  end

  test "an explicit human command does not move a Task-owned route", %{connect: connect} do
    root = root_envelope(connect, "Ev-task-owned")
    scope = route_scope(connect, root)

    assert {:ok, triage_identity} =
             ThreadRouteOwner.clickhouse_root_claim_identity(scope, 1_787_019_000_000_001)

    assert {:ok, :triage} = ThreadRouteOwner.claim_triage(scope, triage_identity)
    assert {:ok, task_identity} = ThreadRouteOwner.task_claim_identity(scope, "cnv_task_owned")
    assert {:ok, :task} = ThreadRouteOwner.claim_task(scope, task_identity)

    command = human_mention_envelope(connect, "Ev-command-on-task-owned", root["event"]["ts"])

    assert callback(connect, command) == {:ok, :accepted}
    assert_receive {:explicit_mention_delivery, _, _, _}
    assert ThreadRouteOwner.verify_claim(scope, :task, task_identity) == {:ok, :task}
    refute_received {:triage_consumer_called, _, _}
  end

  defp incident_connect!(connect, route_attrs) do
    update_connect!(
      connect,
      Map.merge(
        %{
          "workspace_id" => "TINCIDENT",
          "approved_channel_id" => "CINCIDENT",
          "bot_user_id" => "UBRIDGE",
          "bot_id" => "BBRIDGE"
        },
        Map.take(route_attrs, [
          "triage_enabled",
          "triage_provisioned_at",
          "approved_channel_id",
          "connect_generation"
        ])
      )
    )
  end

  defp incident_envelope(connect, event, event_id) do
    connect |> root_envelope(event_id) |> Map.put("event", event)
  end

  defp assert_incident_ignored(connect, fixture) do
    envelope = incident_envelope(connect, fixture["trigger"], "Ev-#{fixture["name"]}-trigger")
    conversation_prefix = Keys.ctl_group_conversations_prefix(connect["group_id"])

    conversations_before =
      Map.filter(S3.Fake.dump(), fn {key, _} -> String.starts_with?(key, conversation_prefix) end)

    # Replay Slack redelivery as well: neither attempt may create a receipt,
    # wake the Router, append to a Task, or create a new Task conversation.
    for _attempt <- 1..2 do
      assert callback(connect, envelope) == {:error, :ignored}
      assert_receive {:mirrored, %{"message_ts" => message_ts}}
      assert message_ts == fixture["trigger"]["ts"]
      refute_received {:explicit_mention_delivery, _, _, _}
      assert CasRecord.get(receipt_key(connect, envelope)) == {:error, :not_found}

      assert Map.filter(S3.Fake.dump(), fn {key, _} ->
               String.starts_with?(key, conversation_prefix)
             end) == conversations_before
    end
  end

  defp update_connect!(connect, attrs) do
    assert {:ok, updated} =
             CasRecord.update(
               Keys.ctl_im_connect(connect["group_id"], connect["connect_id"]),
               fn current ->
                 Map.merge(current, attrs)
               end
             )

    updated
  end

  defp mention_blocks(user_id) do
    [
      %{
        "type" => "rich_text",
        "elements" => [
          %{
            "type" => "rich_text_section",
            "elements" => [%{"type" => "user", "user_id" => user_id}]
          }
        ]
      }
    ]
  end

  defp callback(connect, envelope) do
    result =
      ProviderHTTP.handle_slack_event(
        connect,
        envelope,
        signed_headers(connect, envelope),
        Jason.encode!(envelope)
      )

    # A 500 or raised exception inside the Plug could be rescued by the
    # production API adapter. Assert in the owning test process after every
    # callback instead, including callbacks that are expected to be ignored.
    refute_received {:unexpected_slack_request, _}
    result
  end

  defp root_envelope(connect, event_id) do
    %{
      "type" => "event_callback",
      "api_app_id" => connect["app_id"],
      "team_id" => connect["workspace_id"],
      "event_id" => event_id,
      "event" => %{
        "type" => "message",
        "user" => "U_TRIAGE_HUMAN",
        "text" => "please review this update",
        "channel" => connect["approved_channel_id"],
        "ts" => "1787019000.000001",
        "event_ts" => "1787019000.000001"
      }
    }
  end

  defp human_mention_envelope(connect, event_id, ts) do
    connect
    |> root_envelope(event_id)
    |> put_in(["event", "type"], "app_mention")
    |> put_in(["event", "text"], "<@#{connect["bot_user_id"]}> please help")
    |> put_in(["event", "ts"], ts)
    |> put_in(["event", "event_ts"], ts)
  end

  defp bot_reply_envelope(connect, event_id, ts, thread_ts) do
    connect
    |> root_envelope(event_id)
    |> update_in(["event"], &Map.delete(&1, "user"))
    |> put_in(["event", "subtype"], "bot_message")
    |> put_in(["event", "username"], "Peer Assistant")
    |> put_in(["event", "app_id"], "A_OTHER_APP")
    |> put_in(["event", "bot_id"], "B_OTHER_BOT")
    |> put_in(["event", "text"], "我查完了，结论在下面")
    |> put_in(["event", "ts"], ts)
    |> put_in(["event", "event_ts"], ts)
    |> put_in(["event", "thread_ts"], thread_ts)
  end

  defp agent_mention_envelope(connect, event_id, ts) do
    connect
    |> root_envelope(event_id)
    |> put_in(["event", "user"], "U_OTHER_BOT")
    |> put_in(["event", "app_id"], "A_OTHER_APP")
    |> put_in(["event", "bot_id"], "B_OTHER_BOT")
    |> put_in(["event", "text"], "<@#{connect["bot_user_id"]}> 这个 PR 我看过了")
    |> put_in(["event", "ts"], ts)
    |> put_in(["event", "event_ts"], ts)
  end

  defp route_scope(connect, envelope) do
    event = envelope["event"]

    %{
      "tenant_id" => connect["tenant_id"],
      "group_id" => connect["group_id"],
      "connect_id" => connect["connect_id"],
      "connect_generation" => connect["connect_generation"],
      "workspace_id" => connect["workspace_id"],
      "channel_id" => event["channel"],
      "root_thread_ts" => event["thread_ts"] || event["ts"]
    }
  end

  defp projected_triage_thread!(connect) do
    restore_projected_channel_authority!()

    assert {:ok, _} =
             SalixStore.SlackTriageChannels.provision(%{
               "tenant_id" => connect["tenant_id"],
               "group_id" => connect["group_id"],
               "connect_id" => connect["connect_id"],
               "channel_id" => connect["approved_channel_id"],
               "installation_generation" => connect["connect_generation"],
               "workspace_id" => connect["workspace_id"],
               "channel_name" => "test-channel"
             })

    assert {:ok, authority} =
             SalixIM.ProviderConnects.get_slack_triage_authority(
               connect["tenant_id"],
               connect["group_id"],
               connect["connect_id"],
               connect["approved_channel_id"]
             )

    refute authority["connect_generation"] == connect["connect_generation"]
    root = root_envelope(connect, "Ev-projected-root")
    scope = route_scope(authority, root)

    assert {:ok, identity} =
             ThreadRouteOwner.clickhouse_root_claim_identity(scope, 1_787_019_000_000_001)

    assert {:ok, :triage} = ThreadRouteOwner.claim_triage(scope, identity)
    {root, scope, identity}
  end

  defp signed_headers(connect, envelope) do
    body = Jason.encode!(envelope)
    timestamp = System.system_time(:second)

    mac =
      :crypto.mac(:hmac, :sha256, connect["signing_secret"], "v0:#{timestamp}:#{body}")
      |> Base.encode16(case: :lower)

    [
      {"x-slack-request-timestamp", Integer.to_string(timestamp)},
      {"x-slack-signature", "v0=" <> mac}
    ]
  end

  defp receipt_key(connect, envelope),
    do: Keys.ctl_im_slack_event_receipt(connect["connect_id"], envelope["event_id"])

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp use_legacy_channel_authority! do
    Repo.query!("""
    DELETE FROM salix_cutover_markers
    WHERE name IN ('slack_triage_channels_v1', 'slack_triage_channels_v1_preparing')
    """)
  end

  defp restore_projected_channel_authority! do
    Repo.query!("""
    INSERT INTO salix_cutover_markers (name, completed_at, evidence)
    VALUES ('slack_triage_channels_v1', now(), '{"mode":"callback-route-test"}'::jsonb)
    ON CONFLICT (name) DO NOTHING
    """)
  end
end
