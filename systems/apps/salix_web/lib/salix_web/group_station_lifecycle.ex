defmodule SalixWeb.GroupStationLifecycle do
  @moduledoc "Idle suspension of Group-owned native runtimes; Session work remains authoritative."
  alias SalixStore.Compute, as: GroupCompute
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

  # Where the Group's Cloud VM is retired (`SalixAgent.Sandboxes.cloud_vm_retired?/1`),
  # a Cloudflare VM that is not running is not started again: whoever asked
  # is told so once, and nothing waits for it. One still running serves until
  # the cutover stops it (`SalixWeb.Migrations.CloudVMCutover`). The Agent
  # VMM Host's container is the Group's own machine and wakes as before.
  def wake(group) do
    case GroupCompute.group_workload(group) do
      {:ok, %{"provider" => "cloudflare", "status" => status} = rec}
      when status != "ready" ->
        if SalixAgent.Sandboxes.cloud_vm_retired?(group),
          do: {:error, retired_error(rec["env_id"])},
          else: wake_cloudflare(rec)

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

  @doc """
  What a command or Task told the Group's retired Cloud VM is not started
  answers: not retryable, with what to do instead.
  """
  def retired_error(env_id \\ nil) do
    %{
      "error_class" => "cloud_vm_retired",
      "retryable" => false,
      "message" =>
        "the Group's Cloud VM is retired here: sandboxes have taken its place, and it is not " <>
          "started again. Run the work in a sandbox Task: task.create with runs_on {kind: sandbox}.",
      "env_id" => env_id
    }
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

  @idle_archive_ms 300_000
  @idle_archive_refusal_backoff_max 4

  @doc "Whether the Group Station can suspend without interrupting current work."
  def idle_eligible(rec, opts), do: idle_archive_eligible?(rec, opts)

  defp idle_archive_eligible?(%{"provider" => provider, "status" => "ready"} = rec, opts)
       when provider in ["cloudflare", "agent_vmm"] do
    now = opts[:now] || now_ms()
    idle_ms = idle_period(opts)
    settled = rec["last_agent_settled_after_vm_at"]
    # A provisioned VM that has never run an operation has no agent settlement
    # to wait for. Start its idle grace at readiness, not at provision start.
    idle_since =
      settled ||
        if(is_nil(rec["last_operation_at"]), do: rec["ready_at"])

    active_count = rec["active_operation_count"] || 0

    cond do
      provider_cutover_archive_hold?(rec) ->
        {:skip, :provider_cutover_archive_pending}

      not Keyword.get(opts, :force, false) and (rec["archive_retry_at"] || 0) > now ->
        {:skip, :archive_retry_pending}

      (rec["runtime_selection_until"] || 0) > now ->
        {:skip, :runtime_selection}

      # A teardown abandons the operations still counted active (one that
      # never finished would hold the stop for good, `abandon_operations/2`)
      # and waits for no agent settle: the VM is wanted stopped.
      Keyword.get(opts, :abandon_operations, false) ->
        :ok

      active_count > 0 ->
        {:skip, :active_operations}

      is_nil(idle_since) ->
        {:skip, :not_settled_after_vm}

      Keyword.get(opts, :force, false) ->
        :ok

      now - idle_clock_start(rec, idle_since) >= idle_ms ->
        :ok

      true ->
        {:skip, :not_idle}
    end
  end

  defp idle_archive_eligible?(_rec, _opts), do: {:skip, :not_cloudflare_ready}

  # The idle clock starts at the latest of: readiness, the last operation Salix
  # ran on the VM, the agent's settle after it, and the station's last Task
  # activity (`mark_station_activity/2`).
  def idle_clock_start(rec, idle_since) do
    Enum.max([
      rec["last_operation_at"] || 0,
      idle_since || 0,
      rec["ready_at"] || 0,
      rec["last_station_activity_at"] || 0
    ])
  end

  @doc """
  The station refused to park for an idle archive (it was busy): the record,
  back to ready, waits a full idle period before the next one, doubled for
  each refusal in a row (at most #{@idle_archive_refusal_backoff_max} times),
  until the VM is used again (a Salix operation, or the station's Task
  activity) or archives.
  """
  @spec refused_idle_archive(map(), keyword()) :: map()
  def refused_idle_archive(current, opts) do
    refusals = (current["archive_refusals"] || 0) + 1

    wait =
      idle_period(opts) *
        min(Integer.pow(2, refusals - 1), @idle_archive_refusal_backoff_max)

    current
    |> Map.put("archive_refusals", refusals)
    |> Map.put("archive_retry_at", now_ms() + wait)
  end

  def provider_cutover_archive_hold?(rec),
    do:
      get_in(rec, ["provider_migration", "archive_hold"]) ==
        "awaiting_durable_archive"

  @doc false
  def idle_period(opts), do: Keyword.get(opts, :idle_archive_ms, @idle_archive_ms)

  defp now_ms, do: SystemsClock.system_time(:millisecond)
end
