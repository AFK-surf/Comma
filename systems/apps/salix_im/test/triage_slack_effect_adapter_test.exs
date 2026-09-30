defmodule SalixIM.Triage.SlackEffectAdapterTest do
  use ExUnit.Case, async: true

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
               port_opts: [test_pid: self()]
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
               port_opts: [test_pid: self()]
             )

    assert_receive {:lookup_reply, ^claim}
    refute_receive {:freshness, _claim}
    refute_receive {:prepare_reply, _claim}
    refute_receive {:deliver_reply, _claim, _prepared}
    refute_receive {:conversation_called, _operation}
  end

  test "a provider-confirmed reply stays delivered when continuation admission is invalid" do
    claim = claim("reply")

    assert {:ok,
            %{
              outcome: :applied,
              external_writes: 1,
              communication: %{"kind" => "reply", "status" => "delivered"},
              metadata: %{
                "continuation_admission" => %{
                  "status" => "not_activated",
                  "reason" => "invalid_subscription"
                },
                "message_ts" => "101.000001"
              }
            }} =
             SlackEffectAdapter.apply(claim,
               freshness_port: __MODULE__.FreshPort,
               reply_port: Reply,
               effect_guard: __MODULE__.EffectGuard,
               port_opts: [
                 test_pid: self(),
                 group_directory: __MODULE__.GroupPort,
                 provider_connects: __MODULE__.ReplyProviderPort,
                 reply_delivery_port: __MODULE__.ReplyDeliveryPort,
                 triage_thread_subscription_port: __MODULE__.InvalidSubscriptionPort
               ],
               speaker_label_resolver: __MODULE__.EmptySpeakerLabelPort
             )

    assert_receive {:post_reply, "C1", "100.000001"}
    assert_receive {:invalid_subscription, ^claim, %{"channel" => "C1", "ts" => "101.000001"}}
  end

  test "an invalid continuation admission cannot settle a missing or wrong-channel confirmation" do
    claim = claim("reply")

    for status <- [%{"ts" => "101.000001"}, %{"channel" => "C_WRONG", "ts" => "101.000001"}] do
      Process.put(:reply_provider_status, status)

      assert {:error, :invalid_provider_confirmation, false, 1} =
               SlackEffectAdapter.apply(claim,
                 freshness_port: __MODULE__.FreshPort,
                 reply_port: Reply,
                 effect_guard: __MODULE__.EffectGuard,
                 port_opts: [
                   test_pid: self(),
                   group_directory: __MODULE__.GroupPort,
                   provider_connects: __MODULE__.ReplyProviderPort,
                   reply_delivery_port: __MODULE__.ReplyDeliveryPort,
                   triage_thread_subscription_port: __MODULE__.InvalidSubscriptionPort
                 ],
                 speaker_label_resolver: __MODULE__.EmptySpeakerLabelPort
               )

      assert_receive {:post_reply, "C1", "100.000001"}
      assert_receive {:invalid_subscription, ^claim, ^status}
    end
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
               port_opts: [test_pid: self()]
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
               port_opts: [test_pid: self()]
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
               port_opts: [test_pid: self()]
             )

    assert_receive {:freshness, ^claim}
    assert_receive {:reaction, ^claim, "101.000001", "tada"}
  end

  test "a catalog-backed custom reaction reaches the exact Slack target and unknown emoji fails closed" do
    {:ok, expression_context} =
      ExpressionContext.build("social", {:ok, %{"party_parrot" => "provider-owned-url"}})

    claim =
      claim("reaction")
      |> put_in([:payload, "communication", "emoji"], "party_parrot")
      |> put_in([:payload, "reaction_authority"], expression_context)

    assert {:ok, %{communication: %{"emoji" => "party_parrot", "status" => "added"}}} =
             SlackEffectAdapter.apply(claim,
               freshness_port: __MODULE__.FreshPort,
               reaction_port: __MODULE__.ReactionPort,
               effect_guard: __MODULE__.EffectGuard,
               port_opts: [test_pid: self()]
             )

    assert_receive {:freshness, ^claim}
    assert_receive {:reaction, ^claim, "101.000001", "party_parrot"}

    invalid = put_in(claim, [:payload, "communication", "emoji"], "invented_custom")

    assert {:error, :invalid_product_obligation, false} =
             SlackEffectAdapter.apply(invalid,
               freshness_port: __MODULE__.FreshPort,
               reaction_port: __MODULE__.ReactionPort,
               port_opts: [test_pid: self()]
             )

    refute_receive {:freshness, ^invalid}
    refute_receive {:reaction, ^invalid, _timestamp, _emoji}
  end

  test "an accepted reaction survives source changes after an interrupted delivery" do
    Process.put(:reaction_lookup, {:ok, :present})

    assert {:ok, %{outcome: :applied, external_writes: 0}} =
             SlackEffectAdapter.apply(claim("reaction"),
               freshness_port: __MODULE__.StalePort,
               reaction_port: __MODULE__.ReactionPort,
               port_opts: [test_pid: self()]
             )

    refute_receive {:reaction, _, _, _}
  end

  test "an unknown reaction lookup does not become a new send or a stale retry" do
    Process.put(:reaction_lookup, {:error, :reaction_verification_unavailable, true})

    assert {:error, :reaction_verification_unavailable, true} =
             SlackEffectAdapter.apply(claim("reaction"),
               freshness_port: __MODULE__.StalePort,
               reaction_port: __MODULE__.ReactionPort,
               port_opts: [test_pid: self()]
             )

    refute_receive {:reaction, _, _, _}
  end

  test "reaction is suppressed when its source changed before the write" do
    claim = claim("reaction")

    assert {:ok,
            %{
              outcome: :stale,
              external_writes: 0,
              communication: %{
                "kind" => "reaction",
                "status" => "suppressed_stale"
              }
            }} =
             SlackEffectAdapter.apply(claim,
               freshness_port: __MODULE__.StalePort,
               reaction_port: __MODULE__.ReactionPort,
               port_opts: [test_pid: self()]
             )

    refute_receive {:reaction, _claim, _timestamp, _emoji}
  end

  test "reaction fails closed when the cited source is outside the exact Slack target" do
    claim =
      put_in(
        claim("reaction"),
        [:payload, "communication", "source_refs"],
        ["slack://T1/C2/100.000001/100.000001"]
      )

    assert {:error, :invalid_product_obligation, false} =
             SlackEffectAdapter.apply(claim,
               freshness_port: __MODULE__.FreshPort,
               reaction_port: __MODULE__.ReactionPort,
               port_opts: [test_pid: self()]
             )

    refute_receive {:freshness, ^claim}
    refute_receive {:reaction, _claim, _timestamp, _emoji}
  end

  test "reaction rejects an earlier context message instead of the exact decision target" do
    claim =
      put_in(
        claim("reaction"),
        [:payload, "communication", "source_refs"],
        ["slack://T1/C1/100.000001/100.000001"]
      )

    assert {:error, :invalid_product_obligation, false} =
             SlackEffectAdapter.apply(claim,
               freshness_port: __MODULE__.FreshPort,
               reaction_port: __MODULE__.ReactionPort,
               port_opts: [test_pid: self()]
             )

    refute_receive {:freshness, ^claim}
    refute_receive {:reaction, _claim, _timestamp, _emoji}
  end

  test "production reaction port binds the obligation identity and does not hot-loop a rate limit" do
    claim = claim("reaction")
    Process.put(:reaction_result, {:ok, %{}})

    assert {:ok, %{already_reacted: false}} =
             Reaction.add(claim, "101.000001", "tada", provider: __MODULE__.ProviderApiPort)

    assert_receive {:provider_api, "agent-1", "slack", "slack.add_reaction", args, provider_opts}
    assert provider_opts == [request_options: [timeout_ms: 4_000, pool_retries: 0]]
    assert args["tool_call_id"] == claim.obligation_id
    assert args["connect_id"] == "connect-1"

    assert args["params"] == %{
             "channel" => "C1",
             "ts" => "101.000001",
             "name" => "tada"
           }

    Process.put(:reaction_result, {:error, "Slack API error: rate_limited; retry_after=7"})

    assert {:error, :rate_limited, false} =
             Reaction.add(claim, "101.000001", "tada", provider: __MODULE__.ProviderApiPort)

    Process.put(:reaction_result, {:error, :rate_limited})

    assert {:error, :rate_limited, false} =
             Reaction.add(claim, "101.000001", "tada", provider: __MODULE__.ProviderApiPort)
  end

  test "speaker names enrich presentation metadata without changing silence settlement" do
    claim =
      put_in(claim("silence"), [:payload, "source_messages"], [
        %{"actor_id" => "U12345678", "actor_kind" => "human"}
      ])

    payload = claim.payload

    assert {:ok,
            %{
              outcome: :applied,
              external_writes: 0,
              metadata: %{"source_speaker_labels" => ["Peng Xiao"]}
            }} =
             SlackEffectAdapter.apply(claim,
               speaker_label_resolver: __MODULE__.SpeakerLabelPort,
               speaker_label_opts: [test_pid: self()]
             )

    assert_receive {:speaker_labels, ^payload}
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

  test "freshness recognizes the stable bot-user principal emitted by Slack mirror normalization" do
    connect = %{"tenant_id" => "tenant-1", "workspace_id" => "T1"}

    for attribution <- [
          %{"bot_id" => "B1", "app_id" => "A1", "user" => "BU1"},
          %{"app_id" => "A1", "user" => "BU1"}
        ] do
      event =
        Map.merge(attribution, %{
          "type" => "message",
          "channel" => "C1",
          "ts" => "101.000001",
          "thread_ts" => "100.000001",
          "text" => "A supported answer before the investigation."
        })

      assert {:ok, row} = SalixIM.SlackMessageMirror.Row.from_event(connect, %{"event" => event})
      assert row["actor_id"] == "BU1"
      put_freshness_fixture([row])

      assert {:ok, %{status: :fresh}} = Freshness.check(claim("reply"), freshness_opts())
    end
  end

  test "another bot or an absent principal still makes the frozen source stale" do
    for {kind, actor} <- [
          {"bot", "B_OTHER"},
          {"bot", "U_OTHER"},
          {"app", "U_OTHER"},
          {"bot", ""},
          {"app", nil},
          {"user", nil}
        ] do
      put_freshness_fixture([
        %{"actor_kind" => kind, "actor_id" => actor, "message_ts" => "101.000001"}
      ])

      if is_nil(actor) or actor == "" do
        Process.put(
          :product_authority,
          Map.drop(product_authority(), ~w(bot_id bot_user_id app_id))
        )
      end

      assert {:ok, %{status: :stale, reason: :new_source_message}} =
               Freshness.check(claim("reply"), freshness_opts())
    end
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

  test "ordinary intake admits added channel messages but keeps source and authority checks" do
    current = claim("silence")

    payload =
      current.payload
      |> Map.put("communication", SalixIM.Triage.WorkerSelection.pending_communication())
      |> Map.put("context_candidates", [])
      |> Map.put("ordinary_worker_assignment", true)
      |> Map.put("delegations", [%{"worker_ref" => "comma-agent://worker"}])
      |> Map.put("source_window", %{
        "oldest_ts_us" => 100_000_001,
        "latest_ts_us" => 100_000_001,
        "thread_roots" => ["100.000001"]
      })

    current = %{current | payload: payload}
    opts = Keyword.put(freshness_opts(), :purpose, :worker_intake)

    put_freshness_fixture([
      %{
        "actor_kind" => "user",
        "actor_id" => "U_OTHER",
        "message_ts" => "101.000001",
        "thread_ts" => "99.000001"
      }
    ])

    assert {:ok, %{status: :fresh}} = Freshness.check(current, opts)

    assert {:ok, %{status: :stale, reason: :new_source_message}} =
             Freshness.check(current, freshness_opts())

    assert {:ok, %{status: :stale, reason: :new_source_message}} =
             Freshness.check(
               %{current | payload: Map.delete(payload, "ordinary_worker_assignment")},
               opts
             )

    put_freshness_fixture([], false)

    assert {:ok, %{status: :stale, reason: :freshness_window_incomplete}} =
             Freshness.check(current, opts)

    put_freshness_fixture([])
    page = Process.get(:clickhouse_thread_page)

    Process.put(:clickhouse_thread_page, %{
      page
      | messages: [Map.put(root_row(), "version", 200_000_004)]
    })

    assert {:ok, %{status: :stale, reason: :source_state_changed}} =
             Freshness.check(current, opts)

    Process.put(:clickhouse_thread_page, %{page | messages: []})

    assert {:ok, %{status: :stale, reason: :source_state_changed}} =
             Freshness.check(current, opts)

    put_freshness_fixture([])
    Process.put(:product_authority, Map.put(product_authority(), "connect_generation", "new"))
    assert {:ok, %{status: :stale, reason: :stale_source}} = Freshness.check(current, opts)
  end

  test "a prepared recheck recognizes all frozen messages and rejects later changes" do
    collaborators =
      for second <- 101..103 do
        %{
          "actor_kind" => "bot",
          "actor_id" => "U_COLLABORATOR",
          "message_ts" => "#{second}.000001"
        }
      end

    put_freshness_fixture(collaborators)
    current = claim("reply")

    messages =
      Enum.map(Process.get(:clickhouse_thread_page).messages, fn message ->
        %{
          "actor_id" => message["actor_id"],
          "actor_kind" => "human",
          "message_ts" => message["message_ts"],
          "message_ts_us" => message["message_ts_us"],
          "observed_version" => message["version"],
          "source_ref" => "slack://T1/C1/100.000001/" <> message["message_ts"],
          "text" => "Evidence already included in the frozen model input"
        }
      end)

    aliases =
      messages
      |> Enum.with_index(1)
      |> Map.new(fn {message, index} ->
        {message["source_ref"], "source://run/s00#{index}"}
      end)

    authorization = %SalixIM.Triage.RunFence.AuthorizedProductEffects{
      run_id: "run-recheck",
      fence: %{
        "terminal" => %{
          "status" => "evaluated",
          "settled_at" => 1_787_900_000_000,
          "decision" => %{
            "schema" => "comma.triage-product-decision.v1",
            "communication" => %{
              "kind" => "reply",
              "text" => "The investigation has new evidence.",
              "source_refs" => ["source://run/s001", "source://run/s004"]
            },
            "context_candidates" => [],
            "delegations" => [],
            "identity_interpretation" => %{"topic" => "none", "referenced_principal_refs" => []}
          }
        }
      },
      raw_bundle: %{
        "source_authority" => current.payload["target"],
        "product_identity" =>
          Map.merge(current.payload["product_identity"], %{
            "project_id" => "project-1",
            "agent_id" => "agent-1"
          }),
        "target_cutoff" => current.payload["target_cutoff"],
        "sealed_events" => [
          %{"source_mode" => "scheduled_recheck", "event_id" => "recheck:investigation"}
        ],
        "raw_context" => %{
          "slack_context" => %{
            "messages" => messages,
            "source_refs" => Enum.map(messages, & &1["source_ref"])
          }
        }
      },
      alias_map: %{"sources" => aliases}
    }

    assert {:ok, payload} =
             SalixIM.Triage.ProductObligation.prepare("triage-test", "fence.json", authorization)

    assert SalixIM.Triage.ProductObligation.valid?(payload)
    # The uncited 101 reply is also outside the three-message display summary.
    refute Enum.any?(payload["source_messages"], &(&1["message_ts"] == "101.000001"))
    current = %{current | payload: payload}
    assert {:ok, %{status: :fresh}} = Freshness.check(current, freshness_opts())

    for timestamp <- ["100.500001", "104.000001"] do
      new_message = Map.put(hd(collaborators), "message_ts", timestamp)
      put_freshness_fixture(collaborators ++ [new_message])

      assert {:ok, %{status: :stale, reason: :new_source_message}} =
               Freshness.check(current, freshness_opts())
    end

    put_freshness_fixture([
      Map.put(hd(collaborators), "version", 202_000_004) | tl(collaborators)
    ])

    assert {:ok, %{status: :stale, reason: :source_state_changed}} =
             Freshness.check(current, freshness_opts())

    put_freshness_fixture(tl(collaborators))

    assert {:ok, %{status: :stale, reason: :source_state_changed}} =
             Freshness.check(current, freshness_opts())

    put_freshness_fixture(collaborators)

    unversioned =
      update_in(current, [:payload, "source_authority"], fn sources ->
        Enum.map(sources, &Map.delete(&1, "observed_version"))
      end)

    assert {:ok, %{status: :stale, reason: :new_source_message}} =
             Freshness.check(unversioned, freshness_opts())
  end

  test "freshness fails stale when the UI-owned channel authority changes" do
    put_freshness_fixture([])
    Process.put(:product_authority, Map.put(product_authority(), "connect_generation", "new"))

    assert {:ok, %{status: :stale, reason: :stale_source}} =
             Freshness.check(claim("reply"), freshness_opts())

    refute_receive {:clickhouse_thread_request, _request}
  end

  test "freshness suppresses communication after the thread is handed to a Task" do
    put_freshness_fixture([])
    Process.put(:route_owner, {:ok, :task, String.duplicate("d", 64)})

    assert {:ok, %{status: :stale, reason: :source_route_changed}} =
             Freshness.check(claim("reply"), freshness_opts())

    refute_receive {:clickhouse_thread_request, _request}
  end

  test "freshness suppresses communication after the frozen source is edited or deleted" do
    put_freshness_fixture([])

    Process.put(:clickhouse_thread_page, %{
      Process.get(:clickhouse_thread_page)
      | messages: [Map.put(root_row(), "version", 200_000_004)]
    })

    assert {:ok, %{status: :stale, reason: :source_state_changed}} =
             Freshness.check(claim("reply"), freshness_opts())

    put_freshness_fixture([])
    Process.put(:clickhouse_thread_page, %{messages: [], reactions: [], complete?: true})

    assert {:ok, %{status: :stale, reason: :source_state_changed}} =
             Freshness.check(claim("reply"), freshness_opts())
  end

  test "channel freshness checks sibling sources and new activity without one read per thread" do
    sibling = %{"actor_kind" => "user", "actor_id" => "U_OTHER", "message_ts" => "99.000001"}
    put_freshness_fixture([sibling])
    current = claim("reply")

    payload =
      current.payload
      |> Map.put("source_window", %{
        "oldest_ts_us" => 99_000_001,
        "latest_ts_us" => 100_000_001,
        "thread_roots" => ["100.000001", "99.000001"]
      })
      |> Map.put("source_authority", [
        %{"message_ts_us" => 99_000_001, "observed_version" => 198_000_002},
        %{"message_ts_us" => 100_000_001, "observed_version" => 200_000_002}
      ])

    current = %{current | payload: payload}

    assert {:ok, %{status: :fresh}} = Freshness.check(current, freshness_opts())

    assert_receive {:clickhouse_channel_request,
                    %{window: window, opts: [limit: 200, max_bytes: 1_048_576]}}

    assert window["thread_roots"] == payload["source_window"]["thread_roots"]
    refute_receive {:clickhouse_thread_request, _request}

    put_freshness_fixture([Map.put(sibling, "version", 198_000_004)])

    assert {:ok, %{status: :stale, reason: :source_state_changed}} =
             Freshness.check(current, freshness_opts())

    put_freshness_fixture([])

    assert {:ok, %{status: :stale, reason: :source_state_changed}} =
             Freshness.check(current, freshness_opts())

    put_freshness_fixture([sibling, Map.put(sibling, "message_ts", "101.000001")])

    assert {:ok, %{status: :stale, reason: :new_source_message}} =
             Freshness.check(current, freshness_opts())
  end

  test "freshness fails closed when no ClickHouse thread reader is configured" do
    put_freshness_fixture([])

    assert {:error, :invalid_product_authority, false} =
             Freshness.check(
               claim("reply"),
               Keyword.put(freshness_opts(), :clickhouse_reader, nil)
             )

    refute_receive {:clickhouse_thread_request, _request}
  end

  defmodule FreshPort do
    def check(claim, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:freshness, claim})
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
      send(Keyword.fetch!(opts, :test_pid), {:lookup_reply, claim})

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
      send(Keyword.fetch!(opts, :test_pid), {:prepare_reply, claim})
      {:ok, %{operation_ref: claim.obligation_id}}
    end

    def deliver(claim, prepared, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:deliver_reply, claim, prepared})

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
      send(Keyword.fetch!(opts, :test_pid), {:conversation_called, :prepare})
      {:error, :conversation_called, false}
    end

    def append(_claim, _prepared, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:conversation_called, :append})
      {:error, :conversation_called, false}
    end
  end

  defmodule ReactionPort do
    def lookup(_, _, _, _), do: Process.get(:reaction_lookup, {:ok, :missing})

    def add(claim, timestamp, emoji, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:reaction, claim, timestamp, emoji})
      {:ok, %{already_reacted: false}}
    end
  end

  defmodule ProviderApiPort do
    def call_api(agent_id, platform, api, args, provider_opts) do
      send(self(), {:provider_api, agent_id, platform, api, args, provider_opts})
      Process.get(:reaction_result)
    end
  end

  defmodule SpeakerLabelPort do
    def resolve(payload, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:speaker_labels, payload})
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
      send(self(), {:clickhouse_thread_request, %{scope: scope, root_ts: root_ts, opts: opts}})
      {:ok, Process.get(:clickhouse_thread_page)}
    end

    def read_channel(scope, window, opts) do
      send(self(), {:clickhouse_channel_request, %{scope: scope, window: window, opts: opts}})
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
      send(self(), {:post_reply, params["channel"], params["thread_ts"]})

      {:ok,
       Process.get(:reply_provider_status, %{
         "channel" => params["channel"],
         "ts" => "101.000001"
       })}
    end
  end

  defmodule InvalidSubscriptionPort do
    def after_reply(claim, {:ok, status}, _opts) do
      send(self(), {:invalid_subscription, claim, status})
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
