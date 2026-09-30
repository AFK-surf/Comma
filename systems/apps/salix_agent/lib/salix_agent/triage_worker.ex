defmodule SalixAgent.TriageWorker do
  @moduledoc "Group-owned Triage Worker selection shared by intake and configuration."
  alias SalixAgent.Control
  alias SalixStore.{CasRecord, Ids, Keys}
  @field "triage_worker"

  def get(group_id) do
    with true <- Ids.valid_group_id?(group_id),
         {:ok, group} <- CasRecord.get(Keys.ctl_group(group_id)) do
      {:ok, group[@field] || %{"source" => "unassigned", "revision" => 0}}
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  def ensure(group_id, router_id) do
    with {:ok, _router} <- router(group_id, router_id),
         {:ok, binding} <- get(group_id),
         {:ok, worker} <- worker(group_id, binding["worker_agent_id"]),
         :ok <- available(worker) do
      {:ok, worker["agent_id"]}
    end
  end

  def configure(group_id, router_id, worker_id, expected, audit)
      when is_integer(expected) and expected >= 0 and is_map(audit) do
    with {:ok, router} <- router(group_id, router_id),
         true <- present?(audit["actor_user_id"]) and present?(audit["request_id"]),
         {:ok, selected, source} <- selection(group_id, router, worker_id) do
      update(group_id, fn current ->
        cond do
          current["request_id"] == audit["request_id"] and
            current["worker_agent_id"] == selected and current["source"] == source ->
            {:unchanged, current}

          current["revision"] != expected ->
            {:error, :triage_worker_conflict}

          true ->
            binding(selected, source, router_id, expected + 1)
            |> Map.merge(Map.take(audit, ~w(actor_user_id request_id)))
            |> Map.put("previous_worker_agent_id", current["worker_agent_id"])
        end
      end)
    else
      false -> {:error, :invalid_audit}
      error -> error
    end
  end

  def configure(_, _, _, _, _), do: {:error, :invalid_request}

  defp update(group_id, fun) do
    with {:ok, group} <-
           CasRecord.update(
             Keys.ctl_group(group_id),
             fn group ->
               case fun.(group[@field] || %{"revision" => 0}) do
                 {:unchanged, _} -> {:unchanged, group}
                 {:error, _} = error -> error
                 value -> Map.put(group, @field, value)
               end
             end,
             create: false
           ),
         do: {:ok, group[@field]}
  end

  defp binding(id, source, router_id, revision),
    do: %{
      "worker_agent_id" => id,
      "source" => source,
      "revision" => revision,
      "router_agent_id" => router_id,
      "changed_at" => System.system_time(:millisecond)
    }

  defp selection(_group, _router, nil), do: {:ok, nil, "unassigned"}

  defp selection(group, _router, id) do
    with {:ok, record} <- worker(group, id), :ok <- available(record), do: {:ok, id, "assigned"}
  end

  defp available(record) do
    case availability(record) do
      %{"status" => status} when status in ["ready", "configured"] -> :ok
      _ -> {:error, :triage_worker_unavailable}
    end
  end

  def availability(record) do
    cond do
      not Control.visible?(record) ->
        %{"status" => "unavailable", "issue" => "worker_inactive"}

      Control.external_runtime?(record) ->
        case SalixAgent.RuntimeBindingResolver.status(
               record["runtime_config"],
               record["tenant_id"],
               record["group_id"]
             ) do
          {:ok, status} -> Map.take(status, ~w(status issue))
          _ -> %{"status" => "unknown"}
        end

      true ->
        case SalixAgent.Templates.resolve_template_for_record(record) do
          {:ok, _, _} -> %{"status" => "configured", "issue" => "execution_not_probed"}
          _ -> %{"status" => "unavailable", "issue" => "model_configuration_unavailable"}
        end
    end
  end

  defp router(group_id, router_id) do
    with {:ok, %{"group_id" => ^group_id, "role" => "router"} = record} <-
           Control.get_record(router_id),
         true <- Control.visible?(record),
         do: {:ok, record},
         else: (_ -> {:error, :triage_router_required})
  end

  defp worker(group_id, id) do
    with true <- Ids.valid_agent_id_for_group?(id, group_id),
         {:ok, %{"group_id" => ^group_id, "role" => "worker"} = record} <- Control.get_record(id),
         true <- Control.visible?(record),
         do: {:ok, record},
         else: (_ -> {:error, :triage_worker_unavailable})
  end

  defp present?(value), do: is_binary(value) and byte_size(value) in 1..256
end
