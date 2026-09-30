defmodule BridgeForTeams.ProjectKnowledge.AgentProvider do
  @moduledoc "Runtime adapter from a Salix Agent identity to BFT project knowledge."

  alias BridgeForTeams.{ProjectKnowledge, Repo}
  alias BridgeForTeams.Schema.Agent
  alias BridgeForTeams.SourcedContext.Grounding

  def retrieve(salix_agent_id, question, _context) do
    if Process.whereis(Repo) do
      case BridgeForTeams.Agents.get_agent(salix_agent_id) do
        {:ok, %Agent{} = agent} ->
          if Agent.active?(agent) do
            base = ProjectKnowledge.ground_for_agent(agent.id, question)

            overlay =
              Grounding.ground_for_project_agent(
                agent.id,
                question,
                Grounding.project_agent_capability(agent)
              )

            base = Grounding.merge_results(base, overlay)
            add_retained(base, agent.id, question)
          else
            :none
          end

        _ ->
          :none
      end
    else
      :none
    end
  end

  defp add_retained(
         {:ok, %{status: :resolved, facts: facts, entities: entities}} = base,
         agent_id,
         question
       )
       when length(facts) < 20 and length(entities) < 20 do
    retained =
      ProjectKnowledge.ground_retained_for_agent(agent_id, question,
        limit: min(20 - length(facts), 20 - length(entities))
      )

    Grounding.merge_results(base, retained)
  end

  defp add_retained({:ok, %{status: :unknown}} = base, agent_id, question) do
    Grounding.merge_results(base, ProjectKnowledge.ground_retained_for_agent(agent_id, question))
  end

  defp add_retained(base, _agent_id, _question), do: base
end
