defmodule Salix.Bindings.TriageNativeIdentityTest do
  require SystemsRuntime.Proc

  @moduledoc """
  Identity-mode contract for `Salix.Bindings.TriageEvaluator`: prompt/policy
  bytes, the strict json_schema response format, proof v1/v2/v3 construction, and
  the single authorized read-tool exchange.

  Not ported: the source branch's four `@tag :ingress` cases. They drove
  `Salix.Bindings.TriageReviewIngress`/`TriageHistoricalReplay`, which recorded
  the typed receipt themselves. Main's ingress is
  `SalixIM.Provider.Slack` -> `Salix.Bindings.TriageReceiptConsumer`, and its
  equivalent duplicate/drift/provenance coverage lives in
  `triage_receipt_consumer_test.exs`.
  """

  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixAgent.ToolDisclosure
  alias SalixIM.Triage.{IdentityContract, Pipeline}

  # Only this negative-case provider is scripted: HTTP Slack messages do not
  # carry our mirror's `stale` annotation. Keep the actual Provider/HTTP path
  # in the other permalink cases, and model the mirror seam truthfully here.
  defmodule StaleMirrorProvider do
    defdelegate list_connects(agent_id), to: SalixIM.Provider
    defdelegate provider_manual(platform), to: SalixIM.Provider

    def call_api(_agent, "slack", "slack.get_channel_history", _args) do
      {:ok,
       %{"messages" => [%{"ts" => "1787019000.000001", "text" => "outdated", "stale" => true}]}}
    end
  end

  defmodule SlackPermalinkPlug do
    @behaviour Plug
    import Plug.Conn

    def init({owner, options}), do: %{owner: owner, options: options}

    def call(conn, %{owner: owner, options: options}) do
      {:ok, body, conn} = read_body(conn)
      conn = fetch_query_params(conn)
      method = List.last(conn.path_info)
      params = Map.merge(conn.query_params, URI.decode_query(body))
      SystemsRuntime.Proc.send(owner, {:slack_permalink_request, method, params})

      body =
        case method do
          "auth.test" ->
            if after_auth = options[:after_auth], do: after_auth.()

            Keyword.get(options, :identity, %{
              "ok" => true,
              "team_id" => "T_ATLAS",
              "url" => "https://atlas.slack.com/"
            })

          method when method in ["conversations.history", "conversations.replies"] ->
            %{
              "ok" => true,
              "messages" =>
                Keyword.get(options, :messages, [
                  %{
                    "ts" => "1787019000.000001",
                    "user" => "U024BE7LH",
                    "text" => "The launch is approved for Tuesday after the owner check."
                  }
                ]),
              "has_more" => false
            }

          _other ->
            %{"ok" => false, "error" => "unexpected_test_request"}
        end

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))
    end
  end

  defmodule ReadPagePlug do
    @behaviour Plug
    import Plug.Conn

    @impl true
    def init(owner), do: owner

    @impl true
    def call(%{method: "POST", request_path: "/contents"} = conn, owner) do
      {:ok, body, conn} = read_body(conn)
      request = Jason.decode!(body)

      SystemsRuntime.Proc.send(
        owner,
        {:read_pages_request, request, get_req_header(conn, "x-api-key")}
      )

      response = %{
        "requestId" => "triage-read-1",
        "results" => [
          %{
            "title" => "Bounded launch brief",
            "url" => "https://example.test/launch-brief",
            "text" => "The launch is approved for Tuesday after the owner check."
          }
        ]
      }

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(response))
    end

    def call(conn, _owner), do: send_resp(conn, 404, "not found")
  end

  defmodule EmptyReadPagePlug do
    @behaviour Plug
    import Plug.Conn

    @impl true
    def init(owner), do: owner

    @impl true
    def call(%{method: "POST", request_path: "/contents"} = conn, owner) do
      {:ok, _body, conn} = read_body(conn)
      SystemsRuntime.Proc.send(owner, :empty_read_pages_request)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"requestId" => "triage-read-empty-1", "results" => []}))
    end

    def call(conn, _owner), do: send_resp(conn, 404, "not found")
  end

  defmodule ChatCompletionsToolPlug do
    @behaviour Plug
    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%{method: "POST", request_path: "/chat/completions"} = conn, opts) do
      {:ok, body, conn} = read_body(conn)
      request = Jason.decode!(body)
      SystemsRuntime.Proc.send(opts.owner, {:chat_tool_request, request})
      step = Agent.get_and_update(opts.script, &{&1, &1 + 1})

      message =
        if match?([_tool | _rest], request["tools"]) do
          %{
            "role" => "assistant",
            "content" => "",
            "tool_calls" => [
              %{
                "id" => "triage-read-call-1",
                "type" => "function",
                "function" => %{
                  "name" => "call",
                  "arguments" =>
                    Jason.encode!(%{
                      "tool" => "web.read_pages",
                      "params" => %{"urls" => ["link://run/l001"]}
                    })
                }
              }
            ]
          }
        else
          decision =
            if step == 1,
              do: %{
                "communication" => "silence",
                "investigate" => false,
                "reason" => "The unrequested share has no readable contribution."
              },
              else: opts.decision

          %{"role" => "assistant", "content" => Jason.encode!(decision)}
        end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"choices" => [%{"message" => message}]}))
    end

    def call(conn, _opts), do: send_resp(conn, 404, "not found")
  end

  # A fetched page carrying everything the projected-text gate exists to remove:
  # an address, a UUID, a filesystem path, a Slack id, a Slack mention, and a
  # SECOND URL that is not the authorized target.
  defmodule LeakyReadPagePlug do
    @behaviour Plug
    import Plug.Conn

    @impl true
    def init(owner), do: owner

    @impl true
    def call(%{method: "POST", request_path: "/contents"} = conn, owner) do
      {:ok, body, conn} = read_body(conn)

      SystemsRuntime.Proc.send(
        owner,
        {:read_pages_request, Jason.decode!(body), get_req_header(conn, "x-api-key")}
      )

      response = %{
        "requestId" => "triage-read-leaky-1",
        "results" => [
          %{
            "title" => "Bounded launch brief",
            "url" => "https://example.test/launch-brief",
            "text" =>
              "Owner ops@example.test (U024BE7LH, <@U0123ABCD>) filed " <>
                "123e4567-e89b-12d3-a456-426614174000 under /var/secrets/launch. " <>
                "Mirror at https://mirror.example.test/launch-brief/full."
          }
        ]
      }

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(response))
    end

    def call(conn, _owner), do: send_resp(conn, 404, "not found")
  end

  defmodule FailingReadPagePlug do
    @behaviour Plug
    import Plug.Conn

    @impl true
    def init(owner), do: owner

    @impl true
    def call(%{method: "POST", request_path: "/contents"} = conn, owner) do
      {:ok, _body, conn} = read_body(conn)
      SystemsRuntime.Proc.send(owner, :failing_read_pages_request)
      send_resp(conn, 503, "temporarily unavailable")
    end

    def call(conn, _owner), do: send_resp(conn, 404, "not found")
  end

  defmodule SlowReadPagePlug do
    @behaviour Plug
    import Plug.Conn

    @impl true
    def init(owner), do: owner

    @impl true
    def call(%{method: "POST", request_path: "/contents"} = conn, owner) do
      {:ok, _body, conn} = read_body(conn)
      SystemsRuntime.Proc.send(owner, :slow_read_pages_request)
      SystemsClock.sleep(150)
      send_resp(conn, 200, Jason.encode!(%{"results" => []}))
    end

    def call(conn, _owner), do: send_resp(conn, 404, "not found")
  end

  # Asks for a link this run was never authorized to read: the injection signal.
  defmodule ForeignTargetProvider do
    def complete(messages, tools, opts) do
      payload_bytes =
        Jason.encode!(%{"messages" => messages, "model" => opts["model"], "tools" => tools})

      :ok = opts[:before_send].(payload_bytes)

      {:assistant, "",
       [
         %{
           id: "triage-read-call-foreign",
           name: "call",
           args: %{
             "tool" => "web.read_pages",
             "params" => %{"urls" => ["link://run/l999"]}
           }
         }
       ]}
    end
  end

  defmodule ToolCallingProvider do
    def complete(messages, tools, opts) do
      step = Agent.get_and_update(opts["script"], &{&1, &1 + 1})

      payload_bytes =
        Jason.encode!(%{"messages" => messages, "model" => opts["model"], "tools" => tools})

      :ok = opts[:before_send].(payload_bytes)
      SystemsRuntime.Proc.send(opts["test_pid"], {:triage_tool_round, step, messages, tools})

      case step do
        0 ->
          {:assistant, "",
           [
             %{
               id: "triage-read-call-1",
               name: "call",
               args: %{
                 "tool" => opts["read_tool"] || "web.read_pages",
                 "params" => opts["read_params"] || %{"urls" => ["link://run/l001"]}
               }
             }
           ]}

        1 ->
          {:final, Jason.encode!(opts["decision"])}
      end
    end
  end

  defmodule DirectHistoryToolProvider do
    def complete(messages, tools, opts) do
      step = Agent.get_and_update(opts["script"], &{&1, &1 + 1})

      payload_bytes =
        Jason.encode!(%{"messages" => messages, "model" => opts["model"], "tools" => tools})

      :ok = opts[:before_send].(payload_bytes)

      case step do
        0 ->
          {:assistant, "",
           [
             %{
               id: "triage-history-call-1",
               name: "triage_run.get",
               args: %{"run_ref" => "triage-run://current/r001"}
             }
           ]}

        1 ->
          {:final, Jason.encode!(opts["decision"])}
      end
    end
  end

  defmodule RequestedToolProvider do
    def complete(messages, tools, opts) do
      payload_bytes =
        Jason.encode!(%{"messages" => messages, "model" => opts["model"], "tools" => tools})

      :ok = opts[:before_send].(payload_bytes)
      SystemsRuntime.Proc.send(opts["test_pid"], {:requested_effect_tool, opts["requested_tool"]})

      {:assistant, "",
       [
         %{
           id: "forbidden-effect-call",
           name: "call",
           args: %{
             "tool" => opts["requested_tool"],
             "params" => %{}
           }
         }
       ]}
    end
  end

  defmodule ScriptedProvider do
    def complete(messages, [], opts) do
      participation? =
        get_in(opts, ["response_format", "name"]) == "comma_triage_participation_v1"

      if SystemsRuntime.Proc.is_process(opts["test_pid"]) and not participation? do
        SystemsRuntime.Proc.send(opts["test_pid"], {:triage_messages, messages})

        SystemsRuntime.Proc.send(
          opts["test_pid"],
          {:triage_response_format, opts["response_format"]}
        )

        SystemsRuntime.Proc.send(opts["test_pid"], {:triage_max_tokens, opts["max_tokens"]})

        SystemsRuntime.Proc.send(
          opts["test_pid"],
          {:triage_reasoning_effort, opts["reasoning_effort"]}
        )

        SystemsRuntime.Proc.send(opts["test_pid"], {:triage_thinking, opts["thinking"]})
      end

      payload_bytes = Jason.encode!(%{"messages" => messages, "model" => opts["model"]})
      :ok = opts[:before_send].(payload_bytes)

      content =
        if participation? do
          format = opts["response_format"]

          forced_silence? =
            get_in(format, ["schema", "properties", "communication", "enum"]) == ["silence"]

          selection =
            opts["participation"] ||
              %{
                "communication" =>
                  if(forced_silence?,
                    do: "silence",
                    else: get_in(opts, ["decision", "communication", "kind"]) || "silence"
                  ),
                "investigate" =>
                  not forced_silence? and (get_in(opts, ["decision", "delegations"]) || []) != [],
                "reason" => "The fixture selects the contribution before rendering."
              }

          opts["raw_participation"] || Jason.encode!(selection)
        else
          opts["raw_content"] || Jason.encode!(opts["decision"])
        end

      {:final, content}
    end
  end

  defmodule PhaseResponsePlug do
    @behaviour Plug
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      request = Jason.decode!(body)
      SystemsRuntime.Proc.send(opts.owner, {:phase_wire, request})
      response = Agent.get_and_update(opts.script, fn [next | rest] -> {next, rest} end)
      body = response_body(opts.protocol, response)
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))
    end

    defp response_body(protocol, :read) do
      args = %{"tool" => "web.read_pages", "params" => %{"urls" => ["link://run/l001"]}}

      case protocol do
        "responses" ->
          %{
            "output" => [
              %{
                "type" => "function_call",
                "call_id" => "triage-read-call-1",
                "name" => "call",
                "arguments" => Jason.encode!(args)
              }
            ]
          }

        "anthropic" ->
          %{
            "content" => [
              %{
                "type" => "tool_use",
                "id" => "triage-read-call-1",
                "name" => "call",
                "input" => args
              }
            ],
            "stop_reason" => "tool_use"
          }

        "chat_completions" ->
          %{
            "choices" => [
              %{
                "message" => %{
                  "role" => "assistant",
                  "content" => "",
                  "tool_calls" => [
                    %{
                      "id" => "triage-read-call-1",
                      "type" => "function",
                      "function" => %{"name" => "call", "arguments" => Jason.encode!(args)}
                    }
                  ]
                }
              }
            ]
          }
      end
    end

    defp response_body(protocol, response) do
      text = Jason.encode!(response)

      case protocol do
        "responses" ->
          %{
            "output" => [
              %{"type" => "message", "content" => [%{"type" => "output_text", "text" => text}]}
            ]
          }

        "anthropic" ->
          %{"content" => [%{"type" => "text", "text" => text}], "stop_reason" => "end_turn"}

        "chat_completions" ->
          %{"choices" => [%{"message" => %{"role" => "assistant", "content" => text}}]}
      end
    end
  end

  defmodule PrematureFinalProvider do
    def complete(messages, tools, opts) do
      payload_bytes =
        Jason.encode!(%{"messages" => messages, "model" => opts["model"], "tools" => tools})

      :ok = opts[:before_send].(payload_bytes)
      SystemsRuntime.Proc.send(opts["test_pid"], {:premature_final, tools})
      {:final, Jason.encode!(opts["decision"])}
    end
  end

  defmodule ModelRuntimeFence do
    use GenServer

    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

    @impl true
    def init(owner), do: {:ok, owner}

    @impl true
    def handle_call({:identity_model_runtime, _handle}, _from, owner) do
      {:reply,
       {:ok,
        %{
          "schema" => "comma.triage-model-runtime-authorization.v1",
          "agent_id" => "agent-template-bound",
          "identity_revision_sha256" => String.duplicate("a", 64)
        }}, owner}
    end

    def handle_call({:identity_read_tool_authorize, _handle}, _from, owner),
      do: {:reply, {:proceed, nil}, owner}
  end

  defmodule ProcessLlmResolver do
    @behaviour SalixAgent.LlmResolver

    @impl true
    def resolve(agent_id) do
      SystemsRuntime.Proc.send(
        Process.get(:triage_template_owner),
        {:resolved_triage_agent, agent_id}
      )

      {:ok, Process.get(:triage_template_config)}
    end
  end

  defmodule TemplateProvider do
    def complete(messages, [], opts) do
      SystemsRuntime.Proc.send(opts["test_pid"], {
        :template_provider_config,
        Map.take(opts, [
          "protocol",
          "base_url",
          "api_key",
          "model",
          "provider",
          "account_pool_tenant",
          "transport"
        ])
      })

      payload_bytes = Jason.encode!(%{"messages" => messages, "model" => opts["model"]})
      :ok = opts[:before_send].(payload_bytes)
      {:final, Jason.encode!(opts["decision"])}
    end
  end

  defmodule SubscriptionProxyWorker do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def init(opts), do: {:ok, opts}

    def handle_call({:start, id, bytes, reply_to}, _from, {owner, result} = state) do
      command = Jason.decode!(bytes)
      SystemsRuntime.Proc.send(owner, {:subscription_request, command})

      case result do
        {:ok, response} ->
          SystemsRuntime.Proc.send(
            reply_to,
            {:subscription, id,
             %{"type" => "data", "data" => Base.encode64(Jason.encode!(response))}}
          )

          SystemsRuntime.Proc.send(reply_to, {:subscription, id, %{"type" => "done"}})

        :unavailable ->
          SystemsRuntime.Proc.send(
            reply_to,
            {:subscription, id,
             %{"type" => "error", "status" => 503, "code" => "subscription_request_failed"}}
          )
      end

      {:reply, :ok, state}
    end

    def handle_cast(_, state), do: {:noreply, state}
  end

  @tag :subscription_proxy
  test "identity-bound subscription template reaches the existing proxy without a template key" do
    decision = %{
      "action" => "silence",
      "source_refs" => [],
      "identity_interpretation" => %{"topic" => "none", "referenced_principal_refs" => []}
    }

    response = %{
      "id" => "resp-triage",
      "output" => [
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [
            %{"type" => "output_text", "text" => Jason.encode!(decision)}
          ]
        }
      ]
    }

    opts = subscription_proxy_fixture({:ok, response})

    assert Salix.Bindings.TriageEvaluator.ready?("agent-template-bound")
    assert {:ok, ^decision, proof} = Salix.Bindings.TriageEvaluator.evaluate(model_input(), opts)
    settle_receive({:subscription_request, %{"op" => "/v1/responses"} = request})
    assert request["credential"]["credentials"]["access_token"] == "test-subscription-token"
    refute Map.has_key?(request["credential"]["credentials"], "refresh_token")
    assert proof["request_count"] == 1
    refute proof["provider_payload_bytes"] =~ "test-subscription-token"
    settle_refute_receive({:subscription_request, %{"op" => "/v1/responses"}})
  end

  defp subscription_proxy_fixture(result) do
    previous =
      Map.new(
        [:llm_resolver, :subscription_worker],
        &{&1, SystemsRuntime.get_env(:salix_agent, &1)}
      )

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if is_nil(value),
          do: SystemsRuntime.delete_env(:salix_agent, key),
          else: SystemsRuntime.put_env(:salix_agent, key, value)
      end)
    end)

    tenant = SalixStore.Ids.new_tenant_id()

    for _ <- 1..2 do
      id = SalixAgent.SubscriptionStore.id()

      {:ok, cipher} =
        SalixAgent.SubscriptionStore.seal(tenant, id, %{
          "access_token" => "test-subscription-token",
          "refresh_token" => "test-refresh"
        })

      {:ok, _} =
        SalixAgent.SubscriptionStore.create(
          tenant,
          %{
            "id" => id,
            "credential" => "subscription",
            "source" => "codex",
            "disabled" => false,
            "status" => "ok",
            "credentials" => cipher,
            "prepared" => true
          }
        )
    end

    {:ok, config} =
      SalixAgent.AccountPool.resolve_config(
        %{"account_pool" => "codex", "model" => "gpt-5.5"},
        tenant
      )

    SystemsRuntime.put_env(:salix_agent, :llm_resolver, ProcessLlmResolver)
    Process.put(:triage_template_owner, SystemsRuntime.Proc.self())
    Process.put(:triage_template_config, config)
    worker = start_supervised!({SubscriptionProxyWorker, {SystemsRuntime.Proc.self(), result}})
    SystemsRuntime.put_env(:salix_agent, :subscription_worker, worker)
    fence = start_supervised!({ModelRuntimeFence, SystemsRuntime.Proc.self()})

    [
      provider: SalixLlm.Provider,
      provider_config: :agent_template,
      identity_fence_handle: %SalixIM.Triage.IdentityFenceHandle{
        runtime: fence,
        capability: SystemsRuntime.Proc.make_ref()
      },
      transport_receipt: :single_attempt
    ]
  end

  test "production evaluator resolves the current identity-bound Agent template token" do
    previous_resolver = SystemsRuntime.get_env(:salix_agent, :llm_resolver)

    on_exit(fn ->
      if is_nil(previous_resolver),
        do: SystemsRuntime.delete_env(:salix_agent, :llm_resolver),
        else: SystemsRuntime.put_env(:salix_agent, :llm_resolver, previous_resolver)
    end)

    SystemsRuntime.put_env(:salix_agent, :llm_resolver, ProcessLlmResolver)
    Process.put(:triage_template_owner, SystemsRuntime.Proc.self())

    Process.put(:triage_template_config, %{
      "protocol" => "chat_completions",
      "base_url" => "https://model.example.test/v1",
      "api_key" => "plain-template-token",
      "model" => "template-model",
      "provider" => "openai"
    })

    owner = SystemsRuntime.Proc.self()
    fence = start_supervised!({ModelRuntimeFence, owner})

    handle = %SalixIM.Triage.IdentityFenceHandle{
      runtime: fence,
      capability: SystemsRuntime.Proc.make_ref()
    }

    decision = %{
      "action" => "silence",
      "source_refs" => [],
      "identity_interpretation" => %{
        "topic" => "none",
        "referenced_principal_refs" => []
      }
    }

    assert {:ok, ^decision, proof} =
             Salix.Bindings.TriageEvaluator.evaluate(model_input(),
               provider: TemplateProvider,
               provider_config: :agent_template,
               identity_fence_handle: handle,
               transport_receipt: :single_attempt,
               provider_opts: %{
                 "test_pid" => SystemsRuntime.Proc.self(),
                 "decision" => decision,
                 "account_pool_tenant" => SalixStore.Ids.new_tenant_id(),
                 "transport" => fn _, _ -> flunk("template transport cannot be overridden") end
               }
             )

    settle_receive({:resolved_triage_agent, "agent-template-bound"})
    settle_receive({:template_provider_config, resolved_config})

    assert resolved_config == %{
             "protocol" => "chat_completions",
             "base_url" => "https://model.example.test/v1",
             "api_key" => "plain-template-token",
             "model" => "template-model",
             "provider" => "openai"
           }

    assert proof["provider"] == "openai"
    assert proof["model"] == "template-model"
    assert proof["request_count"] == 1
    refute proof["provider_payload_bytes"] =~ "plain-template-token"
  end

  for {label, decision} <- [
        {"a decision without identity interpretation",
         %{
           "action" => "reply",
           "text" => "I am BFT.",
           "source_refs" => ["bft://projects/project-atlas/agents/agent-router"]
         }},
        {"a source outside the frozen closure",
         %{
           "action" => "reply",
           "text" => "I am BFT.",
           "source_refs" => ["meeting://invented/fact"],
           "identity_interpretation" => %{
             "topic" => "self_identity",
             "referenced_principal_refs" => ["comma-agent://agt1_atlas_router"]
           }
         }},
        {"remember over an identity-specific source",
         %{
           "action" => "remember",
           "fact" => "BFT is the router agent.",
           "source_refs" => ["bft://projects/project-atlas/agents/agent-router"],
           "identity_interpretation" => %{
             "topic" => "none",
             "referenced_principal_refs" => []
           }
         }}
      ] do
  end

  test "identity-enabled evaluator accepts the exact shared interpretation contract" do
    decision = %{
      "action" => "reply",
      "text" => "I am BFT.",
      "source_refs" => ["bft://projects/project-atlas/agents/agent-router"],
      "identity_interpretation" => %{
        "topic" => "self_identity",
        "referenced_principal_refs" => ["comma-agent://agt1_atlas_router"]
      }
    }

    assert {:ok, ^decision, proof} = evaluate(decision)
    assert proof["prompt_bytes"] =~ "identity_interpretation"
    assert proof["request_count"] == 1
    assert proof["retry"] == false
  end

  test "scheduled recheck retains one reply-or-silence outcome plus independent context candidates" do
    provider_decision = %{
      "schema" => "comma.triage-product-decision.v1",
      "communication" => %{
        "kind" => "reply",
        "text" => "我会在这个线程里继续确认 owner。",
        "source_refs" => ["source://run/s003"]
      },
      "context_candidates" => [
        %{
          "kind" => "project_fact",
          "subject" => "atlas-login-owner",
          "value" => "Atlas 登录问题尚未确认 owner",
          "confidence" => "explicit",
          "source_refs" => ["source://run/s003"],
          "recheck_after_hours" => nil,
          "follow_up_ref" => nil,
          "follow_up_action" => nil
        },
        %{
          "kind" => "follow_up",
          "subject" => "atlas-login-owner-follow-up",
          "value" => "重新检查 owner 是否已经明确",
          "confidence" => "explicit",
          "source_refs" => ["source://run/s003"],
          "recheck_after_hours" => 24,
          "follow_up_ref" => nil,
          "follow_up_action" => "create"
        }
      ],
      "delegations" => [],
      "identity_interpretation" => %{
        "topic" => "none",
        "referenced_principal_refs" => []
      }
    }

    expected =
      update_in(provider_decision, ["context_candidates"], fn [fact, follow_up] ->
        [
          Map.drop(fact, ~w(recheck_after_hours follow_up_ref follow_up_action)),
          Map.delete(follow_up, "follow_up_ref")
        ]
      end)

    assert {:ok, ^expected, _proof} =
             evaluate_input(
               with_source_mode(periodic_patrol_model_input_v3(), "scheduled_recheck"),
               provider_decision,
               %{"test_pid" => SystemsRuntime.Proc.self()}
             )

    settle_receive(
      {:triage_response_format,
       %{
         "name" => "comma_triage_product_decision_v2",
         "schema" => schema
       }}
    )

    assert schema["additionalProperties"] == false
    assert get_in(schema, ["properties", "context_candidates", "maxItems"]) == 3
    assert get_in(schema, ["properties", "delegations", "maxItems"]) == 0
  end

  test "ClickHouse intake only selects a Worker and describes the observed batch" do
    input = phase_model_input()
    assignment = phase_product_decision("silence", true)

    assert {:ok, ^assignment, proof} =
             evaluate_input(input, assignment, %{"test_pid" => SystemsRuntime.Proc.self()})

    assert proof["policy_bytes"] =~ "triage-worker-assignment-v1"
    settle_receive({:triage_response_format, %{"schema" => %{"properties" => properties}}})
    assert properties["context_candidates"]["maxItems"] == 0
    assert properties["delegations"]["minItems"] == 1
    assert properties["delegations"]["maxItems"] == 1
  end

  test "periodic patrol system-routes explicit recipients while retaining project context" do
    provider_proposal = %{
      "schema" => "comma.triage-product-decision.v1",
      "communication" => %{
        "kind" => "reply",
        "text" => "I will take this request.",
        "source_refs" => ["source://run/s003"]
      },
      "context_candidates" => [
        %{
          "kind" => "project_fact",
          "subject" => "atlas-owner",
          "value" => "Kim owns the Atlas follow-up",
          "confidence" => "explicit",
          "source_refs" => ["source://run/s003"],
          "recheck_after_hours" => nil
        }
      ],
      "delegations" => [
        %{"task" => "Take over this request", "source_refs" => ["source://run/s003"]}
      ],
      "identity_interpretation" => %{
        "topic" => "none",
        "referenced_principal_refs" => []
      }
    }

    model_input =
      periodic_patrol_model_input_v3()
      |> put_in(
        ["snapshot", "slack_context", "decision_target", "syntactic_addressee"],
        "other"
      )
      |> then(fn input ->
        Map.put(
          input,
          "canonical_snapshot_bytes",
          SalixIM.Triage.CanonicalJSON.encode!(input["snapshot"])
        )
      end)

    assert {:ok, decision, _proof} =
             evaluate_input(model_input, provider_proposal, %{
               "test_pid" => SystemsRuntime.Proc.self()
             })

    assert decision["communication"] == %{
             "kind" => "silence",
             "reason" => "outside_authority",
             "explanation" =>
               "This message explicitly addresses another recipient. Triage does not take over their reply.",
             "source_refs" => []
           }

    assert decision["delegations"] == []
    assert [%{"subject" => "atlas-owner"}] = decision["context_candidates"]

    settle_receive(
      {:triage_response_format,
       %{
         "schema" => %{
           "properties" => %{
             "communication" => communication,
             "delegations" => %{"maxItems" => 0}
           }
         }
       }}
    )

    assert get_in(communication, ["properties", "reason", "enum"]) == ["outside_authority"]
  end

  test "periodic patrol does not inherit the directed CH agent bypass" do
    provider_proposal = %{
      "schema" => "comma.triage-product-decision.v2",
      "communication" => %{
        "kind" => "reply",
        "text" => "I will take this request.",
        "source_refs" => ["source://run/s003"]
      },
      "companion_reaction" => %{
        "kind" => "reaction",
        "emoji" => "eyes",
        "source_refs" => ["source://run/s003"]
      },
      "context_candidates" => [],
      "delegations" => [
        %{"task" => "Take over this request", "source_refs" => ["source://run/s003"]}
      ],
      "identity_interpretation" => %{
        "topic" => "none",
        "referenced_principal_refs" => []
      }
    }

    model_input = product_target(periodic_patrol_model_input_v3(), "agent", "self")

    assert {:ok, decision, _proof} =
             evaluate_input(model_input, provider_proposal, %{
               "test_pid" => SystemsRuntime.Proc.self()
             })

    assert decision["communication"] == %{
             "kind" => "silence",
             "reason" => "duplicate",
             "explanation" =>
               "The direct-message route handles this explicitly addressed message. This patrol does not send a second reply.",
             "source_refs" => []
           }

    assert decision["companion_reaction"] == nil
    assert decision["delegations"] == []
  end

  test "v3 tool-required triage uses one disclosed read-only tool before its final decision" do
    {:ok, script} = Agent.start_link(fn -> 0 end)

    {:ok, server} =
      Bandit.start_link(
        plug: {ReadPagePlug, SystemsRuntime.Proc.self()},
        port: 0,
        startup_log: false
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    previous_base = SystemsRuntime.get_env(:salix_agent, :exa_base_url)
    previous_key = SystemsRuntime.get_env(:salix_agent, :exa_api_key)
    SystemsRuntime.put_env(:salix_agent, :exa_base_url, "http://127.0.0.1:#{port}")
    SystemsRuntime.put_env(:salix_agent, :exa_api_key, "triage-test-key")

    on_exit(fn ->
      SystemsRuntime.Proc.exit(server, :shutdown)
      restore_env(:exa_base_url, previous_base)
      restore_env(:exa_api_key, previous_key)
    end)

    decision = %{
      "action" => "reply",
      "text" => "The linked brief says Tuesday, after the owner check.",
      "source_refs" => ["source://run/s001"],
      "identity_interpretation" => %{
        "topic" => "none",
        "referenced_principal_refs" => []
      }
    }

    tool_context = read_only_tool_context()

    assert {:ok, ^decision, proof} =
             Salix.Bindings.TriageEvaluator.evaluate(tool_required_model_input_v3(),
               provider: ToolCallingProvider,
               provider_opts: %{
                 "decision" => decision,
                 "script" => script,
                 "test_pid" => SystemsRuntime.Proc.self()
               },
               read_tool_context: tool_context,
               transport_receipt: fn payload_bytes ->
                 %{payload_sha256: sha256(payload_bytes), request_count: 1}
               end
             )

    settle_receive({:triage_tool_round, 0, _messages, [%{"name" => "call"}]})

    settle_receive(
      {:read_pages_request,
       %{
         "urls" => ["https://example.test/launch-brief"],
         "text" => %{"maxCharacters" => 10_000}
       }, ["triage-test-key"]}
    )

    settle_receive({:triage_tool_round, 1, second_messages, []})

    assert Enum.any?(second_messages, fn
             %{role: "tool", tool_call_id: "triage-read-call-1", content: content} ->
               content =~ "launch is approved for Tuesday"

             _other ->
               false
           end)

    assert proof["request_count"] == 2
    assert proof["tool_call_count"] == 1
    assert proof["tool_names"] == ["web.read_pages"]
    assert proof["tool_receipts"] |> List.first() |> Map.fetch!("result_sha256")
  end

  test "a Slack permalink supplies exact authorized message semantics, not a web application page" do
    tool_context = slack_permalink_tool_context!()
    {:ok, script} = Agent.start_link(fn -> 0 end)
    install_slack_permalink_transport!()

    decision = %{
      "action" => "reply",
      "text" => "The linked message approves Tuesday after the owner check.",
      "source_refs" => ["source://run/s001"],
      "identity_interpretation" => %{"topic" => "none", "referenced_principal_refs" => []}
    }

    assert {:ok, ^decision, proof} =
             Salix.Bindings.TriageEvaluator.evaluate(tool_required_model_input_v3(),
               provider: ToolCallingProvider,
               provider_opts: %{
                 "decision" => decision,
                 "script" => script,
                 "test_pid" => SystemsRuntime.Proc.self(),
                 "read_tool" => "triage.slack_read_permalink",
                 "read_params" => %{"link_ref" => "link://run/l001"}
               },
               read_tool_context: tool_context,
               transport_receipt: fn bytes ->
                 %{payload_sha256: sha256(bytes), request_count: 1}
               end
             )

    settle_receive({:slack_permalink_request, "auth.test", _})
    settle_receive({:slack_permalink_request, "conversations.history", params})
    assert params["channel"] == "C_ATLAS"
    assert params["oldest"] == "1787019000.000001"
    assert params["latest"] == "1787019000.000001"
    assert params["inclusive"] == "true"
    assert params["limit"] == "1"
    settle_receive({:triage_tool_round, 1, messages, []})
    tool_result = Enum.find(messages, &(&1[:role] == "tool"))
    assert tool_result.content =~ "approved for Tuesday after the owner check"
    refute tool_result.content =~ "U024BE7LH"
    refute Jason.encode!(messages) =~ "atlas.slack.com"
    assert proof["tool_names"] == ["triage.slack_read_permalink"]
    assert proof["tool_call_count"] == 1
    assert proof["request_count"] == 2
    settle_refute_receive({:read_pages_request, _, _})
  end

  for {label, url, options, expected_error, read?} <- [
        {"foreign workspace host", "https://foreign.slack.com/archives/C_ATLAS/p1787019000000001",
         [], "slack_workspace_unverified", false},
        {"unknown authenticated host", nil, [identity: %{"ok" => true, "team_id" => "T_ATLAS"}],
         "slack_workspace_unverified", false},
        {"foreign authenticated workspace", nil,
         [
           identity: %{
             "ok" => true,
             "team_id" => "T_FOREIGN",
             "url" => "https://atlas.slack.com/"
           }
         ], "slack_workspace_unverified", false},
        {"unapproved target channel",
         "https://atlas.slack.com/archives/C_FOREIGN/p1787019000000001", [],
         "slack_target_not_authorized", false},
        {"wrong returned message", nil,
         [messages: [%{"ts" => "1787019000.000002", "text" => "wrong source"}]],
         "slack_exact_message_unavailable", true},
        {"unavailable exact message", nil, [messages: []], "slack_exact_message_unavailable",
         true}
      ] do
    test "Slack permalink fails honestly for #{label}" do
      context = slack_permalink_tool_context!()
      url = unquote(url)

      context =
        if url,
          do: put_in(context, [:link_targets, Access.at(0), "resolved_url"], url),
          else: context

      install_slack_permalink_transport!(unquote(Macro.escape(options)))
      assert {:ok, _decision, proof} = evaluate_slack_permalink(context)
      assert [%{"status" => "error", "error" => true} = receipt] = proof["tool_receipts"]
      assert receipt["canonical_result_bytes"] =~ unquote(expected_error)
      assert proof["request_count"] == 2
      settle_refute_receive({:slack_permalink_request, "contents", _})

      if unquote(read?) do
        settle_receive({:slack_permalink_request, "conversations.history", _})
      else
        settle_refute_receive({:slack_permalink_request, "conversations.history", _})
        settle_refute_receive({:slack_permalink_request, "conversations.replies", _})
      end
    end
  end

  for {channel, expected_error} <- [
        {"C_ATLAS", "slack_source_changed"},
        {"C_TASKS", "slack_target_not_authorized"}
      ] do
    test "revoking #{channel} during host verification prevents a cross-channel read" do
      context = slack_permalink_tool_context!()
      connect = approve_permalink_channel!(context, "C_TASKS")

      context =
        put_in(
          context,
          [:link_targets, Access.at(0), "resolved_url"],
          "https://atlas.slack.com/archives/C_TASKS/p1787019000000001"
        )

      install_slack_permalink_transport!(
        after_auth: fn ->
          assert :ok =
                   SalixStore.SlackTriageChannels.set_enabled(
                     context.tenant_id,
                     context.group_id,
                     connect["connect_id"],
                     unquote(channel),
                     connect["connect_generation"],
                     false
                   )
        end
      )

      assert {:ok, _, proof} = evaluate_slack_permalink(context)
      assert [%{"status" => "error"} = receipt] = proof["tool_receipts"]
      assert receipt["canonical_result_bytes"] =~ unquote(expected_error)
      settle_receive({:slack_permalink_request, "auth.test", _})
      settle_refute_receive({:slack_permalink_request, "conversations.history", _})
      settle_refute_receive({:slack_permalink_request, "conversations.replies", _})
    end
  end

  test "a reconnect after host verification cannot substitute the source installation" do
    context = slack_permalink_tool_context!()

    key =
      SalixStore.Keys.ctl_im_connect(
        context.group_id,
        context.slack_source_authority["connect_id"]
      )

    install_slack_permalink_transport!(
      after_auth: fn ->
        assert {:ok, _} =
                 SalixStore.CasRecord.update(
                   key,
                   &Map.put(&1, "connect_generation", SalixStore.ULID.generate())
                 )
      end
    )

    assert {:ok, _, proof} = evaluate_slack_permalink(context)
    assert [%{"status" => "error"}] = proof["tool_receipts"]
    settle_receive({:slack_permalink_request, "auth.test", _})
    settle_refute_receive({:slack_permalink_request, "conversations.history", _})
    settle_refute_receive({:slack_permalink_request, "conversations.replies", _})
  end

  # A model asking to read something this run was never authorized to read is
  # the injection signal, and it was folded into the generic "bad result"
  # reason — exactly the diagnostic an operator needs and can get nowhere else.
  test "an unauthorized read target keeps its own distinct refusal" do
    assert {:error, :invalid_triage_read_tool_target} =
             Salix.Bindings.TriageEvaluator.evaluate(tool_required_model_input_v3(),
               provider: ForeignTargetProvider,
               provider_opts: %{},
               read_tool_context: read_only_tool_context(),
               transport_receipt: fn payload_bytes ->
                 %{payload_sha256: sha256(payload_bytes), request_count: 1}
               end
             )
  end

  test "history read accepts the exact authorized direct provider call and normalizes it" do
    {:ok, script} = Agent.start_link(fn -> 0 end)

    decision = %{
      "action" => "silence",
      "source_refs" => [],
      "identity_interpretation" => %{
        "topic" => "none",
        "referenced_principal_refs" => []
      }
    }

    assert {:ok, ^decision, proof} =
             Salix.Bindings.TriageEvaluator.evaluate(projected_model_input_v3(),
               provider: DirectHistoryToolProvider,
               provider_opts: %{"decision" => decision, "script" => script},
               read_tool_context: history_read_tool_context(),
               transport_receipt: fn payload_bytes ->
                 %{payload_sha256: sha256(payload_bytes), request_count: 1}
               end
             )

    assert proof["request_count"] == 2
    assert proof["tool_names"] == ["triage_run.get"]
    assert [%{"tool_name" => "triage_run.get"}] = proof["tool_receipts"]
  end

  test "effect-capable tool names are unreachable from the triage evaluator" do
    for tool_name <- [
          "slack.send",
          "memory.write",
          "recipe.create",
          "executor.run",
          "web.write"
        ] do
      assert {:error, :invalid_triage_read_tool_call} =
               Salix.Bindings.TriageEvaluator.evaluate(tool_required_model_input_v3(),
                 provider: RequestedToolProvider,
                 provider_opts: %{
                   "model" => "effect-tool-attempt-v1",
                   "requested_tool" => tool_name,
                   "test_pid" => SystemsRuntime.Proc.self()
                 },
                 read_tool_context: read_only_tool_context(true),
                 transport_receipt: fn payload_bytes ->
                   %{payload_sha256: sha256(payload_bytes), request_count: 1}
                 end
               )

      settle_receive({:requested_effect_tool, ^tool_name})
    end

    settle_refute_receive({:read_pages_request, _, _}, 50)
  end

  defp evaluate(decision, provider_opts \\ %{}) do
    evaluate_input(model_input(), decision, provider_opts)
  end

  test "fixed intake assignment preserves source authority and cannot publish model output" do
    input = phase_model_input()
    assert {:ok, decision} = SalixIM.Triage.WorkerSelection.assignment(input)
    metadata = %{"schema" => "comma.triage-worker-assignment.v1"}

    assert {:ok, ^decision, proof} =
             Pipeline.validate_model_result(input, decision, metadata, :unused)

    assert proof["request_count"] == 0
    assert SalixIM.Triage.RunFence.valid_model_proof?(proof)

    reply =
      put_in(decision, ["communication"], %{
        "kind" => "reply",
        "text" => "invented",
        "source_refs" => []
      })

    assert {:error, :invalid_triage_worker_assignment} =
             Pipeline.validate_model_result(input, reply, metadata, :unused)

    empty = put_in(input, ["snapshot", "team_project_memory", "facts"], [])
    assert {:error, :triage_worker_unavailable} = SalixIM.Triage.WorkerSelection.assignment(empty)
  end

  test "ordinary intake assigns one Worker without choosing participation on every protocol" do
    input = phase_model_input()

    for protocol <- ~w(responses chat_completions anthropic) do
      decision = phase_product_decision("silence", true)
      assert {:ok, ^decision, raw} = phase_http_evaluate(input, protocol, [decision])
      assert raw["request_count"] == 1
      refute Map.has_key?(raw, "participation_decision")

      assert {:ok, ^decision, proof} =
               Pipeline.validate_model_result(input, decision, raw, :unused)

      assert SalixIM.Triage.RunFence.valid_model_proof?(proof)
      settle_receive({:phase_wire, wire})
      settle_refute_receive({:phase_wire, _}, 0)
      assert wire["tools"] in [nil, []]

      assert SalixIM.Triage.RunFence.payload_has_exact_message_content?(
               wire,
               input["canonical_snapshot_bytes"]
             )

      if protocol == "responses" do
        assert get_in(wire, [
                 "text",
                 "format",
                 "schema",
                 "properties",
                 "delegations",
                 "items",
                 "properties",
                 "worker_ref",
                 "enum"
               ]) == ["source://run/worker001"]
      end
    end
  end

  test "one native call rejects malformed communication and Workers outside the frozen roster" do
    input = phase_model_input()
    decision = phase_product_decision("silence", true)

    cases = [
      phase_product_decision("reply", true),
      phase_product_decision("silence", false),
      put_in(decision, ["delegations", Access.at(0), "worker_ref"], "comma-agent://invented")
      | Enum.map(["silence", 1, [], nil], &Map.put(decision, "communication", &1))
    ]

    for protocol <- ~w(responses chat_completions anthropic), malformed <- cases do
      assert {:error, :invalid_triage_decision} =
               phase_http_evaluate(input, protocol, [malformed])

      settle_receive({:phase_wire, _})
      settle_refute_receive({:phase_wire, _}, 0)
    end
  end

  defp phase_model_input do
    input =
      clickhouse_product_model_input_v3() |> Map.put("schema", "comma.triage-model-input.v2")

    memory = %{
      "facts" => [
        %{
          "kind" => "available_investigation_worker",
          "source_ref" => "source://run/worker001",
          "fact" => "Research Worker"
        }
      ]
    }

    snapshot = Map.put(input["snapshot"], "team_project_memory", memory)

    input
    |> Map.put("snapshot", snapshot)
    |> Map.put("canonical_snapshot_bytes", SalixIM.Triage.CanonicalJSON.encode!(snapshot))
    |> Map.update!("source_refs", &Enum.sort(["source://run/worker001" | &1]))
    |> phase_input_hashes()
  end

  defp with_source_mode(input, mode) do
    snapshot = put_in(input["snapshot"], ["identity_context", "source_mode"], mode)

    input
    |> Map.put("snapshot", snapshot)
    |> Map.put("canonical_snapshot_bytes", SalixIM.Triage.CanonicalJSON.encode!(snapshot))
    |> phase_input_hashes()
  end

  defp phase_input_hashes(input) do
    input
    |> Map.put("canonical_snapshot_sha256", sha256(input["canonical_snapshot_bytes"]))
    |> Map.put(
      "source_refs_sha256",
      sha256(SalixIM.Triage.CanonicalJSON.encode!(input["source_refs"]))
    )
  end

  defp phase_product_decision(kind, investigate) do
    communication =
      if kind == "reply",
        do: %{
          "kind" => "reply",
          "text" => "The meeting is at 15:00.",
          "source_refs" => ["source://run/s001"]
        },
        else: SalixIM.Triage.WorkerSelection.pending_communication()

    %{
      "schema" => "comma.triage-product-decision.v2",
      "communication" => communication,
      "companion_reaction" => nil,
      "context_candidates" => [],
      "delegations" =>
        if(investigate,
          do: [
            %{
              "task" => "Read the supplied source and identify the failed handoff.",
              "worker_ref" => "source://run/worker001",
              "source_refs" => ["source://run/s001"]
            }
          ],
          else: []
        ),
      "identity_interpretation" => %{"topic" => "none", "referenced_principal_refs" => []}
    }
  end

  defp phase_http_evaluate(input, protocol, responses, read_context \\ nil) do
    {:ok, script} = Agent.start_link(fn -> responses end)

    {:ok, server} =
      Bandit.start_link(
        plug:
          {PhaseResponsePlug,
           %{owner: SystemsRuntime.Proc.self(), script: script, protocol: protocol}},
        port: 0,
        startup_log: false
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    SystemsRuntime.Proc.unlink(server)

    try do
      Salix.Bindings.TriageEvaluator.evaluate(input,
        provider: SalixLlm.Provider,
        provider_name: "fixture-provider",
        provider_opts: %{
          "protocol" => protocol,
          "base_url" => "http://127.0.0.1:#{port}",
          "api_key" => "fixture-key",
          "model" => "fixture-model"
        },
        read_tool_context: read_context,
        transport_receipt: fn bytes -> %{payload_sha256: sha256(bytes), request_count: 1} end
      )
    after
      SystemsRuntime.Proc.exit(server, :shutdown)
      Agent.stop(script)
    end
  end

  defp evaluate_input(model_input, decision, provider_opts) do
    Salix.Bindings.TriageEvaluator.evaluate(model_input,
      provider: ScriptedProvider,
      provider_opts:
        provider_opts |> Map.put_new("protocol", "responses") |> Map.put("decision", decision),
      transport_receipt: fn payload_bytes ->
        %{payload_sha256: sha256(payload_bytes), request_count: 1}
      end
    )
  end

  defp model_input do
    identity_context = identity_context()

    snapshot = %{
      "schema" => "comma.triage-context-snapshot.v2",
      "identity_context" => identity_context
    }

    %{
      "schema" => "comma.triage-model-input.v2",
      "snapshot" => snapshot,
      "canonical_snapshot_bytes" => SalixIM.Triage.CanonicalJSON.encode!(snapshot),
      "source_refs" => identity_context["source_refs"]
    }
  end

  defp projected_model_input_v3 do
    identity_context = projected_identity_context()

    snapshot = %{
      "schema" => "comma.triage-context-snapshot.v5",
      "identity_context" => identity_context
    }

    %{
      "schema" => "comma.triage-model-input.v3",
      "snapshot" => snapshot,
      "canonical_snapshot_bytes" => SalixIM.Triage.CanonicalJSON.encode!(snapshot),
      "source_refs" => identity_context["source_refs"]
    }
  end

  defp periodic_patrol_model_input_v3 do
    model_input = projected_model_input_v3()

    snapshot =
      update_in(model_input, ["snapshot", "identity_context"], fn identity_context ->
        Map.put(identity_context, "source_mode", "periodic_patrol")
      end)["snapshot"]
      |> Map.put("slack_context", %{
        "decision_target" => %{"syntactic_addressee" => "none"}
      })

    model_input
    |> Map.put("snapshot", snapshot)
    |> Map.put("canonical_snapshot_bytes", SalixIM.Triage.CanonicalJSON.encode!(snapshot))
  end

  defp clickhouse_product_model_input_v3 do
    model_input = periodic_patrol_model_input_v3()

    snapshot =
      update_in(model_input, ["snapshot", "identity_context"], fn identity_context ->
        Map.put(identity_context, "source_mode", "clickhouse_etl")
      end)["snapshot"]

    model_input
    |> Map.put("snapshot", snapshot)
    |> Map.put("canonical_snapshot_bytes", SalixIM.Triage.CanonicalJSON.encode!(snapshot))
    |> product_target("human", "none")
  end

  defp product_target(model_input, actor_kind, syntactic_addressee) do
    snapshot =
      model_input["snapshot"]
      |> put_in(
        ["slack_context", "decision_target"],
        %{
          "ordinal" => 1,
          "message_ref" => "message://run/m001",
          "source_ref" => "source://run/s003",
          "link_refs" => [],
          "syntactic_addressee" => syntactic_addressee
        }
      )
      |> put_in(
        ["slack_context", "messages"],
        [
          %{
            "ordinal" => 1,
            "actor_ref" => "principal://run/p001",
            "actor_kind" => actor_kind,
            "message_ref" => "message://run/m001",
            "text" => "Please check this.",
            "source_ref" => "source://run/s003"
          }
        ]
      )

    model_input
    |> Map.put("snapshot", snapshot)
    |> Map.put("canonical_snapshot_bytes", SalixIM.Triage.CanonicalJSON.encode!(snapshot))
  end

  defp tool_required_model_input_v3 do
    model_input = projected_model_input_v3()

    snapshot =
      Map.put(model_input["snapshot"], "slack_context", %{
        "links" => [
          %{
            "link_ref" => "link://run/l001",
            "display_alias" => "@link:l001",
            "message_refs" => ["message://run/m001"],
            "source_refs" => ["source://run/s001"]
          }
        ],
        "decision_target" => %{
          "ordinal" => 1,
          "message_ref" => "message://run/m001",
          "source_ref" => "source://run/s001",
          "link_refs" => ["link://run/l001"],
          "syntactic_addressee" => "none"
        }
      })

    model_input
    |> Map.put("snapshot", snapshot)
    |> Map.put("canonical_snapshot_bytes", SalixIM.Triage.CanonicalJSON.encode!(snapshot))
  end

  defp projected_identity_context do
    %{
      "schema" => "comma.triage-identity-model-context.v1",
      "source_mode" => "historical_thread_reenactment",
      "self_agent" => %{
        "principal_ref" => "principal://run/self",
        "display_alias" => "@self",
        "role" => "router",
        "source_ref" => "source://run/s001"
      },
      "self_endpoint" => %{
        "endpoint_ref" => "endpoint://run/self",
        "provider" => "slack",
        "display_aliases" => ["@self", "BFT"],
        "represents_principal_ref" => "principal://run/self",
        "revision_status" => "exact",
        "source_ref" => "source://run/s002"
      },
      "observed_principals" => [
        %{
          "principal_ref" => "principal://run/p001",
          "provider" => "slack",
          "kind" => "human",
          "relation_to_self" => "other",
          "display_aliases" => ["@human:p001"],
          "evidence_tier" => "thread_authorship",
          "source_refs" => ["source://run/s003"]
        }
      ],
      "mention_evidence" => [
        %{
          "principal_ref" => "principal://run/p001",
          "message_ref" => "message://run/m001",
          "message_source_ref" => "source://run/s003",
          "selectors" => ["text_token"],
          "source_ref" => "source://run/s004",
          "source_refs" => ["source://run/s003"]
        }
      ],
      "principal_refs" => ["principal://run/self", "principal://run/p001"],
      "remember_forbidden_source_refs" => [
        "principal://run/p001",
        "principal://run/self",
        "source://run/s001",
        "source://run/s002",
        "source://run/s004"
      ],
      "source_refs" => [
        "source://run/s001",
        "source://run/s002",
        "source://run/s003",
        "source://run/s004"
      ]
    }
  end

  defp read_only_tool_context(read_once \\ false) do
    context = %{
      agent_id: "agt1_atlas_router",
      session_id: "triage-tool-session",
      tenant_id: "tenant-atlas",
      group_id: "project-atlas",
      role: "router",
      runtime_kind: :internal,
      llm_tool_envelope: true,
      visible_reply_phase: :clean,
      triage_read_once: read_once
    }

    disclosure = ToolDisclosure.materialize("router", :internal, context)
    web_read = Enum.find(disclosure["tools"], &(&1["name"] == "web.read_pages"))
    disclosure = %{disclosure | "tools" => [web_read]}

    context
    |> Map.put(:tool_disclosure, disclosure)
    |> Map.put(:link_targets, [
      %{
        "link_ref" => "link://run/l001",
        "resolved_url" => "https://example.test/launch-brief",
        "source_refs" => ["source://run/s001"]
      }
    ])
  end

  defp install_slack_permalink_transport!(options \\ []) do
    server =
      start_supervised!(
        {Bandit,
         plug: {SlackPermalinkPlug, {SystemsRuntime.Proc.self(), options}},
         port: 0,
         startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    previous =
      for {app, key, value} <- [
            {:salix_im, :slack_api_base_url, "http://127.0.0.1:#{port}/api"},
            {:salix_agent, :im_provider_mod, SalixIM.Provider},
            {:salix_agent, :exa_base_url, "http://127.0.0.1:#{port}"},
            {:salix_im, :slack_message_mirror_mod, SalixIM.SlackMessageMirror.Noop}
          ] do
        old = SystemsRuntime.get_env(app, key)
        SystemsRuntime.put_env(app, key, value)
        {app, key, old}
      end

    on_exit(fn ->
      for {app, key, old} <- previous do
        if is_nil(old),
          do: SystemsRuntime.delete_env(app, key),
          else: SystemsRuntime.put_env(app, key, old)
      end
    end)
  end

  defp evaluate_slack_permalink(context) do
    {:ok, script} = Agent.start_link(fn -> 0 end)

    Salix.Bindings.TriageEvaluator.evaluate(tool_required_model_input_v3(),
      provider: ToolCallingProvider,
      provider_opts: %{
        "decision" => %{
          "action" => "reply",
          "text" => "来源读取结果已返回，尚未执行发布。",
          "source_refs" => ["source://run/s001"],
          "identity_interpretation" => %{"topic" => "none", "referenced_principal_refs" => []}
        },
        "script" => script,
        "test_pid" => SystemsRuntime.Proc.self(),
        "read_tool" => "triage.slack_read_permalink",
        "read_params" => %{"link_ref" => "link://run/l001"}
      },
      read_tool_context: context,
      transport_receipt: fn bytes -> %{payload_sha256: sha256(bytes), request_count: 1} end
    )
  end

  defp slack_permalink_tool_context! do
    alias SalixStore.{CasRecord, Ids, Keys, ULID}
    unless SystemsRuntime.Proc.whereis(Ids), do: start_supervised!(Ids)

    unless SystemsRuntime.Proc.whereis(SalixStore.S3.Fake),
      do: start_supervised!(SalixStore.S3.Fake)

    tenant = Ids.new_tenant_id()
    group = Ids.new_group_id(tenant)
    agent = Ids.new_agent_id(group)
    connect_id = Ids.new_connect_id()

    assert {:ok, _} =
             CasRecord.create(Keys.ctl_group(group), %{
               "tenant_id" => tenant,
               "group_id" => group,
               "router_agent_id" => agent,
               "router_conversation_id" => "conv-#{group}"
             })

    assert {:ok, _} =
             CasRecord.create(Keys.ctl_agent(agent), %{
               "tenant_id" => tenant,
               "group_id" => group,
               "agent_id" => agent,
               "role" => "router",
               "heartbeat_schedule_id" => "test-heartbeat",
               "router_session_id" => "test-session"
             })

    connect = %{
      "provider" => "slack",
      "tenant_id" => tenant,
      "group_id" => group,
      "connect_id" => connect_id,
      "connect_generation" => ULID.generate(),
      "workspace_id" => "T_ATLAS",
      "approved_channel_id" => "C_ATLAS",
      "inbound_agent_id" => agent,
      "app_id" => "A_BFT",
      "bot_user_id" => "U_BFT",
      "bot_id" => "B_BFT",
      "oauth_completed_at" => 1,
      "triage_enabled" => true,
      "bot_token" => "xoxb-local-fixture-only"
    }

    assert {:ok, _} = CasRecord.create(Keys.ctl_im_connect(group, connect_id), connect)

    assert {:ok, _} =
             SalixStore.SlackTriageChannels.provision(%{
               "tenant_id" => tenant,
               "group_id" => group,
               "connect_id" => connect_id,
               "channel_id" => "C_ATLAS",
               "installation_generation" => connect["connect_generation"],
               "workspace_id" => "T_ATLAS",
               "channel_name" => "triage",
               "channel_generation" => connect["connect_generation"]
             })

    assert {:ok, authority} =
             SalixIM.ProviderConnects.get_slack_triage_authority(
               tenant,
               group,
               connect_id,
               "C_ATLAS"
             )

    context = read_only_tool_context(true)
    entry = history_read_tool_context().tool_disclosure["tools"] |> hd()

    entry = %{
      entry
      | "name" => "triage.slack_read_permalink",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{"link_ref" => %{"type" => "string"}},
          "required" => ["link_ref"],
          "additionalProperties" => false
        }
    }

    %{
      context
      | agent_id: agent,
        tenant_id: tenant,
        group_id: group,
        tool_disclosure: %{"revision" => "triage-slack-read-v1", "tools" => [entry]},
        link_targets: [
          %{
            "link_ref" => "link://run/l001",
            "source_refs" => ["source://run/s001"],
            "resolved_url" => "https://atlas.slack.com/archives/C_ATLAS/p1787019000000001"
          }
        ]
    }
    |> Map.put(:tool_name, "triage.slack_read_permalink")
    |> Map.put(
      :slack_source_authority,
      Map.take(
        authority,
        ~w(provider tenant_id group_id connect_id connect_generation workspace_id approved_channel_id inbound_agent_id app_id bot_user_id bot_id)
      )
    )
  end

  defp approve_permalink_channel!(context, channel) do
    assert {:ok, connect} =
             SalixStore.CasRecord.get(
               SalixStore.Keys.ctl_im_connect(
                 context.group_id,
                 context.slack_source_authority["connect_id"]
               )
             )

    assert {:ok, _} =
             SalixStore.SlackTriageChannels.provision(%{
               "tenant_id" => context.tenant_id,
               "group_id" => context.group_id,
               "connect_id" => connect["connect_id"],
               "channel_id" => channel,
               "installation_generation" => connect["connect_generation"],
               "workspace_id" => connect["workspace_id"],
               "channel_name" => "tasks"
             })

    connect
  end

  defp history_read_tool_context do
    summary_item = %{
      "run_ref" => "triage-run://current/r001",
      "lifecycle_state" => "decision_proposed",
      "review_state" => "not_reviewed",
      "effect_state" => "not_executed",
      "source_relation" => "same_project_router",
      "revision_relation" => "current"
    }

    %{
      agent_id: "agt1_atlas_router",
      session_id: "triage-history-session",
      tenant_id: "tenant-atlas",
      group_id: "project-atlas",
      role: "router",
      runtime_kind: :internal,
      llm_tool_envelope: true,
      visible_reply_phase: :clean,
      triage_read_once: true,
      tool_name: "triage_run.get",
      history_summary: %{
        "schema" => "comma.triage-activity-summary.v1",
        "as_of_ms" => 1,
        "items" => [summary_item]
      },
      history_targets: [
        %{
          "run_ref" => "triage-run://current/r001",
          "private_run_id" => "private-run-1",
          "summary" => summary_item,
          "result" => %{"action" => "silence"}
        }
      ],
      tool_disclosure: %{
        "revision" => "triage-history-read-v1",
        "tools" => [
          %{
            "name" => "triage_run.get",
            "prompt_visibility" => "manual",
            "summary" => "Read one authorized prior Triage run by its opaque run_ref.",
            "manual_available" => true,
            "helpable" => false,
            "callable" => true,
            "safety" => "read",
            "input_schema" => %{
              "type" => "object",
              "properties" => %{"run_ref" => %{"type" => "string"}},
              "required" => ["run_ref"],
              "additionalProperties" => false
            },
            "manual" => "Use exactly one run_ref from Recent Triage Activity.",
            "examples" => %{},
            "discovery_sources" => []
          }
        ]
      }
    }
  end

  defp restore_env(key, nil), do: SystemsRuntime.delete_env(:salix_agent, key)
  defp restore_env(key, value), do: SystemsRuntime.put_env(:salix_agent, key, value)

  defp identity_context do
    identity = %{
      "source_ref" => "bft://projects/project-atlas/agents/agent-router",
      "principal_ref" => "comma-agent://agt1_atlas_router",
      "agent_id" => "agt1_atlas_router",
      "role" => "router",
      "display_name" => "BFT",
      "persona_revision_sha256" => String.duplicate("a", 64)
    }

    {:ok, identity_revision} = IdentityContract.identity_revision_sha256(identity)

    %{
      "schema" => "comma.triage-identity-context.v1",
      "source_mode" => "callback",
      "self_agent" => Map.put(identity, "identity_revision_sha256", identity_revision),
      "self_endpoint" => %{
        "source_ref" => "slack-endpoint://T_ATLAS/connect-atlas@generation-7",
        "provider" => "slack",
        "workspace_id" => "T_ATLAS",
        "connect_id" => "connect-atlas",
        "connect_generation" => "generation-7",
        "provider_app_id" => "A_BFT",
        "bot_user_id" => "U_BFT",
        "bot_id" => "B_BFT",
        "display_aliases" => ["BFT"],
        "represents_principal_ref" => "comma-agent://agt1_atlas_router",
        "revision_sha256" => String.duplicate("b", 64),
        "revision_status" => "exact"
      },
      "observed_principals" => [],
      "mention_evidence" => [],
      "principal_refs" => ["comma-agent://agt1_atlas_router"],
      "remember_forbidden_source_refs" => [
        "bft://projects/project-atlas/agents/agent-router",
        "comma-agent://agt1_atlas_router",
        "slack-endpoint://T_ATLAS/connect-atlas@generation-7"
      ],
      "source_refs" => [
        "bft://projects/project-atlas/agents/agent-router",
        "slack-endpoint://T_ATLAS/connect-atlas@generation-7"
      ]
    }
  end

  defp sha256(bytes) do
    bytes
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
