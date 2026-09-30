defmodule SalixIM.Triage.Runtime do
  @moduledoc """
  Process owner for native Triage serialization, timers, workers, monitors,
  capabilities, ports, and message routing.

  Admission itself stays in the caller: `accept_current/3` verifies current
  connect authority and projects the typed receipt through
  `SalixIM.Triage.Admission` before this process is asked to do anything, so a
  slow storage round-trip on the ingress path never serializes behind the
  engine. What this process owns is everything after admission — the local view
  of the open bucket, the debounce/max-wait flush timer, the generation seal,
  the run fence, the evaluation worker and its monitor, and the recovery lanes.

  The production composition root always injects the bounded product-context
  and evaluator ports on the product-owned namespace. Slack source, channel,
  and monitoring authority decide which ambient messages enter Triage; there
  is no deploy-time engine, namespace, timing, enable, or emergency-stop switch.
  Missing ports remain a fail-closed construction state for tests and invalid
  composition, and are exposed as evaluator-unavailable rather than as an
  alternate product mode.

  ## Deploy ordering

  V1 and v2 bucket contracts are isolated by their stores: legacy nodes retain
  the old S3 namespace while this runtime addresses typed PostgreSQL protocol
  tables through `SalixStore.TriageKeys`. The global receipt ring dual-reads
  valid v1 human roots and projects them into PostgreSQL. The historical staged
  engine rollout and its superseding always-on product contract are recorded in
  `docs/bridge-for-teams/design.md`.

  The durable run-fence safety protocol shared with `SalixIM.Triage.RunFence`
  is modeled in `tla/salix/TriageRunFence.tla`. Recovery generation
  reconciliation is modeled in `tla/salix/TriageBucketRecovery.tla`.
  """

  use GenServer

  require Logger

  alias SalixIM.Triage.{
    Admission,
    AuthoritativeCommit,
    Bucketing,
    CanonicalJSON,
    Correlation,
    IdentityFence,
    IdentityFenceHandle,
    Ledger,
    Pipeline,
    ProjectionProjector,
    Recovery,
    RunFence,
    Telemetry
  }

  alias SalixStore.{TriageRecordStore, ULID}

  # Recovery pagination feeds unscheduled fences after an owned retry succeeds.
  @terminal_projection_retry_limit 16

  # Every owned retry in this process is a bounded backoff, never a fixed hot
  # delay: a storage outage must cost this process a shrinking share of its
  # mailbox, not a steady 25ms wake-up per stuck scope.
  @retry_base_ms 25
  @terminal_projection_retry_base_ms 50
  @retry_cap_ms 5_000
  @late_result_retry_attempts 5
  # Refusals no retry can turn into progress. The durable bucket record itself
  # is invalid, so the scope is parked with a durable refusal and left to the
  # recovery lane's own cadence instead of being rescheduled.
  @permanent_seal_refusals [
    :invalid_triage_bucket,
    :invalid_triage_bucket_policy,
    :invalid_triage_receipt
  ]

  # The per-bucket ceiling on consecutive agent-authored trigger rounds one
  # bucket may drive before this connect stops treating agent traffic as a
  # trigger. Two agents that can each address the other can otherwise ping-pong
  # with no person involved — the failure mode that produced 47 replies in 12
  # seconds elsewhere in the industry.
  #
  # This value is exposed for the admission contract but is not enforced at the
  # live product-effect seam yet. Current Triage can produce provider egress, so
  # callers must not treat this reader as a loop-safety guarantee. The remaining
  # enforcement gap is recorded in the product contract and stays outside the
  # agent-mention fix owned by a separate change. See
  # docs/bridge-for-teams/design.md.
  @default_agent_round_budget 2

  @options [
    :agent_round_budget,
    :before_seal_hook,
    :context_port,
    :debounce_ms,
    :evaluation_timeout_ms,
    :evaluator_port,
    :id,
    :max_wait_ms,
    :mode,
    :name,
    :namespace,
    :recovery_idle_ms,
    :recovery_page_size,
    :restart,
    :review_projection
  ]

  def start_link(opts) when is_list(opts) do
    case opts[:name] do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: Keyword.get(opts, :restart, :permanent),
      type: :worker
    }
  end

  @admission_config_table :salix_im_triage_admission_config

  @doc """
  Creates the node-local admission-config table.

  Called from the `:salix_im` application-start callback process, which has
  application lifetime, so the table cannot vanish with any crashable worker.
  """
  def create_table! do
    if :ets.whereis(@admission_config_table) == :undefined do
      :ets.new(@admission_config_table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    :ok
  end

  @doc """
  Admits one current typed Slack receipt and arms its debounce window.

  Returns `:off` when the vertical is disabled, otherwise the exact
  `SalixIM.Triage.Admission` result. Only a receipt that holds open bucket
  membership after admission enters the engine's local view.

  Nothing on this path waits on the engine's mailbox. The mode/namespace pair is
  static from `init/1`, so it is published to a node-local table and read
  lock-free, and the arming notification is an in-order cast. A cast the process
  never gets to run is not a lost run: the recovery lanes re-read the durable
  bucket and seal any generation whose debounce deadline has passed.
  """
  def accept_current(server, authority, receipt) do
    case accept_current_with_membership(server, authority, receipt) do
      {:ok, status, _membership} -> {:ok, status}
      other -> other
    end
  end

  @doc """
  Admits one current typed Slack receipt and reports its durable canonical
  bucket membership after the admission CAS.

  `:open_member` is still eligible to arm the Runtime. `:sealed_member` is the
  same canonical receipt after its generation sealed; callers may settle an
  already-owned idempotent projection, but must not re-arm evaluation.
  `:evidence_only` is a settled duplicate, such as a superseded physical copy,
  that must remain durable evidence without downstream execution or context
  projection. The classification reuses the admission result and does not
  issue a second storage read.
  """
  def accept_current_with_membership(server, authority, receipt) do
    case admission_config(server) do
      :off ->
        :off

      {:review, namespace} ->
        accept_review_with_membership(server, namespace, authority, receipt)
    end
  end

  defp admission_config(server) do
    case published_admission_config(server) do
      {:ok, config} -> config
      :error -> GenServer.call(server, :admission_config)
    end
  end

  defp published_admission_config(server) do
    with pid when is_pid(pid) <- GenServer.whereis(server),
         [{^pid, config}] <- :ets.lookup(@admission_config_table, pid) do
      {:ok, config}
    else
      _unpublished -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp publish_admission_config(state) do
    config = if state.mode == :review, do: {:review, state.namespace}, else: :off

    # Rows are keyed by pid and always rewritten at init, so a reused pid can
    # never read a predecessor's config; the sweep only keeps the table small.
    :ets.foldl(
      fn {pid, _config}, :ok ->
        unless Process.alive?(pid), do: :ets.delete(@admission_config_table, pid)
        :ok
      end,
      :ok,
      @admission_config_table
    )

    :ets.insert(@admission_config_table, {self(), config})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def ledger_records(server), do: GenServer.call(server, :ledger_records)
  def replay(server, run_id), do: GenServer.call(server, {:replay, run_id})
  def lookup_run(server, selector), do: GenServer.call(server, {:lookup_run, selector})
  def lookup_runs(server, range, opts), do: GenServer.call(server, {:lookup_runs, range, opts})

  def claim_identity_observation(handle, claim),
    do: IdentityFence.claim_observation(handle, claim)

  def mark_identity_transport_started(handle), do: IdentityFence.mark_transport_started(handle)

  def commit_identity_transport(handle, result),
    do: IdentityFence.commit_transport(handle, result)

  def bind_identity_projection(handle, private_projection, context_sha256),
    do: IdentityFence.bind_projection(handle, private_projection, context_sha256)

  def bind_identity_snapshot(handle, model_input),
    do: IdentityFence.bind_snapshot(handle, model_input)

  def authorize_identity_model(handle), do: IdentityFence.authorize_model(handle)

  def validate_identity_model_decision(handle, decision),
    do: IdentityFence.validate_model_decision(handle, decision)

  def authorize_identity_read_tool(handle), do: IdentityFence.authorize_read_tool(handle)

  def commit_identity_read_tool(handle, receipt),
    do: IdentityFence.commit_read_tool(handle, receipt)

  def identity_model_runtime(handle), do: IdentityFence.model_runtime(handle)

  defp accept_review_with_membership(server, namespace, authority, receipt) do
    started_at = Telemetry.start()
    observability_context = SystemsObservability.Context.capture()

    {reply, durable} =
      case Admission.accept_membership(namespace, authority, receipt) do
        {:ok, status, durable} -> {{:ok, status}, durable}
        rejected -> {rejected, nil}
      end

    Telemetry.emit(
      :accept,
      telemetry_outcome(reply),
      receipt_source_mode(receipt),
      observability_surface(observability_context),
      started_at
    )

    membership = admitted_membership(durable, receipt)
    arm_admitted_receipt(server, receipt, durable, membership, observability_context)

    case reply do
      {:ok, status} -> {:ok, status, membership}
      other -> other
    end
  end

  defp admitted_membership(durable, receipt) when is_map(durable) do
    cond do
      Bucketing.open_member?(durable, receipt["receipt_ref"]) -> :open_member
      Bucketing.member?(durable, receipt["receipt_ref"]) -> :sealed_member
      true -> :evidence_only
    end
  end

  defp admitted_membership(_durable, _receipt), do: :evidence_only

  # Only open membership arms a debounce window: a superseded physical copy and
  # a receipt whose generation is already sealed both stay durable evidence
  # without re-entering an open generation.
  #
  # The membership comes from the admission CAS that just wrote it, so ingress
  # issues no extra storage read, and the notification is a cast: the engine may
  # be several seconds deep in one evaluation and the caller must not be pinned
  # behind it. Casts are ordered per sender, and a cast lost to a pod restart is
  # not a lost run — the bucket recovery lane seals any durable generation whose
  # deadline has passed regardless of local view.
  defp arm_admitted_receipt(
         server,
         receipt,
         durable,
         :open_member,
         observability_context
       )
       when is_map(durable) do
    GenServer.cast(server, {:admitted, receipt, durable, observability_context})
    :ok
  end

  defp arm_admitted_receipt(
         _server,
         _receipt,
         _durable,
         _membership,
         _observability_context
       ),
       do: :ok

  @impl true
  def init(opts) do
    state = %{
      namespace: Keyword.get(opts, :namespace),
      mode: Keyword.get(opts, :mode, :off),
      debounce_ms: Keyword.get(opts, :debounce_ms, 180_000),
      max_wait_ms: Keyword.get(opts, :max_wait_ms, :infinity),
      evaluation_timeout_ms: Keyword.get(opts, :evaluation_timeout_ms, 150_000),
      review_projection: Keyword.get(opts, :review_projection, :none),
      context_port: Keyword.get(opts, :context_port),
      evaluator_port: Keyword.get(opts, :evaluator_port),
      before_seal_hook: Keyword.get(opts, :before_seal_hook),
      recovery_page_size: Keyword.get(opts, :recovery_page_size, 50),
      recovery_cursor: Recovery.cursor(idle_ms: Keyword.get(opts, :recovery_idle_ms, 5_000)),
      recovery_work: nil,
      recovery_schedule: nil,
      recovery_requests: [],
      agent_round_budget: Keyword.get(opts, :agent_round_budget, @default_agent_round_budget),
      buckets: %{},
      flush_schedules: %{},
      terminal_projection_schedules: %{},
      projection_convergence_schedule: nil,
      projection_worker: nil,
      background_supervisor: nil,
      active: %{},
      late_wait: %{},
      identity_recovery_retries: %{},
      late_result_retries: %{},
      observability_contexts: %{},
      retry_attempts: %{},
      parked_seals: %{},
      parked_inputs: %{},
      recovery_convergence_scheduled?: false,
      evaluation_disabled_logged?: false
    }

    if valid_options?(opts, state) do
      {:ok, background_supervisor} = Task.Supervisor.start_link()
      state = %{state | background_supervisor: background_supervisor}
      publish_admission_config(state)

      if evaluation_enabled?(state) do
        send(self(), :recover_open_fences)
      end

      {:ok, maybe_schedule_projection_convergence(state, 100)}
    else
      {:stop, :invalid_triage_runtime_options}
    end
  end

  defp valid_options?(opts, state) do
    Enum.all?(Keyword.keys(opts), &(&1 in @options)) and state.mode in [:off, :review] and
      is_binary(state.namespace) and state.namespace == String.trim(state.namespace) and
      state.namespace != "" and is_integer(state.debounce_ms) and state.debounce_ms >= 0 and
      (state.max_wait_ms == :infinity or
         (is_integer(state.max_wait_ms) and state.max_wait_ms >= 0)) and
      is_integer(state.evaluation_timeout_ms) and state.evaluation_timeout_ms > 0 and
      is_integer(state.recovery_page_size) and state.recovery_page_size > 0 and
      is_integer(state.agent_round_budget) and state.agent_round_budget >= 0
  end

  @doc """
  The configured per-bucket agent-to-agent round budget.

  Read-only in this build: review mode has zero egress, so no agent round can
  be spent. The live-mode PR is what consumes it, at the action-execution seam.
  """
  @spec agent_round_budget(GenServer.server()) :: non_neg_integer()
  def agent_round_budget(server), do: GenServer.call(server, :agent_round_budget)

  @doc "Returns the bounded, product-facing state of this runtime."
  @spec status(GenServer.server()) :: %{
          mode: :off | :review,
          namespace: String.t() | nil,
          evaluator_wired: boolean(),
          active_evaluations: non_neg_integer(),
          open_buckets: non_neg_integer(),
          scheduled_buckets: non_neg_integer(),
          observed_at_ms: integer()
        }
  def status(server), do: GenServer.call(server, :status)

  @impl true
  def handle_call(:agent_round_budget, _from, state),
    do: {:reply, state.agent_round_budget, state}

  def handle_call(:status, _from, state), do: {:reply, runtime_status(state), state}

  def handle_call(:admission_config, _from, %{mode: :off} = state),
    do: {:reply, :off, state}

  def handle_call(:admission_config, _from, %{mode: :review} = state),
    do: {:reply, {:review, state.namespace}, state}

  def handle_call(
        {:identity_model_authorize, %IdentityFenceHandle{} = handle},
        {caller, _tag},
        state
      ) do
    case identity_active(state, handle, caller) do
      {:ok, scope_key, %{identity_model_permission: :available} = active} ->
        state = consume_identity_model_permission(state, scope_key, active)
        {:reply, RunFence.authorize_model(state.namespace, active), state}

      _denied ->
        {:reply, {:error, :identity_fence_denied}, state}
    end
  end

  def handle_call(
        {:identity_model_decision_validate, %IdentityFenceHandle{} = handle, decision},
        {caller, _tag},
        state
      ) do
    reply =
      case identity_active(state, handle, caller) do
        {:ok, _scope_key, %{identity_model_permission: :consumed} = active} ->
          RunFence.validate_model_decision(state.namespace, active, decision)

        _denied ->
          {:error, :identity_decision_invalid}
      end

    {:reply, reply, state}
  end

  def handle_call(
        {:identity_model_runtime, %IdentityFenceHandle{} = handle},
        {caller, _tag},
        state
      ) do
    reply =
      case identity_active(state, handle, caller) do
        {:ok, _scope_key, %{identity_model_permission: :consumed} = active} ->
          RunFence.model_runtime_authorization(state.namespace, active)

        _denied ->
          {:error, :identity_fence_denied}
      end

    {:reply, reply, state}
  end

  def handle_call(
        {:identity_read_tool_authorize, %IdentityFenceHandle{} = handle},
        {caller, _tag},
        state
      ) do
    case identity_active(state, handle, caller) do
      {:ok, scope_key,
       %{
         identity_model_permission: :consumed,
         identity_read_tool_permission: :available
       } = active} ->
        state = consume_identity_read_tool_permission(state, scope_key, active)

        case Pipeline.authorize_read_tool(state.namespace, active) do
          {:proceed, authorization} = reply ->
            {:reply, reply, put_identity_read_tool_authorization(state, scope_key, authorization)}

          {:error, _reason} = error ->
            {:reply, error, state}
        end

      _denied ->
        {:reply, {:error, :identity_fence_denied}, state}
    end
  end

  def handle_call(
        {:identity_read_tool_commit, %IdentityFenceHandle{} = handle, receipt},
        {caller, _tag},
        state
      ) do
    started_at = Telemetry.start()

    case identity_active(state, handle, caller) do
      {:ok, scope_key,
       %{
         identity_model_permission: :consumed,
         identity_read_tool_permission: :consumed,
         identity_read_tool_authorization: authorization
       } = active} ->
        case Pipeline.commit_read_tool(active, authorization, receipt) do
          :ok ->
            state = mark_identity_read_tool_committed(state, scope_key)
            emit_active_phase(:tool_call, :ok, active, started_at)
            {:reply, :ok, state}

          {:error, _reason} = error ->
            emit_active_phase(:tool_call, telemetry_outcome(error), active, started_at)
            {:reply, error, state}
        end

      _denied ->
        Telemetry.emit(:tool_call, :rejected, :other, :bft, started_at)
        {:reply, {:error, :identity_fence_denied}, state}
    end
  end

  def handle_call(
        {:identity_fence, %IdentityFenceHandle{} = handle, action, payload},
        {caller, _tag},
        state
      ) do
    case identity_active(state, handle, caller) do
      {:ok, scope_key, %{identity_transport_permission: :available} = active}
      when action == :mark_transport ->
        state = consume_identity_transport_permission(state, scope_key, active)
        {:reply, RunFence.transition(active, action, payload), state}

      {:ok, _scope_key, %{identity_transport_permission: :consumed}}
      when action == :mark_transport ->
        {:reply, {:error, :identity_fence_denied}, state}

      {:ok, _scope_key, active} ->
        {:reply, RunFence.transition(active, action, payload), state}

      :error ->
        {:reply, {:error, :identity_fence_denied}, state}
    end
  end

  def handle_call(:ledger_records, _from, state) do
    reply =
      case Ledger.list(state.namespace) do
        {:ok, records} -> records
        {:error, _reason} = error -> error
      end

    {:reply, reply, state}
  end

  def handle_call({:replay, run_id}, _from, state) do
    started_at = Telemetry.start()
    reply = Ledger.fetch(state.namespace, run_id)

    Telemetry.emit(
      :replay,
      telemetry_outcome(reply),
      replay_source_mode(reply),
      :other,
      started_at
    )

    {:reply, reply, state}
  end

  def handle_call({:lookup_run, selector}, _from, state),
    do: {:reply, Correlation.lookup(state.namespace, selector), state}

  def handle_call({:lookup_runs, range, opts}, _from, state),
    do: {:reply, Correlation.lookup_window(state.namespace, range, opts), state}

  @impl true
  def handle_cast({:admitted, receipt, durable, observability_context}, state),
    do: {:noreply, admit_local(state, receipt, durable, observability_context)}

  def handle_cast(_message, state), do: {:noreply, state}

  @impl true
  def handle_info(:recover_open_fences, state) do
    {:noreply, request_recovery_lane(state, :fences)}
  end

  # One page read or application owns the convergence chain. Only completion
  # re-arms it; duplicate ticks cannot create parallel readers or timer chains.
  def handle_info(:converge_triage_recovery, state) do
    {:noreply, start_recovery_step(state, state.recovery_cursor)}
  end

  def handle_info(:converge_sealed_generations, state) do
    {:noreply, request_recovery_lane(state, :buckets)}
  end

  def handle_info({:converge_triage_recovery, id}, %{recovery_schedule: %{id: id}} = state) do
    state = %{state | recovery_schedule: nil}
    {:noreply, start_recovery_step(state, state.recovery_cursor)}
  end

  def handle_info({:converge_triage_recovery, _stale_id}, state), do: {:noreply, state}

  def handle_info({:triage_recovery_page, id, result}, %{recovery_work: %{id: id} = work} = state) do
    Process.demonitor(work.ref, [:flush])
    {:noreply, receive_recovery_page(state, work.cursor, result)}
  end

  def handle_info({:triage_recovery_page, _id, _result}, state), do: {:noreply, state}

  def handle_info(
        {:recover_record, id},
        %{recovery_work: %{id: id, records: records} = work} = state
      ) do
    case records do
      [record | rest] ->
        state = %{state | recovery_work: %{work | records: rest}}

        state =
          case work.lane do
            :buckets -> recover_bucket_records(state, [record])
            :fences -> recover_fence_records(state, [record])
          end

        send(self(), {:recover_record, id})
        {:noreply, state}

      [] ->
        {:noreply, finish_recovery_step(state, work.next_delay_ms)}
    end
  end

  def handle_info({:recover_record, _stale_id}, state), do: {:noreply, state}

  def handle_info(:converge_terminal_projections, state) do
    state =
      if TriageRecordStore.atomic_authoritative?() do
        maybe_expedite_projection_convergence(state)
      else
        request_recovery_lane(state, :fences)
      end

    {:noreply, state}
  end

  def handle_info(
        {:converge_projection_obligations, schedule_id},
        %{projection_convergence_schedule: %{id: schedule_id}} = state
      ) do
    state = %{state | projection_convergence_schedule: nil}
    {:noreply, start_projection_worker(state)}
  end

  def handle_info({:converge_projection_obligations, _stale_schedule_id}, state),
    do: {:noreply, state}

  def handle_info(
        {:triage_projection_result, id, result},
        %{projection_worker: %{id: id} = work} = state
      ) do
    Process.demonitor(work.ref, [:flush])
    state = %{state | projection_worker: nil}
    limit = min(state.recovery_page_size, 100)

    delay =
      case result do
        {:ok, %{fetched: ^limit, failed: 0}} -> 0
        _idle_or_unavailable -> state.recovery_cursor.idle_ms
      end

    {:noreply, maybe_schedule_projection_convergence(state, delay)}
  end

  def handle_info({:triage_projection_result, _stale_id, _result}, state),
    do: {:noreply, state}

  def handle_info({:project_terminal, fence_key, schedule_id}, state)
      when is_binary(fence_key) and is_reference(schedule_id) do
    case state.terminal_projection_schedules[fence_key] do
      %{id: ^schedule_id} ->
        state = %{
          state
          | terminal_projection_schedules:
              Map.delete(state.terminal_projection_schedules, fence_key)
        }

        state =
          case project_identity_terminal_from_storage(state.namespace, fence_key) do
            :ok ->
              clear_retry(state, {:project_terminal, fence_key})

            :retry ->
              {delay, state} =
                retry_delay(
                  state,
                  {:project_terminal, fence_key},
                  @terminal_projection_retry_base_ms
                )

              schedule_terminal_projection(state, fence_key, delay)
          end

        {:noreply, state}

      _stale_or_foreign ->
        {:noreply, state}
    end
  end

  def handle_info({:project_terminal, _legacy_or_untrusted}, state), do: {:noreply, state}

  def handle_info({:flush, scope_key, token, expected_generation, schedule_id}, state)
      when is_reference(schedule_id) do
    case state.flush_schedules[scope_key] do
      %{id: ^schedule_id, token: ^token, generation: ^expected_generation} ->
        state = %{state | flush_schedules: Map.delete(state.flush_schedules, scope_key)}

        case state.buckets[scope_key] do
          %{token: ^token, generation: ^expected_generation, receipts: [_ | _]} = bucket ->
            now = now()
            due_at = Bucketing.due_at(bucket, state, now)

            cond do
              now < due_at ->
                {:noreply, schedule_flush(state, scope_key, bucket, due_at - now)}

              Map.has_key?(state.active, scope_key) ->
                {:noreply, state}

              true ->
                {:noreply, start_evaluation(state, scope_key, bucket)}
            end

          _rotated_or_empty ->
            {:noreply, state}
        end

      _stale_or_forged ->
        {:noreply, state}
    end
  end

  def handle_info({:flush, _scope_key, _token, _expected_generation}, state),
    do: {:noreply, state}

  def handle_info({:triage_evaluation_result, scope_key, generation, run_id, result}, state) do
    case state.active[scope_key] do
      %{generation: ^generation, run_id: ^run_id} = active ->
        if is_reference(active[:identity_result_capability]) do
          {:noreply, state}
        else
          {:noreply,
           complete_active_evaluation(state, scope_key, generation, run_id, result, active)}
        end

      _not_active ->
        {:noreply, complete_legacy_late_evaluation(state, run_id, result)}
    end
  end

  def handle_info(
        {:triage_evaluation_result, scope_key, generation, run_id, result_capability, result},
        state
      )
      when is_reference(result_capability) do
    case state.active[scope_key] do
      %{
        generation: ^generation,
        run_id: ^run_id,
        identity_result_capability: ^result_capability
      } = active ->
        Logger.info(
          "triage_runtime_result stage=received match=current result=#{runtime_result_class(result)}"
        )

        {:noreply,
         complete_active_evaluation(state, scope_key, generation, run_id, result, active)}

      _not_active ->
        Logger.info(
          "triage_runtime_result stage=received match=late_or_foreign " <>
            "result=#{runtime_result_class(result)}"
        )

        {:noreply,
         complete_identity_late_evaluation(
           state,
           scope_key,
           generation,
           run_id,
           result_capability,
           result
         )}
    end
  end

  def handle_info({:triage_evaluation_timeout, scope_key, generation, run_id}, state) do
    case state.active[scope_key] do
      %{generation: ^generation, run_id: ^run_id} = active ->
        terminal = Pipeline.terminal("skipped_timeout", %{"action" => "silence"}, %{}, now())
        {state, _authoritative?} = settle_active(state, scope_key, active, terminal, true)

        if Map.has_key?(state.active, scope_key) do
          {delay, state} = retry_delay(state, {:settle, scope_key, run_id}, @retry_base_ms)

          Process.send_after(
            self(),
            {:triage_evaluation_timeout, scope_key, generation, run_id},
            delay
          )

          {:noreply, state}
        else
          state = clear_retry(state, {:settle, scope_key, run_id})
          {:noreply, schedule_pending_bucket(state, scope_key)}
        end

      _not_active ->
        {:noreply, state}
    end
  end

  def handle_info({:retry_interrupted_identity_recovery, capability}, state)
      when is_reference(capability) do
    case Map.pop(state.identity_recovery_retries, capability) do
      {nil, _retries} ->
        {:noreply, state}

      {pending, retries} ->
        state = %{state | identity_recovery_retries: retries}
        {:noreply, retry_interrupted_identity_recovery(state, pending)}
    end
  end

  def handle_info({:retry_interrupted_identity_recovery, _run_id, _attempts_left}, state),
    do: {:noreply, state}

  def handle_info({:retry_late_result, capability}, state) when is_reference(capability) do
    case Map.pop(state.late_result_retries, capability) do
      {nil, _retries} ->
        {:noreply, state}

      {{late, attempts_left}, retries} ->
        state = %{state | late_result_retries: retries}
        {:noreply, write_late_result(state, late, attempts_left)}
    end
  end

  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{recovery_work: %{ref: ref, pid: pid} = work} = state
      ) do
    Telemetry.emit_recovery_status(work.cursor.lane, :unavailable, 1)
    state = %{state | recovery_cursor: work.cursor}
    {:noreply, finish_recovery_step(state, state.recovery_cursor.idle_ms)}
  end

  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{projection_worker: %{ref: ref, pid: pid}} = state
      ) do
    state = %{state | projection_worker: nil}
    {:noreply, maybe_schedule_projection_convergence(state, state.recovery_cursor.idle_ms)}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case matching_identity_active(state, ref, pid) do
      {scope_key, active} when reason != :normal ->
        {:noreply, close_interrupted_identity_active(state, scope_key, active)}

      _not_interrupted_identity ->
        active =
          Map.new(state.active, fn {scope_key, active} ->
            active =
              if reason != :normal and active[:monitor_ref] == ref and
                   active[:worker_pid] == pid do
                Map.put(active, :monitor_ref, nil)
              else
                active
              end

            {scope_key, active}
          end)

        late_wait =
          Map.reject(state.late_wait, fn {_run_id, late} ->
            late[:monitor_ref] == ref and late[:worker_pid] == pid
          end)

        {:noreply, %{state | active: active, late_wait: late_wait}}
    end
  end

  # Everything this process acts on is a capability it minted itself, so a
  # message that matches no clause is by definition not authority. Crashing on
  # it would restart the runtime — and drop every armed timer and live fence —
  # over a stray reply from some unrelated library.
  def handle_info(message, state) do
    Logger.debug("triage runtime ignored an unroutable message: #{inspect(message)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # The linked supervisor also exits on an abnormal Runtime death. Explicit
    # shutdown covers a normal stop, so no page reader/projector outlives its
    # owner or races a restarted Runtime's background work.
    if is_pid(state.background_supervisor) and Process.alive?(state.background_supervisor),
      do: Supervisor.stop(state.background_supervisor)

    :ok
  end

  ## Admission -> local bucket

  defp admit_local(state, receipt, durable, observability_context) do
    if evaluation_enabled?(state) do
      merge_admitted_receipt(state, receipt, durable, observability_context)
    else
      log_evaluation_disabled(state)
    end
  end

  defp merge_admitted_receipt(state, receipt, durable, observability_context) do
    scope_key = Bucketing.scope_key(receipt)
    current = state.buckets[scope_key]

    if stale_recovered_generation?(current, durable) do
      state
    else
      received_at = receipt["created_at"] || now()
      bucket = Bucketing.merge_local(durable, current, receipt, received_at, ULID.generate())
      state = %{state | buckets: Map.put(state.buckets, scope_key, bucket)}

      state
      |> remember_accept_context(scope_key, bucket, observability_context)
      |> schedule_flush(scope_key, bucket, Bucketing.flush_delay(bucket, state, now()))
    end
  end

  defp stale_recovered_generation?(nil, _durable), do: false

  # modeled: tla/salix/TriageBucketRecovery.tla CommitRecovered
  defp stale_recovered_generation?(current, durable) do
    current.generation != durable["open_generation"] and
      not Enum.any?(durable["sealed_generations"] || [], fn sealed ->
        sealed["generation"] == current.generation
      end)
  end

  defp remember_accept_context(state, scope_key, %{generation: generation}, context)
       when is_map(context) do
    %{
      state
      | observability_contexts:
          Map.put_new(state.observability_contexts, {scope_key, generation}, context)
    }
  end

  defp remember_accept_context(state, _scope_key, _bucket, _context), do: state

  defp evaluation_enabled?(%{evaluator_port: nil}), do: false
  defp evaluation_enabled?(_state), do: true

  # This is deliberately narrower than `evaluation_enabled?/1`. The latter is
  # the runtime's generic port seam and remains usable by isolated tests and
  # diagnostic harnesses; this predicate proves only that the product
  # composition root wired the one review-only evaluator. It does NOT claim
  # that any particular identity-bound Agent has a complete provider template.
  # That live, per-Agent check belongs to the read model, outside this runtime's
  # mailbox. Literal module atoms keep `salix_im` free of compile-time
  # dependencies on its downstream composition apps.
  defp product_evaluator_wired?(%{
         mode: :review,
         review_projection: :slack,
         context_port: {context_module, context_opts},
         evaluator_port: {evaluator_module, evaluator_opts}
       })
       when context_module == :"Elixir.BridgeForTeams.TriageContext" and
              evaluator_module == :"Elixir.Salix.Bindings.TriageEvaluator" and
              is_list(context_opts) and is_list(evaluator_opts),
       do: true

  defp product_evaluator_wired?(_state), do: false

  defp runtime_status(state) do
    %{
      mode: state.mode,
      namespace: if(state.mode == :review, do: state.namespace),
      evaluator_wired: product_evaluator_wired?(state),
      active_evaluations: map_size(state.active),
      open_buckets: map_size(state.buckets),
      scheduled_buckets: map_size(state.flush_schedules),
      observed_at_ms: now()
    }
  end

  defp log_evaluation_disabled(%{evaluation_disabled_logged?: true} = state), do: state

  defp log_evaluation_disabled(state) do
    Logger.info(
      "triage evaluation disabled: no evaluator port configured; " <>
        "typed receipts stay durable and buckets stay open"
    )

    %{state | evaluation_disabled_logged?: true}
  end

  ## Identity fence capability surface

  defp identity_active(
         state,
         %IdentityFenceHandle{runtime: runtime, capability: capability},
         caller
       )
       when runtime == self() and is_reference(capability) do
    Enum.find_value(state.active, :error, fn {scope_key, active} ->
      if active[:identity_capability] == capability and active[:worker_pid] == caller,
        do: {:ok, scope_key, active}
    end)
  end

  defp identity_active(_state, _handle, _caller), do: :error

  defp consume_identity_transport_permission(state, scope_key, active),
    do: put_active(state, scope_key, Map.put(active, :identity_transport_permission, :consumed))

  defp consume_identity_model_permission(state, scope_key, active),
    do: put_active(state, scope_key, Map.put(active, :identity_model_permission, :consumed))

  defp consume_identity_read_tool_permission(state, scope_key, active),
    do: put_active(state, scope_key, Map.put(active, :identity_read_tool_permission, :consumed))

  defp put_identity_read_tool_authorization(state, scope_key, authorization),
    do:
      put_active(
        state,
        scope_key,
        Map.put(state.active[scope_key], :identity_read_tool_authorization, authorization)
      )

  defp mark_identity_read_tool_committed(state, scope_key),
    do:
      put_active(
        state,
        scope_key,
        Map.put(state.active[scope_key], :identity_read_tool_permission, :committed)
      )

  defp put_active(state, scope_key, active),
    do: %{state | active: Map.put(state.active, scope_key, active)}

  ## Interrupted-worker recovery

  defp matching_identity_active(state, ref, pid) do
    Enum.find(state.active, fn {_scope_key, active} ->
      active[:monitor_ref] == ref and active[:worker_pid] == pid and
        is_map(active[:identity_winning_input])
    end)
  end

  defp close_interrupted_identity_active(state, scope_key, active) do
    _ = Process.cancel_timer(active.timeout_ref)

    state = %{
      state
      | active: Map.delete(state.active, scope_key),
        late_wait: Map.delete(state.late_wait, active.run_id)
    }

    state =
      case recover_interrupted_identity(state.namespace, scope_key, active) do
        {:ok, fence} -> recover_identity_fence(state, active.fence_key, fence)
        {:error, :identity_diagnostic_invalid_fence} -> state
        {:error, _reason} -> request_recovery_convergence(state)
      end

    continue_interrupted_identity_recovery(state, interrupted_identity_recovery(active, 3))
  end

  defp retry_interrupted_identity_recovery(state, pending) do
    case find_identity_fence_by_run(state, pending) do
      {:ok, key, %{"terminal" => nil} = fence} ->
        state = recover_open_identity_fence(state, key, fence, false)
        continue_interrupted_identity_recovery(state, decrement_recovery_attempt(pending))

      {:ok, key, %{"terminal" => terminal} = fence} when is_map(terminal) ->
        recover_identity_fence(state, key, fence)

      {:error, :storage_unavailable} ->
        schedule_interrupted_identity_recovery_retry(state, decrement_recovery_attempt(pending))

      _not_recoverable ->
        state
    end
  end

  defp continue_interrupted_identity_recovery(state, pending) do
    case find_identity_fence_by_run(state, pending) do
      {:ok, key, %{"terminal" => terminal} = fence} when is_map(terminal) ->
        recover_identity_fence(state, key, fence)

      {:ok, _key, %{"terminal" => nil}} ->
        schedule_interrupted_identity_recovery_retry(state, pending)

      {:error, :storage_unavailable} ->
        schedule_interrupted_identity_recovery_retry(state, pending)

      _not_recoverable ->
        state
    end
  end

  defp recover_interrupted_identity(namespace, scope_key, active) do
    if TriageRecordStore.atomic_authoritative?() do
      with {:ok, fence} <- RunFence.read_interrupted(namespace, scope_key, active) do
        case fence["terminal"] do
          nil -> AuthoritativeCommit.recover(namespace, fence, :interrupted_worker)
          terminal when is_map(terminal) -> {:ok, fence}
          _invalid -> {:error, :identity_diagnostic_invalid_fence}
        end
      end
    else
      RunFence.recover_interrupted(namespace, scope_key, active)
    end
  end

  defp interrupted_identity_recovery(active, attempts_left) do
    %{
      fence_key: active.fence_key,
      run_id: active.run_id,
      generation: active.generation,
      fence_ref_sha256: sha256(active.fence_key),
      attempts_left: attempts_left
    }
  end

  defp decrement_recovery_attempt(pending),
    do: Map.update!(pending, :attempts_left, &max(0, &1 - 1))

  defp schedule_interrupted_identity_recovery_retry(
         state,
         %{attempts_left: attempts_left} = pending
       )
       when attempts_left > 0 do
    capability = make_ref()
    Process.send_after(self(), {:retry_interrupted_identity_recovery, capability}, 25)

    %{
      state
      | identity_recovery_retries: Map.put(state.identity_recovery_retries, capability, pending)
    }
  end

  defp schedule_interrupted_identity_recovery_retry(state, _pending), do: state

  defp find_identity_fence_by_run(state, pending) do
    case RunFence.lookup_interrupted(state.namespace, pending) do
      {:ok, key, fence} ->
        if Map.has_key?(state.active, fence["bucket_scope"]),
          do: {:error, :identity_diagnostic_invalid_fence},
          else: {:ok, key, fence}

      {:error, _reason} = error ->
        error
    end
  end

  ## Seal and evaluation

  defp start_evaluation(state, scope_key, bucket) do
    started_at = Telemetry.start()
    source_mode = bucket_source_mode(bucket)
    run_before_seal_hook(state.before_seal_hook, scope_key, bucket.generation)

    case Bucketing.seal(state.namespace, scope_key, bucket.generation, state, now()) do
      {:ok, {:wait, remaining}} ->
        Telemetry.emit(:seal, :skipped, source_mode, source_surface(source_mode), started_at)

        state
        |> clear_retry({:seal, scope_key})
        |> schedule_flush(scope_key, bucket, remaining)

      {:ok, :stale} ->
        Telemetry.emit(:seal, :conflict, source_mode, source_surface(source_mode), started_at)

        state
        |> clear_retry({:seal, scope_key})
        |> drop_local_generation_state(scope_key, bucket.generation)

      {:ok, sealed} when is_map(sealed) ->
        Telemetry.emit(:seal, :ok, source_mode, source_surface(source_mode), started_at)

        state
        |> clear_retry({:seal, scope_key})
        |> do_start_evaluation(scope_key, sealed)

      {:error, reason} when reason in @permanent_seal_refusals ->
        Telemetry.emit(:seal, :rejected, source_mode, source_surface(source_mode), started_at)
        park_refused_seal(state, scope_key, bucket, reason)

      {:error, _transient_reason} ->
        Telemetry.emit(:seal, :unavailable, source_mode, source_surface(source_mode), started_at)
        {delay, state} = retry_delay(state, {:seal, scope_key}, @retry_base_ms)
        schedule_flush(state, scope_key, bucket, delay)
    end
  end

  # A deterministic refusal is not a retry candidate: rescheduling it at a fixed
  # delay starves this process forever without ever producing a sealed
  # generation. Park the exact generation with a durable refusal instead. The
  # bucket and fence recovery lanes still re-read durable storage at their own
  # cadence, and a rotated open generation is not parked, so nothing is lost.
  defp park_refused_seal(state, scope_key, bucket, reason) do
    Logger.error(
      "triage seal refused permanently: scope_ref=#{sha256(scope_key)} " <>
        "generation=#{bucket.generation} reason=#{inspect(reason)}; " <>
        "the generation is parked until its durable bucket is repaired"
    )

    state
    |> clear_retry({:seal, scope_key})
    |> cancel_flush_schedule(scope_key)
    |> then(fn state ->
      %{
        state
        | parked_seals:
            Map.put(state.parked_seals, scope_key, %{
              generation: bucket.generation,
              reason: reason
            })
      }
    end)
  end

  defp retry_delay(state, key, base_ms) do
    attempts = Map.get(state.retry_attempts, key, 0)
    delay = min(base_ms * Integer.pow(2, min(attempts, 10)), @retry_cap_ms)
    {delay, %{state | retry_attempts: Map.put(state.retry_attempts, key, attempts + 1)}}
  end

  defp clear_retry(state, key),
    do: %{state | retry_attempts: Map.delete(state.retry_attempts, key)}

  defp run_before_seal_hook(nil, _scope_key, _generation), do: :ok
  defp run_before_seal_hook(hook, scope_key, generation), do: hook.(scope_key, generation)

  # Three different things must stay distinct: invalid composition with no
  # evaluator (fail closed), a sealed generation this build can never project
  # (deterministic), and a predecessor gate that has not answered yet
  # (transient). Only the last one is a retry candidate; the middle one is
  # parked exactly like a permanently refused seal, and the first one says so
  # once per scope instead of looking like a stuck bucket.
  defp do_start_evaluation(state, scope_key, sealed) do
    generation = sealed["generation"]

    if evaluation_enabled?(state) do
      case Pipeline.build_input(sealed) do
        {:ok, input} -> start_authorized_evaluation(state, scope_key, generation, input)
        {:error, reason} -> park_invalid_sealed_input(state, scope_key, generation, reason)
      end
    else
      log_evaluation_disabled(state)
    end
  end

  defp start_authorized_evaluation(state, scope_key, generation, input) do
    started_at = Telemetry.start()
    source_mode = input["source_mode"]

    if RunFence.predecessor_authoritative?(state.namespace, scope_key, generation) do
      create_and_start_fence(
        state,
        scope_key,
        generation,
        ULID.generate(),
        input,
        now(),
        now() + state.evaluation_timeout_ms
      )
    else
      # Either a predecessor is genuinely still open or storage could not
      # answer; both resolve without this process changing anything, so retry
      # under the same bound every other owned wait uses.
      Telemetry.emit(:fence, :unavailable, source_mode, source_surface(source_mode), started_at)
      request_recovery_convergence(state)
    end
  end

  defp park_invalid_sealed_input(state, scope_key, generation, reason) do
    Logger.error(
      "triage sealed generation cannot be projected: scope_ref=#{sha256(scope_key)} " <>
        "generation=#{generation} reason=#{inspect(reason)}; " <>
        "the generation is parked until its durable record is repaired"
    )

    Telemetry.emit(:fence, :rejected, :other, :bft, Telemetry.start())

    state
    |> cancel_flush_schedule(scope_key)
    |> then(fn state ->
      %{state | parked_inputs: Map.put(state.parked_inputs, scope_key, generation)}
    end)
  end

  defp create_and_start_fence(
         state,
         scope_key,
         generation,
         run_id,
         input,
         created_at,
         deadline_at
       ) do
    started_at = Telemetry.start()
    source_mode = input["source_mode"]

    case RunFence.create(state.namespace, scope_key, run_id, input, created_at, deadline_at) do
      {:ok, {:won, created}} ->
        Telemetry.emit(:fence, :ok, source_mode, source_surface(source_mode), started_at)
        start_worker(state, scope_key, generation, run_id, input, created)

      {:ok, :lost} ->
        Telemetry.emit(:fence, :conflict, source_mode, source_surface(source_mode), started_at)
        drop_local_generation_state(state, scope_key, generation)

      {:error, _reason} ->
        Telemetry.emit(:fence, :unavailable, source_mode, source_surface(source_mode), started_at)
        request_recovery_convergence(state)
    end
  end

  # Recovery is a single self-rescheduling chain. Anything that discovers work
  # for it raises this flag; the chain's own tick clears it and converges
  # immediately. Sending a fresh `:converge_triage_recovery` here instead would
  # fork one more permanent chain per storage error.
  defp request_recovery_convergence(state),
    do: %{state | recovery_convergence_scheduled?: true}

  defp start_worker(state, scope_key, generation, run_id, input, created) do
    identity_diagnostic? = created.identity?
    capability = if identity_diagnostic?, do: make_ref()
    transport_attempt_id = if identity_diagnostic?, do: ULID.generate()

    handle =
      if identity_diagnostic?, do: %IdentityFenceHandle{runtime: self(), capability: capability}

    case identity_ports(state, handle) do
      {:ok, context_port, evaluator_port} ->
        start_authorized_worker(
          state,
          scope_key,
          generation,
          run_id,
          input,
          created,
          %{
            handle: handle,
            capability: capability,
            transport_attempt_id: transport_attempt_id,
            identity?: identity_diagnostic?,
            context_port: context_port,
            evaluator_port: evaluator_port
          }
        )

      {:error, option, port} ->
        refuse_unknown_identity_port(state, scope_key, generation, option, port)
    end
  end

  defp start_authorized_worker(state, scope_key, generation, run_id, input, created, ports) do
    fence_key = created.key
    fence = created.record
    identity_diagnostic? = ports.identity?
    source_mode = input["source_mode"]
    parent = self()
    capability = ports.capability
    transport_attempt_id = ports.transport_attempt_id
    handle = ports.handle
    context_port = ports.context_port
    evaluator_port = ports.evaluator_port
    review_projection = state.review_projection
    snapshot_authority = if identity_diagnostic?, do: handle, else: fence_key
    result_capability = if identity_diagnostic?, do: make_ref()
    context_key = {scope_key, generation}

    observability_context =
      Map.get(
        state.observability_contexts,
        context_key,
        SystemsObservability.Context.capture()
      )

    {worker_pid, monitor_ref} =
      spawn_monitor(fn ->
        SystemsObservability.Context.run(observability_context, fn ->
          result =
            Telemetry.observe(
              :evaluation,
              source_mode,
              observability_surface(observability_context),
              fn ->
                evaluate_run(
                  input,
                  context_port,
                  evaluator_port,
                  review_projection,
                  snapshot_authority
                )
              end
            )

          result_message =
            if is_reference(result_capability) do
              {:triage_evaluation_result, scope_key, generation, run_id, result_capability,
               result}
            else
              {:triage_evaluation_result, scope_key, generation, run_id, result}
            end

          Logger.info(
            "triage_runtime_worker stage=evaluation_complete result=#{runtime_result_class(result)}"
          )

          send(parent, result_message)

          Logger.info(
            "triage_runtime_worker stage=result_sent result=#{runtime_result_class(result)}"
          )
        end)
      end)

    timeout_ref =
      Process.send_after(
        self(),
        {:triage_evaluation_timeout, scope_key, generation, run_id},
        state.evaluation_timeout_ms
      )

    active = %{
      generation: generation,
      run_id: run_id,
      fence_key: fence_key,
      monitor_ref: monitor_ref,
      timeout_ref: timeout_ref,
      worker_pid: worker_pid,
      identity_capability: capability,
      identity_result_capability: result_capability,
      identity_transport_attempt_id: transport_attempt_id,
      identity_transport_permission: if(identity_diagnostic?, do: :available),
      identity_model_permission: if(identity_diagnostic?, do: :available),
      identity_read_tool_permission: if(identity_diagnostic?, do: :available),
      identity_base_input_sha256: if(identity_diagnostic?, do: sha256(fence["input_snapshot"])),
      identity_winning_input: if(identity_diagnostic?, do: input),
      identity_winning_source_anchor:
        if(identity_diagnostic?, do: identity_winning_source_anchor(input))
    }

    %{
      state
      | buckets: drop_local_generation(state.buckets, scope_key, generation),
        observability_contexts: Map.delete(state.observability_contexts, context_key),
        active: Map.put(state.active, scope_key, active)
    }
  end

  # An identity run's fence handle is its ONLY capability, and the only place it
  # can travel is a port's options. Matching on hard-coded adapter module atoms
  # and passing everything else through unchanged meant a port this clause did
  # not recognize ran with no handle at all: every fence-gated step then refused
  # and the run read as an adapter bug instead of the composition error it was.
  # Which adapter is authorized for an identity run is `Pipeline`'s call, not
  # this one's; what this owns is that the capability is never silently dropped.
  # A nil port is retained for fail-closed construction tests; production
  # composition always supplies both fixed product ports.
  defp identity_ports(state, nil), do: {:ok, state.context_port, state.evaluator_port}

  defp identity_ports(state, %IdentityFenceHandle{} = handle) do
    with {:ok, context_port} <- identity_port(state.context_port, handle, :context_port),
         {:ok, evaluator_port} <- identity_port(state.evaluator_port, handle, :evaluator_port) do
      {:ok, context_port, evaluator_port}
    end
  end

  defp identity_port(nil, _handle, _option), do: {:ok, nil}

  defp identity_port({module, opts}, handle, _option) when is_atom(module) and is_list(opts),
    do: {:ok, {module, Keyword.put(opts, :identity_fence_handle, handle)}}

  # A bare module atom has no options, so it cannot carry the capability at all.
  defp identity_port(port, _handle, option), do: {:error, option, port}

  # The fence is already won at this point, so refusing here leaves it open and
  # its own deadline settles it. Starting a capability-less worker instead would
  # burn the run on a diagnostic that names the wrong layer.
  defp refuse_unknown_identity_port(state, scope_key, generation, option, port) do
    Logger.error(
      "triage #{option} cannot carry an identity fence handle: #{inspect(port)}; " <>
        "the run is refused and its fence will settle on its own deadline"
    )

    Telemetry.emit(:fence, :rejected, :other, :bft, Telemetry.start())
    drop_local_generation_state(state, scope_key, generation)
  end

  defp identity_winning_source_anchor(input) do
    %{
      "schema" => "comma.triage-winning-source-anchor.v1",
      "generation" => input["generation"],
      "source_mode" => input["source_mode"],
      "sealed_events" => input["events"],
      "source_authority" => input["source_authority"]
    }
  end

  defp evaluate_run(
         input,
         context_port,
         evaluator_port,
         review_projection,
         %IdentityFenceHandle{} = snapshot_authority
       ),
       do:
         Pipeline.run_identity(
           input,
           context_port,
           evaluator_port,
           review_projection,
           snapshot_authority
         )

  defp evaluate_run(input, context_port, evaluator_port, review_projection, snapshot_authority),
    do:
      Pipeline.run_compatibility(
        input,
        context_port,
        evaluator_port,
        review_projection,
        snapshot_authority
      )

  defp runtime_result_class({:ok, _decision, _proof}), do: "ok"
  defp runtime_result_class({:terminal, _terminal}), do: "terminal"
  defp runtime_result_class({:error, reason}) when is_atom(reason), do: "error_#{reason}"
  defp runtime_result_class({:error, _private}), do: "error_private"
  defp runtime_result_class(_other), do: "invalid"

  defp settlement_error_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp settlement_error_class(_private), do: "private"

  ## Terminal settlement

  defp complete_active_evaluation(state, scope_key, generation, run_id, result, active) do
    terminal = Pipeline.terminal_from_result(result, result_mode(active), now())
    {state, _authoritative?} = settle_active(state, scope_key, active, terminal)

    if Map.has_key?(state.active, scope_key) do
      result_message =
        case active[:identity_result_capability] do
          capability when is_reference(capability) ->
            {:triage_evaluation_result, scope_key, generation, run_id, capability, result}

          _legacy ->
            {:triage_evaluation_result, scope_key, generation, run_id, result}
        end

      {delay, state} = retry_delay(state, {:settle, scope_key, run_id}, @retry_base_ms)
      Process.send_after(self(), result_message, delay)
      state
    else
      state
      |> clear_retry({:settle, scope_key, run_id})
      |> schedule_pending_bucket(scope_key)
    end
  end

  defp complete_legacy_late_evaluation(state, run_id, result) do
    case state.late_wait[run_id] do
      %{identity_late_result?: true} ->
        state

      nil ->
        state

      late ->
        state
        |> persist_late_result(late, result)
        |> then(&%{&1 | late_wait: Map.delete(&1.late_wait, run_id)})
    end
  end

  defp complete_identity_late_evaluation(
         state,
         scope_key,
         generation,
         run_id,
         result_capability,
         result
       ) do
    case state.late_wait[run_id] do
      %{
        generation: ^generation,
        result_capability: ^result_capability,
        identity_late_result?: true
      } = late ->
        if late.scope_ref_sha256 == sha256(scope_key) and
             Pipeline.valid_identity_late_result?(result) do
          state
          |> persist_late_result(late, result)
          |> then(&%{&1 | late_wait: Map.delete(&1.late_wait, run_id)})
        else
          state
        end

      _missing_or_foreign ->
        state
    end
  end

  defp settle_active(state, scope_key, active, terminal, timed_out? \\ false) do
    started_at = Telemetry.start()
    authority = if(timed_out?, do: :timeout, else: :result)

    case terminalize(state.namespace, scope_key, active, terminal, authority) do
      {:ok, settlement} ->
        fence = settlement.fence
        terminal = settlement.requested_terminal
        _ = Process.cancel_timer(active.timeout_ref)
        authoritative? = settlement.outcome == :requested
        authority_status = get_in(fence, ["terminal", "status"])

        {state, projection_outcome} =
          if settlement.outcome in [:requested, :timeout] and
               not TriageRecordStore.atomic_authoritative?() do
            project_settled_terminal(state, active, fence)
          else
            {state, if(TriageRecordStore.atomic_authoritative?(), do: :queued, else: :skipped)}
          end

        state = maybe_expedite_projection_convergence(state)

        active_map = Map.delete(state.active, scope_key)

        state =
          cond do
            timed_out? and identity_active?(active) and active.monitor_ref != nil ->
              late = identity_late_wait(active, authority_status, scope_key)

              %{
                state
                | active: active_map,
                  late_wait: Map.put(state.late_wait, active.run_id, late)
              }

            timed_out? and authority_status == "skipped_timeout" and active.monitor_ref != nil ->
              late = Map.put(active, :authority_status, authority_status)

              %{
                state
                | active: active_map,
                  late_wait: Map.put(state.late_wait, active.run_id, late)
              }

            true ->
              %{state | active: active_map}
          end

        state =
          if not timed_out? and not authoritative? do
            late = Map.put(active, :authority_status, authority_status)
            persist_late_result(state, late, {:terminal, terminal})
          else
            state
          end

        emit_active_phase(
          :terminal,
          terminal_telemetry_outcome(authoritative?, projection_outcome),
          active,
          started_at
        )

        {state, authoritative?}

      {:error, :identity_diagnostic_invalid_fence} ->
        Logger.warning(
          "triage_runtime_settlement_failed reason=identity_diagnostic_invalid_fence"
        )

        _ = Process.cancel_timer(active.timeout_ref)
        emit_active_phase(:terminal, :rejected, active, started_at)
        {%{state | active: Map.delete(state.active, scope_key)}, false}

      {:error, reason} ->
        Logger.warning(
          "triage_runtime_settlement_failed reason=#{settlement_error_class(reason)}"
        )

        emit_active_phase(:terminal, :unavailable, active, started_at)
        {state, false}
    end
  end

  defp terminalize(namespace, scope_key, active, terminal, authority) do
    if TriageRecordStore.atomic_authoritative?(),
      do: AuthoritativeCommit.settle(namespace, scope_key, active, terminal, authority),
      else: RunFence.terminalize(scope_key, active, terminal, authority)
  end

  defp project_settled_terminal(state, active, fence) do
    with {:ok, ready} <- RunFence.prepare_authoritative_projection(state.namespace, fence),
         :ok <- persist_authoritative(state.namespace, ready) do
      {state, :ok}
    else
      _unavailable -> {schedule_terminal_projection(state, active.fence_key, 0), :unavailable}
    end
  end

  defp identity_active?(active), do: is_reference(active[:identity_capability])

  defp identity_late_wait(active, authority_status, scope_key) do
    %{
      run_id: active.run_id,
      generation: active.generation,
      scope_ref_sha256: sha256(scope_key),
      authority_status: authority_status,
      monitor_ref: active.monitor_ref,
      worker_pid: active.worker_pid,
      result_capability: active.identity_result_capability,
      identity_late_result?: true
    }
  end

  defp result_mode(%{identity_capability: capability}) when is_reference(capability),
    do: :identity

  defp result_mode(%{identity_late_result?: true}), do: :identity
  defp result_mode(_active), do: :compatibility

  defp persist_authoritative(namespace, %{"schema" => "comma.triage-bucket-fence.v2"} = fence) do
    with {:ok, authorized_projection} <-
           RunFence.authorize_projection_from_storage(namespace, fence) do
      Ledger.persist(namespace, authorized_projection)
    end
  end

  defp persist_authoritative(namespace, fence), do: Ledger.persist(namespace, fence)

  # A late result is the only durable evidence that a worker answered after its
  # fence had settled. A storage failure here used to be discarded, so the
  # evidence vanished with no log, no telemetry, and no retry; the write is now
  # bounded-retried against one pinned observation identity, and giving up is
  # loud.
  defp persist_late_result(state, active, result) do
    late = %{
      run_id: active.run_id,
      authority_status: active[:authority_status],
      result_parts: Pipeline.result_parts(result, result_mode(active)),
      observation: Ledger.late_observation()
    }

    write_late_result(state, late, @late_result_retry_attempts)
  end

  defp write_late_result(state, late, attempts_left) do
    case Ledger.persist_late(
           state.namespace,
           %{run_id: late.run_id, authority_status: late.authority_status},
           late.result_parts,
           late.observation
         ) do
      :ok ->
        clear_retry(state, {:late_result, late.run_id})

      {:error, reason} ->
        schedule_late_result_retry(state, late, reason, attempts_left)
    end
  end

  defp schedule_late_result_retry(state, late, reason, attempts_left) when attempts_left > 0 do
    Logger.warning(
      "triage late result not durable yet: run_id=#{late.run_id} " <>
        "reason=#{inspect(reason)} attempts_left=#{attempts_left}"
    )

    Telemetry.emit(:terminal, :unavailable, :other, :bft, Telemetry.start())
    capability = make_ref()
    {delay, state} = retry_delay(state, {:late_result, late.run_id}, @retry_base_ms)
    Process.send_after(self(), {:retry_late_result, capability}, delay)

    %{
      state
      | late_result_retries:
          Map.put(state.late_result_retries, capability, {late, attempts_left - 1})
    }
  end

  defp schedule_late_result_retry(state, late, reason, _exhausted) do
    Logger.error(
      "triage late result dropped after bounded retries: run_id=#{late.run_id} " <>
        "reason=#{inspect(reason)}; the authoritative run stays intact but the " <>
        "late observation is lost"
    )

    Telemetry.emit(:terminal, :error, :other, :bft, Telemetry.start())
    clear_retry(state, {:late_result, late.run_id})
  end

  ## Flush scheduling

  defp schedule_flush(state, scope_key, bucket, delay) do
    if parked_generation?(state, scope_key, bucket.generation) do
      state
    else
      # A rotated open generation is a different durable record, so neither park
      # survives it.
      %{
        state
        | parked_seals: Map.delete(state.parked_seals, scope_key),
          parked_inputs: Map.delete(state.parked_inputs, scope_key)
      }
      |> do_schedule_flush(scope_key, bucket, delay)
    end
  end

  defp parked_generation?(state, scope_key, generation) do
    match?(%{generation: ^generation}, state.parked_seals[scope_key]) or
      state.parked_inputs[scope_key] == generation
  end

  defp do_schedule_flush(state, scope_key, bucket, delay) do
    fire_at = now() + max(0, delay)

    case state.flush_schedules[scope_key] do
      %{token: token, generation: generation, fire_at: existing_fire_at}
      when token == bucket.token and generation == bucket.generation and
             existing_fire_at <= fire_at ->
        state

      %{timer_ref: timer_ref} ->
        _ = Process.cancel_timer(timer_ref)
        put_flush_schedule(state, scope_key, bucket, fire_at)

      nil ->
        put_flush_schedule(state, scope_key, bucket, fire_at)
    end
  end

  defp put_flush_schedule(state, scope_key, bucket, fire_at) do
    id = make_ref()

    timer_ref =
      Process.send_after(
        self(),
        {:flush, scope_key, bucket.token, bucket.generation, id},
        max(0, fire_at - now())
      )

    schedule = %{
      id: id,
      token: bucket.token,
      generation: bucket.generation,
      fire_at: fire_at,
      timer_ref: timer_ref
    }

    %{state | flush_schedules: Map.put(state.flush_schedules, scope_key, schedule)}
  end

  defp cancel_flush_schedule(state, scope_key) do
    case state.flush_schedules[scope_key] do
      %{timer_ref: timer_ref} ->
        _ = Process.cancel_timer(timer_ref)
        %{state | flush_schedules: Map.delete(state.flush_schedules, scope_key)}

      nil ->
        state
    end
  end

  defp schedule_pending_bucket(state, scope_key) do
    cond do
      Map.has_key?(state.active, scope_key) ->
        state

      bucket = state.buckets[scope_key] ->
        schedule_flush(state, scope_key, bucket, Bucketing.flush_delay(bucket, state, now()))

      true ->
        state
    end
  end

  defp drop_local_generation(buckets, scope_key, generation) do
    case buckets[scope_key] do
      %{generation: ^generation} -> Map.delete(buckets, scope_key)
      _other -> buckets
    end
  end

  defp drop_local_generation_state(state, scope_key, generation) do
    %{
      state
      | buckets: drop_local_generation(state.buckets, scope_key, generation),
        observability_contexts: Map.delete(state.observability_contexts, {scope_key, generation})
    }
  end

  ## Recovery lanes

  defp request_recovery_lane(%{recovery_work: nil} = state, lane),
    do: start_recovery_step(state, Recovery.focus(state.recovery_cursor, lane))

  defp request_recovery_lane(state, lane),
    do: %{state | recovery_requests: Enum.uniq(state.recovery_requests ++ [lane])}

  defp start_recovery_step(%{recovery_work: nil} = state, cursor) do
    if state.recovery_schedule, do: Process.cancel_timer(state.recovery_schedule.timer_ref)
    owner = self()
    id = make_ref()
    namespace = state.namespace
    page_size = state.recovery_page_size
    active = state.active

    {:ok, pid} =
      Task.Supervisor.start_child(state.background_supervisor, fn ->
        result = read_recovery_page(namespace, page_size, cursor, active)
        send(owner, {:triage_recovery_page, id, result})
      end)

    ref = Process.monitor(pid)

    %{
      state
      | recovery_work: %{id: id, pid: pid, ref: ref, cursor: cursor},
        recovery_schedule: nil
    }
  end

  defp start_recovery_step(state, _cursor), do: state

  defp read_recovery_page(namespace, page_size, cursor, active) do
    SystemsObservability.Context.with_surface(:system, fn ->
      SystemsObservability.Trace.with_span(
        :triage_recovery,
        %{component: :salix_im, operation: :triage_recovery, surface: :system},
        fn ->
          Telemetry.observe(:recovery, :system, :system, fn ->
            Recovery.step(namespace, page_size, cursor)
            |> prepare_recovery_page(namespace, active)
          end)
        end
      )
    end)
  end

  defp prepare_recovery_page({:ok, :fences, records, cursor, delay, errors}, namespace, active) do
    records =
      Enum.map(records, fn {key, fence} ->
        view = RunFence.recovery_view(fence)

        if view == {:identity, :open} and TriageRecordStore.atomic_authoritative?() and
             not active_identity_fence?(%{active: active}, fence) and deadline_reached?(fence) do
          # This transition uses the same durable deadline and revision fence
          # as foreground settlement. A concurrent winner is never overwritten.
          case AuthoritativeCommit.recover(namespace, fence, :deadline) do
            {:ok, recovered} -> {key, recovered, {:identity, :terminal}}
            {:error, :identity_diagnostic_invalid_fence} -> {key, fence, :invalid}
            {:error, _reason} -> {key, fence, :recovery_unavailable}
          end
        else
          {key, fence, view}
        end
      end)

    errors =
      errors +
        Enum.count(records, fn {_, _, view} -> view in [:invalid, :recovery_unavailable] end)

    {:ok, :fences, records, cursor, delay, errors}
  end

  defp prepare_recovery_page({:ok, :buckets, records, cursor, delay, errors}, _namespace, _active) do
    records =
      Enum.flat_map(records, fn {key, bucket} ->
        Enum.map(bucket["sealed_generations"] || [], fn sealed ->
          {key, Map.put(bucket, "sealed_generations", [sealed])}
        end)
      end)

    {:ok, :buckets, records, cursor, delay, errors}
  end

  defp prepare_recovery_page(result, _namespace, _active), do: result

  defp receive_recovery_page(state, cursor, result) do
    case result do
      {:ok, lane, records, next_cursor, next_delay_ms, record_errors} ->
        # A page that listed cleanly but could not be read is not a clean lane:
        # reporting `:ok` for it hid every poison or vanished record behind a
        # healthy-looking recovery signal.
        Telemetry.emit_recovery_status(
          lane,
          if(record_errors > 0, do: :error, else: :ok),
          if(next_delay_ms == 0, do: 1, else: 0),
          record_errors
        )

        id = state.recovery_work.id
        send(self(), {:recover_record, id})

        %{
          state
          | recovery_cursor: next_cursor,
            recovery_work: %{id: id, lane: lane, records: records, next_delay_ms: next_delay_ms}
        }

      {:error, next_cursor, next_delay_ms} ->
        Telemetry.emit_recovery_status(cursor[:lane], :unavailable, 1)
        finish_recovery_step(%{state | recovery_cursor: next_cursor}, next_delay_ms)
    end
  end

  defp finish_recovery_step(state, next_delay_ms) do
    state = %{state | recovery_work: nil}

    {delay, state} =
      if state.recovery_convergence_scheduled? do
        {retry_ms, state} = retry_delay(state, :recovery_convergence, @retry_base_ms)
        {min(retry_ms, max(next_delay_ms, @retry_base_ms)), state}
      else
        {next_delay_ms, clear_retry(state, :recovery_convergence)}
      end

    state = %{state | recovery_convergence_scheduled?: false}

    case state.recovery_requests do
      [lane | rest] ->
        start_recovery_step(
          %{state | recovery_requests: rest},
          Recovery.focus(state.recovery_cursor, lane)
        )

      [] ->
        id = make_ref()
        timer_ref = Process.send_after(self(), {:converge_triage_recovery, id}, delay)
        %{state | recovery_schedule: %{id: id, timer_ref: timer_ref}}
    end
  end

  defp recover_bucket_records(state, buckets) do
    Enum.reduce(buckets, state, fn {_key, bucket}, state ->
      Enum.reduce(bucket["sealed_generations"] || [], state, fn sealed, state ->
        generation = sealed["generation"]
        scope = bucket["bucket_scope"]

        case RunFence.generation_status(state.namespace, scope, generation) do
          :present ->
            state

          :missing ->
            if Map.has_key?(state.active, scope),
              do: state,
              else: do_start_evaluation(state, scope, sealed)

          :unavailable ->
            state
        end
      end)
    end)
  end

  defp recover_fence_records(state, fences) do
    Enum.reduce(fences, state, fn {key, fence, view}, state ->
      case view do
        {:legacy, _fence_state} ->
          recover_fence(state, key, fence)

        {:identity, :open} ->
          if TriageRecordStore.atomic_authoritative?(),
            do: state,
            else: recover_identity_fence(state, key, fence)

        {:identity, _fence_state} ->
          recover_identity_fence(state, key, fence)

        :recovery_unavailable ->
          request_recovery_convergence(state)

        :invalid ->
          state
      end
    end)
  end

  defp recover_fence(state, key, fence) do
    case fence["terminal"] do
      terminal when is_map(terminal) ->
        case persist_authoritative(state.namespace, fence) do
          :ok -> state
          {:error, :identity_diagnostic_invalid_fence} -> state
          {:error, _reason} -> schedule_terminal_projection(state, key, 0)
        end

      nil ->
        scope_key = fence["bucket_scope"]

        if Map.has_key?(state.active, scope_key) do
          state
        else
          delay = max(0, fence["deadline_at"] - now())

          timeout_ref =
            Process.send_after(
              self(),
              {:triage_evaluation_timeout, scope_key, fence["generation"], fence["run_id"]},
              delay
            )

          active = %{
            generation: fence["generation"],
            run_id: fence["run_id"],
            fence_key: key,
            monitor_ref: nil,
            timeout_ref: timeout_ref
          }

          %{state | active: Map.put(state.active, scope_key, active)}
        end
    end
  end

  defp recover_identity_fence(state, key, %{"terminal" => terminal} = fence)
       when is_map(terminal) do
    if TriageRecordStore.atomic_authoritative?() do
      # The terminal, run, replay and projection obligation committed together.
      # Re-arming a local bucket grants no model/effect authority: its new run
      # still goes through the normal seal and fence. Derived projection owns
      # its own validation and retries, without replaying every historical
      # source bundle in the process that grants live worker capabilities.
      schedule_pending_bucket(state, fence["bucket_scope"])
    else
      state =
        case project_identity_terminal(state.namespace, fence) do
          :ok -> state
          {:retry, _ready} -> queue_terminal_projection(state, key)
        end

      with key when is_binary(key) <- key,
           {:ok, authorized_projection} <-
             RunFence.authorize_projection_from_key(state.namespace, key) do
        schedule_pending_bucket(state, authorized_projection.fence["bucket_scope"])
      else
        _not_authoritative -> state
      end
    end
  end

  defp recover_identity_fence(state, key, %{"terminal" => nil} = fence) do
    cond do
      active_identity_fence?(state, fence) -> state
      not deadline_reached?(fence) -> state
      true -> recover_open_identity_fence(state, key, fence)
    end
  end

  defp active_identity_fence?(state, fence) do
    case state.active[fence["bucket_scope"]] do
      %{generation: generation, run_id: run_id} ->
        generation == fence["generation"] and run_id == fence["run_id"]

      _not_active ->
        false
    end
  end

  defp recover_open_identity_fence(
         state,
         key,
         %{"terminal" => nil} = fence,
         require_deadline? \\ true
       ) do
    authority = if(require_deadline?, do: :deadline, else: :interrupted_worker)

    case recover_open_identity(state.namespace, fence, authority) do
      {:ok, recovered} -> recover_identity_fence(state, key, recovered)
      {:error, :identity_diagnostic_invalid_fence} -> state
      {:error, _reason} -> request_recovery_convergence(state)
    end
  end

  defp recover_open_identity(namespace, fence, authority) do
    if TriageRecordStore.atomic_authoritative?(),
      do: AuthoritativeCommit.recover(namespace, fence, authority),
      else: RunFence.recover_open(namespace, fence, authority)
  end

  defp deadline_reached?(%{"deadline_at" => deadline_at}) when is_integer(deadline_at),
    do: now() >= deadline_at

  defp deadline_reached?(_fence), do: true

  defp project_identity_terminal(namespace, fence) do
    case RunFence.prepare_authoritative_projection(namespace, fence) do
      {:ok, ready} ->
        case persist_authoritative(namespace, ready) do
          :ok -> :ok
          {:error, :identity_diagnostic_invalid_fence} -> :ok
          {:error, _reason} -> {:retry, ready}
        end

      {:error, :identity_diagnostic_invalid_fence} ->
        :ok
    end
  end

  defp project_identity_terminal_from_storage(namespace, fence_key) do
    with {:ok, authorized_projection} <-
           RunFence.authorize_projection_from_key(namespace, fence_key) do
      case Ledger.persist(namespace, authorized_projection) do
        :ok -> :ok
        {:error, _reason} -> :retry
      end
    else
      _missing_or_mismatched -> :ok
    end
  end

  defp queue_terminal_projection(state, key) when is_binary(key),
    do: schedule_terminal_projection(state, key, 0)

  defp queue_terminal_projection(state, _key), do: state

  defp schedule_terminal_projection(state, fence_key, delay) do
    case state.terminal_projection_schedules[fence_key] do
      %{id: id} when is_reference(id) ->
        state

      nil
      when map_size(state.terminal_projection_schedules) >= @terminal_projection_retry_limit ->
        state

      nil ->
        id = make_ref()
        timer_ref = Process.send_after(self(), {:project_terminal, fence_key, id}, max(0, delay))
        schedule = %{id: id, timer_ref: timer_ref}

        %{
          state
          | terminal_projection_schedules:
              Map.put(state.terminal_projection_schedules, fence_key, schedule)
        }
    end
  end

  defp maybe_schedule_projection_convergence(state, delay) do
    if TriageRecordStore.atomic_authoritative?() and
         is_nil(state.projection_convergence_schedule) and is_nil(state.projection_worker) do
      id = make_ref()

      timer_ref =
        Process.send_after(self(), {:converge_projection_obligations, id}, max(0, delay))

      %{state | projection_convergence_schedule: %{id: id, timer_ref: timer_ref}}
    else
      state
    end
  end

  defp start_projection_worker(%{projection_worker: nil} = state) do
    owner = self()
    id = make_ref()
    namespace = state.namespace
    limit = min(state.recovery_page_size, 100)

    {:ok, pid} =
      Task.Supervisor.start_child(state.background_supervisor, fn ->
        result = ProjectionProjector.converge(namespace, limit)
        send(owner, {:triage_projection_result, id, result})
      end)

    ref = Process.monitor(pid)

    %{state | projection_worker: %{id: id, pid: pid, ref: ref}}
  end

  defp start_projection_worker(state), do: state

  defp maybe_expedite_projection_convergence(state) do
    if TriageRecordStore.atomic_authoritative?() do
      case state.projection_convergence_schedule do
        %{timer_ref: timer_ref} -> _ = Process.cancel_timer(timer_ref)
        nil -> :ok
      end

      state
      |> Map.put(:projection_convergence_schedule, nil)
      |> maybe_schedule_projection_convergence(0)
    else
      state
    end
  end

  ## Telemetry labels

  defp emit_active_phase(phase, outcome, active, started_at) do
    source_mode = get_in(active, [:identity_winning_input, "source_mode"])
    Telemetry.emit(phase, outcome, source_mode, source_surface(source_mode), started_at)
  end

  defp receipt_source_mode(receipt) when is_map(receipt),
    do: get_in(receipt, ["triage_event", "source_mode"])

  defp receipt_source_mode(_receipt), do: :other

  defp bucket_source_mode(%{receipts: [receipt | _rest]}), do: receipt_source_mode(receipt)
  defp bucket_source_mode(_bucket), do: :other

  defp replay_source_mode({:ok, run}) when is_map(run) do
    run["source_mode"] || get_in(run, ["input_snapshot", "source_mode"]) ||
      get_in(run, ["input_snapshot", "snapshot", "source_mode"])
  end

  defp replay_source_mode(_reply), do: :other

  defp observability_surface(%{"surface" => surface}), do: surface
  defp observability_surface(%{surface: surface}), do: surface
  defp observability_surface(_context), do: :other

  defp terminal_telemetry_outcome(_authoritative?, :unavailable), do: :unavailable
  defp terminal_telemetry_outcome(true, _projection_outcome), do: :ok
  defp terminal_telemetry_outcome(false, _projection_outcome), do: :conflict

  defp source_surface(source_mode)
       when source_mode in [
              :callback,
              "callback",
              :clickhouse_etl,
              "clickhouse_etl",
              :historical,
              "historical_thread_reenactment",
              :periodic_patrol,
              "periodic_patrol",
              :scheduled_recheck,
              "scheduled_recheck"
            ],
       do: :bft

  defp source_surface(source_mode) when source_mode in [:system, "system"], do: :system
  defp source_surface(_source_mode), do: :other

  defp telemetry_outcome(result) do
    case result do
      value when value in [:ok, :accepted, :duplicate] -> :ok
      {:ok, _value} -> :ok
      {:error, :timeout} -> :timeout
      {:error, :unavailable} -> :unavailable
      {:error, :conflict} -> :conflict
      {:error, _reason} -> :error
      _other -> :other
    end
  end

  # Record hashes must be reproducible across OTP releases. Jason follows the
  # map's own iteration order, which above the 32-key flatmap boundary is a HAMT
  # implementation detail, so an OTP upgrade would silently invalidate every
  # historical hash. CanonicalJSON sorts keys, so the bytes are the record's.
  defp sha256(value) do
    value
    |> CanonicalJSON.encode!()
    |> CanonicalJSON.sha256()
  end

  defp now, do: System.system_time(:millisecond)
end
