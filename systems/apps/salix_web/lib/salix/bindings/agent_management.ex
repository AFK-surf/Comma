defmodule Salix.Bindings.AgentManagement do
  @moduledoc false
  @behaviour SalixAgent.AgentManagement.Ports
  alias Salix.Control.Groups

  def project_id(scope) do
    with {:ok, group} <- Groups.get(scope.group_id, scope.tenant_id) do
      case group["billing_owner"] do
        %{"surface" => "bridge", "project_id" => id} when is_binary(id) -> {:ok, id}
        _ -> {:error, :target_not_found}
      end
    end
  end

  def connected_target(id, scope) do
    case SalixWeb.CloudVM.RuntimeLifecycle.select_target(id, scope) do
      {:ok, binding} -> {:ok, binding}
      {:error, :target_not_found} -> {:error, :target_not_found}
      {:error, :target_discovery_required} -> {:error, :target_discovery_required}
      {:error, %{"error_class" => "billing_unavailable"}} = error -> error
      {:error, {:bad_request, _}} -> {:error, :target_not_found}
      _ -> {:error, :target_unavailable}
    end
  end

  def page_targets(caller, args) do
    query = [caller["tenant_id"], caller["group_id"], args["kind"], args["provider"]]

    with {:ok, cursor} <- target_cursor(args["cursor"], query),
         {:ok, page} <- target_page(caller, args, cursor) do
      next =
        if page.next_cursor,
          do: [query, page.next_cursor] |> Jason.encode!() |> Base.url_encode64(padding: false),
          else: nil

      {:ok, %{items: page.items, next_cursor: next}}
    end
  end

  defp target_page(caller, %{"kind" => "connected"} = args, cursor) do
    SalixEnv.Control.page_external_runtime_targets(caller["tenant_id"], caller["group_id"],
      limit: args["limit"],
      cursor: cursor,
      provider: args["provider"]
    )
  end

  defp target_page(caller, %{"kind" => "compute", "provider" => provider} = args, cursor)
       when provider in ~w(codex pi claude) do
    scope = %{tenant_id: caller["tenant_id"], group_id: caller["group_id"]}

    with {:ok, project} <- project_id(scope),
         {:ok, page} <-
           SalixStore.ExternalWorkerTargets.page(
             %{
               tenant_id: scope.tenant_id,
               group_id: scope.group_id,
               owner_type: "project",
               owner_id: project,
               provider: provider
             },
             limit: args["limit"],
             cursor: cursor,
             include_unavailable: true
           ) do
      {:ok,
       %{
         next_cursor: page.next_cursor,
         items:
           Enum.map(page.items, fn item ->
             %{
               "target" => %{
                 "kind" => "compute",
                 "workload_id" => item.workload_id,
                 "selection_fence" => item.selection_fence
               },
               "runtime" => %{
                 "kind" => "compute",
                 "provider" => item.provider,
                 "workload_id" => item.workload_id
               },
               "selectable" => item.selectable,
               "reason" => item.reason
             }
           end)
       }}
    end
  end

  defp target_page(_, _, _), do: {:error, :invalid_arguments}

  defp target_cursor(nil, _query), do: {:ok, nil}

  defp target_cursor(cursor, query) when is_binary(cursor) and byte_size(cursor) <= 4096 do
    with {:ok, bytes} <- Base.url_decode64(cursor, padding: false),
         {:ok, [^query, token]} <- Jason.decode(bytes),
         true <- is_binary(token),
         do: {:ok, token},
         else: (_ -> {:error, :invalid_cursor})
  end

  defp target_cursor(_, _), do: {:error, :invalid_cursor}

  def worker_template(scope),
    do: SalixAgent.AgentDefaults.creation_template("worker", scope.tenant_id)
end
