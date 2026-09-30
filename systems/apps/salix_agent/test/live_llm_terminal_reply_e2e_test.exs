defmodule SalixAgent.LiveLlmTerminalReplyE2eTest do
  @moduledoc """
  Real-model delivery and explicit completion of Router replies. Only the LLM
  crosses a network boundary; Telegram delivery is captured locally. Opt in
  with --include live_llm and the standard LiveLlmTestSupport credentials.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.LiveLlmTestSupport, as: Live
  alias SalixAgent.HistoricalTelegramReplyFixture, as: HistoricalReply
  @moduletag :live_llm
  @moduletag timeout: 300_000

  defmodule TelegramCapture do
    @behaviour SalixAgent.Tools.ImRouter
    @impl true
    def list_connects(_agent),
      do: {:ok, [%{"connect_id" => "telegram-test", "provider" => "telegram"}]}

    @impl true
    def provider_manual("telegram") do
      {:ok,
       %{
         "provider" => "telegram",
         "apis" => [
           %{
             "name" => "telegram.send_message",
             "safety" => "write",
             "description" => "Send a visible Telegram text reply.",
             "required_params" => ["chat_id", "text"],
             "parameters" => %{
               "chat_id" => "Destination chat from the accepted source",
               "text" => "Reply text"
             }
           }
         ]
       }}
    end

    def provider_manual(_), do: {:error, :unsupported}
    @impl true
    def call_api(agent, "telegram", "telegram.send_message", args) do
      send(
        Application.fetch_env!(:salix_agent, :live_llm_test_capture_pid),
        {:terminal_telegram_send, agent, args}
      )

      {:ok, %{"message_id" => 42, "date" => System.system_time(:second)}}
    end
  end

  defmodule Metering do
    @behaviour SalixAgent.LLMMetering
    @impl true
    def before_llm_call(fact) do
      send(
        Application.fetch_env!(:salix_agent, :live_llm_test_capture_pid),
        {:terminal_llm_request, fact.agent_id}
      )

      :ok
    end

    @impl true
    def after_llm_call(_fact), do: :ok
  end

  defmodule NativeCapture do
    @behaviour SalixAgent.TelegramInteraction

    @impl true
    def capabilities(ctx) do
      if SalixAgent.TerminalReply.source_scope_matches_context?(ctx[:reply_source_scope], ctx),
        do: %{"question" => true, "location" => true},
        else: %{}
    end

    @impl true
    def request(scope, type, args, _call_id) do
      send(
        Application.fetch_env!(:salix_agent, :live_llm_test_capture_pid),
        {:terminal_native_prompt, scope, type, args}
      )

      {:ok, %{"request_id" => "native-local", "message_id" => 43}}
    end
  end

  setup_all do
    {:ok, llm: Live.llm_config!()}
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    restore = Live.install_runtime!()
    previous_metering = Application.get_env(:salix_agent, :llm_metering_mod)
    previous_interaction = Application.get_env(:salix_agent, :telegram_interaction_mod)
    Application.put_env(:salix_agent, :im_provider_mod, TelegramCapture)
    Application.put_env(:salix_agent, :llm_metering_mod, Metering)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      restore.()
      Live.restore_env(:llm_metering_mod, previous_metering)
      Live.restore_env(:telegram_interaction_mod, previous_interaction)
    end)

    :ok
  end

  @tag :context_freshness
  test "old snapshots use each request's original date for a visible reply", %{llm: llm} do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    Live.configure!(agent_id, llm, %{"role" => "router"})
    {:ok, agent} = SalixAgent.Control.get(agent_id)
    group_id = SalixStore.Ids.group_id_from_agent!(agent_id)

    group =
      SalixAgent.TestSupport.create_control_group!(group_id, %{"router_agent_id" => agent_id})

    session_id = Live.router_session_id!(agent_id)
    {:ok, config} = SalixAgent.AgentActor.runtime_session_config(agent_id)
    today = Date.utc_today()
    stale_date = today |> Date.add(-7) |> Date.to_iso8601()

    :ok =
      SalixAgent.ContextFreshnessFixture.seed_old_prompt!(
        agent_id,
        session_id,
        config.system_prompt,
        stale_date
      )

    for {name, source_date} <- [
          {"current", today},
          {"queued-before-midnight", Date.add(today, -1)}
        ] do
      source = "time-live-" <> name

      source_time =
        DateTime.new!(
          source_date,
          if(name == "current", do: ~T[00:01:00], else: ~T[23:59:00]),
          "Etc/UTC"
        )

      expected = source_date |> Date.add(-1) |> Date.to_iso8601()

      question =
        "Using the UTC date when this message was sent, what date was yesterday? Reply with only YYYY-MM-DD."

      metadata = %{
        "provider" => "telegram",
        "connect_id" => "telegram-test",
        "chat_id" => "42",
        "chat_type" => "private",
        "message_id" => name,
        "from_user_id" => "42",
        "source_sent_at_ms" => DateTime.to_unix(source_time, :millisecond)
      }

      {:ok, payload} =
        SalixIM.AgentDeliveryPayload.provider_router_delivery(group, agent, question, metadata,
          source_message_id: source,
          trusted_source_text: question
        )

      {:ok, :created} =
        SalixAgent.deliver(
          agent_id,
          %{
            content: payload["content"],
            trusted_origin: payload["trusted_origin"],
            role: "user",
            source_sent_at_ms: payload["source_sent_at_ms"],
            source_timezone: "Etc/UTC"
          },
          source_message_id: source
        )

      Live.await_session_settled!(agent_id, session_id, 90_000)
      assert_receive {:terminal_telegram_send, ^agent_id, args}, 1_000
      assert String.trim(args["params"]["text"]) == expected
      refute_receive {:terminal_telegram_send, ^agent_id, _}, 100

      IO.puts(
        "CONTEXT_FRESHNESS_LIVE model=#{llm.model} scenario=#{name} reply=#{expected} visible_effects=1"
      )
    end
  end

  test "natural answers and essential questions deliver once and explicitly finish",
       %{llm: llm} do
    scenarios = [
      {"arithmetic", "请计算17+25，用一句中文答复。", "done"},
      {"question", "要继续这个练习，必须先向我询问一个尚未给出的四位验证码；除此之外没有可进行的工作。", "blocked"},
      {"format", "用标题和两条列表介绍单元测试。", "done"}
    ]

    for {name, question, outcome} <- scenarios do
      agent_id = SalixAgent.TestSupport.new_agent_id()
      Live.configure!(agent_id, llm, %{"role" => "router"})
      {:ok, agent} = SalixAgent.Control.get(agent_id)
      group_id = SalixStore.Ids.group_id_from_agent!(agent_id)

      group =
        SalixAgent.TestSupport.create_control_group!(group_id, %{"router_agent_id" => agent_id})

      source = "terminal-live-#{name}"

      metadata = %{
        "provider" => "telegram",
        "connect_id" => "telegram-test",
        "chat_id" => "42",
        "chat_type" => "private",
        "message_id" => "1",
        "from_user_id" => "42"
      }

      {:ok, payload} =
        SalixIM.AgentDeliveryPayload.provider_router_delivery(group, agent, question, metadata,
          source_message_id: source,
          trusted_source_text: question
        )

      {:ok, :created} =
        SalixAgent.deliver(
          agent_id,
          %{
            content: payload["content"],
            trusted_origin: payload["trusted_origin"],
            role: "user"
          },
          source_message_id: source
        )

      session_id = Live.router_session_id!(agent_id)
      settled = Live.await_session_settled!(agent_id, session_id, 90_000)

      diagnostic =
        inspect(%{ack: settled.last_ack_message_id, wait: settled.wait, status: settled.status})

      assert_receive {:terminal_telegram_send, ^agent_id, args}, 1000, diagnostic

      assert args["params"]["chat_id"] |> to_string() == "42"
      assert String.trim(args["params"]["text"]) != ""
      refute_receive {:terminal_telegram_send, ^agent_id, _}, 100
      assert settled.last_ack_message_id == source

      assert settled.wait == nil
      request_count = drain_requests(agent_id, 0)
      assert request_count > 0

      [{actor, _}] =
        Registry.lookup(
          SalixAgent.Registry,
          SalixAgent.InternalSessionActor.key(agent_id, session_id)
        )

      GenServer.stop(actor, :normal)
      SalixAgent.InternalSessionActor.wake(agent_id, session_id)
      refute_receive {:terminal_llm_request, ^agent_id}, 500
      refute_receive {:terminal_telegram_send, ^agent_id, _}, 100

      IO.puts(
        "TERMINAL_REPLY_LIVE scenario=#{name} model=#{llm.model} requests=#{request_count} sends=1 outcome=#{outcome}"
      )
    end
  end

  test "native choices and ordinary replies settle once with background context",
       %{llm: llm} do
    Application.put_env(:salix_agent, :telegram_interaction_mod, NativeCapture)
    agent_id = SalixAgent.TestSupport.new_agent_id()
    Live.configure!(agent_id, llm, %{"role" => "router"})
    {:ok, agent} = SalixAgent.Control.get(agent_id)
    group_id = SalixStore.Ids.group_id_from_agent!(agent_id)

    group =
      SalixAgent.TestSupport.create_control_group!(group_id, %{"router_agent_id" => agent_id})

    {:ok, :created} =
      SalixAgent.deliver(
        agent_id,
        %{
          role: "user",
          content: "会议上下文：今天和明天均可安排；等待用户自行选择。",
          trusted_origin: %{"provider" => "internal", "source_actor_type" => "provider_system"}
        },
        source_message_id: "meeting-context",
        no_wake: true
      )

    for {source, message, expected_text} <- [
          {"native-question", "请发两个 Telegram 按钮，让我在今天和明天之间选择；不要仅用文字列出选项。", nil},
          {"native-answer", "我选今天。请用一句中文确认我的选择。", "今天"},
          {"native-ordinary", "请计算17+25，用一句中文答复。", "42"}
        ] do
      metadata = %{
        "provider" => "telegram",
        "connect_id" => "telegram-test",
        "chat_id" => "42",
        "chat_type" => "private",
        "message_id" => source,
        "from_user_id" => "42"
      }

      {:ok, payload} =
        SalixIM.AgentDeliveryPayload.provider_router_delivery(group, agent, message, metadata,
          source_message_id: source,
          trusted_source_text: message
        )

      {:ok, :created} =
        SalixAgent.deliver(
          agent_id,
          %{content: payload["content"], trusted_origin: payload["trusted_origin"], role: "user"},
          source_message_id: source
        )

      settled = Live.await_session_settled!(agent_id, Live.router_session_id!(agent_id), 90_000)
      assert settled.wait == nil

      if source == "native-question" do
        assert_receive {:terminal_native_prompt, scope, "question", args}, 1000
        assert scope["chat_id"] == "42"
        assert scope["source_message_id"] == source
        assert scope["context_source_message_ids"] == ["meeting-context", source]
        assert length(args["choices"]) == 2
        assert args["locale"] == "zh-CN"
        assert Enum.any?(args["choices"], &String.contains?(&1, "今天"))
        assert Enum.any?(args["choices"], &String.contains?(&1, "明天"))

        assert Enum.any?(settled.events, fn event ->
                 event["kind"] == "terminal_reply_delivered" and
                   event["event"]["outcome"] == "blocked" and
                   event["event"]["source_message_id"] == source
               end)

        refute_receive {:terminal_telegram_send, ^agent_id, _}, 100
      else
        assert_receive {:terminal_telegram_send, ^agent_id, args}, 1000
        assert to_string(args["params"]["chat_id"]) == "42"
        assert args["params"]["text"] =~ expected_text

        assert settled.last_ack_message_id == source
      end

      requests = drain_requests(agent_id, 0)
      assert requests > 0
      refute_receive {:terminal_native_prompt, _, _, _}, 100
      refute_receive {:terminal_telegram_send, ^agent_id, _}, 100
      refute_receive {:terminal_llm_request, ^agent_id}, 300

      IO.puts(
        "TELEGRAM_NATIVE_LIVE source=#{source} model=#{llm.model} requests=#{requests} effects=1"
      )
    end
  end

  @tag :native_discovery
  test "current native choices supersede an earlier unsupported answer", %{llm: llm} do
    agent_id = SalixAgent.TestSupport.new_agent_id()

    Live.configure!(agent_id, llm, %{
      "role" => "router",
      "disabled_tools" => ["question.request"]
    })

    {:ok, agent} = SalixAgent.Control.get(agent_id)
    group_id = SalixStore.Ids.group_id_from_agent!(agent_id)

    group =
      SalixAgent.TestSupport.create_control_group!(group_id, %{"router_agent_id" => agent_id})

    # Replay the old user-visible mistake through the normal runtime, so the
    # real model sees an acknowledged earlier answer, not an instruction to
    # call a particular tool or a newly inserted user claim about capability.
    Application.put_env(:salix_agent, :llm, HistoricalReply)
    deliver_native_message!(group, agent, "before-native-support", "能不能发一个带按钮的问题？")

    for {id, args} <- [
          {"historical-help",
           %{"tool" => "help", "params" => %{"tool" => "im_api.telegram.send_message"}}},
          {"historical-denial",
           %{
             "tool" => "im_api.telegram.send_message",
             "params" => %{
               "connect_id" => "telegram-test",
               "chat_id" => "42",
               "text" => "目前我无法直接在 Telegram 对话中生成原生按钮，只能用文字列出选项。"
             },
             "reply_mode" => "final",
             "final_outcome" => "done"
           }}
        ] do
      assert_receive {:historical_reply_request, pid}, 5_000
      HistoricalReply.respond(pid, id, args)
    end

    assert_receive {:historical_reply_request, pid}, 5_000

    HistoricalReply.finish(pid)

    session_id = Live.router_session_id!(agent_id)
    prior = Live.await_session_settled!(agent_id, session_id, 10_000)
    refute prior.system_prompt =~ "question.request"
    assert_receive {:terminal_telegram_send, ^agent_id, old_reply}, 1_000
    assert old_reply["params"]["text"] =~ "无法"
    drain_requests(agent_id, 0)

    Application.put_env(:salix_agent, :llm, SalixLlm.Provider)
    Application.put_env(:salix_agent, :telegram_interaction_mod, NativeCapture)
    assert {:ok, _} = SalixAgent.Control.configure(agent_id, %{"disabled_tools" => []})

    deliver_native_message!(
      group,
      agent,
      "native-current-request",
      "请用 Telegram 原生的两个按钮让我选择：继续测试 / 结束测试。点击后请在本聊天回复我选了哪个。这只是一次无害问答验收，不要申请文件、位置或账号权限，不要执行其他业务操作。"
    )

    settled = Live.await_session_settled!(agent_id, session_id, 90_000)
    assert_receive {:terminal_native_prompt, scope, "question", args}, 1_000
    assert scope["source_message_id"] == "native-current-request"
    assert scope["chat_id"] == "42"
    assert args["locale"] == "zh-CN"
    assert length(args["choices"]) == 2
    assert Enum.any?(args["choices"], &String.contains?(&1, "继续测试"))
    assert Enum.any?(args["choices"], &String.contains?(&1, "结束测试"))
    assert settled.wait == nil
    assert settled.system_prompt == prior.system_prompt
    refute_receive {:terminal_telegram_send, ^agent_id, _}, 100
    refute_receive {:terminal_native_prompt, _, _, _}, 100

    IO.puts(
      "TELEGRAM_NATIVE_DISCOVERY_LIVE scenario=stale-denial model=#{llm.model} requests=#{drain_requests(agent_id, 0)} native_prompts=1"
    )
  end

  @tag :location_city
  test "weather asks for a city while an explicit location request uses dialogue locale",
       %{llm: llm} do
    Application.put_env(:salix_agent, :telegram_interaction_mod, NativeCapture)

    for {name, message} <- [
          {"weather", "我今天的天气如何？"},
          {"location", "请发一个 Telegram 位置请求，我会在手机端自愿分享当前位置。"}
        ] do
      agent_id = SalixAgent.TestSupport.new_agent_id()
      Live.configure!(agent_id, llm, %{"role" => "router"})
      {:ok, agent} = SalixAgent.Control.get(agent_id)
      group_id = SalixStore.Ids.group_id_from_agent!(agent_id)

      group =
        SalixAgent.TestSupport.create_control_group!(group_id, %{"router_agent_id" => agent_id})

      deliver_native_message!(group, agent, name, message)
      settled = Live.await_session_settled!(agent_id, Live.router_session_id!(agent_id), 90_000)
      assert settled.wait == nil

      if name == "location" do
        assert_receive {:terminal_native_prompt, scope, "location", args}, 1_000
        assert scope["source_message_id"] == name
        assert args["locale"] == "zh-CN"
      else
        receive do
          {:terminal_native_prompt, scope, "question", args} ->
            assert scope["source_message_id"] == name
            assert args["locale"] == "zh-CN"
            assert args["question"] =~ "城市"

          {:terminal_telegram_send, ^agent_id, args} ->
            assert args["params"]["text"] =~ "城市"
        after
          1_000 ->
            flunk(
              "weather must ask for a city through the current source: " <>
                inspect(%{messages: settled.messages, events: settled.events}, limit: :infinity)
            )
        end
      end

      refute_receive {:terminal_native_prompt, _, _, _}, 100
      refute_receive {:terminal_telegram_send, ^agent_id, _}, 100

      assert settled.last_ack_message_id == name

      IO.puts(
        "TELEGRAM_LOCATION_LIVE scenario=#{name} model=#{llm.model} requests=#{drain_requests(agent_id, 0)} prompts=1"
      )
    end
  end

  defp deliver_native_message!(group, agent, source, message) do
    metadata = %{
      "provider" => "telegram",
      "connect_id" => "telegram-test",
      "chat_id" => "42",
      "chat_type" => "private",
      "message_id" => source,
      "from_user_id" => "42"
    }

    {:ok, payload} =
      SalixIM.AgentDeliveryPayload.provider_router_delivery(group, agent, message, metadata,
        source_message_id: source,
        trusted_source_text: message
      )

    assert {:ok, :created} =
             SalixAgent.deliver(
               agent["agent_id"],
               %{
                 content: payload["content"],
                 trusted_origin: payload["trusted_origin"],
                 role: "user"
               },
               source_message_id: source
             )
  end

  defp drain_requests(agent, count) do
    receive do
      {:terminal_llm_request, ^agent} -> drain_requests(agent, count + 1)
    after
      0 -> count
    end
  end
end
