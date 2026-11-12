defmodule SalixWeb.TaskStations do
  @moduledoc """
  Select a machine before a runtime Task is invited; accepted Tasks keep their
  stored device. The order: an authorized VMM Station, the requesting member's
  own connected Station, then a sandbox of the Task's own where the Group's
  Cloud VM is retired (`SalixAgent.Sandboxes.cloud_vm_retired?/1`), else its
  Cloudflare Cloud VM.
  """

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
            if SalixAgent.Sandboxes.cloud_vm_retired?(scope.group_id),
              do: sandbox(scope),
              else: cloudflare(scope, model)
        end
    end
  end

  def resolve(_, _), do: {:error, :invalid_runtime_model}

  # A sandbox of the Task's own: the Group under its limit of them, and its
  # start authorized against its credits (`Salix.Bindings.AgentConversations`).
  defp sandbox(scope), do: Salix.Bindings.AgentConversations.sandbox_place(scope)

  defp vmm(scope, model) do
    with {:ok, record} <- Compute.group_station(scope.tenant_id, scope.group_id),
         true <- record["status"] == "ready" || {:error, :vmm_station_not_ready},
         :ok <- cloud_accounts(scope, model),
         {:ok, _} <- candidate(scope, record["device_id"], model) do
      {:ok, %{"kind" => vmm_kind(scope, record["device_id"]), "device_id" => record["device_id"]}}
    end
  end

  # The Group's own VM on the Host was named as its Cloud VM; where the Cloud
  # VM is retired, that name is refused, and the VM is named as the station
  # it is.
  defp vmm_kind(scope, device_id) do
    if device_id == SalixStore.RuntimeIds.cloud_vm_device_id(scope.group_id) and
         not SalixAgent.Sandboxes.cloud_vm_retired?(scope.group_id),
       do: "cloud_vm",
       else: "station"
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

  @doc """
  The requesting member's own connected computers that take Tasks, whatever
  runtime they run: a Worker inside Salix can drive any of them. VMM Stations
  and the Group's Cloud VM are not a person's computers.
  """
  @spec personal_computers(map()) :: {:ok, [map()]} | {:error, term()}
  def personal_computers(scope) do
    with {:ok, member} <- requester(scope),
         true <-
           StationMembers.enroller?(scope.tenant_id, scope.group_id, member) ||
             {:error, :requester_not_authorized},
         rows when is_list(rows) <-
           StationDeviceLookup.page(scope.tenant_id, scope.group_id, member, @member_candidates) do
      {:ok, Enum.flat_map(rows, &personal_computer(scope, member, &1))}
    else
      {:error, _} = error -> error
      _ -> {:error, :station_lookup_unavailable}
    end
  end

  defp personal_computer(scope, member, row) do
    with {:ok, device} <- usable_device(scope, row.device_id),
         true <- get_in(device, ["meta", "owner_user_id"]) == member,
         true <- get_in(device, ["meta", "station_id"]) == row.station_id,
         true <- get_in(device, ["meta", "managed_compute"]) != true do
      [
        %{
          "device_id" => row.device_id,
          "station_id" => row.station_id,
          "name" => device["display_name"] || get_in(device, ["meta", "name"]) || row.device_id,
          "os" => get_in(device, ["meta", "os"]) || ""
        }
      ]
    else
      _ -> []
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
    with {:ok, device} <- usable_device(scope, device_id),
         true <- runs_model?(get_in(device, ["meta", "capabilities", "task_models"]), model) do
      {:ok, device}
    else
      _ -> {:error, :station_unavailable}
    end
  end

  defp usable_device(scope, device_id) do
    with :ok <-
           SalixStore.ComputeStation.admit_device(scope.tenant_id, scope.group_id, device_id),
         {:ok, %{"status" => "connected", "connector_run_id" => run} = device}
         when is_binary(run) and run != "" <-
           Registry.get_device(scope.tenant_id, scope.group_id, device_id),
         {:ok, _owner} <-
           SalixEnv.StationConnection.authorize(
             SalixStore.ComputeStation.connection(scope.tenant_id, scope.group_id, device)
           ),
         :ready <- SalixStore.StationReadiness.check(get_in(device, ["meta", "capabilities"])) do
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
