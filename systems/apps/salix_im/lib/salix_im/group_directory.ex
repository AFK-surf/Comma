defmodule SalixIM.GroupDirectory do
  @moduledoc """
  Read-only access to canonical groups and agents used by the IM runtime.

  Control-plane writers remain outside SalixIM. This module validates the
  records that IM consumers are allowed to observe and never mutates them.
  """

  alias SalixStore.ReadScope
  alias SalixStore.{CasRecord, Ids, Keys, S3}

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
      case read_record(Keys.ctl_agent(agent_id)) do
        {:ok,
         %{"agent_id" => ^agent_id, "tenant_id" => tenant_id, "group_id" => group_id} = agent} ->
          if Ids.valid_group_id_for_tenant?(group_id, tenant_id) and
               Ids.valid_agent_id_for_group?(agent_id, group_id) and
               not archived?(agent) and
               not blank?(agent["heartbeat_schedule_id"]) and
               (agent["role"] != "router" or not blank?(agent["router_session_id"])),
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
    with {:ok, _group} <- get_group(group_id),
         {:ok, objects} <- S3.list_all(Keys.ctl_agents_prefix_for_group(group_id)) do
      agents =
        Enum.flat_map(objects, fn %{key: key} ->
          agent_id =
            key
            |> String.replace_prefix(Keys.ctl_agents_prefix(), "")
            |> String.replace_suffix(".json", "")

          if key == Keys.ctl_agent(agent_id) do
            case get_agent(agent_id) do
              {:ok, %{"group_id" => ^group_id} = agent} -> [agent]
              _ -> []
            end
          else
            []
          end
        end)

      {:ok, agents}
    end
  end

  defp blank?(value), do: trim(value) == ""
  defp archived?(agent), do: Map.has_key?(agent, "archived_at")
  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()
  defp control_error(reason) when is_binary(reason), do: reason
  defp control_error(reason), do: inspect(reason)
end
