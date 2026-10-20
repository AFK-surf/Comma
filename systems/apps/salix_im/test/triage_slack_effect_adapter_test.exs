defmodule SalixIM.Triage.SlackEffectAdapterTest do
  use SystemsClock.Case, async: true

  alias SalixIM.Triage.{ExpressionContext, SlackEffectAdapter}
  alias SalixIM.Triage.SlackEffectAdapter.{Freshness, Reaction, Reply}

  test "reply is delivered directly after two freshness checks without Conversation" do
    claim = claim("reply")

    assert {:ok,
            %{
              adapter: :slack,
              outcome: :applied,
              external_writes: 1,
              communication: %{"kind" => "reply", "status" => "delivered"},
              metadata: %{
                "delivery" => "direct_slack_reply",
                "operation_ref" => operation_ref
              }
            }} =
             SlackEffectAdapter.apply(claim,
               freshness_port: __MODULE__.FreshPort,
               reply_port: __MODULE__.ReplyPort,
               effect_guard: __MODULE__.EffectGuard,
               conversation_port: __MODULE__.ConversationMustNotRun,
               port_opts: [test_pid: SystemsRuntime.Proc.self()]
             )

    assert operation_ref == claim.obligation_id
    assert_receive {:lookup_reply, ^claim}
    assert_receive {:freshness, ^claim}
    assert_receive {:prepare_reply, ^claim}
    assert_receive {:freshness, ^claim}
    assert_receive {:deliver_reply, ^claim, %{operation_ref: ^operation_ref}}
    refute_receive {:conversation_called, _operation}
  end

  test "a provider-confirmed retry completes locally without freshness or a provider repost" do
    claim = claim("reply")
    Process.put(:reply_already_delivered, true)

    assert {:ok,
            %{
              outcome: :applied,
              external_writes: 0,
              communication: %{"kind" => "reply", "status" => "delivered"},
              metadata: %{
                "delivery" => "direct_slack_reply",
                "already_delivered" => true
              }
            }} =
             SlackEffectAdapter.apply(claim,
               freshness_port: __MODULE__.FreshPort,
               reply_port: __MODULE__.ReplyPort,
               conversation_port: __MODULE__.ConversationMustNotRun,
               port_opts: [test_pid: SystemsRuntime.Proc.self()]
             )

    assert_receive {:lookup_reply, ^claim}
    refute_receive {:freshness, _claim}
    refute_receive {:prepare_reply, _claim}
    refute_receive {:deliver_reply, _claim, _prepared}
    refute_receive {:conversation_called, _operation}
  end

  test "a changed thread suppresses reply but still permits product settlement" do
    claim = claim("reply")

    assert {:ok,
            %{
              outcome: :stale,
              external_writes: 0,
              communication: %{
                "kind" => "reply",
                "status" => "suppressed_stale",
                "reason" => "new_source_message"
              }
            }} =
             SlackEffectAdapter.apply(claim,
               freshness_port: __MODULE__.StalePort,
               reply_port: __MODULE__.ReplyPort,
               conversation_port: __MODULE__.ConversationMustNotRun,
               port_opts: [test_pid: SystemsRuntime.Proc.self()]
             )

    assert_receive {:lookup_reply, ^claim}
    refute_receive {:prepare_reply, _claim}
    refute_receive {:deliver_reply, _claim, _prepared}
    refute_receive {:conversation_called, _operation}
  end

  test "silence records no provider effect and needs no source read" do
    claim = claim("silence")

    assert {:ok,
            %{
              outcome: :applied,
              external_writes: 0,
              communication: %{"kind" => "silence", "reason" => "already_answered"}
            }} =
             SlackEffectAdapter.apply(claim,
               freshness_port: __MODULE__.StalePort,
               conversation_port: __MODULE__.ConversationPort,
               port_opts: [test_pid: SystemsRuntime.Proc.self()]
             )

    refute_receive _message
  end

  test "reaction freshness-checks the exact decision target and uses one idempotent Slack write" do
    claim = claim("reaction")

    assert {:ok,
            %{
              adapter: :slack,
              outcome: :applied,
              external_writes: 1,
              communication: %{
                "kind" => "reaction",
                "emoji" => "tada",
                "status" => "added"
              }
            }} =
             SlackEffectAdapter.apply(claim,
               freshness_port: __MODULE__.FreshPort,
               reaction_port: __MODULE__.ReactionPort,
               effect_guard: __MODULE__.EffectGuard,
               port_opts: [test_pid: SystemsRuntime.Proc.self()]
             )

    assert_receive {:freshness, ^claim}
    assert_receive {:reaction, ^claim, "101.000001", "tada"}
  end

  for {name, source_ref} <- [
        {"reaction fails closed when the cited source is outside the exact Slack target",
         "slack://T1/C2/100.000001/100.000001"},
        {"reaction rejects an earlier context message instead of the exact decision target",
         "slack://T1/C1/100.000001/100.000001"}
      ] do
    @source_ref source_ref
    test name do
      claim =
        put_in(claim("reaction"), [:payload, "communication", "source_refs"], [@source_ref])

      assert {:error, :invalid_product_obligation, false} =
               SlackEffectAdapter.apply(claim,
                 freshness_port: __MODULE__.FreshPort,
                 reaction_port: __MODULE__.ReactionPort,
                 port_opts: [test_pid: SystemsRuntime.Proc.self()]
               )

      refute_receive {:freshness, ^claim}
      refute_receive {:reaction, _claim, _timestamp, _emoji}
    end
  end

  test "freshness accepts only self output after the frozen cutoff" do
    put_freshness_fixture([
      %{"actor_kind" => "app", "actor_id" => "A1", "message_ts" => "101.000001"},
      %{"actor_kind" => "bot", "actor_id" => "B1", "message_ts" => "102.000001"}
    ])

    assert {:ok, %{status: :fresh, authority_ref: authority_ref}} =
             Freshness.check(claim("reply"), freshness_opts())

    assert elem(authority_ref, 0) == "generation-1"

    assert_receive {:clickhouse_thread_request,
                    %{
                      scope: %{
                        "tenant_id" => "tenant-1",
                        "workspace_id" => "T1",
                        "channel_id" => "C1"
                      },
                      root_ts: "100.000001"
                    }}
  end

  test "freshness suppresses a reply after any new human message or incomplete page" do
    put_freshness_fixture([
      %{"actor_kind" => "user", "actor_id" => "U1", "message_ts" => "101.000001"}
    ])

    assert {:ok, %{status: :stale, reason: :new_source_message}} =
             Freshness.check(claim("reply"), freshness_opts())

    put_freshness_fixture([], false)

    assert {:ok, %{status: :stale, reason: :freshness_window_incomplete}} =
             Freshness.check(claim("reply"), freshness_opts())
  end

  for {name, change, reason} <- [
        {"freshness fails stale when the UI-owned channel authority changes",
         :authority_generation, :stale_source},
        {"freshness suppresses communication after the thread is handed to a Task",
         :task_route_owner, :source_route_changed}
      ] do
    @change change
    @reason reason
    test name do
      put_freshness_fixture([])

      case @change do
        :authority_generation ->
          Process.put(
            :product_authority,
            Map.put(product_authority(), "connect_generation", "new")
          )

        :task_route_owner ->
          Process.put(:route_owner, {:ok, :task, String.duplicate("d", 64)})
      end

      assert {:ok, %{status: :stale, reason: @reason}} =
               Freshness.check(claim("reply"), freshness_opts())

      refute_receive {:clickhouse_thread_request, _request}
    end
  end

  defmodule FreshPort do
    def check(claim, opts) do
      SystemsRuntime.Proc.send(Keyword.fetch!(opts, :test_pid), {:freshness, claim})
      {:ok, %{status: :fresh, authority_ref: {"generation-1", "C1"}}}
    end
  end

  defmodule StalePort do
    def check(_claim, _opts), do: {:ok, %{status: :stale, reason: :new_source_message}}
  end

  defmodule EffectGuard do
    def run(_claim, _freshness, _opts, fun), do: fun.()
  end

  defmodule ReplyPort do
    def lookup(claim, opts) do
      SystemsRuntime.Proc.send(Keyword.fetch!(opts, :test_pid), {:lookup_reply, claim})

      if Process.get(:reply_already_delivered) do
        {:ok,
         {:delivered,
          %{
            operation_ref: claim.obligation_id,
            channel_id: "C1",
            message_ts: "101.000001",
            already_delivered: true,
            external_writes: 0
          }}}
      else
        {:ok, :not_delivered}
      end
    end

    def prepare(claim, opts) do
      SystemsRuntime.Proc.send(Keyword.fetch!(opts, :test_pid), {:prepare_reply, claim})
      {:ok, %{operation_ref: claim.obligation_id}}
    end

    def deliver(claim, prepared, opts) do
      SystemsRuntime.Proc.send(Keyword.fetch!(opts, :test_pid), {:deliver_reply, claim, prepared})

      {:ok, {:confirmed, prepared.operation_ref}}
    end

    def complete(_claim, _prepared, {:confirmed, operation_ref}, _opts) do
      {:ok,
       %{
         operation_ref: operation_ref,
         channel_id: "C1",
         message_ts: "101.000001",
         already_delivered: false,
         external_writes: 1
       }}
    end
  end

  defmodule ConversationMustNotRun do
    def prepare(_claim, opts) do
      SystemsRuntime.Proc.send(Keyword.fetch!(opts, :test_pid), {:conversation_called, :prepare})
      {:error, :conversation_called, false}
    end

    def append(_claim, _prepared, opts) do
      SystemsRuntime.Proc.send(Keyword.fetch!(opts, :test_pid), {:conversation_called, :append})
      {:error, :conversation_called, false}
    end
  end

  defmodule ReactionPort do
    def lookup(_, _, _, _), do: Process.get(:reaction_lookup, {:ok, :missing})

    def add(claim, timestamp, emoji, opts) do
      SystemsRuntime.Proc.send(
        Keyword.fetch!(opts, :test_pid),
        {:reaction, claim, timestamp, emoji}
      )

      {:ok, %{already_reacted: false}}
    end
  end

  defmodule ProviderApiPort do
    def call_api(agent_id, platform, api, args, provider_opts) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.Proc.self(),
        {:provider_api, agent_id, platform, api, args, provider_opts}
      )

      Process.get(:reaction_result)
    end
  end

  defmodule SpeakerLabelPort do
    def resolve(payload, opts) do
      SystemsRuntime.Proc.send(Keyword.fetch!(opts, :test_pid), {:speaker_labels, payload})
      ["Peng Xiao"]
    end
  end

  defmodule GroupPort do
    def get_group("group-1"), do: {:ok, %{"tenant_id" => "tenant-1"}}
  end

  defmodule ProviderPort do
    def get_slack_triage_authority(_tenant_id, _group_id, _connect_id, _channel_id),
      do: {:ok, Process.get(:product_authority)}
  end

  defmodule ClickHousePort do
    def read_thread(scope, root_ts, opts) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.Proc.self(),
        {:clickhouse_thread_request, %{scope: scope, root_ts: root_ts, opts: opts}}
      )

      {:ok, Process.get(:clickhouse_thread_page)}
    end

    def read_channel(scope, window, opts) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.Proc.self(),
        {:clickhouse_channel_request, %{scope: scope, window: window, opts: opts}}
      )

      {:ok, Process.get(:clickhouse_thread_page)}
    end
  end

  defmodule ReplyProviderPort do
    def get_active_connect_by_id("group-1", "connect-1", "slack") do
      {:ok,
       %{
         "tenant_id" => "tenant-1",
         "group_id" => "group-1",
         "provider" => "slack",
         "connect_id" => "connect-1",
         "workspace_id" => "T1"
       }}
    end

    def get_slack_triage_authority("tenant-1", "group-1", "connect-1", "C1") do
      {:ok,
       %{
         "triage_enabled" => true,
         "connect_id" => "connect-1",
         "connect_generation" => "generation-1",
         "workspace_id" => "T1",
         "approved_channel_id" => "C1",
         "inbound_agent_id" => "agent-1"
       }}
    end
  end

  defmodule ReplyDeliveryPort do
    def find_message(_tenant_id, _connect, _channel_id, _thread_ts, _operation_ref),
      do: {:ok, nil}

    def post_message(_tenant_id, _connect, params) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.Proc.self(),
        {:post_reply, params["channel"], params["thread_ts"]}
      )

      {:ok,
       Process.get(:reply_provider_status, %{
         "channel" => params["channel"],
         "ts" => "101.000001"
       })}
    end
  end

  defmodule InvalidSubscriptionPort do
    def after_reply(claim, {:ok, status}, _opts) do
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:invalid_subscription, claim, status})
      {:unknown, %{"status" => "triage_subscription_contract_invalid"}, :invalid_subscription}
    end
  end

  defmodule EmptySpeakerLabelPort do
    def resolve(_payload, _opts), do: []
  end

  defmodule RouteOwnerPort do
    def lookup_claim(_scope),
      do: Process.get(:route_owner, {:ok, :triage, String.duplicate("c", 64)})
  end

  defp freshness_opts do
    [
      group_directory: __MODULE__.GroupPort,
      provider_connects: __MODULE__.ProviderPort,
      route_owner: __MODULE__.RouteOwnerPort,
      clickhouse_reader: __MODULE__.ClickHousePort
    ]
  end

  defp put_freshness_fixture(messages, complete? \\ true) do
    Process.put(:product_authority, product_authority())

    current =
      Enum.map(messages, fn message ->
        {:ok, message_ts_us} =
          SalixIM.SlackMessageMirror.Row.slack_ts_micros(message["message_ts"])

        message
        |> Map.put_new("message_ts_us", message_ts_us)
        |> Map.put_new("version", message_ts_us * 2)
      end)

    Process.put(:clickhouse_thread_page, %{
      messages: [root_row() | current],
      reactions: [],
      complete?: complete?
    })
  end

  defp root_row do
    %{
      "actor_kind" => "user",
      "actor_id" => "U_SOURCE",
      "message_ts" => "100.000001",
      "message_ts_us" => 100_000_001,
      "version" => 200_000_002
    }
  end

  defp product_authority do
    %{
      "triage_enabled" => true,
      "connect_id" => "connect-1",
      "connect_generation" => "generation-1",
      "workspace_id" => "T1",
      "approved_channel_id" => "C1",
      "app_id" => "A1",
      "bot_id" => "B1",
      "bot_user_id" => "BU1"
    }
  end

  defp claim(kind) do
    communication =
      case kind do
        "reply" ->
          %{
            "kind" => "reply",
            "text" => "Please confirm the owner.",
            "source_refs" => ["slack://T1/C1/100.000001"]
          }

        "reaction" ->
          %{
            "kind" => "reaction",
            "emoji" => "tada",
            "source_refs" => ["slack://T1/C1/100.000001/101.000001"]
          }

        "silence" ->
          %{"kind" => "silence", "reason" => "already_answered", "source_refs" => []}
      end

    %{
      obligation_id: "triage-product-" <> String.duplicate("b", 64),
      claim_token: "triage-product-claim-test",
      payload: %{
        "run_id" => "run-1",
        "communication" => communication,
        "source_messages" => [
          %{
            "actor_id" => "U_SOURCE",
            "actor_kind" => "human",
            "message_ts" => "100.000001",
            "message_ts_us" => 100_000_001,
            "observed_version" => 200_000_002,
            "excerpt" => "Please help"
          }
        ],
        "target_cutoff" => %{
          "event_message_timestamps" =>
            if(kind == "reaction", do: ["100.000001", "101.000001"], else: ["100.000001"])
        },
        "target" => %{
          "connect_id" => "connect-1",
          "connect_generation" => "generation-1",
          "workspace_id" => "T1",
          "channel_id" => "C1",
          "thread_ts" => "100.000001"
        },
        "product_identity" => %{
          "project_salix_group_id" => "group-1",
          "salix_agent_id" => "agent-1"
        }
      }
    }
  end
end
