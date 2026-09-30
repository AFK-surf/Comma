defmodule SalixAgent.ProjectKnowledgeContextTest do
  use ExUnit.Case, async: false

  alias SalixAgent.ProjectKnowledgeContext

  defmodule Provider do
    def retrieve(agent_id, question, context) do
      send(
        Application.fetch_env!(:salix_agent, :project_knowledge_context_test_pid),
        {:retrieved, agent_id, question, context}
      )

      Process.sleep(Application.get_env(:salix_agent, :project_knowledge_context_delay_ms, 0))

      :salix_agent
      |> Application.fetch_env!(:project_knowledge_context_result)
      |> with_default_subject()
    end

    defp with_default_subject({:ok, %{status: :resolved, facts: facts} = result})
         when not is_map_key(result, :entities) do
      subject = {:project, "project-test"}

      {:ok,
       result
       |> Map.put(:entities, [
         %{kind: :project, id: "project-test", matched_alias: "Test Project"}
       ])
       |> Map.put(:facts, Enum.map(facts, &Map.put_new(&1, :about, [subject])))}
    end

    defp with_default_subject(result), do: result
  end

  setup do
    previous_provider = Application.get_env(:salix_agent, :project_knowledge_provider_mod)
    previous_result = Application.get_env(:salix_agent, :project_knowledge_context_result)
    previous_test_pid = Application.get_env(:salix_agent, :project_knowledge_context_test_pid)
    previous_delay = Application.get_env(:salix_agent, :project_knowledge_context_delay_ms)
    previous_timeout = Application.get_env(:salix_agent, :project_knowledge_provider_timeout_ms)
    Application.put_env(:salix_agent, :project_knowledge_provider_mod, Provider)
    Application.put_env(:salix_agent, :project_knowledge_context_test_pid, self())

    on_exit(fn ->
      restore(:project_knowledge_provider_mod, previous_provider)
      restore(:project_knowledge_context_result, previous_result)
      restore(:project_knowledge_context_test_pid, previous_test_pid)
      restore(:project_knowledge_context_delay_ms, previous_delay)
      restore(:project_knowledge_provider_timeout_ms, previous_timeout)
    end)

    :ok
  end

  test "resolved sourced facts become a deterministic runtime message" do
    result =
      {:ok,
       %{
         status: :resolved,
         facts: [
           %{
             id: "assertion-1",
             kind: :decision,
             content: "Lin owns the Atlas launch checklist.",
             source_refs: [
               %{type: "slack_receipt", ref: "s3://triage/receipts/decision.json"}
             ]
           }
         ]
       }}

    Application.put_env(:salix_agent, :project_knowledge_context_result, result)

    session = %{
      next_message_id: 2,
      messages: [%{id: 1, role: "user", content: "What does Lin own in Atlas?"}]
    }

    assert {:messages, [payload]} =
             ProjectKnowledgeContext.prepare("agent-1", "session-1", session)

    assert_receive {:retrieved, "agent-1", "What does Lin own in Atlas?",
                    %{session_id: "session-1"}}

    assert payload["runtime_message_type"] == "project_knowledge"
    assert payload["runtime_message_id"] =~ "project-knowledge:"

    assert %{
             "contract" => _contract,
             "facts" => [%{"id" => "assertion-1", "content" => content}]
           } = Jason.decode!(payload["content"])

    assert content == "Lin owns the Atlas launch checklist."

    assert get_in(payload, ["source_refs", "assertions"]) == [
             %{
               "id" => "assertion-1",
               "sources" => [
                 %{
                   "type" => "slack_receipt",
                   "ref" => "s3://triage/receipts/decision.json"
                 }
               ]
             }
           ]

    committed =
      put_in(session, [:messages], [
        %{role: "runtime", runtime_message_id: payload["runtime_message_id"]}
        | session.messages
      ])

    assert :none = ProjectKnowledgeContext.prepare("agent-1", "session-1", committed)

    continued = %{committed | next_message_id: 4}

    assert {:messages, [continued_payload]} =
             ProjectKnowledgeContext.prepare("agent-1", "session-1", continued)

    refute continued_payload["runtime_message_id"] == payload["runtime_message_id"]
  end

  test "facts already rendered in place for this activation are not committed again" do
    result =
      {:ok,
       %{
         status: :resolved,
         facts: [
           %{
             id: "assertion-1",
             kind: :decision,
             content: "Lin owns the Atlas launch checklist.",
             source_refs: [
               %{type: "slack_receipt", ref: "s3://triage/receipts/decision.json"}
             ]
           }
         ]
       }}

    Application.put_env(:salix_agent, :project_knowledge_context_result, result)

    question = %{id: 1, role: "user", content: "What does Lin own in Atlas?"}

    assert {:messages, [payload]} =
             ProjectKnowledgeContext.prepare("agent-1", "session-1", %{
               next_message_id: 2,
               messages: [question]
             })

    in_place = %{
      id: 2,
      role: "runtime",
      type: "project_knowledge",
      runtime_message_id: "project-knowledge:earlier-round",
      content: payload["content"]
    }

    # A later round of the same activation: the block is still in the request.
    continued = %{
      next_message_id: 5,
      messages: [question, in_place, %{id: 3, role: "assistant", content: "", tool_calls: []}]
    }

    assert :none = ProjectKnowledgeContext.prepare("agent-1", "session-1", continued)

    # A new user input starts another activation; the block is out of view.
    next_activation = %{
      next_message_id: 6,
      messages:
        continued.messages ++ [%{id: 5, role: "user", content: "What does Lin own in Atlas?"}]
    }

    assert {:messages, [fresh]} =
             ProjectKnowledgeContext.prepare("agent-1", "session-1", next_activation)

    assert fresh["content"] == payload["content"]
    refute fresh["runtime_message_id"] == payload["runtime_message_id"]
  end

  test "runtime knowledge preserves resolved subjects and rejects facts outside that set" do
    entities = [
      %{kind: :person, id: "person-lin", matched_alias: "Lin"},
      %{kind: :person, id: "person-ann", matched_alias: "Ann"}
    ]

    Application.put_env(
      :salix_agent,
      :project_knowledge_context_result,
      {:ok,
       %{
         status: :resolved,
         entities: entities,
         facts: [
           %{
             id: "assertion-lin",
             kind: :fact,
             content: "Owns the launch checklist.",
             about: [{:person, "person-lin"}],
             source_refs: [%{type: "manual", ref: "manual://lin/launch"}]
           },
           %{
             id: "assertion-ann",
             kind: :fact,
             content: "Owns release communications.",
             about: [{:person, "person-ann"}],
             source_refs: [%{type: "manual", ref: "manual://ann/release"}]
           }
         ]
       }}
    )

    session = %{
      next_message_id: 2,
      messages: [%{id: 1, role: "user", content: "What do Lin and Ann own?"}]
    }

    assert {:messages, [payload]} =
             ProjectKnowledgeContext.prepare("agent-1", "session-1", session)

    assert %{
             "entities" => [
               %{"id" => "person-lin", "kind" => "person", "matched_alias" => "Lin"},
               %{"id" => "person-ann", "kind" => "person", "matched_alias" => "Ann"}
             ],
             "facts" => [
               %{
                 "id" => "assertion-lin",
                 "about" => [%{"id" => "person-lin", "kind" => "person"}]
               },
               %{
                 "id" => "assertion-ann",
                 "about" => [%{"id" => "person-ann", "kind" => "person"}]
               }
             ]
           } = Jason.decode!(payload["content"])

    Application.put_env(
      :salix_agent,
      :project_knowledge_context_result,
      {:ok,
       %{
         status: :resolved,
         entities: entities,
         facts: [
           %{
             id: "assertion-foreign",
             kind: :fact,
             content: "Owns an unrelated secret.",
             about: [{:person, "person-foreign"}],
             source_refs: [%{type: "manual", ref: "manual://foreign"}]
           }
         ]
       }}
    )

    assert :none = ProjectKnowledgeContext.prepare("agent-1", "session-1", session)

    Application.put_env(
      :salix_agent,
      :project_knowledge_context_result,
      {:ok,
       %{
         status: :resolved,
         entities: [],
         facts: [
           %{
             id: "assertion-unresolved",
             kind: :fact,
             content: "Has no resolved subject.",
             about: [{:person, "person-lin"}],
             source_refs: [%{type: "manual", ref: "manual://unresolved"}]
           }
         ]
       }}
    )

    assert :none = ProjectKnowledgeContext.prepare("agent-1", "session-1", session)
  end

  test "one activation queries every ordered user delivery" do
    Application.put_env(
      :salix_agent,
      :project_knowledge_context_result,
      {:ok,
       %{
         status: :resolved,
         facts: [
           %{
             id: "assertion-atlas-owner",
             kind: :fact,
             content: "Lin owns Atlas.",
             source_refs: [%{type: "manual", ref: "manual://atlas/owner"}]
           }
         ]
       }}
    )

    session = %{
      last_ack_message_id: 2,
      next_message_id: 3,
      messages: [
        %{
          id: 1,
          role: "user",
          source_message_id: "delivery-1",
          content: "What does Lin own in Atlas?"
        },
        %{
          id: 2,
          role: "user",
          source_message_id: "delivery-2",
          content: "Also say hello."
        }
      ]
    }

    assert {:messages, [_payload]} =
             ProjectKnowledgeContext.prepare("agent-1", "session-1", session)

    assert_receive {:retrieved, "agent-1", "What does Lin own in Atlas?\n\nAlso say hello.",
                    %{session_id: "session-1"}}
  end

  test "unknown, ambiguous, and unsourced results expose no context" do
    session = %{
      next_message_id: 2,
      messages: [%{id: 1, role: "user", content: "Who owns Atlas?"}]
    }

    for result <- [
          {:ok, %{status: :unknown, facts: []}},
          {:ok, %{status: :ambiguous, facts: []}},
          {:ok,
           %{
             status: :resolved,
             facts: [%{id: "a", kind: :fact, content: "unsourced", source_refs: []}]
           }}
        ] do
      Application.put_env(:salix_agent, :project_knowledge_context_result, result)
      assert :none = ProjectKnowledgeContext.prepare("agent-1", "session-1", session)
    end
  end

  test "a provider page larger than the runtime budget is deterministically truncated" do
    facts =
      for index <- 1..21 do
        %{
          id: "assertion-#{index}",
          kind: :fact,
          content: "Fact #{index}",
          source_refs: [%{type: "manual", ref: "manual://fact/#{index}"}]
        }
      end

    Application.put_env(
      :salix_agent,
      :project_knowledge_context_result,
      {:ok, %{status: :resolved, facts: facts}}
    )

    session = %{
      next_message_id: 2,
      messages: [%{id: 1, role: "user", content: "What do we know?"}]
    }

    assert {:messages, [payload]} =
             ProjectKnowledgeContext.prepare("agent-1", "session-1", session)

    decoded = Jason.decode!(payload["content"])
    assert length(decoded["facts"]) == 20
    assert Enum.map(decoded["facts"], & &1["id"]) == Enum.map(1..20, &"assertion-#{&1}")
  end

  for {name, count, digit_bytes, ref_bytes, expected_ids} <- [
        {"the complete runtime payload stays within its aggregate byte budget", 20, 7_900, 512,
         :nonempty_prefix},
        {"source evidence is included in the complete runtime block byte budget", 4, 6_500, 1_024,
         ["assertion-1", "assertion-2", "assertion-3"]}
      ] do
    test name do
      facts =
        for index <- 1..unquote(count) do
          %{
            id: "assertion-#{index}",
            kind: :fact,
            content: String.duplicate(Integer.to_string(rem(index, 10)), unquote(digit_bytes)),
            source_refs: [
              %{
                type: "manual",
                ref: "manual://fact/#{index}/#{String.duplicate("r", unquote(ref_bytes))}"
              }
            ]
          }
        end

      Application.put_env(
        :salix_agent,
        :project_knowledge_context_result,
        {:ok, %{status: :resolved, facts: facts}}
      )

      session = %{
        next_message_id: 2,
        messages: [%{id: 1, role: "user", content: "What do we know?"}]
      }

      assert {:messages, [payload]} =
               ProjectKnowledgeContext.prepare("agent-1", "session-1", session)

      runtime_message =
        %{messages: [payload]}
        |> SalixAgent.ContextProviders.model_messages()
        |> then(fn [message] -> message end)

      # Since #1145 a transcript that is entirely system-authored is not folded
      # into `system` — Anthropic `messages` may not be empty, so the lone
      # runtime block is demoted to one `<system>`-wrapped user turn. The
      # aggregate byte budget still governs the runtime block itself.
      assert {nil, [%{"role" => "user", "content" => "<system>\n" <> demoted}]} =
               SalixLlm.Convert.to_anthropic([runtime_message])

      runtime_block = String.replace_suffix(demoted, "\n</system>", "")
      assert byte_size(runtime_block) <= 32 * 1024

      ids = Enum.map(Jason.decode!(payload["content"])["facts"], & &1["id"])

      case unquote(expected_ids) do
        :nonempty_prefix ->
          assert ids != []
          assert ids == Enum.map(1..length(ids), &"assertion-#{&1}")

        expected ->
          assert ids == expected
      end
    end
  end

  test "a stalled provider fails open at the configured deadline and emits a bounded outcome" do
    handler_id = "project-knowledge-timeout-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:salix, :project_knowledge, :retrieve, :stop],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:project_knowledge_telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    Application.put_env(:salix_agent, :project_knowledge_provider_timeout_ms, 20)
    Application.put_env(:salix_agent, :project_knowledge_context_delay_ms, 250)
    Application.put_env(:salix_agent, :project_knowledge_context_result, :none)

    session = %{
      next_message_id: 2,
      messages: [%{id: 1, role: "user", content: "Who owns Atlas?"}]
    }

    started_at = System.monotonic_time(:millisecond)
    assert :none = ProjectKnowledgeContext.prepare("agent-1", "session-1", session)
    assert System.monotonic_time(:millisecond) - started_at < 150

    assert_receive {:project_knowledge_telemetry, [:salix, :project_knowledge, :retrieve, :stop],
                    %{duration: duration}, %{outcome: :timeout}}

    assert is_integer(duration) and duration > 0
  end

  test "a product provider absent from an isolated runtime is inert" do
    Application.put_env(
      :salix_agent,
      :project_knowledge_provider_mod,
      SalixAgent.ProjectKnowledgeContextTest.MissingProvider
    )

    session = %{
      next_message_id: 2,
      messages: [%{id: 1, role: "user", content: "Who owns Atlas?"}]
    }

    assert :none = ProjectKnowledgeContext.prepare("agent-1", "session-1", session)
  end

  defp restore(key, nil), do: Application.delete_env(:salix_agent, key)
  defp restore(key, value), do: Application.put_env(:salix_agent, key, value)
end
