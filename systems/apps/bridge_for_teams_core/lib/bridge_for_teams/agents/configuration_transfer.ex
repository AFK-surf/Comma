defmodule BridgeForTeams.Agents.ConfigurationTransfer do
  @moduledoc "Bounded operator inventory for the one-release configuration handoff."
  import Ecto.Query
  alias BridgeForTeams.{Agents, Repo}
  alias BridgeForTeams.Salix.Client
  alias BridgeForTeams.Schema.{Agent, Organization, Project}
  alias SalixStore.{AgentConfigurationRollout, Ids}

  @page_size 20

  # The release runner owns this cursor. No new persistent work queue or timer.
  # References and native pages include the pre-rollout population. New
  # provisioning after admission writes canonical records and needs no backfill.
  def page(nil), do: page(%{"stage" => "references"})

  def page(cursor) when is_map(cursor) do
    with :ok <- AgentConfigurationRollout.ensure_open(),
         {:ok, candidates, next} <- release_inventory(cursor),
         {:ok, count} <- transfer(candidates) do
      if next == nil do
        with :ok <- AgentConfigurationRollout.complete(),
             do: {:ok, %{processed: count, next_cursor: nil}}
      else
        {:ok, %{processed: count, next_cursor: next}}
      end
    end
  end

  defp release_inventory(%{"stage" => "references"} = cursor) do
    {items, next} = inventory([after: cursor["after"]], @page_size)

    next =
      if next, do: %{"stage" => "references", "after" => next}, else: %{"stage" => "projects"}

    {:ok, items, next}
  end

  defp release_inventory(%{"stage" => "projects"} = cursor) do
    project =
      if id = cursor["project"] do
        Repo.get!(Project, id)
      else
        query = from p in Project, order_by: [asc: p.id], limit: 1
        query = if cursor["after"], do: where(query, [p], p.id > ^cursor["after"]), else: query
        Repo.one(query)
      end

    cond do
      project == nil ->
        {:ok, [], nil}

      project.salix_group_id == nil ->
        {:ok, [], %{"stage" => "projects", "after" => project.id}}

      true ->
        org = Repo.get!(Organization, project.org_id)

        with {:ok, page} <-
               Client.impl().page_group_agents(org.salix_tenant_id, project.salix_group_id,
                 limit: @page_size,
                 cursor: cursor["native"],
                 lifecycle: "all"
               ) do
          next =
            if page.next_cursor,
              do: %{"stage" => "projects", "project" => project.id, "native" => page.next_cursor},
              else: %{"stage" => "projects", "after" => project.id}

          {:ok, canonical_candidates(project, page.items), next}
        end
    end
  end

  defp release_inventory(_), do: {:error, :invalid_transfer_cursor}

  defp transfer(candidates) do
    Enum.reduce_while(candidates, {:ok, 0}, fn candidate, {:ok, count} ->
      result =
        if candidate.needs_transfer,
          do: Agents.transfer_configuration(candidate.id),
          else: {:ok, candidate}

      case result do
        {:ok, _} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, {:agent_transfer_failed, candidate.id, reason}}}
      end
    end)
  end

  def inventory(opts, limit) do
    cond do
      opts[:project] ->
        project = Repo.get!(Project, opts[:project])
        org = Repo.get!(Organization, project.org_id)

        case Client.impl().page_group_agents(org.salix_tenant_id, project.salix_group_id,
               limit: limit,
               cursor: opts[:cursor],
               lifecycle: "all"
             ) do
          {:ok, page} -> {canonical_candidates(project, page.items), page.next_cursor}
          {:error, reason} -> raise("Salix inventory unavailable: #{inspect(reason)}")
        end

      opts[:agent] && Ids.valid_agent_id?(opts[:agent]) ->
        project = Repo.get_by!(Project, salix_group_id: Ids.group_id_from_agent!(opts[:agent]))
        org = Repo.get!(Organization, project.org_id)

        case Client.impl().get_agent(opts[:agent], org.salix_tenant_id) do
          {:ok, record} -> {canonical_candidates(project, [record]), nil}
          {:error, reason} -> raise("Agent inventory unavailable: #{inspect(reason)}")
        end

      true ->
        query = from a in Agent, order_by: [asc: a.id], limit: ^limit
        query = if opts[:after], do: where(query, [a], a.id > ^opts[:after]), else: query
        query = if opts[:agent], do: where(query, [a], a.id == ^opts[:agent]), else: query
        agents = Repo.all(query)
        next = if length(agents) == limit and is_nil(opts[:agent]), do: List.last(agents).id
        {Enum.map(agents, &candidate(&1, nil)), next}
    end
  end

  defp canonical_candidates(project, records) do
    ids = Enum.map(records, & &1["agent_id"])

    refs =
      Repo.all(from a in Agent, where: a.project_id == ^project.id and a.salix_agent_id in ^ids)
      |> Map.new(&{&1.salix_agent_id, &1})

    Enum.map(records, fn record ->
      ref =
        refs[record["agent_id"]] ||
          %Agent{
            id: record["agent_id"],
            salix_agent_id: record["agent_id"],
            project_id: project.id,
            configuration_authority: record["configuration_authority"] || "legacy"
          }

      candidate(ref, record)
    end)
  end

  defp candidate(agent, record) do
    %{
      id: agent.id,
      salix_agent_id: agent.salix_agent_id,
      configuration_authority: agent.configuration_authority,
      needs_transfer:
        agent.configuration_authority != "salix" ||
          (record != nil && record["configuration_authority"] != "salix")
    }
  end
end
