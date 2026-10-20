defmodule SalixAgent.ProjectKnowledgeContextTest do
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixAgent.ProjectKnowledgeContext

  defmodule Provider do
    def retrieve(agent_id, question, context) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_agent, :project_knowledge_context_test_pid),
        {:retrieved, agent_id, question, context}
      )

      SystemsClock.sleep(
        SystemsRuntime.get_env(:salix_agent, :project_knowledge_context_delay_ms, 0)
      )

      :salix_agent
      |> SystemsRuntime.fetch_env!(:project_knowledge_context_result)
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
    previous_provider = SystemsRuntime.get_env(:salix_agent, :project_knowledge_provider_mod)
    previous_result = SystemsRuntime.get_env(:salix_agent, :project_knowledge_context_result)
    previous_test_pid = SystemsRuntime.get_env(:salix_agent, :project_knowledge_context_test_pid)
    previous_delay = SystemsRuntime.get_env(:salix_agent, :project_knowledge_context_delay_ms)

    previous_timeout =
      SystemsRuntime.get_env(:salix_agent, :project_knowledge_provider_timeout_ms)

    SystemsRuntime.put_env(:salix_agent, :project_knowledge_provider_mod, Provider)

    SystemsRuntime.put_env(
      :salix_agent,
      :project_knowledge_context_test_pid,
      SystemsRuntime.Proc.self()
    )

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

    SystemsRuntime.put_env(:salix_agent, :project_knowledge_context_result, result)

    session = %{
      next_message_id: 2,
      messages: [%{id: 1, role: "user", content: "What does Lin own in Atlas?"}]
    }

    assert {:messages, [payload]} =
             ProjectKnowledgeContext.prepare("agent-1", "session-1", session)

    settle_receive(
      {:retrieved, "agent-1", "What does Lin own in Atlas?", %{session_id: "session-1"}}
    )

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

  test "runtime knowledge preserves resolved subjects and rejects facts outside that set" do
    entities = [
      %{kind: :person, id: "person-lin", matched_alias: "Lin"},
      %{kind: :person, id: "person-ann", matched_alias: "Ann"}
    ]

    SystemsRuntime.put_env(
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

    SystemsRuntime.put_env(
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

    SystemsRuntime.put_env(
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

      SystemsRuntime.put_env(
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

      # Mid-conversation project knowledge reaches the model as the result of a
      # synthetic `get_runtime_message` call (Chat) or as runtime text in a
      # user turn (Anthropic). The budget governs both.
      conversation = [%{role: "user", content: "What do we know?"}, runtime_message]

      assert [_question, _call, %{"role" => "tool", "content" => runtime_result}] =
               SalixLlm.ConvertOpenAI.to_chat(conversation)

      assert {nil, [_question, %{"role" => "user", "content" => runtime_text}]} =
               SalixLlm.Convert.to_anthropic(conversation)

      assert byte_size(runtime_result) <= 32 * 1024
      assert byte_size(runtime_text) <= 32 * 1024

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

  defp restore(key, nil), do: SystemsRuntime.delete_env(:salix_agent, key)
  defp restore(key, value), do: SystemsRuntime.put_env(:salix_agent, key, value)
end
