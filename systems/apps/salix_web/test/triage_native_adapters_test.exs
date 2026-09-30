defmodule Salix.Bindings.TriageNativeEvaluatorTest do
  use ExUnit.Case, async: false

  defmodule LoopbackServer do
    import Plug.Conn

    def init(server), do: server

    def call(conn, server) do
      {:ok, raw_body, conn} = read_body(conn)

      response_content =
        Agent.get_and_update(server, fn state ->
          {state.response_content, %{state | requests: state.requests ++ [raw_body]}}
        end)

      response = %{
        "choices" => [
          %{
            "message" => %{"content" => response_content},
            "finish_reason" => "stop"
          }
        ]
      }

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(response))
    end
  end

  setup do
    response_content =
      Jason.encode!(%{
        "action" => "reply",
        "text" => "Atlas 登录事故由 Lin 跟进。",
        "source_refs" => ["meeting://meeting-weekly-7/action-item/0"]
      })

    server =
      start_supervised!(
        {Agent, fn -> %{requests: [], response_content: response_content} end},
        id: make_ref()
      )

    bandit =
      start_supervised!(
        {Bandit, plug: {LoopbackServer, server}, port: 0, startup_log: false},
        id: make_ref()
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)

    snapshot = %{
      "schema" => "comma.triage-context-snapshot.v1",
      "source_authority" => %{
        "connect_id" => "imc-native-triage",
        "connect_generation" => "generation-7",
        "workspace_id" => "T1",
        "channel_id" => "C1",
        "thread_ts" => "200.001"
      },
      "slack_context" => %{
        "messages" => [%{"text" => "Atlas 登录事故的负责人是谁？"}],
        "source_refs" => ["slack://T1/C1/200.001/200.002"]
      },
      "team_project_memory" => %{
        "project" => %{"key" => "atlas", "name" => "Atlas"},
        "members" => [%{"key" => "member-lin", "display_name" => "Lin"}],
        "facts" => [
          %{
            "kind" => "meeting_action_item",
            "text" => "Close the login incident follow-up",
            "owner" => "Lin",
            "source_ref" => "meeting://meeting-weekly-7/action-item/0"
          }
        ]
      },
      "answered_recheck" => %{"answered" => false}
    }

    {:ok, snapshot_bytes} = SalixIM.Triage.CanonicalJSON.encode(snapshot)

    {:ok,
     server: server,
     base_url: "http://127.0.0.1:#{port}",
     model_input: %{
       "schema" => "comma.triage-model-input.v1",
       "snapshot" => snapshot,
       "canonical_snapshot_bytes" => snapshot_bytes,
       "source_refs" => [
         "meeting://meeting-weekly-7/action-item/0",
         "slack://T1/C1/200.001/200.002"
       ]
     }}
  end

  test "one fixed no-tool call proves exact final bytes and parses sourced reply", %{
    model_input: model_input,
    server: server,
    base_url: base_url
  } do
    assert {:ok, decision, proof} =
             Salix.Bindings.TriageEvaluator.evaluate(model_input,
               provider: SalixLlm.Provider,
               provider_name: "loopback-openai-chat",
               provider_opts: %{
                 "protocol" => "chat_completions",
                 "base_url" => base_url,
                 "api_key" => "test-only",
                 "model" => "gpt-5.6-luna"
               },
               transport_receipt: fn observed_bytes ->
                 assert [received_bytes] = Agent.get(server, & &1.requests)
                 assert received_bytes == observed_bytes

                 %{
                   payload_sha256: sha256(received_bytes),
                   request_count: 1
                 }
               end
             )

    assert decision == %{
             "action" => "reply",
             "text" => "Atlas 登录事故由 Lin 跟进。",
             "source_refs" => ["meeting://meeting-weekly-7/action-item/0"]
           }

    assert proof["provider"] == "loopback-openai-chat"
    assert proof["model"] == "gpt-5.6-luna"
    assert proof["observer_payload_sha256"] == sha256(proof["provider_payload_bytes"])
    assert proof["transport_payload_sha256"] == proof["observer_payload_sha256"]
    assert proof["request_count"] == 1
    assert proof["retry"] == false

    assert {:ok, payload} = Jason.decode(proof["provider_payload_bytes"])
    refute Map.has_key?(payload, "tools")

    assert get_in(payload, ["messages", Access.at(1), "content"]) ==
             model_input["canonical_snapshot_bytes"]
  end

  test "rejects a non-enumerated model decision", %{
    model_input: model_input,
    server: server,
    base_url: base_url
  } do
    Agent.update(server, fn state ->
      %{
        state
        | response_content: Jason.encode!(%{"action" => "post_everywhere", "text" => "oops"})
      }
    end)

    assert {:error, :invalid_triage_decision} =
             Salix.Bindings.TriageEvaluator.evaluate(model_input,
               provider: SalixLlm.Provider,
               provider_name: "loopback-openai-chat",
               provider_opts: %{
                 "protocol" => "chat_completions",
                 "base_url" => base_url,
                 "api_key" => "test-only",
                 "model" => "gpt-5.6-luna"
               },
               transport_receipt: fn bytes ->
                 assert [^bytes] = Agent.get(server, & &1.requests)
                 %{payload_sha256: sha256(bytes), request_count: 1}
               end
             )
  end

  test "rejects a sourced reply without source refs", %{
    model_input: model_input,
    server: server,
    base_url: base_url
  } do
    Agent.update(server, fn state ->
      %{
        state
        | response_content:
            Jason.encode!(%{"action" => "reply", "text" => "Atlas login owner is Lin."})
      }
    end)

    assert {:error, :invalid_triage_decision} =
             Salix.Bindings.TriageEvaluator.evaluate(model_input,
               provider: SalixLlm.Provider,
               provider_name: "loopback-openai-chat",
               provider_opts: %{
                 "protocol" => "chat_completions",
                 "base_url" => base_url,
                 "api_key" => "test-only",
                 "model" => "gpt-5.6-luna"
               },
               transport_receipt: fn bytes ->
                 assert [^bytes] = Agent.get(server, & &1.requests)
                 %{payload_sha256: sha256(bytes), request_count: 1}
               end
             )
  end

  test "rejects a sourced reply that invents a ref outside the frozen closure", %{
    model_input: model_input,
    server: server,
    base_url: base_url
  } do
    Agent.update(server, fn state ->
      %{
        state
        | response_content:
            Jason.encode!(%{
              "action" => "reply",
              "text" => "Atlas login owner is Lin.",
              "source_refs" => ["meeting://invented/owner/0"]
            })
      }
    end)

    assert {:error, :invalid_triage_decision} =
             Salix.Bindings.TriageEvaluator.evaluate(model_input,
               provider: SalixLlm.Provider,
               provider_name: "loopback-openai-chat",
               provider_opts: %{
                 "protocol" => "chat_completions",
                 "base_url" => base_url,
                 "api_key" => "test-only",
                 "model" => "gpt-5.6-luna"
               },
               transport_receipt: fn bytes ->
                 assert [^bytes] = Agent.get(server, & &1.requests)
                 %{payload_sha256: sha256(bytes), request_count: 1}
               end
             )
  end

  test "fails before provider egress when receiver-side transport evidence is absent", %{
    model_input: model_input,
    server: server,
    base_url: base_url
  } do
    assert {:error, :transport_receipt_required} =
             Salix.Bindings.TriageEvaluator.evaluate(model_input,
               provider: SalixLlm.Provider,
               provider_opts: %{
                 "protocol" => "chat_completions",
                 "base_url" => base_url,
                 "api_key" => "test-only",
                 "model" => "gpt-5.6-luna"
               }
             )

    assert Agent.get(server, & &1.requests) == []
  end

  defp sha256(bytes) do
    bytes
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
