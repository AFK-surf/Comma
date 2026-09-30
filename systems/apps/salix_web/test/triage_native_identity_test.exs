defmodule Salix.Bindings.TriageNativeIdentityTest do
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

  use ExUnit.Case, async: false

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
      send(owner, {:slack_permalink_request, method, params})

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
      send(owner, {:read_pages_request, request, get_req_header(conn, "x-api-key")})

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
      send(owner, :empty_read_pages_request)

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
      send(opts.owner, {:chat_tool_request, request})
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
      send(owner, {:read_pages_request, Jason.decode!(body), get_req_header(conn, "x-api-key")})

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
      send(owner, :failing_read_pages_request)
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
      send(owner, :slow_read_pages_request)
      Process.sleep(150)
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
      send(opts["test_pid"], {:triage_tool_round, step, messages, tools})

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
      send(opts["test_pid"], {:requested_effect_tool, opts["requested_tool"]})

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

      if is_pid(opts["test_pid"]) and not participation? do
        send(opts["test_pid"], {:triage_messages, messages})
        send(opts["test_pid"], {:triage_response_format, opts["response_format"]})
        send(opts["test_pid"], {:triage_max_tokens, opts["max_tokens"]})
        send(opts["test_pid"], {:triage_reasoning_effort, opts["reasoning_effort"]})
        send(opts["test_pid"], {:triage_thinking, opts["thinking"]})
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
      send(opts.owner, {:phase_wire, request})
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
      send(opts["test_pid"], {:premature_final, tools})
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
      send(Process.get(:triage_template_owner), {:resolved_triage_agent, agent_id})
      {:ok, Process.get(:triage_template_config)}
    end
  end

  defmodule TemplateProvider do
    def complete(messages, [], opts) do
      send(opts["test_pid"], {
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
      send(owner, {:subscription_request, command})

      case result do
        {:ok, response} ->
          send(
            reply_to,
            {:subscription, id,
             %{"type" => "data", "data" => Base.encode64(Jason.encode!(response))}}
          )

          send(reply_to, {:subscription, id, %{"type" => "done"}})

        :unavailable ->
          send(
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
    assert_receive {:subscription_request, %{"op" => "/v1/responses"} = request}
    assert request["credential"]["credentials"]["access_token"] == "test-subscription-token"
    refute Map.has_key?(request["credential"]["credentials"], "refresh_token")
    assert proof["request_count"] == 1
    refute proof["provider_payload_bytes"] =~ "test-subscription-token"
    refute_receive {:subscription_request, %{"op" => "/v1/responses"}}
  end

  @tag :subscription_proxy
  test "a failed dispatched Triage request does not spend another subscription account" do
    opts = subscription_proxy_fixture(:unavailable)
    assert {:error, _} = Salix.Bindings.TriageEvaluator.evaluate(model_input(), opts)
    assert_receive {:subscription_request, %{"op" => "/v1/responses"}}
    refute_receive {:subscription_request, %{"op" => "/v1/responses"}}
  end

  defp subscription_proxy_fixture(result) do
    previous =
      Map.new(
        [:llm_resolver, :subscription_worker],
        &{&1, Application.get_env(:salix_agent, &1)}
      )

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:salix_agent, key),
          else: Application.put_env(:salix_agent, key, value)
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
            "credential_kind" => "subscription_oauth",
            "provider" => "codex",
            "disabled" => false,
            "status" => "active",
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

    Application.put_env(:salix_agent, :llm_resolver, ProcessLlmResolver)
    Process.put(:triage_template_owner, self())
    Process.put(:triage_template_config, config)
    worker = start_supervised!({SubscriptionProxyWorker, {self(), result}})
    Application.put_env(:salix_agent, :subscription_worker, worker)
    fence = start_supervised!({ModelRuntimeFence, self()})

    [
      provider: SalixLlm.Provider,
      provider_config: :agent_template,
      identity_fence_handle: %SalixIM.Triage.IdentityFenceHandle{
        runtime: fence,
        capability: make_ref()
      },
      transport_receipt: :single_attempt
    ]
  end

  test "Workbench readiness fails closed for an incomplete identity-bound Agent template" do
    previous_resolver = Application.get_env(:salix_agent, :llm_resolver)
    credential_env = "SALIX_TRIAGE_READINESS_TEST_TOKEN"
    previous_credential = System.get_env(credential_env)

    on_exit(fn ->
      if is_nil(previous_resolver),
        do: Application.delete_env(:salix_agent, :llm_resolver),
        else: Application.put_env(:salix_agent, :llm_resolver, previous_resolver)

      if is_nil(previous_credential),
        do: System.delete_env(credential_env),
        else: System.put_env(credential_env, previous_credential)
    end)

    Application.put_env(:salix_agent, :llm_resolver, ProcessLlmResolver)
    Process.put(:triage_template_owner, self())
    System.delete_env(credential_env)

    Process.put(:triage_template_config, %{
      "protocol" => "chat_completions",
      "base_url" => "https://model.example.test/v1",
      "model" => "template-model",
      "provider" => "openai"
    })

    refute Salix.Bindings.TriageEvaluator.ready?("agent-template-bound")
    assert_receive {:resolved_triage_agent, "agent-template-bound"}

    assert {:ok, %{runtime: %{evaluation_ready: false}}} =
             SalixIM.Triage.ReadModel.ring_status(%{
               runtime: Salix.Bindings.TriageReviewRuntime,
               recovery: nil,
               evaluation_agent_id: "agent-template-bound"
             })

    assert_receive {:resolved_triage_agent, "agent-template-bound"}

    Process.put(:triage_template_config, %{
      "protocol" => "chat_completions",
      "base_url" => "https://model.example.test/v1",
      "api_key_env" => credential_env,
      "model" => "template-model",
      "provider" => "openai"
    })

    refute Salix.Bindings.TriageEvaluator.ready?("agent-template-bound")
    assert_receive {:resolved_triage_agent, "agent-template-bound"}

    assert {:ok, %{runtime: %{evaluation_ready: false}}} =
             SalixIM.Triage.ReadModel.ring_status(%{
               runtime: Salix.Bindings.TriageReviewRuntime,
               recovery: nil,
               evaluation_agent_id: "agent-template-bound"
             })

    assert_receive {:resolved_triage_agent, "agent-template-bound"}

    System.put_env(credential_env, "resolved-template-token")

    assert Salix.Bindings.TriageEvaluator.ready?("agent-template-bound")
    assert_receive {:resolved_triage_agent, "agent-template-bound"}

    assert {:ok, %{runtime: %{evaluation_ready: true}} = status} =
             SalixIM.Triage.ReadModel.ring_status(%{
               runtime: Salix.Bindings.TriageReviewRuntime,
               recovery: nil,
               evaluation_agent_id: "agent-template-bound"
             })

    assert_receive {:resolved_triage_agent, "agent-template-bound"}
    refute inspect(status) =~ "resolved-template-token"
    refute inspect(status) =~ credential_env
    refute inspect(status) =~ "template-model"
    refute inspect(status) =~ "model.example.test"
  end

  test "production evaluator resolves the current identity-bound Agent template token" do
    previous_resolver = Application.get_env(:salix_agent, :llm_resolver)

    on_exit(fn ->
      if is_nil(previous_resolver),
        do: Application.delete_env(:salix_agent, :llm_resolver),
        else: Application.put_env(:salix_agent, :llm_resolver, previous_resolver)
    end)

    Application.put_env(:salix_agent, :llm_resolver, ProcessLlmResolver)
    Process.put(:triage_template_owner, self())

    Process.put(:triage_template_config, %{
      "protocol" => "chat_completions",
      "base_url" => "https://model.example.test/v1",
      "api_key" => "plain-template-token",
      "model" => "template-model",
      "provider" => "openai"
    })

    owner = self()
    fence = start_supervised!({ModelRuntimeFence, owner})

    handle = %SalixIM.Triage.IdentityFenceHandle{
      runtime: fence,
      capability: make_ref()
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
                 "test_pid" => self(),
                 "decision" => decision,
                 "account_pool_tenant" => SalixStore.Ids.new_tenant_id(),
                 "transport" => fn _, _ -> flunk("template transport cannot be overridden") end
               }
             )

    assert_receive {:resolved_triage_agent, "agent-template-bound"}

    assert_receive {:template_provider_config, resolved_config}

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

  test "production evaluator fails closed before provider invocation for an incomplete Agent template" do
    previous_resolver = Application.get_env(:salix_agent, :llm_resolver)

    on_exit(fn ->
      if is_nil(previous_resolver),
        do: Application.delete_env(:salix_agent, :llm_resolver),
        else: Application.put_env(:salix_agent, :llm_resolver, previous_resolver)
    end)

    Application.put_env(:salix_agent, :llm_resolver, ProcessLlmResolver)
    Process.put(:triage_template_owner, self())

    Process.put(:triage_template_config, %{
      "protocol" => "chat_completions",
      "base_url" => "https://model.example.test/v1",
      "model" => "template-model",
      "provider" => "openai"
    })

    fence = start_supervised!({ModelRuntimeFence, self()})

    handle = %SalixIM.Triage.IdentityFenceHandle{
      runtime: fence,
      capability: make_ref()
    }

    assert {:error, :invalid_triage_provider_config} =
             Salix.Bindings.TriageEvaluator.evaluate(model_input(),
               provider: TemplateProvider,
               provider_config: :agent_template,
               identity_fence_handle: handle,
               transport_receipt: :single_attempt,
               provider_opts: %{
                 "test_pid" => self(),
                 "decision" => %{
                   "action" => "silence",
                   "source_refs" => [],
                   "identity_interpretation" => %{
                     "topic" => "none",
                     "referenced_principal_refs" => []
                   }
                 }
               }
             )

    assert_receive {:resolved_triage_agent, "agent-template-bound"}
    refute_receive {:template_provider_config, _config}
  end

  test "single-attempt receipts cannot be enabled without Agent-template authority" do
    assert {:error, :transport_receipt_required} =
             Salix.Bindings.TriageEvaluator.evaluate(model_input(),
               provider: ScriptedProvider,
               transport_receipt: :single_attempt,
               provider_opts: %{
                 "test_pid" => self(),
                 "decision" => %{
                   "action" => "silence",
                   "source_refs" => [],
                   "identity_interpretation" => %{
                     "topic" => "none",
                     "referenced_principal_refs" => []
                   }
                 }
               }
             )

    refute_receive {:triage_messages, _messages}
  end

  test "identity-enabled evaluator rejects a decision without identity interpretation" do
    decision = %{
      "action" => "reply",
      "text" => "I am BFT.",
      "source_refs" => ["bft://projects/project-atlas/agents/agent-router"]
    }

    assert {:error, :invalid_triage_decision} = evaluate(decision)
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

  test "v3 identity input uses the interpretation prompt and rejects nonconforming decisions" do
    decisions = [
      %{
        "action" => "reply",
        "text" => "I am BFT.",
        "source_refs" => ["bft://projects/project-atlas/agents/agent-router"]
      },
      %{
        "action" => "reply",
        "text" => "I am BFT.",
        "source_refs" => ["bft://projects/project-atlas/agents/agent-router"],
        "identity_interpretation" => %{
          "topic" => "not_a_valid_identity_topic",
          "referenced_principal_refs" => []
        }
      }
    ]

    Enum.each(decisions, fn decision ->
      result = evaluate_v3(decision, %{"test_pid" => self()})

      assert_receive {:triage_messages, [%{role: "summary", content: prompt}, %{role: "user"}]}
      assert prompt =~ "identity_interpretation"
      assert {:error, :invalid_triage_decision} = result
    end)
  end

  test "v3 projected identity context accepts the exact interpretation contract" do
    decision = %{
      "action" => "reply",
      "text" => "I am the project router.",
      "source_refs" => ["source://run/s001"],
      "identity_interpretation" => %{
        "topic" => "self_identity",
        "referenced_principal_refs" => ["principal://run/self"]
      }
    }

    assert {:ok, ^decision, proof} =
             evaluate_input(projected_model_input_v3(), decision, %{})

    assert proof["prompt_bytes"] =~ "identity_interpretation"
    assert proof["request_count"] == 1
  end

  test "v3 evaluator requests a strict closed decision and normalizes nullable action fields" do
    provider_decision = %{
      "action" => "silence",
      "text" => nil,
      "reaction" => nil,
      "task" => nil,
      "fact" => nil,
      "source_refs" => [],
      "identity_interpretation" => %{
        "topic" => "none",
        "referenced_principal_refs" => []
      }
    }

    expected_decision =
      Map.drop(provider_decision, ~w(text reaction task fact))

    assert {:ok, ^expected_decision, _proof} =
             evaluate_input(projected_model_input_v3(), provider_decision, %{"test_pid" => self()})

    assert_receive {:triage_response_format,
                    %{
                      "type" => "json_schema",
                      "name" => "comma_triage_decision_v1",
                      "strict" => true,
                      "schema" => schema
                    }}

    assert schema["additionalProperties"] == false

    assert schema["required"] ==
             ~w(action text reaction task fact source_refs identity_interpretation)

    assert get_in(schema, ["properties", "source_refs", "items", "enum"]) ==
             projected_model_input_v3()["source_refs"]

    assert get_in(schema, [
             "properties",
             "identity_interpretation",
             "properties",
             "referenced_principal_refs",
             "items",
             "enum"
           ]) == Enum.sort(projected_identity_context()["principal_refs"])
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
               %{"test_pid" => self()}
             )

    assert_receive {:triage_response_format,
                    %{
                      "name" => "comma_triage_product_decision_v2",
                      "schema" => schema
                    }}

    assert schema["additionalProperties"] == false
    assert get_in(schema, ["properties", "context_candidates", "maxItems"]) == 3
    assert get_in(schema, ["properties", "delegations", "maxItems"]) == 0
  end

  test "scheduled recheck schema admits a sourced resolution but rejects fields from other candidate kinds" do
    input = with_source_mode(periodic_patrol_model_input_v3(), "scheduled_recheck")

    assert {:ok, _decision, _proof} =
             evaluate_input(input, phase_product_decision("silence", false), %{
               "test_pid" => self()
             })

    assert_receive {:triage_response_format, %{"schema" => schema}}

    candidate_schema =
      schema
      |> get_in(["properties", "context_candidates", "items"])
      |> ExJsonSchema.Schema.resolve()

    [first_ref, second_ref | _] = input["source_refs"]

    resolution = %{
      "kind" => "follow_up_resolution",
      "subject" => "codex-3720 runtime recovery",
      "value" => "The requester confirmed the failure was fixed.",
      "confidence" => "explicit",
      "source_refs" => [first_ref, second_ref],
      "knowledge_scope" => nil,
      "follow_up_ref" => nil,
      "follow_up_action" => nil,
      "follow_up_basis" => nil,
      "resolution_basis" => "source_confirmation",
      "recheck_after_hours" => nil
    }

    assert :ok = ExJsonSchema.Validator.validate(candidate_schema, resolution)

    assert {:ok, _decision, _proof} =
             evaluate_input(
               input,
               %{
                 phase_product_decision("silence", false)
                 | "context_candidates" => [
                     Map.drop(
                       resolution,
                       ~w(knowledge_scope follow_up_ref follow_up_action follow_up_basis recheck_after_hours)
                     )
                   ]
               },
               %{"test_pid" => self()}
             )

    for invalid <- [
          %{resolution | "follow_up_ref" => first_ref},
          %{resolution | "knowledge_scope" => "project"},
          %{resolution | "confidence" => "inferred"},
          %{resolution | "source_refs" => [first_ref]}
        ] do
      assert {:error, _} = ExJsonSchema.Validator.validate(candidate_schema, invalid)
    end
  end

  test "ordinary intake rejects direct reactions and compound public replies" do
    input = phase_model_input()
    assignment = phase_product_decision("silence", true)
    reaction = %{"kind" => "reaction", "emoji" => "tada", "source_refs" => ["source://run/s003"]}

    for decision <- [
          Map.put(assignment, "communication", reaction),
          Map.put(phase_product_decision("reply", true), "companion_reaction", reaction),
          Map.put(assignment, "companion_reaction", reaction)
        ] do
      assert {:error, :invalid_triage_decision} =
               evaluate_input(input, decision, %{"test_pid" => self()})

      assert_receive {:triage_response_format, %{"schema" => %{"properties" => properties}}}
      assert properties["communication"]["properties"]["kind"]["enum"] == ["silence"]
      assert properties["companion_reaction"] == %{"type" => "null"}
      assert properties["delegations"]["minItems"] == 1
    end
  end

  test "scheduled recheck expression context reaches the response schema and authorizes a custom companion reaction" do
    decision = %{
      "schema" => "comma.triage-product-decision.v2",
      "communication" => %{
        "kind" => "reply",
        "text" => "Ship it.",
        "source_refs" => ["source://run/s003"]
      },
      "companion_reaction" => %{
        "kind" => "reaction",
        "emoji" => "party_parrot",
        "source_refs" => ["source://run/s003"]
      },
      "context_candidates" => [],
      "delegations" => [],
      "identity_interpretation" => %{
        "topic" => "none",
        "referenced_principal_refs" => []
      }
    }

    model_input = with_source_mode(clickhouse_expression_model_input_v3(), "scheduled_recheck")

    assert {:ok, ^decision, _proof} =
             evaluate_input(model_input, decision, %{"test_pid" => self()})

    assert_receive {:triage_response_format,
                    %{
                      "schema" => %{
                        "properties" => %{
                          "companion_reaction" => %{"anyOf" => companion_variants}
                        }
                      }
                    }}

    reaction_schema =
      Enum.find(companion_variants, fn variant ->
        get_in(variant, ["properties", "kind", "enum"]) == ["reaction"]
      end)

    assert "party_parrot" in get_in(reaction_schema, ["properties", "emoji", "enum"])

    assert get_in(reaction_schema, ["properties", "source_refs", "items", "enum"]) == [
             "source://run/s003"
           ]

    assert {:error, :invalid_triage_decision} =
             evaluate_input(
               model_input,
               put_in(decision, ["companion_reaction", "emoji"], "invented_custom"),
               %{"test_pid" => self()}
             )
  end

  test "directed agent self mentions require a Worker instead of a native reply" do
    input = product_target(phase_model_input(), "agent", "self")

    assert {:error, :invalid_triage_decision} =
             evaluate_input(input, phase_product_decision("reply", true), %{})

    assignment = phase_product_decision("silence", true)
    assert {:ok, ^assignment, _} = evaluate_input(input, assignment, %{"test_pid" => self()})
    assert_receive {:triage_response_format, %{"schema" => %{"properties" => properties}}}
    assert properties["delegations"]["minItems"] == 1
    assert properties["delegations"]["maxItems"] == 1
  end

  test "ClickHouse intake only selects a Worker and describes the observed batch" do
    input = phase_model_input()
    assignment = phase_product_decision("silence", true)
    assert {:ok, ^assignment, proof} = evaluate_input(input, assignment, %{"test_pid" => self()})
    assert proof["policy_bytes"] =~ "triage-worker-assignment-v1"
    assert_receive {:triage_response_format, %{"schema" => %{"properties" => properties}}}
    assert properties["context_candidates"]["maxItems"] == 0
    assert properties["delegations"]["minItems"] == 1
    assert properties["delegations"]["maxItems"] == 1
  end

  test "schema-valid multilingual assessment survives evaluator validation without taking another recipient's work" do
    input = clickhouse_expression_model_input_v3() |> product_target("human", "other")
    decision = assessment_decision(String.duplicate("已检查来源。", 100))

    assert {:ok, accepted, proof} = evaluate_input(input, decision, %{"test_pid" => self()})
    assert accepted["assessment"] == decision["assessment"]
    assert accepted["communication"]["reason"] == "outside_authority"
    assert accepted["delegations"] == []
    assert proof["request_count"] == 1
  end

  test "assessment rejection identifies the failed field without logging private values" do
    input = clickhouse_expression_model_input_v3() |> product_target("human", "other")
    private_text = "PRIVATE_ASSESSMENT_CANARY " <> String.duplicate("字", 1201)
    decision = assessment_decision(private_text)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :invalid_triage_decision} =
                 evaluate_input(input, decision, %{"test_pid" => self()})
      end)

    assert log =~ "check=assessment_available_evidence"
    assert log =~ "reason=too_long"
    refute log =~ "PRIVATE_ASSESSMENT_CANARY"
    refute log =~ "source://run/"
    assert byte_size(log) < 3000
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
             evaluate_input(model_input, provider_proposal, %{"test_pid" => self()})

    assert decision["communication"] == %{
             "kind" => "silence",
             "reason" => "outside_authority",
             "explanation" =>
               "This message explicitly addresses another recipient. Triage does not take over their reply.",
             "source_refs" => []
           }

    assert decision["delegations"] == []
    assert [%{"subject" => "atlas-owner"}] = decision["context_candidates"]

    assert_receive {:triage_response_format,
                    %{
                      "schema" => %{
                        "properties" => %{
                          "communication" => communication,
                          "delegations" => %{"maxItems" => 0}
                        }
                      }
                    }}

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
             evaluate_input(model_input, provider_proposal, %{"test_pid" => self()})

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

  test "periodic patrol bounds the full-agent output budget without changing ordinary Triage" do
    decision = phase_product_decision("silence", true)

    assert {:ok, ^decision, _proof} =
             evaluate_input(
               with_source_mode(phase_model_input(), "periodic_patrol"),
               decision,
               %{
                 "max_tokens" => 65_536,
                 "reasoning_effort" => "high",
                 "thinking" => %{"type" => "adaptive"},
                 "test_pid" => self()
               }
             )

    assert_receive {:triage_max_tokens, 16_384}
    assert_receive {:triage_reasoning_effort, "medium"}
    assert_receive {:triage_thinking, nil}

    ordinary = %{
      "action" => "silence",
      "source_refs" => [],
      "identity_interpretation" => %{
        "topic" => "none",
        "referenced_principal_refs" => []
      }
    }

    assert {:ok, ^ordinary, _proof} =
             evaluate_input(
               projected_model_input_v3(),
               ordinary,
               %{
                 "max_tokens" => 65_536,
                 "reasoning_effort" => "high",
                 "thinking" => %{"type" => "adaptive"},
                 "test_pid" => self()
               }
             )

    assert_receive {:triage_max_tokens, 65_536}
    assert_receive {:triage_reasoning_effort, "high"}
    assert_receive {:triage_thinking, %{"type" => "adaptive"}}
  end

  test "periodic patrol accepts one exact JSON code fence and rejects prose around it" do
    decision = phase_product_decision("silence", true)

    json = Jason.encode!(decision)

    assert {:ok, ^decision, _proof} =
             evaluate_input(
               with_source_mode(phase_model_input(), "periodic_patrol"),
               decision,
               %{"raw_content" => "```json\n#{json}\n```"}
             )

    assert {:error, :invalid_triage_decision} =
             evaluate_input(
               with_source_mode(phase_model_input(), "periodic_patrol"),
               decision,
               %{"raw_content" => "Here is the result:\n```json\n#{json}\n```"}
             )

    assert {:error, :invalid_triage_decision} =
             evaluate_input(
               with_source_mode(phase_model_input(), "periodic_patrol"),
               decision,
               %{"raw_content" => "```json\n#{json}\n```\nextra"}
             )
  end

  test "periodic patrol does not expose the interactive prior-run detail tool" do
    decision = phase_product_decision("silence", true)

    assert {:ok, ^decision, proof} =
             Salix.Bindings.TriageEvaluator.evaluate(
               with_source_mode(phase_model_input(), "periodic_patrol"),
               provider: ScriptedProvider,
               provider_opts: %{"decision" => decision, "test_pid" => self()},
               read_tool_context: history_read_tool_context(),
               transport_receipt: fn payload_bytes ->
                 %{payload_sha256: sha256(payload_bytes), request_count: 1}
               end
             )

    assert proof["request_count"] == 1
    assert_receive {:triage_messages, _messages}
    assert_receive {:triage_response_format, _format}
  end

  test "v3 tool-required triage uses one disclosed read-only tool before its final decision" do
    {:ok, script} = Agent.start_link(fn -> 0 end)
    {:ok, server} = Bandit.start_link(plug: {ReadPagePlug, self()}, port: 0, startup_log: false)
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    previous_base = Application.get_env(:salix_agent, :exa_base_url)
    previous_key = Application.get_env(:salix_agent, :exa_api_key)
    Application.put_env(:salix_agent, :exa_base_url, "http://127.0.0.1:#{port}")
    Application.put_env(:salix_agent, :exa_api_key, "triage-test-key")

    on_exit(fn ->
      Process.exit(server, :shutdown)
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
                 "test_pid" => self()
               },
               read_tool_context: tool_context,
               transport_receipt: fn payload_bytes ->
                 %{payload_sha256: sha256(payload_bytes), request_count: 1}
               end
             )

    assert_receive {:triage_tool_round, 0, _messages, [%{"name" => "call"}]}

    assert_receive {:read_pages_request,
                    %{
                      "urls" => ["https://example.test/launch-brief"],
                      "text" => %{"maxCharacters" => 10_000}
                    }, ["triage-test-key"]}

    assert_receive {:triage_tool_round, 1, second_messages, []}

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

  test "an approved cross-channel Task permalink retains its visible result in the model tool response" do
    context = slack_permalink_tool_context!()
    approve_permalink_channel!(context, "C_TASKS")

    context =
      put_in(
        context,
        [:link_targets, Access.at(0), "resolved_url"],
        "https://atlas.slack.com/archives/C_TASKS/p1787019000000001"
      )

    install_slack_permalink_transport!(
      messages: [
        %{
          "ts" => "1787019000.000001",
          "text" => "Task Review PR #67: ready for review",
          "blocks" => [
            %{
              "type" => "task_card",
              "title" => "Review PR #67",
              "status" => "complete",
              "task_id" => "PRIVATE_TASK_ID",
              "output" => %{
                "type" => "rich_text",
                "elements" => [
                  %{
                    "type" => "rich_text_section",
                    "elements" => [
                      %{
                        "type" => "text",
                        "text" => "Approved at f231813; no blockers. Nothing merged or deployed."
                      }
                    ]
                  }
                ]
              }
            }
          ]
        }
      ]
    )

    assert {:ok, _decision, proof} = evaluate_slack_permalink(context)

    assert_receive {:slack_permalink_request, "conversations.history",
                    %{"channel" => "C_TASKS", "limit" => "1"}}

    assert_receive {:triage_tool_round, 1, messages, []}
    tool_result = Enum.find(messages, &(&1[:role] == "tool"))
    assert tool_result.content =~ "Approved at f231813; no blockers. Nothing merged or deployed."
    assert tool_result.content =~ "output_complete"
    refute tool_result.content =~ "PRIVATE_TASK_ID"
    assert proof["tool_call_count"] == 1
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
                 "test_pid" => self(),
                 "read_tool" => "triage.slack_read_permalink",
                 "read_params" => %{"link_ref" => "link://run/l001"}
               },
               read_tool_context: tool_context,
               transport_receipt: fn bytes ->
                 %{payload_sha256: sha256(bytes), request_count: 1}
               end
             )

    assert_receive {:slack_permalink_request, "auth.test", _}
    assert_receive {:slack_permalink_request, "conversations.history", params}
    assert params["channel"] == "C_ATLAS"
    assert params["oldest"] == "1787019000.000001"
    assert params["latest"] == "1787019000.000001"
    assert params["inclusive"] == "true"
    assert params["limit"] == "1"
    assert_receive {:triage_tool_round, 1, messages, []}
    tool_result = Enum.find(messages, &(&1[:role] == "tool"))
    assert tool_result.content =~ "approved for Tuesday after the owner check"
    refute tool_result.content =~ "U024BE7LH"
    refute Jason.encode!(messages) =~ "atlas.slack.com"
    assert proof["tool_names"] == ["triage.slack_read_permalink"]
    assert proof["tool_call_count"] == 1
    assert proof["request_count"] == 2
    refute_receive {:read_pages_request, _, _}
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
      refute_receive {:slack_permalink_request, "contents", _}

      if unquote(read?) do
        assert_receive {:slack_permalink_request, "conversations.history", _}
      else
        refute_receive {:slack_permalink_request, "conversations.history", _}
        refute_receive {:slack_permalink_request, "conversations.replies", _}
      end
    end
  end

  test "a permalink in another approved channel reads the exact target through the same installation" do
    context = slack_permalink_tool_context!()
    approve_permalink_channel!(context, "C_TASKS")

    context =
      put_in(
        context,
        [:link_targets, Access.at(0), "resolved_url"],
        "https://atlas.slack.com/archives/C_TASKS/p1787019000000001"
      )

    install_slack_permalink_transport!()
    assert {:ok, _, proof} = evaluate_slack_permalink(context)
    assert [%{"status" => "completed"}] = proof["tool_receipts"]

    assert_receive {:slack_permalink_request, "conversations.history",
                    %{"channel" => "C_TASKS", "limit" => "1"}}

    refute_receive {:slack_permalink_request, "conversations.history", _}
    assert proof["tool_call_count"] == 1
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
      assert_receive {:slack_permalink_request, "auth.test", _}
      refute_receive {:slack_permalink_request, "conversations.history", _}
      refute_receive {:slack_permalink_request, "conversations.replies", _}
    end
  end

  test "stale mirror evidence is not reported as a successfully read message" do
    context = slack_permalink_tool_context!()
    install_slack_permalink_transport!()
    Application.put_env(:salix_agent, :im_provider_mod, StaleMirrorProvider)
    assert {:ok, _, proof} = evaluate_slack_permalink(context)
    assert [%{"status" => "error"} = receipt] = proof["tool_receipts"]
    assert receipt["canonical_result_bytes"] =~ "slack_exact_message_unavailable"
    refute receipt["canonical_result_bytes"] =~ "outdated"
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
    assert_receive {:slack_permalink_request, "auth.test", _}
    refute_receive {:slack_permalink_request, "conversations.history", _}
    refute_receive {:slack_permalink_request, "conversations.replies", _}
  end

  test "a reply permalink reads only its exact timestamp under the supplied parent" do
    context = slack_permalink_tool_context!()

    context =
      update_in(
        context,
        [:link_targets, Access.at(0), "resolved_url"],
        &(&1 <> "?thread_ts=1787018999.000000&cid=C_ATLAS")
      )

    install_slack_permalink_transport!()
    assert {:ok, _, proof} = evaluate_slack_permalink(context)
    assert [%{"status" => "completed"}] = proof["tool_receipts"]

    assert_receive {:slack_permalink_request, "conversations.replies",
                    %{
                      "ts" => "1787018999.000000",
                      "oldest" => "1787019000.000001",
                      "latest" => "1787019000.000001",
                      "limit" => "1",
                      "inclusive" => "true"
                    }}

    refute_receive {:slack_permalink_request, "conversations.history", _}
  end

  test "Chat Completions product intake retains identity validation without a read phase" do
    {:ok, script} = Agent.start_link(fn -> 0 end)

    decision = phase_product_decision("silence", true)

    {:ok, read_server} =
      Bandit.start_link(plug: {EmptyReadPagePlug, self()}, port: 0, startup_log: false)

    {:ok, chat_server} =
      Bandit.start_link(
        plug: {ChatCompletionsToolPlug, %{owner: self(), decision: decision, script: script}},
        port: 0,
        startup_log: false
      )

    {:ok, {_address, read_port}} = ThousandIsland.listener_info(read_server)
    {:ok, {_address, chat_port}} = ThousandIsland.listener_info(chat_server)
    previous_base = Application.get_env(:salix_agent, :exa_base_url)
    previous_key = Application.get_env(:salix_agent, :exa_api_key)
    Application.put_env(:salix_agent, :exa_base_url, "http://127.0.0.1:#{read_port}")
    Application.put_env(:salix_agent, :exa_api_key, "triage-test-key")

    on_exit(fn ->
      Process.exit(read_server, :shutdown)
      Process.exit(chat_server, :shutdown)
      restore_env(:exa_base_url, previous_base)
      restore_env(:exa_api_key, previous_key)
    end)

    model_input = phase_model_input()

    assert {:ok, ^decision, raw_proof} =
             Salix.Bindings.TriageEvaluator.evaluate(model_input,
               provider: SalixLlm.Provider,
               provider_name: "openai",
               provider_opts: %{
                 "protocol" => "chat_completions",
                 "base_url" => "http://127.0.0.1:#{chat_port}",
                 "api_key" => "triage-chat-key",
                 "model" => "gpt-5.6-terra"
               },
               read_tool_context: read_only_tool_context(),
               transport_receipt: fn payload_bytes ->
                 %{payload_sha256: sha256(payload_bytes), request_count: 1}
               end
             )

    refute_receive :empty_read_pages_request
    assert_receive {:chat_tool_request, request}
    assert request["tools"] in [nil, []]
    refute_receive {:chat_tool_request, _}, 0
    assert raw_proof["request_count"] == 1

    assert {:ok, ^decision, _validated_proof} =
             Pipeline.validate_model_result(model_input, decision, raw_proof, :unused)
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

  # Tool-result bytes used to bypass every privacy gate except the URL one, and
  # even that collapsed every distinct URL onto the authorized `link_ref` — so
  # the model read an unrelated mirror as if it were the one source this run was
  # authorized to read.
  test "a fetched page crosses the projected-text privacy gate before the second payload" do
    {:ok, script} = Agent.start_link(fn -> 0 end)

    {:ok, server} =
      Bandit.start_link(plug: {LeakyReadPagePlug, self()}, port: 0, startup_log: false)

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    previous_base = Application.get_env(:salix_agent, :exa_base_url)
    previous_key = Application.get_env(:salix_agent, :exa_api_key)
    Application.put_env(:salix_agent, :exa_base_url, "http://127.0.0.1:#{port}")
    Application.put_env(:salix_agent, :exa_api_key, "triage-test-key")

    on_exit(fn ->
      Process.exit(server, :shutdown)
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

    assert {:ok, ^decision, proof} =
             Salix.Bindings.TriageEvaluator.evaluate(tool_required_model_input_v3(),
               provider: ToolCallingProvider,
               provider_opts: %{
                 "decision" => decision,
                 "script" => script,
                 "test_pid" => self()
               },
               read_tool_context: read_only_tool_context(),
               transport_receipt: fn payload_bytes ->
                 %{payload_sha256: sha256(payload_bytes), request_count: 1}
               end
             )

    assert_receive {:triage_tool_round, 0, _first_messages, [%{"name" => "call"}]}
    assert_receive {:read_pages_request, _request, _key}
    assert_receive {:triage_tool_round, 1, second_messages, []}

    tool_content =
      Enum.find_value(second_messages, fn
        %{role: "tool", content: content} -> content
        _other -> nil
      end)

    # Authorized names and locators remain usable evidence. The separate
    # tool-authority tests still reject URLs that are not frozen run links.
    assert tool_content =~ "ops@example.test"
    assert tool_content =~ "123e4567"
    assert tool_content =~ "/var/secrets/launch"
    assert tool_content =~ "U024BE7LH"
    assert tool_content =~ "U0123ABCD"
    assert tool_content =~ "mirror.example.test"
    assert tool_content =~ "https://"
    refute tool_content =~ "link://page/"

    # The durable receipt binds exactly the text shown to the model.
    receipt = proof["tool_receipts"] |> List.first()
    assert {:ok, %{"content" => stored}} = Jason.decode(receipt["canonical_result_bytes"])
    assert stored == tool_content
    assert stored =~ "ops@example.test"
  end

  # An authorized read tool is a permission, not an obligation. The fence mints
  # a single-use authorization; if the model already has enough frozen context
  # to decide, that authorization simply expires uncommitted and the run settles
  # on the direct single-request proof. Refusing the answer turned a legitimate
  # zero-tool-call decision into `invalid_triage_model_result`.
  test "v3 link-authorized triage settles a first-round final that used no read tool" do
    assert {:ok, decision, proof} =
             evaluate_premature_final(tool_required_model_input_v3(), read_only_tool_context())

    assert decision["action"] == "silence"
    assert proof["schema"] == "comma.triage-model-proof.v1"
    assert proof["request_count"] == 1
    assert proof["retry"] == false
    refute Map.has_key?(proof, "tool_receipts")

    assert_receive {:premature_final, [%{"name" => "call", "input_schema" => schema}]}
    assert schema["properties"]["tool"]["enum"] == ["web.read_pages"]
  end

  test "v3 history-authorized triage settles a first-round final that used no read tool" do
    assert {:ok, decision, proof} =
             evaluate_premature_final(projected_model_input_v3(), history_read_tool_context())

    assert decision["action"] == "silence"
    assert proof["schema"] == "comma.triage-model-proof.v1"
    refute Map.has_key?(proof, "tool_receipts")

    assert_receive {:premature_final, [%{"name" => "call", "input_schema" => schema}]}
    assert schema["properties"]["tool"]["enum"] == ["triage_run.get"]
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

  test "identity-enabled evaluator rejects a source outside the frozen closure" do
    decision = %{
      "action" => "reply",
      "text" => "I am BFT.",
      "source_refs" => ["meeting://invented/fact"],
      "identity_interpretation" => %{
        "topic" => "self_identity",
        "referenced_principal_refs" => ["comma-agent://agt1_atlas_router"]
      }
    }

    assert {:error, :invalid_triage_decision} = evaluate(decision)
  end

  test "identity read failure is returned once to the model without transport retry" do
    {:ok, script} = Agent.start_link(fn -> 0 end)

    {:ok, server} =
      Bandit.start_link(plug: {FailingReadPagePlug, self()}, port: 0, startup_log: false)

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    previous_base = Application.get_env(:salix_agent, :exa_base_url)
    previous_key = Application.get_env(:salix_agent, :exa_api_key)
    Application.put_env(:salix_agent, :exa_base_url, "http://127.0.0.1:#{port}")
    Application.put_env(:salix_agent, :exa_api_key, "triage-test-key")

    on_exit(fn ->
      Process.exit(server, :shutdown)
      restore_env(:exa_base_url, previous_base)
      restore_env(:exa_api_key, previous_key)
    end)

    decision = %{
      "action" => "delegate",
      "task" => "Confirm the linked source is available before answering.",
      "source_refs" => ["source://run/s001"],
      "identity_interpretation" => %{
        "topic" => "none",
        "referenced_principal_refs" => []
      }
    }

    assert {:ok, ^decision, proof} =
             Salix.Bindings.TriageEvaluator.evaluate(tool_required_model_input_v3(),
               provider: ToolCallingProvider,
               provider_opts: %{
                 "decision" => decision,
                 "script" => script,
                 "test_pid" => self()
               },
               read_tool_context: read_only_tool_context(true),
               transport_receipt: fn payload_bytes ->
                 %{payload_sha256: sha256(payload_bytes), request_count: 1}
               end
             )

    assert_receive :failing_read_pages_request
    refute_receive :failing_read_pages_request, 100
    assert_receive {:triage_tool_round, 1, second_messages, []}

    assert Enum.any?(second_messages, fn
             %{role: "tool", content: content} ->
               content =~ "temporarily unavailable"

             _other ->
               false
           end)

    [receipt] = proof["tool_receipts"]
    assert receipt["status"] == "error"
    assert receipt["error"] == true
    assert receipt["error_class"] == "tool_error"
    assert proof["request_count"] == 2
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
                   "test_pid" => self()
                 },
                 read_tool_context: read_only_tool_context(true),
                 transport_receipt: fn payload_bytes ->
                   %{payload_sha256: sha256(payload_bytes), request_count: 1}
                 end
               )

      assert_receive {:requested_effect_tool, ^tool_name}
    end

    refute_receive {:read_pages_request, _, _}, 50
  end

  test "identity read timeout is frozen once and followed by an honest bounded delegate" do
    {:ok, script} = Agent.start_link(fn -> 0 end)

    {:ok, server} =
      Bandit.start_link(plug: {SlowReadPagePlug, self()}, port: 0, startup_log: false)

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    previous_base = Application.get_env(:salix_agent, :exa_base_url)
    previous_key = Application.get_env(:salix_agent, :exa_api_key)
    previous_timeouts = Application.get_env(:salix_agent, :tool_timeouts)
    Application.put_env(:salix_agent, :exa_base_url, "http://127.0.0.1:#{port}")
    Application.put_env(:salix_agent, :exa_api_key, "triage-test-key")
    Application.put_env(:salix_agent, :tool_timeouts, %{"web.read_pages" => 25})

    on_exit(fn ->
      Process.exit(server, :shutdown)
      restore_env(:exa_base_url, previous_base)
      restore_env(:exa_api_key, previous_key)
      restore_env(:tool_timeouts, previous_timeouts)
    end)

    decision = %{
      "action" => "delegate",
      "task" => "Retry source verification later; do not infer unavailable content.",
      "source_refs" => ["source://run/s001"],
      "identity_interpretation" => %{
        "topic" => "none",
        "referenced_principal_refs" => []
      }
    }

    assert {:ok, ^decision, proof} =
             Salix.Bindings.TriageEvaluator.evaluate(tool_required_model_input_v3(),
               provider: ToolCallingProvider,
               provider_opts: %{
                 "decision" => decision,
                 "script" => script,
                 "test_pid" => self()
               },
               read_tool_context: read_only_tool_context(true),
               transport_receipt: fn payload_bytes ->
                 %{payload_sha256: sha256(payload_bytes), request_count: 1}
               end
             )

    assert_receive :slow_read_pages_request
    refute_receive :slow_read_pages_request, 100
    assert_receive {:triage_tool_round, 1, second_messages, []}

    assert Enum.any?(second_messages, fn
             %{role: "tool", content: content} -> content =~ "timed out"
             _other -> false
           end)

    [receipt] = proof["tool_receipts"]
    assert receipt["status"] == "error"
    assert receipt["error"] == true
    assert receipt["error_class"] == "timeout"
    assert proof["request_count"] == 2
  end

  test "identity-enabled evaluator rejects remember over an identity-specific source" do
    decision = %{
      "action" => "remember",
      "fact" => "BFT is the router agent.",
      "source_refs" => ["bft://projects/project-atlas/agents/agent-router"],
      "identity_interpretation" => %{
        "topic" => "none",
        "referenced_principal_refs" => []
      }
    }

    assert {:error, :invalid_triage_decision} = evaluate(decision)
  end

  defp evaluate(decision, provider_opts \\ %{}) do
    evaluate_input(model_input(), decision, provider_opts)
  end

  defp evaluate_v3(decision, provider_opts) do
    evaluate_input(model_input_v3(), decision, provider_opts)
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
      assert_receive {:phase_wire, wire}
      refute_receive {:phase_wire, _}, 0
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

  test "assessment types and closed references reach advisory providers over HTTP" do
    input = clickhouse_expression_model_input_v3() |> product_target("human", "other")
    decision = assessment_decision("已检查来源。")
    assessment = decision["assessment"]

    for protocol <- ~w(chat_completions anthropic) do
      assert {:ok, accepted, _proof} = phase_http_evaluate(input, protocol, [decision])
      assert accepted["assessment"] == assessment
      assert accepted["communication"]["reason"] == "outside_authority"
      assert accepted["delegations"] == []
      assert_receive {:phase_wire, wire}
      refute Map.has_key?(wire, "response_format")

      system =
        if protocol == "anthropic" do
          Enum.map_join(wire["system"], "\n", & &1["text"])
        else
          wire["messages"]
          |> Enum.filter(&(&1["role"] in ["system", "developer"]))
          |> Enum.map_join("\n", & &1["content"])
        end

      assert [_, encoded | _] = String.split(system, "```json\n", parts: 2)
      schema = encoded |> String.split("\n```", parts: 2) |> hd() |> Jason.decode!()
      fields = get_in(schema, ["properties", "assessment", "properties"])
      assert fields["unavailable_input"]["type"] == "string"
      assert fields["requested_outcome"]["type"] == "string"
      assert fields["available_evidence"]["type"] == "string"

      assert Enum.sort(fields["unread_source_refs"]["items"]["enum"]) ==
               Enum.sort(input["source_refs"])
    end

    for bad_assessment <- [
          Map.put(assessment, "unavailable_input", nil),
          Map.put(assessment, "unread_source_refs", ["link://run/l001"])
        ] do
      assert {:error, :invalid_triage_decision} =
               phase_http_evaluate(input, "chat_completions", [
                 Map.put(decision, "assessment", bad_assessment)
               ])

      assert_receive {:phase_wire, _}
      refute_receive {:phase_wire, _}, 0
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

      assert_receive {:phase_wire, _}
      refute_receive {:phase_wire, _}, 0
    end
  end

  test "single-call proof rejects extra requests and changed snapshot" do
    input = phase_model_input()
    decision = phase_product_decision("silence", true)
    assert {:ok, ^decision, raw} = phase_http_evaluate(input, "responses", [decision])

    changed =
      raw["provider_payload_bytes"] |> Jason.decode!() |> Map.put("input", []) |> Jason.encode!()

    changed_proof =
      raw
      |> Map.put("provider_payload_bytes", changed)
      |> Map.put("observer_payload_sha256", sha256(changed))
      |> Map.put("transport_payload_sha256", sha256(changed))

    for malformed <- [
          Map.put(raw, "request_count", 2),
          Map.put(raw, "retry", true),
          changed_proof
        ] do
      assert {:error, :invalid_model_proof} =
               Pipeline.validate_model_result(input, decision, malformed, :unused)
    end
  end

  test "product intake exposes no read tool even when a read context exists" do
    input = phase_model_input()
    decision = phase_product_decision("silence", true)

    for protocol <- ~w(responses chat_completions anthropic) do
      assert {:ok, ^decision, raw} =
               phase_http_evaluate(input, protocol, [decision], read_only_tool_context())

      assert raw["request_count"] == 1
      assert_receive {:phase_wire, wire}
      assert wire["tools"] in [nil, []]
      refute_receive {:read_pages_request, _, _}, 0

      assert {:error, :invalid_triage_read_tool_call} =
               phase_http_evaluate(input, protocol, [:read], read_only_tool_context())

      assert_receive {:phase_wire, _}
      refute_receive {:phase_wire, _}, 0
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
        plug: {PhaseResponsePlug, %{owner: self(), script: script, protocol: protocol}},
        port: 0,
        startup_log: false
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    Process.unlink(server)

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
      Process.exit(server, :shutdown)
      Agent.stop(script)
    end
  end

  defp assessment_decision(evidence) do
    %{
      "schema" => "comma.triage-product-decision.v2",
      "assessment" => %{
        "requested_outcome" => "Explain the reported error",
        "available_evidence" => evidence,
        "unread_source_refs" => [],
        "unavailable_input" => ""
      },
      "communication" => %{
        "kind" => "silence",
        "reason" => "outside_authority",
        "source_refs" => []
      },
      "companion_reaction" => nil,
      "context_candidates" => [],
      "delegations" => [],
      "identity_interpretation" => %{"topic" => "none", "referenced_principal_refs" => []}
    }
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

  defp model_input_v3 do
    v2 = model_input()
    snapshot = Map.put(v2["snapshot"], "schema", "comma.triage-context-snapshot.v5")

    v2
    |> Map.put("schema", "comma.triage-model-input.v3")
    |> Map.put("snapshot", snapshot)
    |> Map.put(
      "canonical_snapshot_bytes",
      SalixIM.Triage.CanonicalJSON.encode!(snapshot)
    )
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

  defp clickhouse_expression_model_input_v3 do
    model_input = clickhouse_product_model_input_v3()

    {:ok, expression_context} =
      SalixIM.Triage.ExpressionContext.build(
        "social",
        {:ok, %{"party_parrot" => "provider-owned-url"}}
      )

    snapshot =
      model_input["snapshot"]
      |> Map.put("schema", "comma.triage-context-snapshot.v7")
      |> put_in(["slack_context", "expression_context"], expression_context)

    model_input
    |> Map.put("snapshot", snapshot)
    |> Map.put("canonical_snapshot_bytes", SalixIM.Triage.CanonicalJSON.encode!(snapshot))
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
        {Bandit, plug: {SlackPermalinkPlug, {self(), options}}, port: 0, startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    previous =
      for {app, key, value} <- [
            {:salix_im, :slack_api_base_url, "http://127.0.0.1:#{port}/api"},
            {:salix_agent, :im_provider_mod, SalixIM.Provider},
            {:salix_agent, :exa_base_url, "http://127.0.0.1:#{port}"},
            {:salix_im, :slack_message_mirror_mod, SalixIM.SlackMessageMirror.Noop}
          ] do
        old = Application.get_env(app, key)
        Application.put_env(app, key, value)
        {app, key, old}
      end

    on_exit(fn ->
      for {app, key, old} <- previous do
        if is_nil(old),
          do: Application.delete_env(app, key),
          else: Application.put_env(app, key, old)
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
        "test_pid" => self(),
        "read_tool" => "triage.slack_read_permalink",
        "read_params" => %{"link_ref" => "link://run/l001"}
      },
      read_tool_context: context,
      transport_receipt: fn bytes -> %{payload_sha256: sha256(bytes), request_count: 1} end
    )
  end

  defp slack_permalink_tool_context! do
    alias SalixStore.{CasRecord, Ids, Keys, ULID}
    unless Process.whereis(Ids), do: start_supervised!(Ids)
    unless Process.whereis(SalixStore.S3.Fake), do: start_supervised!(SalixStore.S3.Fake)
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

  defp evaluate_premature_final(model_input, read_tool_context) do
    decision = %{
      "action" => "silence",
      "source_refs" => [],
      "identity_interpretation" => %{
        "topic" => "none",
        "referenced_principal_refs" => []
      }
    }

    Salix.Bindings.TriageEvaluator.evaluate(model_input,
      provider: PrematureFinalProvider,
      provider_opts: %{"decision" => decision, "test_pid" => self()},
      read_tool_context: read_tool_context,
      transport_receipt: fn payload_bytes ->
        %{payload_sha256: sha256(payload_bytes), request_count: 1}
      end
    )
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

  defp restore_env(key, nil), do: Application.delete_env(:salix_agent, key)
  defp restore_env(key, value), do: Application.put_env(:salix_agent, key, value)

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
