defmodule SalixWeb.TaskStations do
  @moduledoc "Select a machine before a runtime Task is invited; accepted Tasks keep their stored device."

  alias SalixStore.{Compute, StationMembers, StationDeviceLookup}
  alias SalixEnv.Registry

  @member_candidates 8
  @cloud_start_budget_ms 15_000

  def resolve(scope, %{"kind" => "runtime", "provider" => provider} = model)
      when provider in ~w(codex claude) do
    case vmm(scope, model) do
      {:ok, _} = selected ->
        selected

      {:error, reason} when reason in [:ambiguous_vmm_hosts, :ambiguous_vmm_environments] ->
        {:error, reason}

      _ ->
        case physical(scope, model) do
          {:ok, _} = selected ->
            selected

          {:error, reason} = limited
          when reason in [:station_candidate_page_exhausted, :station_lookup_unavailable] ->
            limited

          _ ->
            cloudflare(scope, model)
        end
    end
  end

  def resolve(_, _), do: {:error, :invalid_runtime_model}

  defp vmm(scope, model) do
    with {:ok, record} <- Compute.group_station(scope.tenant_id, scope.group_id),
         true <- record["status"] == "ready" || {:error, :vmm_station_not_ready},
         :ok <- cloud_accounts(scope, model),
         {:ok, _} <- candidate(scope, record["device_id"], model) do
      {:ok,
       %{
         "kind" =>
           if(record["device_id"] == SalixStore.RuntimeIds.cloud_vm_device_id(scope.group_id),
             do: "cloud_vm",
             else: "station"
           ),
         "device_id" => record["device_id"]
       }}
    end
  end

  defp physical(scope, model) do
    with {:ok, member} <- requester(scope),
         true <-
           StationMembers.enroller?(scope.tenant_id, scope.group_id, member) ||
             {:error, :requester_not_authorized},
         rows when is_list(rows) <-
           StationDeviceLookup.page(scope.tenant_id, scope.group_id, member, @member_candidates) do
      Enum.find_value(rows, fn row ->
        with {:ok, device} <- candidate(scope, row.device_id, model),
             true <- get_in(device, ["meta", "owner_user_id"]) == member,
             true <- get_in(device, ["meta", "station_id"]) == row.station_id,
             true <- get_in(device, ["meta", "managed_compute"]) != true do
          {:ok, %{"kind" => "station", "device_id" => row.device_id}}
        else
          _ -> nil
        end
      end) ||
        {:error,
         if(length(rows) == @member_candidates,
           do: :station_candidate_page_exhausted,
           else: :no_personal_station
         )}
    end
  end

  defp cloudflare(scope, model) do
    with {:ok, agent} <- SalixAgent.Control.get_record(scope.agent_id),
         true <- SalixAgent.CloudVM.allowed?(agent) || {:error, :cloud_vm_disabled},
         :ok <- cloud_accounts(scope, model),
         :ok <- start_cloudflare(scope),
         {:ok, %{"provider" => "cloudflare", "status" => "ready"} = record} <-
           Compute.group_workload(scope.group_id),
         {:ok, _} <- candidate(scope, record["device_id"], model) do
      {:ok, %{"kind" => "cloud_vm", "device_id" => record["device_id"]}}
    else
      {:error, _} = error -> error
      _ -> {:error, :cloud_vm_not_running}
    end
  end

  defp start_cloudflare(scope) do
    case Compute.group_workload(scope.group_id) do
      {:ok, %{"provider" => "agent_vmm"}} ->
        {:error, :cloudflare_station_not_configured}

      {:ok, %{"provider" => "cloudflare", "status" => "ready"}} ->
        :ok

      _ ->
        case SalixWeb.CloudVM.Start.run(scope.agent_id, @cloud_start_budget_ms) do
          {:ok, _} -> :ok
          {:error, reason, _steps} -> {:error, reason}
        end
    end
  end

  defp candidate(scope, device_id, model) do
    with :ok <-
           SalixStore.ComputeStation.admit_device(scope.tenant_id, scope.group_id, device_id),
         {:ok, %{"status" => "connected", "connector_run_id" => run} = device}
         when is_binary(run) and run != "" <-
           Registry.get_device(scope.tenant_id, scope.group_id, device_id),
         {:ok, _owner} <-
           SalixEnv.StationConnection.authorize(
             SalixStore.ComputeStation.connection(scope.tenant_id, scope.group_id, device)
           ),
         :ready <- SalixStore.StationReadiness.check(get_in(device, ["meta", "capabilities"])),
         true <- runs_model?(get_in(device, ["meta", "capabilities", "task_models"]), model) do
      {:ok, device}
    else
      _ -> {:error, :station_unavailable}
    end
  end

  defp runs_model?(models, %{"provider" => provider, "model" => model}) when is_map(models),
    do: model in List.wrap(models[provider])

  defp runs_model?(models, %{"provider" => provider}) when is_map(models),
    do: List.wrap(models[provider]) != []

  defp runs_model?(_, _), do: false

  defp cloud_accounts(scope, %{"provider" => provider}) do
    case {provider, SalixWeb.StationLLM.tier()} do
      {"codex", {:ok, _}} ->
        :ok

      _ ->
        case SalixAgent.SubscriptionStore.runtime_candidates(scope.tenant_id, provider) do
          {:ok, [_ | _]} -> :ok
          _ -> {:error, :cloud_runtime_account_unavailable}
        end
    end
  end

  defp requester(%{requester_user_id: member}) when is_binary(member), do: {:ok, member}

  defp requester(scope) do
    case SalixAgent.IFC.principal(scope[:trusted_origin]) do
      {:comma_user, member} ->
        {:ok, member}

      {:provider_user, connect_id, subject} ->
        with {:ok, connect} <-
               SalixIM.ProviderConnects.get_active_connect_by_id(scope.group_id, connect_id),
             do: StationMembers.requester(scope.tenant_id, scope.group_id, connect, subject)

      _ ->
        {:error, :requester_required}
    end
  end
end
