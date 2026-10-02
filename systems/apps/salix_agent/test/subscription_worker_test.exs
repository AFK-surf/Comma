defmodule SalixAgent.SubscriptionWorkerTest do
  use ExUnit.Case, async: false
  alias SalixAgent.{SubscriptionWorker, AccountPool, SubscriptionStore}

  defmodule Upstream do
    def init(owner), do: owner

    def call(%{request_path: "/oauth/token"} = conn, owner) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:refresh, URI.decode_query(body)})

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
      send(owner, {:upstream, conn.request_path, Jason.decode!(body)})

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
      send(owner, {:upstream, conn.request_path, data})
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
      send(owner, {:upstream, conn.request_path, data})

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

        if data["model"] in ["hang", "stall"] do
          conn =
            conn
            |> Plug.Conn.put_resp_content_type("text/event-stream")
            |> Plug.Conn.send_chunked(200)

          {:ok, conn} =
            Plug.Conn.chunk(
              conn,
              "data: {\"type\":\"response.output_text.delta\",\"delta\":\"First\"}\n\n"
            )

          send(owner, {:hanging, self()})

          receive do
            :finish -> conn
          after
            if(data["model"] == "stall", do: 35_000, else: 10_000) -> conn
          end
        else
          if String.contains?(conn.request_path, "responses") do
            # Native Codex uses an upstream SSE response even for blocking calls.
            events = [
              %{"type" => "response.output_text.delta", "delta" => "Hello"},
              %{"type" => "response.completed", "response" => response}
            ]

            if data["model"] == "slow_summary" do
              conn =
                conn
                |> Plug.Conn.put_resp_content_type("text/event-stream")
                |> Plug.Conn.send_chunked(200)

              for _ <- 1..121 do
                Plug.Conn.chunk(conn, "data: " <> Jason.encode!(hd(events)) <> "\n\n")
                Process.sleep(1_000)
              end

              {:ok, conn} =
                Plug.Conn.chunk(conn, "data: " <> Jason.encode!(List.last(events)) <> "\n\n")

              conn
            else
              conn
              |> Plug.Conn.put_resp_content_type("text/event-stream")
              |> Plug.Conn.send_resp(
                200,
                Enum.map_join(events, "", &("data: " <> Jason.encode!(&1) <> "\n\n"))
              )
            end
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
    dir = Path.join(System.tmp_dir!(), "subscription-wire-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    binary = Path.join(dir, "worker-test")
    {_, 0} = System.cmd("go", ["test", "-c", "-o", binary], cd: source, stderr_to_stdout: true)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, binary: binary}
  end

  setup %{binary: binary} do
    upstream =
      start_supervised!(
        {Bandit, plug: {Upstream, self()}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
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
    old = Application.get_env(:salix_agent, :subscription_worker)
    Application.put_env(:salix_agent, :subscription_worker, worker)

    on_exit(fn ->
      if old,
        do: Application.put_env(:salix_agent, :subscription_worker, old),
        else: Application.delete_env(:salix_agent, :subscription_worker)
    end)

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
            "expired" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 3600))
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
      "expired" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 3600))
    }

    {:ok, sealed} = SubscriptionStore.seal(tenant, id, credentials)

    {:ok, _} =
      SubscriptionStore.create(tenant, %{
        "id" => id,
        "credential_kind" => "subscription_oauth",
        "provider" => "codex",
        "status" => "active",
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
          "credential_kind" => "subscription_oauth",
          "provider" => provider,
          "credentials" => sealed,
          "prepared" => true,
          "status" => "active",
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

      owner = self()

      result =
        AccountPool.dispatch(config, fn opts ->
          messages = [%{"role" => "user", "content" => "hello"}]

          if stream,
            do:
              module.complete_stream(
                messages,
                [],
                fn delta -> send(owner, {:delta, delta}) end,
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

  test "malformed inference bodies return the worker validation error" do
    assert {:error, 400, "model_required", ""} =
             SubscriptionWorker.request("/v1/responses", [], credentials("codex"))
  end

  test "a request above the former frame limit reaches the native provider intact" do
    input = String.duplicate("x", 4 * 1024 * 1024)

    assert {:ok, response} =
             SubscriptionWorker.request(
               "/v1/responses",
               %{"model" => "gpt-5.5", "input" => input},
               credentials("codex")
             )

    assert Jason.decode!(response)["status"] == "completed"
    assert_receive {:upstream, "/backend-api/codex/responses", sent}, 1_000
    assert Jason.encode!(sent) =~ input
  end

  @tag timeout: 150_000, subscription_timeout_regression: true
  test "blocking Codex summaries can finish after the former two-minute worker deadline" do
    tenant = SalixStore.Ids.new_tenant_id()
    id = SubscriptionStore.id()
    {:ok, sealed} = SubscriptionStore.seal(tenant, id, credentials("codex")["credentials"])

    {:ok, _} =
      SubscriptionStore.create(tenant, %{
        "id" => id,
        "credential_kind" => "subscription_oauth",
        "provider" => "codex",
        "credentials" => sealed,
        "prepared" => true,
        "status" => "active",
        "disabled" => false
      })

    {:ok, config} =
      AccountPool.resolve_config(%{"account_pool" => "codex", "model" => "slow_summary"}, tenant)

    started = System.monotonic_time(:millisecond)

    assert {:final, "Hello", _} =
             AccountPool.dispatch(config, fn opts ->
               SalixLlm.OpenAIResponses.complete(
                 [%{"role" => "user", "content" => "Summarize this conversation"}],
                 [],
                 opts
               )
             end)

    assert System.monotonic_time(:millisecond) - started >= 120_000
    {:ok, account} = SubscriptionStore.get(tenant, id)
    assert account["status"] == "active"
    refute account["cooldown_until"]
  end

  @tag timeout: 45_000
  test "a stalled stream still times out and leaves the worker usable", %{worker: worker} do
    assert {:error, 504, "worker_idle_timeout", partial} =
             SubscriptionWorker.request(
               "/v1/responses",
               %{"model" => "stall", "stream" => true, "input" => "hello"},
               credentials("codex"),
               server: worker
             )

    assert partial =~ "First"
    assert_receive {:hanging, upstream}
    send(upstream, :finish)
    assert {:ok, _} = SubscriptionWorker.request("/normalize", credentials("codex"))
    assert :sys.get_state(worker).calls == %{}
  end

  test "the configured LLM budget cancels a blocking call", %{worker: worker} do
    old_budget = Application.get_env(:salix_agent, :llm_request_timeout_ms)
    Application.put_env(:salix_agent, :llm_request_timeout_ms, 1_000)

    on_exit(fn ->
      if old_budget,
        do: Application.put_env(:salix_agent, :llm_request_timeout_ms, old_budget),
        else: Application.delete_env(:salix_agent, :llm_request_timeout_ms)
    end)

    caller =
      Task.async(fn ->
        SubscriptionWorker.request(
          "/v1/responses",
          %{"model" => "hang", "input" => "hello"},
          credentials("codex"),
          server: worker
        )
      end)

    assert_receive {:hanging, upstream}, 5_000
    assert {:error, 504, "worker_timeout", ""} = Task.await(caller)
    send(upstream, :finish)
    assert {:ok, _} = SubscriptionWorker.request("/normalize", credentials("codex"))
    assert :sys.get_state(worker).calls == %{}
  end

  test "native Codex import refreshes expired credentials and persists the replacement" do
    tenant = SalixStore.Ids.new_tenant_id()

    claims =
      Base.url_encode64(Jason.encode!(%{"exp" => System.system_time(:second) - 3600}),
        padding: false
      )

    {:ok, account} =
      AccountPool.create(tenant, %{
        "credential_kind" => "subscription_oauth",
        "provider" => "codex",
        "credentials" => %{
          "tokens" => %{
            "access_token" => "header." <> claims <> ".signature",
            "refresh_token" => "synthetic-refresh"
          }
        }
      })

    {:ok, config} =
      AccountPool.resolve_config(%{"account_pool" => "codex", "model" => "gpt-5.5"}, tenant)

    invoke = fn opts ->
      SalixLlm.OpenAIResponses.complete([%{"role" => "user", "content" => "hello"}], [], opts)
    end

    assert {:final, "Hello", _} = AccountPool.dispatch(config, invoke)
    assert_receive {:refresh, %{"refresh_token" => "synthetic-refresh"}}, 5_000
    {:ok, saved} = SubscriptionStore.get(tenant, account["id"])
    assert saved["prepared"] == true
    assert saved["status"] == "active"
    assert {:ok, expiry, _} = DateTime.from_iso8601(saved["expires_at"])
    assert DateTime.compare(expiry, DateTime.utc_now()) == :gt

    assert {:ok, %{"access_token" => "rotated-access", "refresh_token" => "rotated-refresh"}} =
             SubscriptionStore.open(tenant, account["id"], saved["credentials"])

    assert {:final, "Hello", _} = AccountPool.dispatch(config, invoke)
    refute_receive {:refresh, _}, 100
  end

  test "partial non-text streams never replay on another account" do
    previous = Application.get_env(:salix_agent, :llm)
    Application.put_env(:salix_agent, :llm, SalixLlm.OpenAIResponses)
    on_exit(fn -> Application.put_env(:salix_agent, :llm, previous) end)

    for model <- ["fail_reasoning", "fail_tool", "fail_before_output"] do
      tenant = SalixStore.Ids.new_tenant_id()

      for _ <- 1..2 do
        id = SubscriptionStore.id()
        {:ok, sealed} = SubscriptionStore.seal(tenant, id, credentials("codex")["credentials"])

        {:ok, _} =
          SubscriptionStore.create(tenant, %{
            "id" => id,
            "credential_kind" => "subscription_oauth",
            "provider" => "codex",
            "credentials" => sealed,
            "prepared" => true,
            "status" => "active",
            "disabled" => false
          })
      end

      {:ok, config} =
        AccountPool.resolve_config(%{"account_pool" => "codex", "model" => model}, tenant)

      owner = self()

      config =
        Map.merge(config, %{
          "on_reasoning_delta" => fn delta -> send(owner, {:reasoning, delta}) end,
          "on_tool_delta" => fn delta -> send(owner, {:tool, delta}) end
        })

      assert {:error, _} =
               SalixAgent.LLM.complete_stream(
                 [%{"role" => "user", "content" => "hello"}],
                 [],
                 fn _ -> flunk("no text expected") end,
                 config
               )

      assert_receive {:upstream, _, %{"model" => ^model}}, 5_000

      if model == "fail_before_output" do
        assert_receive {:upstream, _, %{"model" => ^model}}, 5_000
      else
        if model == "fail_reasoning", do: assert_receive({:reasoning, _})
        if model == "fail_tool", do: assert_receive({:tool, _})
        refute_receive {:upstream, _, %{"model" => ^model}}, 100
      end
    end
  end

  test "caller cancellation releases one stream and leaves the worker usable", %{worker: worker} do
    owner = self()

    caller =
      spawn(fn ->
        SubscriptionWorker.request(
          "/v1/responses",
          %{"model" => "hang", "stream" => true, "input" => "hello"},
          credentials("codex"),
          consume: fn data, acc ->
            send(owner, {:chunk, data})
            {:cont, acc}
          end
        )
      end)

    assert_receive {:hanging, upstream}, 5_000
    assert_receive {:chunk, _}, 5_000
    Process.exit(caller, :kill)
    # A round-trip after DOWN gives the GenServer an opportunity to process cancellation.
    assert {:ok, _} = SubscriptionWorker.request("/normalize", credentials("codex"))
    state = :sys.get_state(worker)
    refute Enum.any?(state.calls, fn {_, c} -> c.pid == caller end)
    send(upstream, :finish)
  end

  test "worker death fails a partial stream and the next call starts a new process", %{
    worker: worker
  } do
    owner = self()

    task =
      Task.async(fn ->
        SubscriptionWorker.request(
          "/v1/responses",
          %{"model" => "hang", "stream" => true, "input" => "hello"},
          credentials("codex"),
          consume: fn data, acc ->
            send(owner, {:chunk, data})
            {:cont, acc <> data}
          end
        )
      end)

    assert_receive {:hanging, upstream}, 5_000
    assert_receive {:chunk, _}, 5_000
    old_port = :sys.get_state(worker).port
    {:os_pid, pid} = Port.info(old_port, :os_pid)
    System.cmd("kill", ["-KILL", to_string(pid)])
    assert {:error, 503, "worker_down", partial} = Task.await(task)
    assert partial =~ "First"
    assert {:ok, _} = SubscriptionWorker.request("/normalize", credentials("codex"))
    refute :sys.get_state(worker).port == old_port
    send(upstream, :finish)
  end
end
