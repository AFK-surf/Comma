defmodule BridgeForTeams.ProjectKnowledgeLiveAcceptanceTest do
  @moduledoc """
  One real-model acceptance boundary for project-scoped knowledge.

  The deterministic tests prove retrieval, normalization, and atomic runtime
  publication. This test proves the remaining product claim: a BFT Agent
  reached through `BridgeForTeams.Agents.deliver/3` actually consumes the
  PostgreSQL-backed evidence, answers from it, and retains its assertion and
  source references in the durable Salix session.
  """

  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{Agents, Orgs, ProjectKnowledge, Projects, Repo}
  alias BridgeForTeams.Schema.Agent
  alias SalixAgent.LiveLlmTestSupport, as: Live

  @moduletag :live_llm
  @moduletag timeout: 300_000

  setup_all do
    {:ok, llm: Live.llm_config!()}
  end

  setup %{llm: llm} do
    SalixStore.S3.Fake.reset()
    restore_runtime = Live.install_runtime!()

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      restore_runtime.()
    end)

    suffix = Live.unique_suffix()

    {:ok, org} =
      Orgs.create_org(%{
        "name" => "Knowledge live #{suffix}",
        "slug" => "knowledge-live-#{suffix}"
      })

    {:ok, project} =
      Projects.create_project(org.id, %{
        "name" => "Atlas #{suffix}",
        "slug" => "atlas-live-#{suffix}"
      })

    agent = Repo.get_by!(Agent, project_id: project.id, role: "router")
    Live.configure!(agent.salix_agent_id, llm, %{"role" => "router"})

    %{agent: agent, project: project}
  end

  test "a real BFT Agent answers from sourced project knowledge and retains the evidence", ctx do
    source = %{
      type: :slack_receipt,
      ref: "s3://triage/receipts/live-project-knowledge.json"
    }

    assert {:ok, _alias} =
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
               "The Atlas launch codename is ORBITAL-TEAL-47.",
               [{:project, ctx.project.id}],
               source
             )

    session_id = Live.router_session_id!(ctx.agent.salix_agent_id)

    assert {:ok, status} =
             Agents.deliver(
               ctx.agent,
               %{
                 "content" => "What is the Atlas launch codename? Reply with the exact codename."
               },
               source_message_id: "project-knowledge-live:#{assertion.id}"
             )

    assert status in [:created, :duplicate]

    session = Live.await_session_settled!(ctx.agent.salix_agent_id, session_id)

    assert Enum.any?(SalixAgent.InternalSession.get(session, :messages), fn message ->
             message.role == "assistant" and
               String.contains?(Live.text_content(message.content), "ORBITAL-TEAL-47")
           end)

    assert %{role: "runtime", type: "project_knowledge", source_refs: source_refs} =
             Enum.find(SalixAgent.InternalSession.get(session, :messages), fn message ->
               message.role == "runtime" and message.type == "project_knowledge"
             end)

    assert source_refs["provider"] == "bft_project_knowledge"

    assert source_refs["assertions"] == [
             %{
               "id" => assertion.id,
               "sources" => [
                 %{"type" => "slack_receipt", "ref" => source.ref}
               ]
             }
           ]
  end
end
