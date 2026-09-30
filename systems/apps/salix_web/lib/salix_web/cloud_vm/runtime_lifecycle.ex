defmodule SalixWeb.CloudVM.RuntimeLifecycle do
  @moduledoc "Idle suspension of Group-owned native runtimes; Session work remains authoritative."
  alias SalixStore.Compute, as: GroupCompute
  # Cloudflare parks the whole resource through Compute's archive transition.
  def reconcile(_), do: :ok

  def demand?(group) do
    case SalixStore.SessionWorkCandidates.ready_for_external_group?(group) do
      {:ok, value} -> value
      _ -> true
    end
  end

  # Management selection is a mutation, unlike device/runtime discovery.
  # A bounded hold prevents parking while reconnect inventory becomes selectable.
  def select_target(id, scope, opts \\ []) do
    select = fn ->
      SalixEnv.Control.select_device_runtime_binding(id, scope.tenant_id, scope.group_id)
    end

    case select.() do
      {:error, :target_unavailable} -> select_vm_target(id, scope, opts, select)
      result -> result
    end
  end

  defp select_vm_target(id, scope, opts, select) do
    with {:ok,
          %{
            "tenant_id" => tenant,
            "device_id" => device_id,
            "provider" => provider,
            "runtime_connector" => true,
            "status" => status
          }} <- GroupCompute.group_workload(scope.group_id),
         true <- tenant == scope.tenant_id,
         true <- provider == "cloudflare" and status in ~w(ready archived waking),
         {:ok, %{"device_id" => ^device_id} = device} <-
           SalixEnv.RuntimeTargets.device(scope.tenant_id, scope.group_id, id),
         true <-
           Enum.any?(
             get_in(device, ["meta", "agent_runtimes"]) || [],
             &(&1["device_runtime_id"] == id)
           ) do
      timeout = Keyword.get(opts, :timeout, 30_000) |> max(0) |> min(30_000)
      deadline = System.monotonic_time(:millisecond) + timeout

      with :ok <-
             hold(scope.group_id, tenant, device_id, System.system_time(:millisecond) + timeout,
               require_runtime_connector: true
             ) do
        await_wake(scope.group_id, select, deadline)
      else
        _ -> {:error, :target_unavailable}
      end
    else
      {:error, :target_discovery_required} = error -> error
      {:error, :target_not_found} = error -> error
      _ -> {:error, :target_unavailable}
    end
  end

  @doc "Keep selection or pre-dispatch execution demand until a bounded deadline."
  def hold(group, tenant, device_id, until, opts \\ []) do
    case GroupCompute.update_group_workload(group, fn
           %{
             "tenant_id" => ^tenant,
             "device_id" => ^device_id,
             "provider" => "cloudflare",
             "status" => status
           } = current
           when status in ~w(creating ready archived waking) ->
             if opts[:require_runtime_connector] == true and current["runtime_connector"] != true do
               {:error, :target_unavailable}
             else
               current
               |> Map.put("runtime_activity", Ecto.UUID.generate())
               |> Map.put(
                 "runtime_selection_until",
                 max(current["runtime_selection_until"] || 0, until)
               )
             end

           _ ->
             {:error, :target_unavailable}
         end) do
      {:ok, _, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp await_wake(group, select, deadline) do
    case wake(group) do
      :ok ->
        await_selection(select, deadline)

      {:error, :runtime_waking} ->
        if pause_selection(deadline),
          do: await_wake(group, select, deadline),
          else: {:error, :target_unavailable}
    end
  end

  defp await_selection(select, deadline) do
    case select.() do
      {:error, :target_unavailable} = error ->
        if pause_selection(deadline), do: await_selection(select, deadline), else: error

      result ->
        result
    end
  end

  defp pause_selection(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining > 0, do: Process.sleep(min(remaining, 200))
    remaining > 0
  end

  def wake_binding(config, tenant, group) when is_map(config) do
    with {:ok, %{"tenant_id" => ^tenant, "runtime_connector" => true} = rec} <-
           GroupCompute.group_workload(group),
         {:ok, device} <-
           SalixEnv.RuntimeTargets.device(tenant, group, config["device_runtime_id"]),
         true <- device["device_id"] == rec["device_id"] do
      wake(group)
    else
      _ -> :ok
    end
  end

  def wake_binding(_, _, _), do: :ok

  def wake(group) do
    case GroupCompute.group_workload(group) do
      {:ok, %{"provider" => "cloudflare"} = rec} ->
        wake_cloudflare(rec)

      _ ->
        :ok
    end
  end

  defp wake_cloudflare(%{"status" => status}) when status not in ~w(archived waking), do: :ok

  defp wake_cloudflare(rec) do
    case SalixEnv.ComputeReconciler.request_group_wake(rec["group_id"]) do
      {:error, :group_recovery_action_required} ->
        {:error,
         %{
           "error_class" => "vm_recovery_action_required",
           "retryable" => false,
           "message" => "VM recovery requires operator action",
           "env_id" => rec["env_id"]
         }}

      result ->
        result
    end
  end
end
