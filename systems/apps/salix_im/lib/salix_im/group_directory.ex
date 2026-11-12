defmodule SalixIM.GroupDirectory do
  @moduledoc """
  Read-only access to canonical groups and agents used by the IM runtime.

  Control-plane writers remain outside SalixIM. This module validates the
  records that IM consumers are allowed to observe and never mutates them.
  """

  alias SalixStore.ReadScope
  alias SalixStore.{AgentPGStore, CasRecord, Ids, Keys}

  def scope_for_agent(agent_id) do
    agent_id = trim(agent_id)

    cond do
      agent_id == "" ->
        {:error, "tenant_id and group_id are required"}

      true ->
        with {:ok, agent} <- get_agent(agent_id) do
          tenant_id = trim(agent["tenant_id"])
          group_id = trim(agent["group_id"])

          if tenant_id == "" or group_id == "" do
            {:error, "tenant_id and group_id are required"}
          else
            {:ok, %{agent: agent, agent_id: agent_id, tenant_id: tenant_id, group_id: group_id}}
          end
        else
          {:error, :not_found} -> {:error, "agent not found"}
          {:error, reason} -> {:error, control_error(reason)}
        end
    end
  end

  def get_agent(agent_id) do
    if Ids.valid_agent_id?(agent_id) do
      case ReadScope.fetch({:agent_config, agent_id}, fn ->
             case AgentPGStore.read_config(agent_id) do
               {:ok, %{record: record}} -> {:ok, record}
               error -> error
             end
           end) do
        {:ok,
         %{"agent_id" => ^agent_id, "tenant_id" => tenant_id, "group_id" => group_id} = agent} ->
          if visible_agent?(agent, agent_id, tenant_id, group_id),
            do: {:ok, agent},
            else: {:error, :not_found}

        {:ok, _record} ->
          {:error, :not_found}

        {:error, _} = error ->
          error
      end
    else
      {:error, :not_found}
    end
  end

  def get_group(group_id, tenant_id \\ nil) do
    if Ids.valid_group_id?(group_id) do
      case read_record(Keys.ctl_group(group_id)) do
        {:ok, %{"group_id" => ^group_id, "tenant_id" => owner_tenant_id} = group} ->
          if Ids.valid_group_id_for_tenant?(group_id, owner_tenant_id) and
               not blank?(group["router_conversation_id"]) and
               (blank?(tenant_id) or owner_tenant_id == trim(tenant_id)),
             do: {:ok, group},
             else: {:error, :not_found}

        {:ok, _record} ->
          {:error, :not_found}

        {:error, _} = error ->
          error
      end
    else
      {:error, :not_found}
    end
  end

  # One provider callback or one delivery reads the same Group and Agent
  # records at several seams; inside a `SalixStore.ReadScope` the stored
  # record is read once and validated per caller.
  defp read_record(key), do: ReadScope.fetch({:record, key}, fn -> CasRecord.get(key) end)

  def list_group_agents(group_id) do
    with {:ok, _group} <- get_group(group_id) do
      list_agent_pages(group_id, nil, [])
    end
  end

  defp list_agent_pages(group_id, cursor, pages) do
    with {:ok, %{items: records, next: next}} <-
           AgentPGStore.page_configs(%{group_id: group_id}, cursor: cursor, limit: 500) do
      agents =
        Enum.filter(records, fn agent ->
          visible_agent?(agent, agent["agent_id"], agent["tenant_id"], group_id)
        end)

      if is_nil(next),
        do: {:ok, pages |> Enum.reverse() |> List.flatten() |> Kernel.++(agents)},
        else: list_agent_pages(group_id, next, [agents | pages])
    end
  end

  defp visible_agent?(agent, agent_id, tenant_id, group_id) do
    Ids.valid_group_id_for_tenant?(group_id, tenant_id) and
      Ids.valid_agent_id_for_group?(agent_id, group_id) and
      not archived?(agent) and not blank?(agent["heartbeat_schedule_id"]) and
      (agent["role"] != "router" or not blank?(agent["router_session_id"]))
  end

  defp blank?(value), do: trim(value) == ""
  defp archived?(agent), do: Map.has_key?(agent, "archived_at")
  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()
  defp control_error(reason) when is_binary(reason), do: reason
  defp control_error(reason), do: inspect(reason)
end
