defmodule BridgeForTeams.TestSupport.CanonicalAgentClient do
  @moduledoc "Real Agent owner calls for tests that replace an unrelated Salix integration."
  def drain do
    previous = SystemsRuntime.get_env(:bridge_for_teams_core, :salix_client)
    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, BridgeForTeams.Salix.Erpc)

    try do
      drain_batches(100)
    after
      if previous do
        SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, previous)
      else
        SystemsRuntime.delete_env(:bridge_for_teams_core, :salix_client)
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
      ensure_provisioned!(project)
      {:ok, project}
    end
  end

  # The drain counts a failed row as progress, so a project whose group or
  # router was never created would otherwise come back as provisioned.
  defp ensure_provisioned!(project) do
    import Ecto.Query

    agent_ids =
      from(a in BridgeForTeams.Schema.Agent,
        where: a.project_id == ^project.id,
        select: type(a.id, :string)
      )
      |> BridgeForTeams.Repo.all()

    unsettled =
      from(r in BridgeForTeams.Schema.ReconcileOutbox,
        where:
          r.status != "done" and
            ((r.aggregate == "organization" and r.aggregate_id == ^project.org_id) or
               (r.aggregate == "project" and r.aggregate_id == ^project.id) or
               (r.aggregate == "agent" and r.aggregate_id in ^agent_ids)),
        order_by: [asc: r.created_at],
        select: {r.op, r.status, r.attempts, r.last_error}
      )
      |> BridgeForTeams.Repo.all()

    if unsettled != [],
      do: raise("Project fixture is not provisioned: #{inspect(unsettled)}")
  end

  def create_provisioned_agent(project_id, attrs) do
    # BridgeForTeams makes no new Worker: one is made as before the
    # retirement (`BridgeForTeams.TestSupport.LegacyWorker`).
    create =
      if to_string(attrs["role"] || attrs[:role]) == "worker",
        do: &BridgeForTeams.TestSupport.LegacyWorker.create/2,
        else: &BridgeForTeams.Agents.create_agent/2

    with {:ok, agent} <- create.(project_id, attrs) do
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
      defdelegate triage_tools(group), to: BridgeForTeams.Salix.Erpc
      defdelegate ensure_task_agent(tenant, group), to: BridgeForTeams.Salix.Erpc
      defdelegate archive_agent_configuration(id, tenant), to: BridgeForTeams.Salix.Erpc

      defdelegate rebind_station_worker(id, tenant, binding, expected),
        to: BridgeForTeams.Salix.Erpc

      defdelegate claim_agent_configuration(id, tenant, archived_at),
        to: BridgeForTeams.Salix.Erpc

      defdelegate page_group_agents(tenant, group, opts), to: BridgeForTeams.Salix.Erpc
      defdelegate get_agent(id, tenant), to: BridgeForTeams.Salix.Erpc
      defdelegate model_catalog(), to: BridgeForTeams.Salix.Erpc
      defdelegate servable_models(tenant), to: BridgeForTeams.Salix.Erpc
      defdelegate choose_model(choice, tenant), to: BridgeForTeams.Salix.Erpc
      defdelegate public_model(choice, tenant), to: BridgeForTeams.Salix.Erpc
      defdelegate platform_model(role), to: BridgeForTeams.Salix.Erpc
      defdelegate get_group_task_model(group), to: BridgeForTeams.Salix.Erpc
      defdelegate put_group_task_model(tenant, group, choice), to: BridgeForTeams.Salix.Erpc
      defdelegate get_group_task_place(group), to: BridgeForTeams.Salix.Erpc
      defdelegate put_group_task_place(tenant, group, place), to: BridgeForTeams.Salix.Erpc

      defdelegate create_placed_task_conversation(group, router, attrs),
        to: BridgeForTeams.Salix.Erpc

      defoverridable create_owned_agent: 1,
                     configure_agent: 3,
                     archive_agent_configuration: 2,
                     rebind_station_worker: 4,
                     claim_agent_configuration: 3,
                     page_group_agents: 3,
                     get_agent: 2,
                     model_catalog: 0,
                     servable_models: 1,
                     choose_model: 2,
                     public_model: 2,
                     platform_model: 1,
                     get_group_task_model: 1,
                     put_group_task_model: 3,
                     get_group_task_place: 1,
                     put_group_task_place: 3,
                     create_placed_task_conversation: 3
    end
  end
end
