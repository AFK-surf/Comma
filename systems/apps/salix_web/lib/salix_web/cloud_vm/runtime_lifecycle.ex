defmodule SalixWeb.CloudVM.RuntimeLifecycle do
  @moduledoc "Idle suspension of Group-owned native runtimes; Session work remains authoritative."
  alias SalixStore.Compute, as: GroupCompute
  # Compute parks the whole Cloud VM: a Cloudflare archive, or a stopped
  # container on an Agent VMM Host.
  def reconcile(_), do: :ok

  @doc "Keep pre-dispatch execution demand until a bounded deadline."
  def hold(group, tenant, device_id, until) do
    case GroupCompute.update_group_workload(group, fn
           %{
             "tenant_id" => ^tenant,
             "device_id" => ^device_id,
             "provider" => provider,
             "status" => status
           } = current
           when provider in ~w(cloudflare agent_vmm) and
                  status in ~w(creating ready archived waking) ->
             current
             |> Map.put("runtime_activity", SystemsRuntime.Proc.uuid())
             |> Map.put(
               "runtime_selection_until",
               max(current["runtime_selection_until"] || 0, until)
             )

           _ ->
             {:error, :target_unavailable}
         end) do
      {:ok, _, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def wake(group) do
    case GroupCompute.group_workload(group) do
      {:ok, %{"provider" => "cloudflare"} = rec} ->
        wake_cloudflare(rec)

      # The tenant's own Host: its stopped container starts again, unmetered.
      {:ok, %{"provider" => "agent_vmm", "status" => status} = rec}
      when status in ~w(archived waking) ->
        request_wake(rec)

      _ ->
        :ok
    end
  end

  defp wake_cloudflare(%{"status" => status, "group_id" => group})
       when status in ~w(creating billing_suspended eligible_for_resume),
       do: SalixWeb.ComputeProviders.Cloudflare.authorize_resume(group)

  defp wake_cloudflare(%{"status" => status}) when status not in ~w(archived waking), do: :ok

  defp wake_cloudflare(rec) do
    with :ok <- SalixWeb.ComputeProviders.Cloudflare.authorize_resume(rec["group_id"]) do
      request_wake(rec)
    end
  end

  defp request_wake(rec) do
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
