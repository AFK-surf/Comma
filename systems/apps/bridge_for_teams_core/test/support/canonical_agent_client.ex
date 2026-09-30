defmodule BridgeForTeams.TestSupport.CanonicalAgentClient do
  @moduledoc "Real Agent owner calls for tests that replace an unrelated Salix integration."
  def drain do
    previous = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, BridgeForTeams.Salix.Erpc)

    try do
      drain_batches(100)
    after
      if previous do
        Application.put_env(:bridge_for_teams_core, :salix_client, previous)
      else
        Application.delete_env(:bridge_for_teams_core, :salix_client)
      end
    end
  end

  defp drain_batches(0), do: raise("Agent fixture outbox did not drain within 100 batches")

  defp drain_batches(remaining) do
    case BridgeForTeams.Salix.Reconciler.drain_once() do
      {:ok, 0} -> :ok
      {:ok, _} -> drain_batches(remaining - 1)
      error -> raise "Agent fixture provisioning failed: #{inspect(error)}"
    end
  end

  def create_provisioned_project(org_id, attrs, opts \\ []) do
    with {:ok, project} <- BridgeForTeams.Projects.create_project(org_id, attrs, opts) do
      drain()
      {:ok, project}
    end
  end

  def create_provisioned_agent(project_id, attrs) do
    with {:ok, agent} <- BridgeForTeams.Agents.create_agent(project_id, attrs) do
      drain()

      case BridgeForTeams.Agents.get_agent(agent.id) do
        {:ok, %{provisioning: nil, salix: %{"agent_id" => _}} = ready} -> {:ok, ready}
        other -> raise "Agent fixture is not active: #{inspect(other)}"
      end
    end
  end

  defmacro __using__(_) do
    quote do
      defdelegate create_owned_agent(attrs), to: BridgeForTeams.Salix.Erpc
      defdelegate configure_agent(id, tenant, attrs), to: BridgeForTeams.Salix.Erpc
      defdelegate triage_worker_binding(group), to: BridgeForTeams.Salix.Erpc
      defdelegate archive_agent_configuration(id, tenant), to: BridgeForTeams.Salix.Erpc

      defdelegate rebind_agent_configuration(id, tenant, target, expected, invocation),
        to: BridgeForTeams.Salix.Erpc

      defdelegate claim_agent_configuration(id, tenant, archived_at),
        to: BridgeForTeams.Salix.Erpc

      defdelegate page_group_agents(tenant, group, opts), to: BridgeForTeams.Salix.Erpc
      defdelegate get_agent(id, tenant), to: BridgeForTeams.Salix.Erpc

      defoverridable create_owned_agent: 1,
                     configure_agent: 3,
                     archive_agent_configuration: 2,
                     rebind_agent_configuration: 5,
                     claim_agent_configuration: 3,
                     page_group_agents: 3,
                     get_agent: 2
    end
  end
end
