defmodule BridgeForTeams.ProjectKnowledgeTest do
  use BridgeForTeams.DataCase, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.BridgeForTeams"]

  alias BridgeForTeams.{Accounts, Memberships, Orgs, ProjectKnowledge, Projects, Repo}
  alias BridgeForTeams.Schema.{Agent, ProjectKnowledgeAssertion}

  defmodule UsageClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    def list_project_knowledge_uses(agent_id, opts) do
      if pid = SystemsRuntime.get_env(:bridge_for_teams_core, :project_knowledge_usage_test_pid) do
        SystemsRuntime.Proc.send(pid, {:project_knowledge_usage_called, agent_id, opts})
      end

      SystemsRuntime.fetch_env!(:bridge_for_teams_core, :project_knowledge_usage_result)
    end

    def triage_knowledge_context(_project_id, _group_id, _agent_id, _opts) do
      SystemsRuntime.get_env(
        :bridge_for_teams_core,
        :project_knowledge_triage_result,
        {:ok, %{items: [], complete: true}}
      )
    end
  end

  setup do
    suffix = SystemsRuntime.Proc.unique_integer([:positive])

    {:ok, org} =
      Orgs.create_org(%{
        "name" => "Knowledge #{suffix}",
        "slug" => "knowledge-#{suffix}"
      })

    {:ok, owner} =
      Accounts.create_user(%{
        "email" => "knowledge-owner-#{suffix}@example.test",
        "name" => "Peng"
      })

    {:ok, lin} =
      Accounts.create_user(%{
        "email" => "knowledge-lin-#{suffix}@example.test",
        "name" => "Lin"
      })

    {:ok, _} = Memberships.put_org_member(org.id, owner.id, "owner")
    {:ok, _} = Memberships.put_org_member(org.id, lin.id, "member")

    {:ok, project} =
      Projects.create_project(
        org.id,
        %{"name" => "Atlas", "slug" => "atlas-#{suffix}"},
        creator_user_id: owner.id
      )

    drain_all()
    agent = Repo.get_by!(Agent, project_id: project.id, role: "router")

    %{org: org, owner: owner, lin: lin, project: project, agent: agent}
  end

  defp drain_all do
    case BridgeForTeams.Salix.Reconciler.drain_once() do
      {:ok, 0} -> :ok
      {:ok, _} -> drain_all()
    end
  end

  test "an Agent retrieves only fully grounded facts with their durable source", ctx do
    source = %{type: :slack_receipt, ref: "s3://triage/receipts/atlas-decision.json"}

    assert {:ok, _} =
             ProjectKnowledge.register_alias(ctx.project.id, {:person, ctx.lin.id}, "Lin", source)

    assert {:ok, _} =
             ProjectKnowledge.register_alias(
               ctx.project.id,
               {:project, ctx.project.id},
               "Atlas",
               source
             )

    assert {:ok, assertion} =
             ProjectKnowledge.append_assertion(
               ctx.project.id,
               :decision,
               "Lin owns the Atlas launch checklist.",
               [{:person, ctx.lin.id}, {:project, ctx.project.id}],
               source
             )

    assert {:ok,
            %{
              status: :resolved,
              entities: entities,
              facts: [fact]
            }} = ProjectKnowledge.ground_for_agent(ctx.agent.id, "What does Lin own in Atlas?")

    assert MapSet.new(entities, &{&1.kind, &1.id}) ==
             MapSet.new([{:person, ctx.lin.id}, {:project, ctx.project.id}])

    assert fact.id == assertion.id
    assert fact.kind == :decision
    assert fact.content == "Lin owns the Atlas launch checklist."
    assert fact.about == [{:person, ctx.lin.id}, {:project, ctx.project.id}]
    assert fact.source_refs == [%{type: "slack_receipt", ref: source.ref}]
  end

  test "the project read model joins product identities, sources, and accepted Agent use", ctx do
    source = %{type: :slack_receipt, ref: "s3://triage/receipts/read-model.json"}

    assert {:ok, _} =
             ProjectKnowledge.register_alias(ctx.project.id, {:person, ctx.lin.id}, "Lin", source)

    assert {:ok, assertion} =
             ProjectKnowledge.append_assertion(
               ctx.project.id,
               :decision,
               "Lin owns the release review.",
               [{:person, ctx.lin.id}, {:project, ctx.project.id}],
               source
             )

    previous_client = SystemsRuntime.get_env(:bridge_for_teams_core, :salix_client)

    previous_result =
      SystemsRuntime.get_env(:bridge_for_teams_core, :project_knowledge_usage_result)

    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, UsageClient)

    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :project_knowledge_usage_result,
      {:ok,
       %{
         "uses" => [
           %{
             "session_id" => "ses1_knowledge",
             "retrieval_id" => "project-knowledge:accepted",
             "used_at" => 1_787_310_000,
             "assistant_message_id" => 4,
             "assistant_excerpt" => "Lin owns the release review.",
             "assertions" => [%{"id" => assertion.id, "sources" => []}]
           }
         ],
         "complete" => true,
         "history_truncated" => false,
         "sessions_scanned" => 1
       }}
    )

    on_exit(fn ->
      restore_env(:salix_client, previous_client)
      restore_env(:project_knowledge_usage_result, previous_result)
    end)

    assert {:ok, result} = ProjectKnowledge.list_for_agent(ctx.agent.id)
    assert result.project == %{id: ctx.project.id, name: "Atlas"}
    assert result.usage_status == :available
    assert result.usage_complete
    assert result.assertions_complete
    assert result.entities_complete

    assert [listed] = result.assertions
    assert listed.id == assertion.id
    assert listed.source == %{type: "slack_receipt", ref: source.ref}

    assert %{name: "Lin", aliases: ["Lin"]} =
             Enum.find(listed.subjects, &(&1.kind == :person))

    assert %{name: "Atlas"} = Enum.find(listed.subjects, &(&1.kind == :project))
    assert [%{"session_id" => "ses1_knowledge", "assistant_message_id" => 4}] = listed.uses
  end

  test "the project read model includes active Triage context through its canonical interface",
       ctx do
    previous_client = SystemsRuntime.get_env(:bridge_for_teams_core, :salix_client)

    previous_triage =
      SystemsRuntime.get_env(:bridge_for_teams_core, :project_knowledge_triage_result)

    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, UsageClient)

    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :project_knowledge_triage_result,
      {:ok,
       %{
         items: [
           %{
             context_ref: "triage-retained-decision",
             kind: "decision",
             state: :active,
             subject: "Staging rollout owner",
             value: "Peng owns the staging rollout decision",
             confidence: "explicit",
             source_count: 2,
             next_check_at_ms: nil,
             resolved_at_ms: nil,
             inserted_at_ms: 1_788_300_000_000,
             updated_at_ms: 1_788_300_001_000
           }
         ],
         complete: true
       }}
    )

    on_exit(fn ->
      restore_env(:salix_client, previous_client)
      restore_env(:project_knowledge_triage_result, previous_triage)
    end)

    assert {:ok, result} = ProjectKnowledge.list_for_agent(ctx.agent.id)

    assert result.retained_context == [
             %{
               id: "triage-retained-decision",
               kind: :decision,
               source_kind: :decision,
               name: "Staging rollout owner",
               content: "Peng owns the staging rollout decision",
               confidence: "explicit",
               knowledge_scope: nil,
               scope_owner: nil,
               source_attribution: [],
               source_count: 2,
               source: %{type: "triage_context", ref: "triage-retained-decision"},
               next_check_at_ms: nil,
               updated_at_ms: 1_788_300_001_000
             }
           ]

    assert result.retained_context_status == :available
    assert result.retained_context_complete
  end

  test "retained personal decisions use the existing person subject without inventing a BFT member",
       ctx do
    previous_client = SystemsRuntime.get_env(:bridge_for_teams_core, :salix_client)

    previous_triage =
      SystemsRuntime.get_env(:bridge_for_teams_core, :project_knowledge_triage_result)

    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, UsageClient)
    person_id = "slack-user://T1/U_PENG"

    item = %{
      context_ref: "personal-codex",
      source_ref: "triage-context://personal-codex",
      kind: "decision",
      state: :active,
      subject: "Codex 工作流",
      value: "Peng 个人偏好先实现再补测试",
      confidence: "explicit",
      source_count: 1,
      updated_at_ms: 1_788_300_001_000,
      knowledge_scope: "person",
      scope_owner: %{"kind" => "person", "id" => person_id},
      source_attribution: [
        %{
          "actor_id" => "U_PENG",
          "message_ts" => "123.000001",
          "source_ref" => "slack://T1/C1/123/123"
        }
      ]
    }

    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :project_knowledge_triage_result,
      {:ok, %{items: [item], complete: true}}
    )

    on_exit(fn ->
      restore_env(:salix_client, previous_client)
      restore_env(:project_knowledge_triage_result, previous_triage)
    end)

    assert {:ok, result} = ProjectKnowledge.ground_retained_for_agent(ctx.agent.id, "Codex 工作流")
    assert [%{kind: :person, id: ^person_id}] = result.entities
    assert [fact] = result.facts
    assert fact.about == [{:person, person_id}]
    refute {:project, ctx.project.id} in fact.about
    assert fact.content =~ "123.000001"
    assert fact.content =~ "Explicit team rules take precedence"
    assert fact.source_refs == [%{type: "triage_context", ref: "triage-context://personal-codex"}]
  end

  test "the production Salix adapter turns PostgreSQL knowledge into the exact runtime payload",
       ctx do
    source = %{type: :slack_receipt, ref: "s3://triage/receipts/runtime.json"}

    assert {:ok, _} =
             ProjectKnowledge.register_alias(ctx.project.id, {:person, ctx.lin.id}, "Lin", source)

    assert {:ok, assertion} =
             ProjectKnowledge.append_assertion(
               ctx.project.id,
               :decision,
               "Lin owns the incident follow-up.",
               [{:person, ctx.lin.id}],
               source
             )

    previous = SystemsRuntime.get_env(:salix_agent, :project_knowledge_provider_mod)

    SystemsRuntime.put_env(
      :salix_agent,
      :project_knowledge_provider_mod,
      BridgeForTeams.ProjectKnowledge.AgentProvider
    )

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_agent, :project_knowledge_provider_mod, previous),
        else: SystemsRuntime.delete_env(:salix_agent, :project_knowledge_provider_mod)
    end)

    session = %{messages: [%{id: 1, role: "user", content: "What does Lin own?"}]}

    assert {:messages, [payload]} =
             SalixAgent.ProjectKnowledgeContext.prepare(
               ctx.agent.salix_agent_id,
               "session-runtime",
               session
             )

    assert payload["runtime_message_type"] == "project_knowledge"

    assert get_in(payload, ["source_refs", "assertions"]) == [
             %{
               "id" => assertion.id,
               "sources" => [%{"type" => "slack_receipt", "ref" => source.ref}]
             }
           ]
  end

  test "an assertion is hidden until every subject is resolved", ctx do
    source = %{type: :slack_receipt, ref: "s3://triage/receipts/partial.json"}

    assert {:ok, _} =
             ProjectKnowledge.register_alias(ctx.project.id, {:person, ctx.lin.id}, "Lin", source)

    assert {:ok, _} =
             ProjectKnowledge.register_alias(
               ctx.project.id,
               {:project, ctx.project.id},
               "Atlas",
               source
             )

    assert {:ok, _} =
             ProjectKnowledge.append_assertion(
               ctx.project.id,
               :fact,
               "Lin is coordinating Atlas.",
               [{:person, ctx.lin.id}, {:project, ctx.project.id}],
               source
             )

    assert {:ok, %{status: :resolved, facts: []}} =
             ProjectKnowledge.ground_for_agent(ctx.agent.id, "What is Lin coordinating?")
  end

  test "an alias collision fails closed without facts", ctx do
    {:ok, second_user} =
      Accounts.create_user(%{
        "email" => "second-lin-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.test",
        "name" => "Second Lin"
      })

    {:ok, _} = Memberships.put_org_member(ctx.org.id, second_user.id, "member")

    assert {:ok, _} =
             ProjectKnowledge.register_alias(
               ctx.project.id,
               {:person, ctx.lin.id},
               "Lin",
               %{type: :manual, ref: "manual://alias/lin-1"}
             )

    assert {:ok, _} =
             ProjectKnowledge.register_alias(
               ctx.project.id,
               {:person, second_user.id},
               "Lin",
               %{type: :manual, ref: "manual://alias/lin-2"}
             )

    assert {:ok, %{status: :ambiguous, entities: [], facts: []}} =
             ProjectKnowledge.ground_for_agent(ctx.agent.id, "Ask Lin about the launch")
  end

  test "a Han alias matches inside a Chinese sentence without spaces", ctx do
    source = %{type: :manual, ref: "manual://alias/xiaolin"}

    assert {:ok, _} =
             ProjectKnowledge.register_alias(
               ctx.project.id,
               {:person, ctx.lin.id},
               "小林",
               source
             )

    assert {:ok, _} =
             ProjectKnowledge.append_assertion(
               ctx.project.id,
               :fact,
               "小林负责发布清单。",
               [{:person, ctx.lin.id}],
               source
             )

    assert {:ok, %{status: :resolved, facts: [_fact]}} =
             ProjectKnowledge.ground_for_agent(ctx.agent.id, "请问小林负责什么？")
  end

  test "entities outside the project organization cannot be registered", ctx do
    suffix = SystemsRuntime.Proc.unique_integer([:positive])
    {:ok, other_org} = Orgs.create_org(%{"name" => "Other", "slug" => "other-#{suffix}"})

    {:ok, outsider} =
      Accounts.create_user(%{"email" => "outsider-#{suffix}@example.test", "name" => "Outsider"})

    {:ok, _} = Memberships.put_org_member(other_org.id, outsider.id, "member")

    assert {:error, :person_outside_project_org} =
             ProjectKnowledge.register_alias(
               ctx.project.id,
               {:person, outsider.id},
               "Outsider",
               %{type: :manual, ref: "manual://outsider"}
             )
  end

  test "knowledge assertions are append-only at the database boundary", ctx do
    assert {:ok, assertion} =
             ProjectKnowledge.append_assertion(
               ctx.project.id,
               :decision,
               "Ship after review.",
               [{:project, ctx.project.id}],
               %{type: :manual, ref: "manual://decision/ship"}
             )

    assert_raise Postgrex.Error, ~r/project knowledge records are append-only/, fn ->
      Repo.update!(Ecto.Changeset.change(assertion, content: "Mutated"))
    end

    assert %ProjectKnowledgeAssertion{id: id} = assertion
    assert is_binary(id)
  end

  defp restore_env(key, nil), do: SystemsRuntime.delete_env(:bridge_for_teams_core, key)
  defp restore_env(key, value), do: SystemsRuntime.put_env(:bridge_for_teams_core, key, value)
end
