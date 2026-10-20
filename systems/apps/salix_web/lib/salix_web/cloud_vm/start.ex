defmodule SalixWeb.CloudVM.Start do
  @moduledoc """
  An agent starting its Group's Cloud VM itself (`cloud_vm.start`), as one
  turns on a remote computer before sending it anything: a new Task for a
  station not connected is refused (`SalixWeb.StationTasks`); only a Message
  of a Task its station already takes part in wakes it by itself. An agent
  may start it for itself or for a live Worker of its Group it names, when the
  Group's Cloud VM switch is on (`SalixAgent.CloudVM.allowed?/1`).
  It asks for what the VM needs next (created when there is none
  or it failed, woken when archived or its Connector is gone) and follows it
  until its station is connected, the VM failed, or `budget_ms` ran out.

  The answer names each state the VM went through, in order, with the seconds
  since the start: `none`, `creating`, `archived`, `archiving`, `waking`,
  `reviving`, `ready` (up, its station not connected yet), `connected`,
  `failed`, or another status the provider gives.
  """

  alias SalixWeb.ComputeProviders.Cloudflare

  @step_ms 1_000

  @spec run(String.t(), non_neg_integer(), String.t() | nil) ::
          {:ok, map()} | {:error, term(), [map()]}
  def run(agent_id, budget_ms, worker_id \\ nil) when is_binary(agent_id) do
    with {:ok, %{"group_id" => group, "tenant_id" => tenant} = agent} <-
           SalixAgent.Control.get_record(agent_id),
         {:ok, worker} <- worker(agent, worker_id),
         true <- SalixAgent.CloudVM.allowed?(worker) || {:error, :cloud_vm_disabled} do
      started = SystemsClock.monotonic_time(:millisecond)

      follow(%{
        agent: agent,
        group: group,
        tenant: tenant,
        device: SalixStore.RuntimeIds.cloud_vm_device_id(group),
        started: started,
        deadline: started + budget_ms,
        created?: false,
        steps: []
      })
    else
      {:ok, _agent} -> {:error, :not_found, []}
      {:error, reason} -> {:error, reason, []}
    end
  end

  # The caller starts its Group's VM for itself or for a Worker of that same
  # Group; the Group's switch decides for both.
  defp worker(agent, nil), do: {:ok, agent}
  defp worker(%{"agent_id" => id} = agent, id), do: {:ok, agent}

  defp worker(%{"group_id" => group}, worker_id) when is_binary(worker_id) do
    case SalixAgent.Control.get_record(worker_id) do
      {:ok, %{"group_id" => ^group} = worker} -> {:ok, worker}
      {:ok, _other_group} -> {:error, :worker_not_found}
      {:error, :not_found} -> {:error, :worker_not_found}
      {:error, _} = error -> error
    end
  end

  defp worker(_agent, _worker_id), do: {:error, :worker_not_found}

  defp follow(run) do
    state = state(run)
    run = step(run, state)
    left = run.deadline - SystemsClock.monotonic_time(:millisecond)

    cond do
      state == "connected" ->
        {:ok, %{"status" => "connected", "steps" => Enum.reverse(run.steps)}}

      state == "failed" and run.created? ->
        {:error, :cloud_vm_failed, Enum.reverse(run.steps)}

      left <= 0 ->
        {:error, :timeout, Enum.reverse(run.steps)}

      true ->
        case ask(run, state) do
          {:ok, run} ->
            SystemsClock.sleep(min(@step_ms, left))
            follow(run)

          {:error, reason} ->
            {:error, reason, Enum.reverse(run.steps)}
        end
    end
  end

  defp state(run) do
    status =
      case Cloudflare.get_record(run.group) do
        {:ok, %{"status" => status}} when is_binary(status) -> status
        {:error, :not_found} -> "none"
        _other -> "unknown"
      end

    if status == "ready" and connected?(run), do: "connected", else: status
  end

  defp connected?(run) do
    match?(
      {:ok, %{"status" => "connected", "connector_run_id" => id}} when is_binary(id) and id != "",
      SalixEnv.Registry.get_device(run.tenant, run.group, run.device)
    )
  end

  defp step(%{steps: [%{"state" => state} | _]} = run, state), do: run

  defp step(run, state) do
    at = div(SystemsClock.monotonic_time(:millisecond) - run.started, 1_000)
    %{run | steps: [%{"state" => state, "at_s" => at} | run.steps]}
  end

  # What the VM needs next: created (once), or woken. A VM on its way is left
  # to come up.
  defp ask(%{created?: false} = run, state) when state in ~w(none failed) do
    case Cloudflare.ensure_provisioning(run.agent) do
      {:ok, _record} -> {:ok, %{run | created?: true}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ask(run, state) when state in ~w(archived ready) do
    case Cloudflare.wake_if_archived(run.group) do
      {:error, %{"error_class" => _} = error} -> {:error, error}
      _waking_or_ready -> {:ok, run}
    end
  end

  defp ask(run, _state), do: {:ok, run}
end
