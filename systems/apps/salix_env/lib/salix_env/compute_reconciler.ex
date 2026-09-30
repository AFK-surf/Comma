defmodule SalixEnv.ComputeReconciler do
  @moduledoc """
  Bounded production caller for provider-specific Compute convergence.

  Each pass selects at most `@batch_size` desired Workloads for the Cloudflare and Agent VMM
  providers through the workload/allocation/provider-binding indexes and
  advances each exact `(workload_id, generation)` once. Provider operations are
  idempotent command intents; an unknown side effect is observed before a new
  command is issued.
  """

  # Capacity rejection settlement maps to
  # tla/salix/ComputeCapacityAction.tla. Other scheduling refinements have no
  # current standalone model; see tla/README.md.

  use GenServer

  import Ecto.Query
  require Logger

  alias SalixStore.{Compute, Repo}

  @batch_size 32
  @candidate_limit 128
  @max_per_tenant 8
  @default_interval_ms 5_000
  # Agent VMM import needs 15 minutes; Cloudflare archive restore can use 45.
  @claim_lease_ms 900_000
  @cloudflare_claim_lease_ms 3_300_000
  @claim_retry_ms 5_000
  @max_retry_ms 60_000
  @concurrency 4
  @task_budget_ms 870_000
  @cursor_id "compute-reconciler-agent-vmm"
  @provider "agent_vmm"
  # One release-owned row, three product templates. Selection adds no Host RPC
  # or per-Workload timer. The existing fair cursor and four task slots bound work.
  @runtime_update_due_sql """
  ? = 'ready' AND EXISTS (
    SELECT 1 FROM compute_runtime_release release
    WHERE release.id = 1
      AND release.templates->?->>'runtime_revision' <> ?
      AND NOT (COALESCE(?->>'phase', '') = 'cancelled'
        AND COALESCE(?->>'target_revision', '') = release.templates->?->>'runtime_revision')
  )
  """
  @external_demand_sql """
  EXISTS (
    SELECT 1 FROM session_work_candidates swc
    WHERE swc.workload_id = ?
      AND (swc.due_at_ms IS NULL
        OR swc.due_at_ms <= floor(extract(epoch FROM statement_timestamp()) * 1000)::bigint)
  ) OR EXISTS (
    SELECT 1 FROM compute_commands cc
    WHERE cc.workload_id = ? AND cc.target_generation = ?
      AND cc.status IN ('pending', 'admitted', 'executing', 'unknown_outcome')
  ) OR EXISTS (
    SELECT 1 FROM compute_runtime_inputs input
    WHERE input.workload_id = ? AND input.generation = ?
      AND input.status IN ('pending', 'in_flight')
  )
  """
  @external_runtime_active_sql """
  EXISTS (
    SELECT 1 FROM compute_runtime_instances active_runtime
    LEFT JOIN compute_reconciler_claims recovery
      ON recovery.workload_id = active_runtime.workload_id
      AND recovery.generation = active_runtime.generation
      AND recovery.provider = 'agent_vmm'
    WHERE active_runtime.workload_id = ?
      AND active_runtime.generation = ?
      AND ((active_runtime.status = 'connected'
        AND active_runtime.readiness = 'ready'
        AND active_runtime.connection_epoch = active_runtime.caught_up_epoch)
        OR recovery.last_error->>'runtime_recovery_deadline' IS NOT NULL)
  )
  """
  # Select each obsolete health projection once so its normal reconciliation
  # removes the key. Container facts then decide whether idle cleanup is due.
  @external_idle_cleanup_sql """
  EXISTS (
    SELECT 1
    FROM (VALUES (?::jsonb)) AS observed(value)
    WHERE jsonb_exists(observed.value, 'health')
      OR (
        observed.value->>'imported_reference' IS NOT NULL
        AND (
          NOT jsonb_exists(observed.value, 'current_container')
          OR jsonb_typeof(observed.value->'current_container') IS DISTINCT FROM 'object'
          OR observed.value->>'container_status' = 'running'
          OR (
            observed.value->'current_container' = '{}'::jsonb
            AND observed.value->>'container_status' IS DISTINCT FROM 'absent'
          )
          OR (
            observed.value->'current_container' <> '{}'::jsonb
            AND (
              observed.value->>'container_status' IS NULL
              OR observed.value->>'container_status' NOT IN ('created', 'stopped')
            )
          )
        )
      )
  )
  """
  @runtime_ready_sql """
  NOT EXISTS (
    SELECT 1
    FROM compute_runtime_instances r
    WHERE r.workload_id = ?
      AND r.generation = ?
      AND r.status = 'connected'
      AND r.readiness = 'ready'
      AND r.connection_epoch = r.caught_up_epoch
      AND EXISTS (
        SELECT 1
        FROM agent_vmm_sessions s
        WHERE s.registration_id = ?
          AND s.runtime_instance_id = r.id
          AND s.allocation_id = ?
          AND s.status = 'ready'
          AND s.expires_at > ?
          AND s.allocation_generation = ?
          AND s.gateway_instance_id = (?->>'gateway_instance_id')
          AND s.connection_epoch = (?->>'connection_epoch')
          AND EXISTS (
            SELECT 1 FROM (SELECT ?::jsonb AS facts) proof
            WHERE proof.facts->>'runtime_verified_host_epoch' = s.connection_epoch
              AND proof.facts->>'runtime_execution_epoch' = r.connection_epoch
              AND proof.facts->>'runtime_container_instance_id' <> ''
              AND proof.facts->>'runtime_container_instance_id' = proof.facts->'current_container'->>'instance_id'
              AND proof.facts->>'container_status' = 'running'
          )
      )
  )
  """

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec reconcile_workload(String.t(), pos_integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def reconcile_workload(workload_id, generation, opts \\ [])
      when is_binary(workload_id) and is_integer(generation) and generation > 0 do
    with %Compute.Workload{} = workload <- Repo.get(Compute.Workload, workload_id),
         true <- workload.generation == generation || {:error, :stale_generation},
         true <-
           workload.desired_state in ["ready", "draining", "stopped"] ||
             {:error, :not_desired},
         :ok <- ensure_claim_current(workload, opts),
         %Compute.Allocation{} = allocation <-
           Repo.get(Compute.Allocation, workload.allocation_id),
         true <- allocation.status != "released" || {:error, :allocation_released},
         %Compute.ProviderBinding{provider: provider} <-
           Repo.get(Compute.ProviderBinding, allocation.provider_binding_id),
         :ok <- provider_budget(provider, workload, allocation, opts),
         result <- reconcile_provider(provider, allocation, workload, opts) do
      settle_result(workload, result, Keyword.get(opts, :claim_token))
    else
      nil -> {:error, :not_found}
      false -> {:error, :stale_generation}
      {:error, _} = error -> error
      _ -> {:error, :unsupported_provider}
    end
  rescue
    exception ->
      Logger.error("Compute reconciliation failed",
        workload_id: workload_id,
        stage: :provider_reconcile,
        exception: inspect(exception.__struct__)
      )

      {:error, :unavailable}
  end

  defp provider_budget("agent_vmm", workload, allocation, opts),
    do: runtime_recovery_budget(workload, allocation, opts)

  defp provider_budget(provider, workload, _allocation, _opts)
       when provider == "cloudflare" do
    claim =
      Repo.one(
        from(c in Compute.ReconcilerClaim,
          where:
            c.provider == ^provider and c.workload_id == ^workload.id and
              c.generation == ^workload.generation
        )
      )

    deadline = claim && (claim.last_error || %{})["provider_recovery_deadline"]

    case deadline && DateTime.from_iso8601(deadline) do
      {:ok, expires, _} ->
        if DateTime.compare(DateTime.utc_now(), expires) != :lt,
          do:
            {:error,
             {:gateway_error,
              %{
                "code" => "group_provider_recovery_expired",
                "provider_recovery_deadline" => deadline
              }}},
          else: :ok

      _ ->
        :ok
    end
  end

  defp provider_budget(_, _, _, _), do: {:error, :unsupported_provider}

  defp reconcile_provider("agent_vmm", allocation, workload, opts),
    do: SalixEnv.ComputeProviders.AgentVMM.reconcile(allocation, workload, opts)

  # salix_web composes Group/runtime ownership above salix_env. This fixed call
  # avoids a reverse application dependency; provider selection is not configurable.
  defp reconcile_provider(provider, allocation, workload, opts)
       when provider == "cloudflare",
       do: apply(SalixWeb.ComputeProviders.Cloudflare, :reconcile, [allocation, workload, opts])

  @doc "Advance an expired recovery retry without changing its execution identity. Call through the release RPC boundary."
  def retry_runtime_recovery(workload_id, generation, expected_deadline)
      when is_binary(workload_id) and is_integer(generation) and is_binary(expected_deadline) do
    Repo.transaction(fn ->
      workload = Repo.get(Compute.Workload, workload_id)

      claim =
        Repo.one(
          from(c in Compute.ReconcilerClaim,
            where:
              c.provider in ["agent_vmm", "cloudflare"] and
                c.workload_id == ^workload_id and
                c.generation == ^generation,
            lock: "FOR UPDATE"
          )
        )

      now = DateTime.utc_now()
      error = (claim && claim.last_error) || %{}

      {code, deadline_key} =
        if claim && claim.provider == "cloudflare",
          do: {"group_provider_recovery_expired", "provider_recovery_deadline"},
          else: {"runtime_recovery_expired", "runtime_recovery_deadline"}

      desired =
        workload &&
          (workload.desired_state == "ready" ||
             (claim && claim.provider == "cloudflare" &&
                workload.desired_state in ["draining", "stopped"]))

      unless workload && workload.generation == generation && desired &&
               claim && error["code"] == code &&
               error[deadline_key] == expected_deadline &&
               (is_nil(claim.lease_expires_at) ||
                  DateTime.compare(claim.lease_expires_at, now) != :gt) do
        Repo.rollback(:recovery_changed)
      end

      Repo.update_all(from(c in Compute.ReconcilerClaim, where: c.id == ^claim.id),
        set: [
          last_error:
            if(claim.provider == "agent_vmm",
              do: Map.put(error, "kind", "retryable"),
              else: Map.drop(error, ["kind", "code", deadline_key])
            ),
          next_retry_at: now,
          updated_at: now
        ]
      )

      %{workload_id: workload_id, generation: generation, retry: "scheduled"}
    end)
  end

  @doc "Request an archived Group wake, reopening only a recovery superseded by a later archive."
  def request_group_wake(group_id) when is_binary(group_id) do
    case Compute.update_group_workload(group_id, fn
           %{"provider" => "cloudflare", "status" => "archived"} = current ->
             case admit_archived_group_wake(current) do
               :ok -> Map.put(current, "wake_requested_at", System.system_time(:millisecond))
               {:error, _} = error -> error
             end

           %{"provider" => "cloudflare", "status" => "ready"} = current ->
             Map.put(current, "runtime_activity", Ecto.UUID.generate())

           %{"provider" => "cloudflare", "status" => "waking"} = current ->
             current

           _ ->
             {:error, :runtime_waking}
         end) do
      {:ok, %{"status" => "ready"}, _} ->
        :ok

      {:ok, %{"status" => status}, _} when status in ~w(archived waking) ->
        {:error, :runtime_waking}

      {:error, _} = error ->
        error
    end
  end

  defp admit_archived_group_wake(current) do
    workload = Repo.get(Compute.Workload, current["workload_id"])

    claim =
      workload &&
        Repo.one(
          from(c in Compute.ReconcilerClaim,
            where:
              c.provider == "cloudflare" and c.workload_id == ^workload.id and
                c.generation == ^workload.generation,
            lock: "FOR UPDATE"
          )
        )

    case claim && claim.last_error do
      %{"kind" => "action_required", "code" => "group_provider_recovery_expired"} = error ->
        archived_at = current["archived_at"]

        if (is_integer(archived_at) and claim.updated_at) &&
             is_binary(error["provider_recovery_deadline"]) &&
             DateTime.to_unix(claim.updated_at, :millisecond) < archived_at do
          case retry_runtime_recovery(
                 workload.id,
                 workload.generation,
                 error["provider_recovery_deadline"]
               ) do
            {:ok, _} -> :ok
            {:error, _} = result -> result
          end
        else
          {:error, :group_recovery_action_required}
        end

      %{"kind" => "action_required", "code" => "group_transition_recovery_required"} ->
        if completed_archive_after_claim?(current, claim) do
          now = DateTime.utc_now()

          case Repo.update_all(from(c in Compute.ReconcilerClaim, where: c.id == ^claim.id),
                 set: [last_error: %{}, next_retry_at: now, updated_at: now]
               ) do
            {1, _} -> :ok
            _ -> {:error, :group_recovery_action_required}
          end
        else
          {:error, :group_recovery_action_required}
        end

      %{"kind" => "action_required"} ->
        {:error, :group_recovery_action_required}

      _ ->
        :ok
    end
  end

  defp completed_archive_after_claim?(current, claim) do
    archived_at = current["archived_at"]
    archive = current["archive"] || %{}
    last_operation = current["archive_last_operation"] || %{}
    archive_operation = archive["operation"] || archive["restore_operation"]

    is_integer(archived_at) and not is_nil(claim.updated_at) and
      DateTime.to_unix(claim.updated_at, :millisecond) < archived_at and
      (is_nil(claim.lease_expires_at) or
         DateTime.compare(claim.lease_expires_at, DateTime.utc_now()) != :gt) and
      is_binary(archive_operation) and
      archive_operation == last_operation["operation"] and
      last_operation["result"] == "archived"
  end

  # One durable recovery deadline per unfinished episode. Foreground callers
  # use the same claim as the sweeper; reconnects and claim renewal cannot reset it.
  defp runtime_recovery_budget(%{runtime_update: %{"phase" => phase}}, _allocation, _opts)
       when phase not in ["complete", "cancelled"], do: :ok

  defp runtime_recovery_budget(workload, allocation, opts) do
    runtime = Repo.get(Compute.RuntimeInstance, "runtime:" <> workload.id)

    ready =
      runtime && runtime.status == "connected" && runtime.readiness == "ready" &&
        runtime.caught_up_epoch == runtime.connection_epoch &&
        Compute.runtime_control_current?(runtime)

    prior_claim = Repo.get(Compute.ReconcilerClaim, claim_id(workload.id, workload.generation))

    continuing? =
      not is_nil(prior_claim && (prior_claim.last_error || %{})["runtime_recovery_deadline"])

    recovering =
      SalixEnv.ComputeProviders.AgentVMM.runtime_recovery_needed?(
        allocation,
        workload,
        opts,
        continuing?
      )

    if recovering do
      Repo.transaction(fn ->
        now = DateTime.utc_now()
        id = claim_id(workload.id, workload.generation)

        Repo.insert_all(
          Compute.ReconcilerClaim,
          [
            %{
              id: id,
              provider: @provider,
              workload_id: workload.id,
              generation: workload.generation,
              claim_token: claim_token(),
              attempt_count: 0,
              created_at: now,
              updated_at: now
            }
          ],
          on_conflict: :nothing
        )

        claim =
          Repo.one!(from(c in Compute.ReconcilerClaim, where: c.id == ^id, lock: "FOR UPDATE"))

        token = Keyword.get(opts, :claim_token)

        if is_binary(token) and
             (claim.claim_token != token or is_nil(claim.lease_expires_at) or
                DateTime.compare(claim.lease_expires_at, now) != :gt),
           do: Repo.rollback(:claim_lost)

        error = claim.last_error || %{}

        cond do
          error["kind"] == "action_required" and error["code"] != "runtime_recovery_expired" ->
            {:error, {:gateway_error, error}}

          ready ->
            Repo.update_all(from(c in Compute.ReconcilerClaim, where: c.id == ^id),
              set: [last_error: clear_runtime_recovery(error), updated_at: now]
            )

            :ok

          true ->
            deadline =
              error["runtime_recovery_deadline"] ||
                DateTime.to_iso8601(DateTime.add(now, 900, :second))

            {:ok, expires_at, _} = DateTime.from_iso8601(deadline)
            error = Map.put(error, "runtime_recovery_deadline", deadline)
            expired = DateTime.compare(now, expires_at) != :lt

            error =
              if expired,
                do:
                  Map.merge(error, %{
                    "kind" => "retryable",
                    "code" => "runtime_recovery_expired"
                  }),
                else: error

            Repo.update_all(from(c in Compute.ReconcilerClaim, where: c.id == ^id),
              set: [last_error: error, updated_at: now]
            )

            # Foreground requests stop waiting. A claimed background pass still
            # observes the provider and can repair the current container proof.
            if expired and is_nil(Keyword.get(opts, :claim_token)),
              do: {:error, {:gateway_error, error}},
              else: :ok
        end
      end)
      |> case do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    else
      Repo.update_all(
        from(c in Compute.ReconcilerClaim,
          where: c.workload_id == ^workload.id and c.generation == ^workload.generation,
          update: [
            set: [
              last_error:
                fragment(
                  "CASE WHEN ?->>'code' = 'runtime_recovery_expired' THEN ? - ARRAY['kind','code','runtime_recovery_deadline'] ELSE ? - 'runtime_recovery_deadline' END",
                  c.last_error,
                  c.last_error,
                  c.last_error
                )
            ]
          ]
        ),
        []
      )

      :ok
    end
  end

  @doc "Wake the exact Workload after its Host Session commits. The sweep covers lost notifications."
  def host_session_ready(allocation_id, server \\ __MODULE__) when is_binary(allocation_id) do
    GenServer.cast(server, {:host_session_ready, allocation_id})
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      enabled: Keyword.get(opts, :start_sweeper?, true),
      tasks: %{},
      timer: nil
    }

    {:ok, if(state.enabled, do: schedule_sweep(state, 0), else: state)}
  end

  @impl true
  def handle_cast({:host_session_ready, allocation_id}, %{enabled: true} = state) do
    # An active claim is never stolen. At capacity, make the durable retry due
    # and leave selection to the next available slot. No per-Workload queue.
    case claim_host_workload(allocation_id, map_size(state.tasks) < @concurrency) do
      {:ok, [claim]} -> {:noreply, start_claim(state, claim)}
      _ -> {:noreply, schedule_sweep(state, 0)}
    end
  end

  def handle_cast({:host_session_ready, _}, state), do: {:noreply, state}

  @impl true
  def handle_info(:sweep, state) do
    state = %{state | timer: nil}
    slots = @concurrency - map_size(state.tasks)

    {state, more?} =
      if slots > 0 do
        case claim_page(slots) do
          {:ok, {claims, more?}} ->
            {Enum.reduce(claims, state, &start_claim(&2, &1)), more?}

          {:error, _} ->
            {state, false}
        end
      else
        {state, false}
      end

    delay = if more? and map_size(state.tasks) < @concurrency, do: 0, else: state.interval_ms
    {:noreply, schedule_sweep(state, delay)}
  end

  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_task(state, ref, nil)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, finish_task(state, ref, {:error, :reconcile_process_failed})}
  end

  def handle_info({:claim_timeout, ref}, state) do
    case state.tasks[ref] do
      nil ->
        {:noreply, state}

      task ->
        Process.exit(task.pid, :kill)
        Process.demonitor(ref, [:flush])
        {:noreply, finish_task(state, ref, {:error, :reconcile_timeout})}
    end
  end

  # Tasks are linked to this owner. Its exit cancels all local work; the
  # durable leases then recover on another pass without orphan task slots.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.tasks, fn {_ref, task} -> Process.exit(task.pid, :shutdown) end)
    :ok
  end

  defp start_claim(state, claim) do
    context = SystemsObservability.Context.capture()

    task =
      Task.async(fn -> SystemsObservability.Context.run(context, fn -> run_claim(claim) end) end)

    timer = Process.send_after(self(), {:claim_timeout, task.ref}, @task_budget_ms)
    entry = Map.merge(claim, %{pid: task.pid, timer: timer})
    %{state | tasks: Map.put(state.tasks, task.ref, entry)}
  end

  defp finish_task(state, ref, error) do
    case Map.pop(state.tasks, ref) do
      {nil, _} ->
        state

      {task, tasks} ->
        Process.cancel_timer(task.timer)

        if error do
          Logger.warning("Compute reconciliation interrupted",
            workload_id: task.workload.id,
            stage: :provider_reconcile,
            reason: elem(error, 1)
          )

          settle_claim(task.workload, error, task.claim_token)
        end

        schedule_sweep(%{state | tasks: tasks}, 0)
    end
  end

  defp schedule_sweep(state, delay) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :sweep, delay)}
  end

  defp run_claim(%{workload: workload, claim_token: token}) do
    started = System.monotonic_time(:millisecond)
    result = reconcile_workload(workload.id, workload.generation, claim_token: token)

    if match?({:error, _}, result) do
      Logger.warning("Compute reconciliation will retry or await action",
        workload_id: workload.id,
        stage: :provider_reconcile,
        duration_ms: System.monotonic_time(:millisecond) - started,
        reason: reconcile_log_reason(result)
      )
    end

    settle_claim(workload, result, token)
  end

  defp reconcile_log_reason({:error, reason}) when is_atom(reason), do: reason
  defp reconcile_log_reason({:error, {:gateway_error, _}}), do: :gateway_error
  defp reconcile_log_reason(_), do: :provider_error

  # This synchronous ops entry point claims one row immediately before use.
  # Production uses the independent slots above, so a slow import cannot stop
  # selection or settlement in the other slots.
  @doc "Run at most the requested number of reconciliation attempts."
  def sweep(limit \\ @batch_size) when limit in 1..@batch_size do
    Enum.reduce_while(1..limit, :complete, fn _, _ ->
      case claim_page(1) do
        {:ok, {claims, more?}} ->
          Enum.each(claims, &run_claim/1)
          if more?, do: {:cont, :more}, else: {:halt, :complete}

        {:error, _} ->
          {:halt, :complete}
      end
    end)
  end

  defp claim_host_workload(allocation_id, available?) do
    Repo.transaction(fn ->
      # Share the durable selector lock with every node's sweep.
      lock_or_create_cursor!()

      workload =
        Repo.one(
          from(w in Compute.Workload,
            join: r in Compute.RuntimeInstance,
            on: r.workload_id == w.id,
            where:
              r.allocation_id == ^allocation_id and w.allocation_id == ^allocation_id and
                w.generation == r.generation and w.desired_state == "ready",
            limit: 1
          )
        )

      if workload do
        now = DateTime.utc_now()
        id = claim_id(workload.id, workload.generation)

        claim =
          Repo.one(from(c in Compute.ReconcilerClaim, where: c.id == ^id, lock: "FOR UPDATE"))

        active? =
          claim && claim.lease_expires_at && DateTime.compare(claim.lease_expires_at, now) == :gt

        error = (claim && claim.last_error) || %{}

        parked? =
          error["kind"] == "action_required" and error["code"] != "runtime_recovery_expired"

        if active? || parked? do
          []
        else
          if claim do
            Repo.update_all(from(c in Compute.ReconcilerClaim, where: c.id == ^id),
              set: [next_retry_at: now, updated_at: now]
            )
          end

          if available?,
            do: claim_workloads!([%{workload: workload, provider: @provider}]),
            else: []
        end
      else
        []
      end
    end)
  rescue
    exception ->
      Logger.warning("Compute Host wake failed; sweep will retry",
        stage: :claim,
        exception: inspect(exception.__struct__)
      )

      {:error, :unavailable}
  end

  defp claim_page(limit) do
    Repo.transaction(fn ->
      cursor = lock_or_create_cursor!()
      high_watermark = high_watermark(cursor)

      case high_watermark do
        nil ->
          clear_cursor!(cursor)
          {[], false}

        watermark ->
          candidate_limit = @candidate_limit

          candidates =
            candidate_query(cursor_key(cursor), watermark)
            |> limit(^candidate_limit)
            |> Repo.all()

          {selected, cursor_candidate} = fair_workloads(candidates, limit)
          # A fair page can contain rows skipped by the tenant cap even when
          # it is smaller than the provider batch limit. Keep the fast sweep
          # path active until those rows have also been claimed.
          has_more? = length(candidates) >= limit or length(selected) < length(candidates)

          if candidates != [] do
            # Do not advance past rows skipped by the tenant cap. Keeping the
            # cursor immediately before the first skipped row lets the next
            # page make progress through a tenant whose fair share is full.
            advance_cursor!(cursor, cursor_candidate || List.last(candidates), watermark)
          else
            clear_cursor!(cursor)
          end

          claimed = claim_workloads!(selected)

          {claimed, has_more?}
      end
    end)
  end

  defp lock_or_create_cursor! do
    now = DateTime.utc_now()

    {_count, _} =
      Repo.insert_all(
        Compute.ReconcilerCursor,
        [
          %{
            id: @cursor_id,
            provider: @provider,
            created_at: now,
            updated_at: now
          }
        ],
        on_conflict: :nothing,
        conflict_target: [:provider]
      )

    Repo.one!(from(c in Compute.ReconcilerCursor, where: c.id == ^@cursor_id, lock: "FOR UPDATE"))
  end

  defp high_watermark(%Compute.ReconcilerCursor{
         high_watermark_tenant_id: tenant_id,
         high_watermark_updated_at: updated_at,
         high_watermark_workload_id: workload_id
       })
       when is_binary(tenant_id) and is_binary(workload_id) and not is_nil(updated_at),
       do: %{tenant_id: tenant_id, updated_at: updated_at, workload_id: workload_id}

  defp high_watermark(_cursor) do
    now = DateTime.utc_now()

    Repo.one(
      from(w in Compute.Workload,
        join: a in Compute.Allocation,
        on: a.id == w.allocation_id,
        join: b in Compute.ProviderBinding,
        on: b.id == a.provider_binding_id,
        join: e in Compute.Environment,
        on: e.id == w.environment_id,
        where:
          w.desired_state in ["ready", "draining", "stopped"] and
            a.generation == e.generation and a.status != "released" and
            ((b.provider == "cloudflare" and
                fragment("?->>'group_default' = 'true'", w.spec) and
                (w.desired_state == "stopped" or
                   fragment("? #>> '{archive,wake_requested_at}' IS NOT NULL", w.spec) or
                   w.observed_state in [
                     "creating",
                     "ready",
                     "waking",
                     "archiving",
                     "eligible_for_resume",
                     "billing_suspended"
                   ])) or
               (b.provider == "agent_vmm" and
                  (fragment(
                     @runtime_update_due_sql,
                     w.desired_state,
                     w.template_key,
                     w.runtime_revision,
                     w.runtime_update,
                     w.runtime_update,
                     w.template_key
                   ) or
                     w.observed_state != w.desired_state or
                     (w.desired_state == "ready" and
                        w.kind in ["external_worker", "meeting_runtime"] and
                        fragment(
                          @runtime_ready_sql,
                          w.id,
                          w.generation,
                          b.provider_ref,
                          a.id,
                          ^now,
                          a.generation,
                          b.observation,
                          b.observation,
                          a.provider_observation
                        )) or
                     (w.desired_state == "ready" and w.kind == "external_worker" and
                        fragment(
                          @external_idle_cleanup_sql,
                          a.provider_observation
                        )) or
                     (w.desired_state == "ready" and w.kind == "external_worker" and
                        fragment(@external_runtime_active_sql, w.id, w.generation))) and
                  (fragment(
                     @runtime_update_due_sql,
                     w.desired_state,
                     w.template_key,
                     w.runtime_revision,
                     w.runtime_update,
                     w.runtime_update,
                     w.template_key
                   ) or
                     w.kind != "external_worker" or w.observed_state != w.desired_state or
                     fragment(
                       @external_idle_cleanup_sql,
                       a.provider_observation
                     ) or
                     fragment(@external_demand_sql, w.id, w.id, w.generation, w.id, w.generation) or
                     fragment(@external_runtime_active_sql, w.id, w.generation)) and
                  b.provider == "agent_vmm")),
        order_by: [desc: e.tenant_id, desc: w.updated_at, desc: w.id],
        select: %{tenant_id: e.tenant_id, updated_at: w.updated_at, workload_id: w.id},
        limit: 1
      )
    )
  end

  defp candidate_query(cursor, watermark) do
    now = DateTime.utc_now()

    after_cursor =
      case cursor do
        nil ->
          dynamic([_w, _a, _b, _e], true)

        %{tenant_id: tenant_id, updated_at: updated_at, workload_id: workload_id} ->
          dynamic(
            [w, _a, _b, e],
            e.tenant_id > ^tenant_id or
              (e.tenant_id == ^tenant_id and w.updated_at > ^updated_at) or
              (e.tenant_id == ^tenant_id and w.updated_at == ^updated_at and
                 w.id > ^workload_id)
          )
      end

    before_watermark =
      dynamic(
        [w, _a, _b, e],
        e.tenant_id < ^watermark.tenant_id or
          (e.tenant_id == ^watermark.tenant_id and w.updated_at < ^watermark.updated_at) or
          (e.tenant_id == ^watermark.tenant_id and w.updated_at == ^watermark.updated_at and
             w.id <= ^watermark.workload_id)
      )

    from(w in Compute.Workload,
      join: a in Compute.Allocation,
      on: a.id == w.allocation_id,
      join: b in Compute.ProviderBinding,
      on: b.id == a.provider_binding_id,
      join: e in Compute.Environment,
      on: e.id == w.environment_id,
      left_join: claim in Compute.ReconcilerClaim,
      on:
        claim.provider == b.provider and claim.workload_id == w.id and
          claim.generation == w.generation and
          (claim.lease_expires_at > ^now or claim.next_retry_at > ^now or
             fragment(
               "?->>'kind' = 'action_required' AND COALESCE(?->>'code', '') <> 'runtime_recovery_expired'",
               claim.last_error,
               claim.last_error
             )),
      where:
        w.desired_state in ["ready", "draining", "stopped"] and
          a.generation == e.generation and a.status != "released" and
          ((b.provider == "cloudflare" and
              fragment("?->>'group_default' = 'true'", w.spec) and
              (w.desired_state == "stopped" or
                 fragment("? #>> '{archive,wake_requested_at}' IS NOT NULL", w.spec) or
                 w.observed_state in [
                   "creating",
                   "ready",
                   "waking",
                   "archiving",
                   "eligible_for_resume",
                   "billing_suspended"
                 ])) or
             (b.provider == "agent_vmm" and
                (fragment(
                   @runtime_update_due_sql,
                   w.desired_state,
                   w.template_key,
                   w.runtime_revision,
                   w.runtime_update,
                   w.runtime_update,
                   w.template_key
                 ) or
                   w.observed_state != w.desired_state or
                   (w.desired_state == "ready" and
                      w.kind in ["external_worker", "meeting_runtime"] and
                      fragment(
                        @runtime_ready_sql,
                        w.id,
                        w.generation,
                        b.provider_ref,
                        a.id,
                        ^now,
                        a.generation,
                        b.observation,
                        b.observation,
                        a.provider_observation
                      )) or
                   (w.desired_state == "ready" and w.kind == "external_worker" and
                      fragment(
                        @external_idle_cleanup_sql,
                        a.provider_observation
                      )) or
                   (w.desired_state == "ready" and w.kind == "external_worker" and
                      fragment(@external_runtime_active_sql, w.id, w.generation))) and
                (fragment(
                   @runtime_update_due_sql,
                   w.desired_state,
                   w.template_key,
                   w.runtime_revision,
                   w.runtime_update,
                   w.runtime_update,
                   w.template_key
                 ) or
                   w.kind != "external_worker" or w.observed_state != w.desired_state or
                   fragment(
                     @external_idle_cleanup_sql,
                     a.provider_observation
                   ) or
                   fragment(@external_demand_sql, w.id, w.id, w.generation, w.id, w.generation) or
                   fragment(@external_runtime_active_sql, w.id, w.generation)) and
                b.provider == "agent_vmm")) and is_nil(claim.id),
      where: ^after_cursor,
      where: ^before_watermark,
      order_by: [asc: e.tenant_id, asc: w.updated_at, asc: w.id],
      select: %{
        workload: w,
        provider: b.provider,
        tenant_id: e.tenant_id,
        updated_at: w.updated_at
      }
    )
  end

  defp claim_workloads!([]), do: []

  defp claim_workloads!(selected) do
    # Acquiring or reacquiring a claim must not erase the last actionable cause.
    now = DateTime.utc_now()

    claimed =
      Enum.map(selected, fn %{workload: workload, provider: provider} ->
        claim_token = claim_token()

        lease_ms =
          if provider == "cloudflare", do: @cloudflare_claim_lease_ms, else: @claim_lease_ms

        lease_expires_at = DateTime.add(now, lease_ms, :millisecond)

        %{
          workload: workload,
          claim_token: claim_token,
          row: %{
            id: "#{provider}:#{workload.id}:#{workload.generation}",
            provider: provider,
            workload_id: workload.id,
            generation: workload.generation,
            claim_token: claim_token,
            attempt_count: 1,
            lease_expires_at: lease_expires_at,
            created_at: now,
            updated_at: now
          }
        }
      end)

    Enum.each(claimed, fn %{row: row} ->
      {updated, _} =
        Repo.update_all(
          from(c in Compute.ReconcilerClaim,
            where:
              c.id == ^row.id and
                ((is_nil(c.lease_expires_at) or c.lease_expires_at <= ^now) and
                   (is_nil(c.next_retry_at) or c.next_retry_at <= ^now))
          ),
          set: [
            claim_token: row.claim_token,
            next_retry_at: nil,
            lease_expires_at: row.lease_expires_at,
            updated_at: now
          ],
          inc: [attempt_count: 1]
        )

      if updated == 0 do
        Repo.insert_all(Compute.ReconcilerClaim, [row], on_conflict: :nothing)
      end
    end)

    Enum.map(claimed, &Map.take(&1, [:workload, :claim_token]))
  end

  defp settle_claim(workload, {:ok, %{outcome: :group_reconciled}}, claim_token),
    do: release_claim(workload, claim_token)

  defp settle_claim(workload, {:ok, %{outcome: :pending}}, claim_token),
    do: retry_claim_preserving_error(workload, claim_token)

  defp settle_claim(workload, {:ok, _result}, claim_token) do
    # settle_result/2 may have advanced the Workload revision and observed
    # state. Never decide from the pre-reconcile struct captured by claim_page.
    case Repo.get(Compute.Workload, workload.id) do
      %Compute.Workload{
        generation: generation,
        desired_state: desired_state,
        observed_state: observed_state
      }
      when generation == workload.generation and desired_state == observed_state ->
        release_claim(workload, claim_token)

      _ ->
        retry_claim_preserving_error(workload, claim_token)
    end
  end

  defp settle_claim(workload, {:error, reason}, claim_token)
       when reason in [:not_found, :not_desired, :stale_generation, :unsupported_provider] do
    release_claim(workload, claim_token)
  end

  defp settle_claim(
         workload,
         {:error, {:gateway_error, %{"code" => "resource_capacity_exhausted"} = error}},
         claim_token
       ) do
    if capacity_import_error?(error) do
      park_action_required(workload, Map.put(error, "kind", "action_required"), claim_token)
    else
      retry_claim(
        workload,
        claim_error({:error, {:gateway_error, error}}),
        claim_token
      )
    end
  end

  defp settle_claim(workload, {:error, {:gateway_error, %{"code" => code} = error}}, claim_token)
       when code in [
              "workload_stop_unresolved",
              "capacity_wait_expired",
              "workload_update_action_required",
              "group_transition_recovery_required",
              "group_provider_recovery_expired"
            ] do
    park_action_required(workload, Map.put(error, "kind", "action_required"), claim_token)
  end

  defp settle_claim(workload, result, claim_token) do
    retry_claim(workload, claim_error(result), claim_token)
  end

  defp retry_claim(workload, error, claim_token) do
    now = DateTime.utc_now()

    claim =
      Repo.one(
        from(c in Compute.ReconcilerClaim,
          where:
            c.workload_id == ^workload.id and c.generation == ^workload.generation and
              c.claim_token == ^claim_token
        )
      )

    error =
      if claim && (claim.last_error || %{})["code"] == "runtime_recovery_expired" do
        Map.merge(error, %{"kind" => "retryable", "code" => "runtime_recovery_expired"})
      else
        error
      end

    error =
      if claim && claim.provider == "cloudflare" do
        Map.put(
          error,
          "provider_recovery_deadline",
          (claim.last_error || %{})["provider_recovery_deadline"] ||
            DateTime.to_iso8601(DateTime.add(now, @cloudflare_claim_lease_ms, :millisecond))
        )
      else
        error
      end

    {_count, _} =
      Repo.update_all(
        from(c in Compute.ReconcilerClaim,
          where:
            c.workload_id == ^workload.id and
              c.generation == ^workload.generation and c.claim_token == ^claim_token,
          update: [
            set: [
              last_error:
                fragment(
                  "? || jsonb_strip_nulls(jsonb_build_object('capacity_wait_deadline', ?->'capacity_wait_deadline', 'runtime_recovery_deadline', ?->'runtime_recovery_deadline'))",
                  type(^error, :map),
                  c.last_error,
                  c.last_error
                )
            ]
          ]
        ),
        set: [
          lease_expires_at: nil,
          next_retry_at: DateTime.add(now, retry_delay(claim), :millisecond),
          updated_at: now
        ]
      )

    :ok
  end

  defp park_action_required(workload, error, claim_token) do
    # Model anchor: ComputeCapacityAction.Attempt with unavailable capacity.
    now = DateTime.utc_now()

    Repo.update_all(
      from(c in Compute.ReconcilerClaim,
        where:
          c.workload_id == ^workload.id and
            c.generation == ^workload.generation and c.claim_token == ^claim_token,
        update: [
          set: [
            last_error:
              fragment(
                "? || jsonb_strip_nulls(jsonb_build_object('capacity_wait_deadline', ?->'capacity_wait_deadline', 'runtime_recovery_deadline', ?->'runtime_recovery_deadline'))",
                type(^error, :map),
                c.last_error,
                c.last_error
              )
          ]
        ]
      ),
      set: [
        lease_expires_at: nil,
        next_retry_at: nil,
        updated_at: now
      ]
    )

    :ok
  end

  defp retry_claim_preserving_error(workload, claim_token) do
    case Repo.get_by(Compute.ReconcilerClaim,
           workload_id: workload.id,
           generation: workload.generation,
           claim_token: claim_token
         ) do
      %Compute.ReconcilerClaim{} = claim ->
        retry_claim(workload, claim.last_error || %{}, claim_token)

      _ ->
        :ok
    end
  end

  defp retry_delay(%{
         last_error: %{"code" => "runtime_recovery_expired"},
         attempt_count: attempts
       }),
       do: min(@claim_retry_ms * Integer.pow(2, min(max(attempts - 1, 0), 4)), @max_retry_ms)

  defp retry_delay(_), do: @claim_retry_ms

  defp clear_runtime_recovery(%{"code" => "runtime_recovery_expired"} = error),
    do: Map.drop(error, ["kind", "code", "runtime_recovery_deadline"])

  defp clear_runtime_recovery(error), do: Map.delete(error, "runtime_recovery_deadline")

  defp release_claim(workload, claim_token) do
    Repo.delete_all(
      from(c in Compute.ReconcilerClaim,
        where:
          c.workload_id == ^workload.id and
            c.generation == ^workload.generation and c.claim_token == ^claim_token
      )
    )

    :ok
  end

  defp claim_error({:error, {:gateway_error, %{} = error}}),
    do: Map.put(error, "kind", "provider_error")

  defp claim_error({:error, reason}),
    do: %{"kind" => "error", "reason" => inspect(reason, limit: 10, printable_limit: 512)}

  defp claim_error(result),
    do: %{"kind" => "unknown", "result" => inspect(result, limit: 10, printable_limit: 512)}

  defp capacity_import_error?(%{
         "code" => "resource_capacity_exhausted",
         "stage" => "import_admission",
         "resource" => "storage_headroom"
       }),
       do: true

  defp capacity_import_error?(%{
         "code" => "resource_capacity_exhausted",
         "stage" => "import_slot",
         "resource" => "import_slot"
       }),
       do: true

  defp capacity_import_error?(_), do: false

  defp claim_id(workload_id, generation),
    do: "#{@provider}:#{workload_id}:#{generation}"

  defp claim_token,
    do: :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)

  defp cursor_key(%Compute.ReconcilerCursor{
         cursor_tenant_id: tenant_id,
         cursor_updated_at: updated_at,
         cursor_workload_id: workload_id
       })
       when is_binary(tenant_id) and is_binary(workload_id) and not is_nil(updated_at),
       do: %{tenant_id: tenant_id, updated_at: updated_at, workload_id: workload_id}

  defp cursor_key(_), do: nil

  defp fair_workloads(candidates, limit) do
    {selected, _counts, previous, first_skipped} =
      Enum.reduce_while(candidates, {[], %{}, nil, nil}, fn candidate,
                                                            {selected, counts, previous,
                                                             first_skipped} ->
        if length(selected) >= limit do
          {:halt, {selected, counts, previous, first_skipped}}
        else
          count = Map.get(counts, candidate.tenant_id, 0)

          if count >= @max_per_tenant do
            {:cont, {selected, counts, previous, first_skipped || previous}}
          else
            {:cont,
             {[candidate | selected], Map.put(counts, candidate.tenant_id, count + 1), candidate,
              first_skipped}}
          end
        end
      end)

    {Enum.reverse(selected), first_skipped || previous}
  end

  defp advance_cursor!(cursor, candidate, watermark) do
    {1, _} =
      Repo.update_all(
        from(c in Compute.ReconcilerCursor, where: c.id == ^cursor.id),
        set: [
          cursor_tenant_id: candidate.tenant_id,
          cursor_updated_at: candidate.updated_at,
          cursor_workload_id: candidate.workload.id,
          high_watermark_tenant_id: watermark.tenant_id,
          high_watermark_updated_at: watermark.updated_at,
          high_watermark_workload_id: watermark.workload_id,
          updated_at: DateTime.utc_now()
        ]
      )
  end

  defp clear_cursor!(cursor) do
    {1, _} =
      Repo.update_all(
        from(c in Compute.ReconcilerCursor, where: c.id == ^cursor.id),
        set: [
          cursor_tenant_id: nil,
          cursor_updated_at: nil,
          cursor_workload_id: nil,
          high_watermark_tenant_id: nil,
          high_watermark_updated_at: nil,
          high_watermark_workload_id: nil,
          updated_at: DateTime.utc_now()
        ]
      )
  end

  defp settle_result(
         workload,
         {:ok, %{outcome: :succeeded, observation: %{}}},
         claim_token
       ) do
    observed_state =
      if workload.desired_state in ["draining", "stopped"],
        do: workload.desired_state,
        else: "ready"

    cond do
      not is_nil(claim_token) and not claim_current?(workload, claim_token) ->
        {:error, :claim_lost}

      workload.observed_state == observed_state ->
        {:ok, workload}

      true ->
        Compute.observe_workload(
          workload.id,
          workload.revision,
          workload.generation,
          observed_state
        )
    end
  end

  defp settle_result(_workload, {:ok, result}, _claim_token), do: {:ok, result}
  defp settle_result(_workload, {:error, _} = error, _claim_token), do: error

  defp claim_current?(workload, claim_token) do
    now = DateTime.utc_now()

    Repo.exists?(
      from(c in Compute.ReconcilerClaim,
        where:
          c.workload_id == ^workload.id and
            c.generation == ^workload.generation and c.claim_token == ^claim_token and
            c.lease_expires_at > ^now
      )
    )
  end

  defp ensure_claim_current(workload, opts) when is_list(opts) do
    case Keyword.get(opts, :claim_token) do
      token when is_binary(token) ->
        if claim_current?(workload, token), do: :ok, else: {:error, :claim_lost}

      _ ->
        :ok
    end
  end

  defp ensure_claim_current(_workload, _opts), do: :ok
end
