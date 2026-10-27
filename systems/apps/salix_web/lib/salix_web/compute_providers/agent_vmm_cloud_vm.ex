defmodule SalixWeb.ComputeProviders.AgentVMMCloudVM do
  @moduledoc """
  A Group's Cloud VM on an Agent VMM Host: the Group's `station.default`
  container (`SalixEnv.ComputeProviders.AgentVMM`). The shared Compute
  reconciler advances it through the Group record's status, as it does a
  Cloudflare Cloud VM, with the same status names.

  The Host's volume is persistent, so nothing is exported: an idle VM sleeps
  by stopping its container (`archiving`, then `archived`) and wakes by
  starting it again (`waking`, then `ready`). Before the stop, the station
  confirms it is quiet and stays parked (`cloud_runtime_quiesce`, then
  `cloud_runtime_release`), as before a Cloudflare archive. A station that is
  busy or not connected keeps the VM ready; a busy one makes the next try wait
  longer (`SalixWeb.ComputeProviders.Cloudflare.refused_idle_archive/2`).

  `opts` may name the container provider (`:vmm`, default
  `SalixEnv.ComputeProviders.AgentVMM`) and the station's connection
  (`:station`, default `#{inspect(__MODULE__)}.Station`).
  """

  alias SalixStore.Compute, as: GroupCompute
  alias SalixWeb.ComputeProviders.Cloudflare

  @quiesce_ms 100_000
  @release_ms 20_000

  @doc "Advance one claimed Group Workload on an Agent VMM Host."
  def reconcile(allocation, workload, opts) do
    with %GroupCompute.Environment{owner_type: "group", owner_id: group} <-
           SalixStore.Repo.get(GroupCompute.Environment, workload.environment_id),
         {:ok, %{"workload_id" => id, "provider" => "agent_vmm"} = rec} <-
           GroupCompute.group_workload(group),
         true <-
           (id == workload.id and rec["generation"] == workload.generation) ||
             {:error, :stale_generation} do
      reconcile_record(rec, allocation, workload, opts)
    else
      nil -> {:error, :not_found}
      {:ok, _other_provider} -> {:error, :unsupported_provider}
      {:error, _} = error -> error
    end
  end

  defp reconcile_record(rec, allocation, workload, opts) do
    group = rec["group_id"]

    cond do
      workload.desired_state in ["stopped", "draining"] ->
        vmm(opts).reconcile(allocation, workload, opts)

      rec["status"] == "archived" and is_integer(rec["wake_requested_at"]) ->
        with {:ok, _} <- start_waking(group), do: run(group, allocation, workload, opts)

      # `pending`: the Host saw the ready VM's container stop (a VM restart).
      # The Workload follows the container facts again: run and verify it.
      rec["status"] in ["creating", "waking", "pending"] ->
        run(group, allocation, workload, opts)

      rec["status"] == "archiving" ->
        sleep(rec, allocation, workload, opts)

      rec["status"] == "ready" ->
        ready(rec, allocation, workload, opts)

      true ->
        {:ok, %{outcome: :group_reconciled}}
    end
  end

  # The container runs: created, started, or left running. The VM is ready
  # once the Host runs it; its station then connects by itself. The record's
  # status is the Workload's observed state, so this write settles it.
  defp run(group, allocation, workload, opts) do
    case vmm(opts).reconcile(allocation, workload, opts) do
      {:ok, %{outcome: :succeeded}} ->
        with {:ok, ready, previous} <-
               update_with_previous(group, fn
                 %{"status" => status} = current
                 when status in ["creating", "waking", "pending"] ->
                   current
                   |> Map.put("status", "ready")
                   |> Map.put("ready_at", now_ms())
                   |> Map.put("error", nil)

                 current ->
                   current
               end) do
          emit_wake_end(previous, ready)
          SalixWeb.StationTasks.vm_ready(previous, ready)
          {:ok, %{outcome: :group_reconciled}}
        end

      other ->
        other
    end
  end

  defp start_waking(group) do
    update(group, fn
      %{"status" => "archived"} = current ->
        current
        |> Map.put("status", "waking")
        |> Map.put("last_wake_at", now_ms())
        |> Map.delete("wake_requested_at")

      %{"status" => "waking"} = current ->
        current

      _ ->
        {:error, :wake_superseded}
    end)
  end

  defp ready(rec, allocation, workload, opts) do
    cond do
      Cloudflare.idle_eligible(rec, opts) == :ok ->
        sleep_idle(rec, allocation, workload, opts)

      station(opts).connected?(rec) ->
        {:ok, %{outcome: :group_reconciled}}

      # A ready VM whose station is gone: the Host shows whether its
      # container still runs, and starts it again when it stopped.
      true ->
        run(rec["group_id"], allocation, workload, opts)
    end
  end

  defp sleep_idle(rec, allocation, workload, opts) do
    operation = "sleep-" <> SystemsRuntime.Proc.uuid()

    case update(rec["group_id"], fn current ->
           if current["status"] == "ready" and Cloudflare.idle_eligible(current, opts) == :ok do
             current
             |> Map.put("status", "archiving")
             |> Map.put("archive_operation_id", operation)
             |> Map.put("archive_started_at", now_ms())
             |> Map.put("archive_reason", "idle")
           else
             {:error, :not_idle}
           end
         end) do
      {:ok, archiving} -> sleep(archiving, allocation, workload, opts)
      {:error, :not_idle} -> {:ok, %{outcome: :group_reconciled}}
      {:error, _} = error -> error
    end
  end

  # The station parks quiet under the operation's token, then the container
  # stops. Once the station released itself, only the stop remains, even when
  # its connection is already gone.
  defp sleep(%{"archive_reason" => "idle_committing"} = rec, allocation, workload, opts),
    do: stop(rec, allocation, workload, opts)

  defp sleep(rec, allocation, workload, opts) do
    operation = rec["archive_operation_id"]
    station = station(opts)

    with :quiet <- quiesce(station, rec, operation),
         {:ok, %{"released" => true}} <-
           station.request(rec, "cloud_runtime_release", %{"token" => operation}, @release_ms),
         {:ok, committing} <-
           update(rec["group_id"], fn current ->
             if current["status"] == "archiving" and current["archive_operation_id"] == operation,
               do: Map.put(current, "archive_reason", "idle_committing"),
               else: {:error, :sleep_superseded}
           end) do
      stop(committing, allocation, workload, opts)
    else
      :not_quiet -> resume(station, rec, operation, :not_quiet, opts)
      _unreachable -> resume(station, rec, operation, :unreachable, opts)
    end
  end

  defp quiesce(station, rec, operation) do
    case station.request(
           rec,
           "cloud_runtime_quiesce",
           %{"token" => operation, "timeout_ms" => @quiesce_ms},
           @quiesce_ms
         ) do
      {:ok, %{"quiet" => true}} ->
        :quiet

      {:ok, %{"quiet" => false}} ->
        :not_quiet

      # The station's connector answers with the method first.
      {:error, why}
      when why in ["runtime is not quiet", "cloud_runtime_quiesce: runtime is not quiet"] ->
        :not_quiet

      _ ->
        :unreachable
    end
  end

  defp stop(rec, allocation, workload, opts) do
    operation = rec["archive_operation_id"]

    with {:ok, :stopped} <- vmm(opts).stop_container(allocation, workload, operation),
         {:ok, archived, previous} <-
           update_with_previous(rec["group_id"], fn current ->
             if current["status"] == "archiving" and current["archive_operation_id"] == operation do
               current
               |> Map.put("status", "archived")
               |> Map.put("archived_at", now_ms())
               |> Map.put("archive_last_operation", %{
                 "operation" => operation,
                 "result" => "stopped"
               })
               |> Map.delete("archive_operation_id")
               |> Map.delete("archive_reason")
               |> Map.delete("archive_refusals")
             else
               {:error, :sleep_superseded}
             end
           end) do
      emit_archive_end(previous, archived["archived_at"], "ok")
      {:ok, %{outcome: :group_reconciled}}
    end
  end

  # A busy or unreachable station keeps its VM: it leaves the parked state and
  # the VM is ready again. Nothing of the sleep began, so the archive counts as
  # refused. A busy station waits a growing idle period before the next try;
  # one that is away is asked again in a minute.
  defp resume(station, rec, operation, why, opts) do
    _ = station.request(rec, "cloud_runtime_resume", %{"token" => operation}, @release_ms)

    with {:ok, resumed, previous} <-
           update_with_previous(rec["group_id"], fn current ->
             if current["status"] == "archiving" and current["archive_operation_id"] == operation do
               current
               |> Map.put("status", "ready")
               |> Map.delete("archive_operation_id")
               |> Map.delete("archive_reason")
               |> wait_before_next_sleep(why, opts)
             else
               current
             end
           end) do
      if previous["status"] == "archiving" and resumed["status"] == "ready",
        do: emit_archive_end(previous, now_ms(), "refused")

      SalixWeb.StationTasks.vm_ready(previous, resumed)
      {:ok, %{outcome: :group_reconciled}}
    end
  end

  defp wait_before_next_sleep(current, :not_quiet, opts),
    do: Cloudflare.refused_idle_archive(current, opts)

  defp wait_before_next_sleep(current, :unreachable, _opts),
    do: Map.put(current, "archive_retry_at", now_ms() + 60_000)

  # ---- lifecycle metrics (Salix.Telemetry, salix.vm.*) ----

  defp metric_metadata(rec) do
    %{
      provider: "agent_vmm",
      profile: get_in(rec, ["provider_spec", "profile_key"]) || "unknown"
    }
  end

  # The write that made a waking record ready ends its wake.
  defp emit_wake_end(
         %{"status" => "waking", "last_wake_at" => last_wake_at},
         %{
           "status" => "ready",
           "ready_at" => ready_at
         } = ready
       )
       when is_integer(last_wake_at) and is_integer(ready_at) do
    Salix.Telemetry.emit_vm_wake(
      Map.put(metric_metadata(ready), :outcome, "ok"),
      ready_at - last_wake_at
    )
  end

  defp emit_wake_end(_previous, _ready), do: :ok

  # The write that ends a sleep: stopped (ok) or kept ready (cancelled).
  defp emit_archive_end(%{"archive_started_at" => started_at} = previous, ended_at, outcome)
       when is_integer(started_at) and is_integer(ended_at) do
    Salix.Telemetry.emit_vm_archive(
      previous |> metric_metadata() |> Map.merge(%{reason: "idle", outcome: outcome}),
      ended_at - started_at
    )
  end

  defp emit_archive_end(_previous, _ended_at, _outcome), do: :ok

  @doc "Whether the station of this Cloud VM's container is connected now."
  def station_connected?(rec), do: __MODULE__.Station.connected?(rec)

  defp vmm(opts), do: Keyword.get(opts, :vmm, SalixEnv.ComputeProviders.AgentVMM)
  defp station(opts), do: Keyword.get(opts, :station, __MODULE__.Station)

  defp update(group, fun) do
    with {:ok, current, _previous} <- update_with_previous(group, fun), do: {:ok, current}
  end

  defp update_with_previous(group, fun) do
    case GroupCompute.update_group_workload(group, fun) do
      {:ok, current, previous} -> {:ok, current, previous}
      {:error, _} = error -> error
    end
  end

  defp now_ms, do: SystemsClock.system_time(:millisecond)

  defmodule Station do
    @moduledoc "The connection of a Cloud VM's station: the Group device's current connector run."

    def connected?(rec), do: match?({:ok, _run}, run(rec))

    def request(rec, method, params, timeout) do
      case run(rec) do
        {:ok, run} -> SalixEnv.Connector.Live.request(run, method, params, timeout: timeout)
        :error -> {:error, :disconnected}
      end
    end

    defp run(%{"tenant_id" => tenant, "group_id" => group, "device_id" => device} = rec)
         when is_binary(tenant) and is_binary(group) and is_binary(device) do
      resource = rec["provider_resource_name"]

      case SalixEnv.Registry.get_device(tenant, group, device) do
        {:ok,
         %{
           "status" => "connected",
           "connector_run_id" => run,
           "meta" => %{"provider" => "agent_vmm", "provider_resource_name" => ^resource}
         }}
        when is_binary(run) and run != "" ->
          {:ok, run}

        _ ->
          :error
      end
    end

    defp run(_rec), do: :error
  end
end
