defmodule SalixAgent.SubscriptionWorkerTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false
  alias SalixAgent.{SubscriptionWorker, AccountPool, SubscriptionStore}

  defmodule BackgroundClient do
    use SystemsRuntime.Server

    def start_link(opts), do: SystemsRuntime.Server.start_link(__MODULE__, nil, opts)
    def init(nil), do: {:ok, nil}

    def handle_call(:worker, _from, state),
      do: {:reply, SubscriptionWorker.server(), state}
  end

  defmodule Upstream do
    def init(owner), do: owner

    def call(%{request_path: "/oauth/token"} = conn, owner) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      SystemsRuntime.Proc.send(owner, {:refresh, URI.decode_query(body)})

      claims =
        Base.url_encode64(Jason.encode!(%{"email" => "refreshed@example.com"}), padding: false)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "access_token" => "rotated-access",
          "refresh_token" => "rotated-refresh",
          "expires_in" => 3600,
          "id_token" => "header." <> claims <> ".signature"
        })
      )
    end

    # Antigravity serves Gemini through Cloud Code SSE, also for blocking calls.
    def call(%{request_path: "/v1internal:" <> _} = conn, owner) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      SystemsRuntime.Proc.send(owner, {:upstream, conn.request_path, Jason.decode!(body)})

      event = %{
        "response" => %{
          "candidates" => [
            %{
              "content" => %{"role" => "model", "parts" => [%{"text" => "Hello"}]},
              "finishReason" => "STOP"
            }
          ],
          "usageMetadata" => %{
            "promptTokenCount" => 3,
            "candidatesTokenCount" => 1,
            "totalTokenCount" => 4
          },
          "modelVersion" => "gemini-3-flash"
        }
      }

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, "data: " <> Jason.encode!(event) <> "\n\n")
    end

    def call(%{request_path: "/chat/completions"} = conn, owner) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      data = Jason.decode!(body)
      SystemsRuntime.Proc.send(owner, {:upstream, conn.request_path, data})
      usage = %{"prompt_tokens" => 3, "completion_tokens" => 1, "total_tokens" => 4}

      if data["stream"] do
        chunks = [
          %{
            "choices" => [
              %{"index" => 0, "delta" => %{"role" => "assistant", "content" => "Hello"}}
            ]
          },
          %{
            "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}],
            "usage" => usage
          }
        ]

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(
          200,
          Enum.map_join(
            chunks,
            "",
            &("data: " <>
                Jason.encode!(
                  Map.merge(&1, %{
                    "id" => "c",
                    "object" => "chat.completion.chunk",
                    "model" => data["model"]
                  })
                ) <> "\n\n")
          ) <>
            "data: [DONE]\n\n"
        )
      else
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "id" => "c",
            "object" => "chat.completion",
            "model" => data["model"],
            "choices" => [
              %{
                "index" => 0,
                "message" => %{"role" => "assistant", "content" => "Hello"},
                "finish_reason" => "stop"
              }
            ],
            "usage" => usage
          })
        )
      end
    end

    def call(conn, owner) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      data = Jason.decode!(body)
      SystemsRuntime.Proc.send(owner, {:upstream, conn.request_path, data})

      if data["model"] in ["fail_reasoning", "fail_tool", "fail_before_output"] do
        events =
          case data["model"] do
            "fail_reasoning" ->
              [%{"type" => "response.reasoning_summary_text.delta", "delta" => "Thinking"}]

            "fail_tool" ->
              [
                %{
                  "type" => "response.output_item.added",
                  "output_index" => 0,
                  "item" => %{
                    "type" => "function_call",
                    "id" => "item1",
                    "call_id" => "call1",
                    "name" => "lookup",
                    "arguments" => ""
                  }
                },
                %{
                  "type" => "response.function_call_arguments.delta",
                  "output_index" => 0,
                  "item_id" => "item1",
                  "delta" => "{}"
                }
              ]

            _ ->
              []
          end

        events =
          events ++
            [
              %{
                "type" => "response.failed",
                "response" => %{
                  "error" => %{"code" => "server_error", "message" => "synthetic failure"}
                }
              }
            ]

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(
          200,
          Enum.map_join(events, "", &("data: " <> Jason.encode!(&1) <> "\n\n"))
        )
      else
        response =
          if String.contains?(conn.request_path, "messages") do
            %{
              "id" => "m",
              "type" => "message",
              "role" => "assistant",
              "model" => "claude-sonnet-4-6",
              "content" => [%{"type" => "text", "text" => "Hello"}],
              "stop_reason" => "end_turn",
              "usage" => %{"input_tokens" => 3, "output_tokens" => 1}
            }
          else
            %{
              "id" => "r",
              "object" => "response",
              "status" => "completed",
              "model" => "gpt-5.5",
              "output" => [
                %{
                  "type" => "message",
                  "role" => "assistant",
                  "content" => [%{"type" => "output_text", "text" => "Hello"}]
                }
              ],
              "usage" => %{"input_tokens" => 3, "output_tokens" => 1}
            }
          end

        if data["model"] == "hang" do
          conn =
            conn
            |> Plug.Conn.put_resp_content_type("text/event-stream")
            |> Plug.Conn.send_chunked(200)

          {:ok, conn} =
            Plug.Conn.chunk(
              conn,
              "data: {\"type\":\"response.output_text.delta\",\"delta\":\"First\"}\n\n"
            )

          SystemsRuntime.Proc.send(owner, {:hanging, SystemsRuntime.Proc.self()})

          SystemsRuntime.Proc.receive do
            :finish -> conn
          after
            10_000 -> conn
          end
        else
          if String.contains?(conn.request_path, "responses") do
            # Native Codex uses an upstream SSE response even for blocking calls.
            events = [
              %{"type" => "response.output_text.delta", "delta" => "Hello"},
              %{"type" => "response.completed", "response" => response}
            ]

            conn
            |> Plug.Conn.put_resp_content_type("text/event-stream")
            |> Plug.Conn.send_resp(
              200,
              Enum.map_join(events, "", &("data: " <> Jason.encode!(&1) <> "\n\n"))
            )
          else
            if data["stream"] do
              events = [
                %{"type" => "message_start", "message" => Map.put(response, "content", [])},
                %{
                  "type" => "content_block_start",
                  "index" => 0,
                  "content_block" => %{"type" => "text", "text" => ""}
                },
                %{
                  "type" => "content_block_delta",
                  "index" => 0,
                  "delta" => %{"type" => "text_delta", "text" => "Hello"}
                },
                %{"type" => "content_block_stop", "index" => 0},
                %{
                  "type" => "message_delta",
                  "delta" => %{"stop_reason" => "end_turn"},
                  "usage" => %{"output_tokens" => 1}
                },
                %{"type" => "message_stop"}
              ]

              conn
              |> Plug.Conn.put_resp_content_type("text/event-stream")
              |> Plug.Conn.send_resp(
                200,
                Enum.map_join(events, "", &("data: " <> Jason.encode!(&1) <> "\n\n"))
              )
            else
              conn
              |> Plug.Conn.put_resp_content_type("application/json")
              |> Plug.Conn.send_resp(200, Jason.encode!(response))
            end
          end
        end
      end
    end
  end

  setup_all do
    source = Path.expand("../../../account-proxy", __DIR__)

    dir =
      Path.join(
        System.tmp_dir!(),
        "subscription-wire-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    binary = Path.join(dir, "worker-test")
    {_, 0} = System.cmd("go", ["test", "-c", "-o", binary], cd: source, stderr_to_stdout: true)
    on_exit(fn -> File.rm_rf!(dir) end)
    background = start_supervised!(BackgroundClient)
    {:ok, binary: binary, background: background, outside_worker: SubscriptionWorker.server()}
  end

  setup %{binary: binary} do
    upstream =
      start_supervised!(
        {Bandit,
         plug: {Upstream, SystemsRuntime.Proc.self()},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(upstream)

    command =
      {"/usr/bin/env",
       [
         "SALIX_SUBSCRIPTION_TEST_UPSTREAM=http://127.0.0.1:#{port}",
         binary,
         "-test.run=TestWorkerProcess"
       ]}

    worker = start_supervised!({SubscriptionWorker, name: nil, command: command})
    SystemsRuntime.Test.put_env(:salix_agent, :subscription_worker, worker)

    {:ok, worker: worker}
  end

  defp credentials(provider),
    do: %{
      "provider" => provider,
      "credentials" =>
        Map.merge(
          %{
            "access_token" => "synthetic",
            "account_uuid" => "11111111-1111-4111-8111-111111111111",
            "claude_device_ids" => [String.duplicate("a", 64)],
            "expired" => DateTime.to_iso8601(DateTime.add(SystemsClock.utc_now(), 3600))
          },
          case provider do
            "gemini" ->
              %{"project_id" => "project-1"}

            "kimi-code" ->
              %{"device_id" => "device-1"}

            "github-copilot" ->
              %{"access_token" => "tid=1;proxy-ep=proxy.individual.githubcopilot.com"}

            _ ->
              %{}
          end
        )
    }

  @models %{
    "codex" => {"gpt-5.5", SalixLlm.OpenAIResponses},
    "claude" => {"claude-sonnet-4-6", SalixLlm.Anthropic},
    "gemini" => {"gemini-3-flash", SalixLlm.OpenAIChat},
    "grok" => {"grok-build", SalixLlm.OpenAIResponses},
    "kimi-code" => {"kimi-for-coding", SalixLlm.Anthropic},
    "github-copilot" => {"gpt-4.1", SalixLlm.OpenAIChat}
  }

  @tag :subscription_runtime
  test "runtime access refreshes centrally and a repeated rejected revision uses the replacement" do
    tenant = SalixStore.Ids.new_tenant_id()
    id = SubscriptionStore.id()

    credentials = %{
      "access_token" => "old-access",
      "refresh_token" => "old-refresh",
      "account_id" => "workspace-account",
      "expired" => DateTime.to_iso8601(DateTime.add(SystemsClock.utc_now(), 3600))
    }

    {:ok, sealed} = SubscriptionStore.seal(tenant, id, credentials)

    {:ok, _} =
      SubscriptionStore.create(tenant, %{
        "id" => id,
        "credential" => "subscription",
        "source" => "codex",
        "status" => "ok",
        "disabled" => false,
        "prepared" => true,
        "credential_revision" => "original",
        "credentials" => sealed
      })

    assert {:ok, first} = AccountPool.codex_access(tenant, id)
    assert first["access_token"] == "old-access"
    refute_receive {:refresh, _}, 50
    assert {:ok, rotated} = AccountPool.codex_access(tenant, id, "original")
    assert_receive {:refresh, %{"refresh_token" => "old-refresh"}}
    assert rotated["access_token"] == "rotated-access"
    refute Map.has_key?(rotated, "refresh_token")
    assert {:ok, repeated} = AccountPool.codex_access(tenant, id, "original")
    assert repeated["credential_revision"] == rotated["credential_revision"]
    refute_receive {:refresh, _}, 50
    {:ok, record} = SubscriptionStore.get(tenant, id)

    {:ok, _} =
      AccountPool.update(tenant, id, %{"version" => record["version"], "disabled" => true})

    assert {:error, :subscription_access_unavailable} = AccountPool.codex_access(tenant, id)
  end

  test "native providers stream and complete through the pipe and existing parsers" do
    for provider <- AccountPool.providers(), stream <- [false, true] do
      {model, module} = @models[provider]

      tenant = SalixStore.Ids.new_tenant_id()
      id = SubscriptionStore.id()
      {:ok, sealed} = SubscriptionStore.seal(tenant, id, credentials(provider)["credentials"])

      {:ok, _} =
        SubscriptionStore.create(tenant, %{
          "id" => id,
          "credential" => "subscription",
          "source" => provider,
          "credentials" => sealed,
          "prepared" => true,
          "status" => "ok",
          "disabled" => false
        })

      {:ok, config} =
        AccountPool.resolve_config(
          %{
            "account_pool" => provider,
            "model" => model
          },
          tenant
        )

      owner = SystemsRuntime.Proc.self()

      result =
        AccountPool.dispatch(config, fn opts ->
          messages = [%{"role" => "user", "content" => "hello"}]

          if stream,
            do:
              module.complete_stream(
                messages,
                [],
                fn delta -> SystemsRuntime.Proc.send(owner, {:delta, delta}) end,
                opts
              ),
            else: module.complete(messages, [], opts)
        end)

      assert {:final, "Hello", meta} = result, "#{provider} stream=#{stream}: #{inspect(result)}"
      assert meta["usage"]["prompt_tokens"] == 3
      if stream, do: assert_receive({:delta, "Hello"})
      assert_receive {:upstream, _, _}
      # Pooled subscription traffic stays on the billing-exempt worker route.
      assert AccountPool.owns_route?(config)
    end
  end

  test "worker logs correlate completion and validation errors without payloads" do
    previous = Logger.metadata()
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    log =
      ExUnit.CaptureLog.capture_log(
        [level: :info, format: {CommaLog.Formatter, :format}, metadata: :all],
        fn ->
          SalixAgent.SubscriptionLog.context(
            [
              tenant_id: "ten1_log_test",
              agent_id: "agt1_log_test",
              session_id: "ses1_log_test",
              provider: "codex"
            ],
            fn ->
              assert {:ok, _} =
                       SubscriptionWorker.request(
                         "/v1/responses",
                         %{"model" => "gpt-5.5", "input" => "PRIVATE_PROMPT_SENTINEL"},
                         credentials("codex")
                       )

              assert {:error, 400, "model_required", ""} =
                       SubscriptionWorker.request("/v1/responses", [], credentials("codex"))
            end
          )
        end
      )

    rows = log |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    finishes = Enum.filter(rows, &(&1["msg"] == "subscription_worker_call_finish"))
    assert [success, failure] = finishes
    assert success["outcome"] == "ok"
    assert success["host_frames"] == 1
    assert success["host_bytes"] > 0
    assert success["host_first_frame_ms"] <= success["duration_ms"]
    assert success["agent_id"] == "agt1_log_test"
    assert success["session_id"] == "ses1_log_test"
    assert failure["error_code"] == "model_required"
    assert failure["host_frames"] == 0
    refute Map.has_key?(failure, "host_first_frame_ms")

    for finish <- finishes do
      assert Enum.any?(
               rows,
               &(&1["msg"] == "subscription_worker_call_start" and
                   &1["worker_request_id"] == finish["worker_request_id"])
             )
    end

    for secret <- ["PRIVATE_PROMPT_SENTINEL", "synthetic", "Hello", "access_token"],
        do: refute(log =~ secret)

    assert Logger.metadata() == previous
  end

  test "partial non-text streams never replay on another account" do
    SystemsRuntime.Test.put_env(:salix_agent, :llm, SalixLlm.OpenAIResponses)

    for model <- ["fail_reasoning", "fail_tool", "fail_before_output"] do
      tenant = SalixStore.Ids.new_tenant_id()

      for _ <- 1..2 do
        id = SubscriptionStore.id()
        {:ok, sealed} = SubscriptionStore.seal(tenant, id, credentials("codex")["credentials"])

        {:ok, _} =
          SubscriptionStore.create(tenant, %{
            "id" => id,
            "credential" => "subscription",
            "source" => "codex",
            "credentials" => sealed,
            "prepared" => true,
            "status" => "ok",
            "disabled" => false
          })
      end

      {:ok, config} =
        AccountPool.resolve_config(%{"account_pool" => "codex", "model" => model}, tenant)

      owner = SystemsRuntime.Proc.self()

      config =
        Map.merge(config, %{
          "on_reasoning_delta" => fn delta ->
            SystemsRuntime.Proc.send(owner, {:reasoning, delta})
          end,
          "on_tool_delta" => fn delta -> SystemsRuntime.Proc.send(owner, {:tool, delta}) end
        })

      assert {:error, _} =
               SalixAgent.LLM.complete_stream(
                 [%{"role" => "user", "content" => "hello"}],
                 [],
                 fn _ -> flunk("no text expected") end,
                 config
               )

      assert_receive {:upstream, _, %{"model" => ^model}}

      if model == "fail_before_output" do
        assert_receive {:upstream, _, %{"model" => ^model}}
      else
        if model == "fail_reasoning", do: assert_receive({:reasoning, _})
        if model == "fail_tool", do: assert_receive({:tool, _})
        refute_receive {:upstream, _, %{"model" => ^model}}, 100
      end
    end
  end
end
