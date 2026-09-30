defmodule SalixAgent.Round do
  @moduledoc """
  Drives one round of an internal runtime session. A round is one activation
  precondition pass, one LLM request, and the synchronous tool results produced
  by that request. Continuous rounds until final/wait/async pause make a turn;
  the boundary between rounds belongs to `InternalSessionActor` activation, not
  to this module.

  Session state is persisted through `SalixAgent.InternalSessionStore`; workspace
  side effects are committed through the agent workspace operation API before
  their tool results are written back to the session.

  Tool availability and the optional role system prompt come from the
  role-specific `SalixAgent.AgentActor` runtime policy. `ToolPolicy` is only the
  pure assembly helper behind that role actor boundary.

  Returns `{:ok, context, outcome}` where outcome is `:final |
  :round_boundary | {:llm_pending, pending} |
  {:async_tools_started, pending}`, or `{:error, reason}`.

  The kernel's `loop_step` (`VerifiedKernel.Session.Loop`) decides every
  branch of the round. This module prepares the provider request and runs
  the effects the loop returns. The tool turn's commit-intent ->
  execute-tools -> commit-results order follows the proven
  `AgentLoop.Round` machine.

  The retired pre-LLM automatic visible-reply handoff is modeled historically
  in `tla/salix/VisibleReplyObligation.tla`; current rounds use its remaining
  codecs only to retire rolling state and never append a Conversation Message.

  Source-bound transient presentation identity is modeled in
  `tla/salix/ActivityPresentation.tla`; exact Participant transport ownership
  is defined by the 2026-08-25 Participant-status ADR. Public/private summary
  authority and egress sanitization are modeled in
  `tla/salix/ActivitySummaryAuthority.tla`.

  Scheduled Task dependency-failure containment and its same-window terminal
  result are modeled in `tla/salix/ScheduledTaskFailure.tla`.
  """

  require Logger

  alias CommaLog

  alias SalixAgent.InternalSessionStore.Revision

  alias SalixAgent.{
    ActivityEvent,
    SessionDriver,
    AgentActor,
    ContextProviders,
    ProjectKnowledgeContext,
    SendMessageDraftStream,
    DependencyJob,
    InternalSessionFleet,
    InternalSessionStore,
    LLM,
    LLMMetering,
    LLMProvider,
    OwnershipCell,
    SessionToolDispatch,
    ToolResultProjection,
    Tools,
    VisibleReply,
    VisibleReplyPolicy
  }

  alias SalixAgent.LLM.ReasoningDelta
  alias SalixAgent.InternalSession

  require InternalSession

  @type runtime_context :: %{
          required(:agent_id) => String.t(),
          required(:session_id) => String.t(),
          optional(atom()) => term()
        }

  @llm_request_max_retries 5
  @llm_request_retry_base_ms 250
  # A rate limit (429) or load shedding (529) clears on the provider's clock,
  # typically a one-minute window, so the ordinary millisecond backoff burns
  # the whole retry budget inside it. Staging 2026-09-14: opus 429s retried six
  # times in ten seconds and the rounds failed anyway.
  @llm_rate_limit_retry_base_ms 5_000
  @llm_rate_limit_statuses [429, 529]
  @llm_retry_delay_cap_ms 60_000
  @tool_result_envelope_max_bytes ToolResultProjection.model_envelope_max_bytes()
  @llm_meter_tracker_key {__MODULE__, :llm_meter_tracker}
  @visible_reply_draft_key {__MODULE__, :visible_reply_draft}
  @send_message_draft_stream_key {__MODULE__, :send_message_draft_stream}
  @reasoning_activity_key {__MODULE__, :reasoning_activity}

  # Live Thinking refreshes only from provider-designated public summaries:
  # keep the tail and emit at most ~2 activities/second.
  @reasoning_tail_max_chars 600
  @reasoning_activity_throttle_ms 500

  @doc false
  # Internal round executor. Direct/operator callers must enter through
  # InternalSessionActor.run_round/4 so strict activation preconditions are
  # checked before durable session status is set to active.
  @spec run(runtime_context(), String.t(), keyword()) ::
          {:ok, runtime_context(),
           :final
           | :round_boundary
           | :guard_failure_parked
           | {:llm_pending, map()}
           | {:async_tools_started, [map()]}}
          | {:error, term()}
  def run(context, session_id, opts \\ [])

  def run(%SalixStore.Agent.Owned{}, _session_id, _opts),
    do: {:error, :agent_lease_not_session_runtime_context}

  def run(%{agent_id: agent_id} = context, session_id, opts)
      when is_binary(agent_id) and is_binary(session_id) do
    with :ok <- require_session_context(context, session_id) do
      InternalSessionFleet.run_round(
        agent_id,
        session_id,
        context,
        Keyword.put(opts, :__round_run_delegate__, true)
      )
    end
  end

  defp log_round_result(result, context, session_id) do
    case result do
      {:ok, _context, outcome} ->
        CommaLog.log("round_end", %{
          agent_id: context.agent_id,
          session_id: session_id,
          outcome: outcome
        })

      {:error, reason} ->
        CommaLog.log("round_error", %{
          agent_id: context.agent_id,
          session_id: session_id,
          reason: reason
        })

      _dispatched ->
        :ok
    end

    result
  end

  # Provider computation may precede persistence. Public deltas and the final
  # provider result cannot cross back into the runtime until the owner opens
  # this exact fence. The owner does not wait here, only the dependency does.
  defp persistence_ready?(%{persistence_gate: gate}) do
    case Process.get({__MODULE__, gate}) do
      nil ->
        # Streaming callbacks can encounter this gate before the provider
        # returns. Measure that wait without changing output admission.
        SystemsObservability.Trace.with_span(
          :salix_stream_persistence_wait,
          %{component: "salix_agent", surface: SystemsObservability.Context.current_surface()},
          fn ->
            receive do
              {:persistence_fence, ^gate, ready} ->
                Process.put({__MODULE__, gate}, ready)
                ready
            end
          end
        )

      ready ->
        ready
    end
  end

  defp persistence_ready?(_context), do: true

  @doc false
  # The first half of a round, before the kernel builds its request. The
  # answer is `{:guard, config, host}` for a runtime failure notice, whose
  # facts the kernel builds from `config`; `{:request, config, prep}` for a
  # model round, whose request the kernel builds from `config`; or an error.
  def prepare(context, session_id, opts) do
    SystemsObservability.Context.with_surface(operation_surface(context, opts), fn ->
      do_prepare(context, session_id, opts)
    end)
  end

  defp do_prepare(context, session_id, opts) do
    # Phase telemetry: the `prepare` fact spans from here to the provider
    # dispatch; `activation` (when the actor stamped one) ends here.
    opts =
      opts
      |> Keyword.put_new(:round_started_ms, SalixAgent.PhaseTelemetry.now_ms())
      |> Keyword.put_new(:round_operation_started, System.monotonic_time())

    CommaLog.log("round_start", %{agent_id: context.agent_id, session_id: session_id})

    result =
      with {:ok, context} <-
             ensure_revision(context, session_id, opts)
             |> tag_pre_llm_error(:round_session_read) do
        case {Keyword.get(opts, :runtime_failure_reply, false),
              Keyword.get(opts, :prepared_activation)} do
          {true, prepared} ->
            session = revision_state(context)

            with :ok <-
                   if(is_nil(prepared),
                     do: :ok,
                     else: validate_prepared_activation(context, session_id, prepared)
                   ),
                 {:ok, config} <-
                   round_session_config(
                     context,
                     session,
                     InternalSession.get(session, :platform),
                     opts
                   ) do
              context = Map.put(context, :guard_tool_config, config)
              host = loop_host(context, session_id, %{guard_round: opts})
              {:guard, facts_config(host), host}
            end

          {false, nil} ->
            with {:ok, llm_opts} <- resolved_llm_opts(context, opts),
                 {:ok, context} <-
                   set_status(context, session_id, "active")
                   |> tag_pre_llm_error(:round_status_activation) do
              context
              |> run_one_round(session_id, llm_opts, Keyword.put(opts, :restore_idle, true))
              |> clear_active_status_after_round_error(context, session_id)
            end

          # An activation that is not durable yet (`:speculative`) has no
          # status to restore on failure: the owner settles it once its fence
          # lands.
          {_, prepared} ->
            with :ok <- validate_prepared_activation(context, session_id, prepared) do
              restore? = not Keyword.get(opts, :speculative, false)
              opts = Keyword.put(opts, :restore_idle, restore?)
              result = run_one_round(context, session_id, prepared.llm_opts, opts)

              if restore?,
                do: clear_active_status_after_round_error(result, context, session_id),
                else: result
            end
        end
      end

    case result do
      {:error, _} = error -> finish_round(error, context, session_id, opts)
      prepared -> prepared
    end
  end

  @doc false
  # A prepared round that will not start: its authorization ends, and a round
  # that set the session active restores it.
  def abandon(prep, reason) do
    Task.shutdown(prep.authorization, :brutal_kill)

    {:error, reason}
    |> restore_idle(prep)
    |> finish_round(prep.context, prep.session_id, prep.opts)
  end

  # Every round's log line and operation telemetry, once it dispatched or failed.
  defp finish_round(result, context, session_id, opts) do
    log_round_result(result, context, session_id)

    Salix.Telemetry.emit_operation(
      "salix_agent",
      "round",
      operation_surface(context, opts),
      if(match?({:ok, _, _}, result), do: "ok", else: "error"),
      System.monotonic_time() - (opts[:round_operation_started] || System.monotonic_time())
    )

    result
  end

  defp operation_surface(context, opts) do
    billing = Map.get(context, :billing_context) || Map.get(context, "billing_context") || %{}

    opts[:surface] || Map.get(context, :surface) || Map.get(context, "surface") ||
      Map.get(billing, :surface) || Map.get(billing, "surface") || "system"
  end

  defp clear_active_status_after_round_error({:error, reason} = result, context, session_id) do
    # Restore the durable round boundary here, but leave terminal activity to
    # InternalSessionActor after it consumes the typed reconciliation outcome.
    # A retryable pre-LLM failure still owns live work and must not clear the
    # ActivitySurface before that work durably settles.
    case set_status(context, session_id, "idle") do
      {:ok, _context} ->
        result

      {:error, cleanup_reason} ->
        CommaLog.log("round_status_cleanup_error", %{
          agent_id: context.agent_id,
          session_id: session_id,
          reason: reason,
          cleanup_reason: cleanup_reason
        })

        result
    end
  end

  defp clear_active_status_after_round_error(result, _context, _session_id), do: result

  defp resolved_llm_opts(context, opts) do
    case opts[:resolved_round_config] do
      %{llm_opts: llm_opts} -> {:ok, llm_opts}
      _ -> resolve_llm_opts(context)
    end
  end

  defp resolve_llm_opts(context) do
    with :ok <- SalixAgent.Control.ensure_not_stopped(context.agent_id),
         do: SalixAgent.LlmResolver.resolve_runtime(context.agent_id)
  end

  defp validate_prepared_activation(context, session_id, %{
         session: session,
         session_config: session_config,
         llm_opts: _llm_opts
       })
       when is_map(session_config) and InternalSession.is_session(session) do
    cond do
      InternalSession.agent_id(session) != context.agent_id ->
        {:error, :prepared_activation_agent_mismatch}

      InternalSession.session_id(session) != session_id ->
        {:error, :prepared_activation_session_mismatch}

      InternalSession.status(session) != :active ->
        {:error, :prepared_activation_not_active}

      true ->
        :ok
    end
  end

  defp validate_prepared_activation(_context, _session_id, _prepared),
    do: {:error, :invalid_prepared_activation}

  # Local, zero-I/O abort gate before a provider dispatch: a runtime this
  # node already knows is superseded (ownership cell fenced) must not start
  # a new LLM call. Safety still comes from the durable session-epoch fence;
  # this is the fast local refusal (rollout-concurrent-runner-fencing D3).
  defp before_llm_call_with_ownership(agent_id, meter_ctx) do
    case SalixAgent.OwnershipCell.check(agent_id) do
      {:error, :fenced} -> {:error, :runtime_fenced}
      :ok -> LLMMetering.before_llm_call(meter_ctx)
    end
  end

  defp await_authorization(task, agent_id) do
    case Task.yield(task, :infinity) do
      {:ok, {:error, _} = error} ->
        error

      {:ok, decision} ->
        case SalixAgent.OwnershipCell.check(agent_id) do
          :ok -> decision
          {:error, :fenced} -> {:error, :runtime_fenced}
        end

      {:exit, _} ->
        {:error, :billing_authorization_failed}
    end
  end

  defp run_one_round(context, session_id, llm_opts, opts) do
    with {:ok, session} <-
           round_session(context, session_id, opts)
           |> tag_pre_llm_error(:round_session_read),
         platform <- InternalSession.get(session, :platform),
         {:ok, session_config} <-
           round_session_config(context, session, platform, opts),
         {:ok, context, session} <-
           ensure_session_prompt_snapshot(
             context,
             session_id,
             session_config,
             opts
           ) do
      trace_ctx = new_trace_context()

      meter_ctx =
        llm_meter_context(context, session, session_id, llm_opts, trace_ctx, session_config)

      captured = SystemsObservability.Context.capture()

      authorization =
        Task.Supervisor.async_nolink(SalixAgent.TaskSup, fn ->
          SystemsObservability.Context.run(captured, fn ->
            before_llm_call_with_ownership(context.agent_id, meter_ctx)
          end)
        end)

      # The authorization runs until the round starts or is abandoned.
      prepared =
        run_prepared_round(
          context,
          session_id,
          llm_opts,
          opts,
          session,
          session_config,
          trace_ctx,
          meter_ctx,
          authorization
        )

      with {:error, _} <- prepared, do: Task.shutdown(authorization, :brutal_kill)
      prepared
    end
  end

  defp run_prepared_round(
         context,
         session_id,
         llm_opts,
         opts,
         session,
         session_config,
         trace_ctx,
         meter_ctx,
         authorization
       ) do
    with {:ok, session, activation_delta} <-
           context_provider_activation(context, session_id, session, session_config),
         {:ok, view} <- InternalSession.query(session, :round_view) do
      platform = InternalSession.get(session, :platform)

      %{
        "source_ids" => source_message_ids,
        "source_message_id" => source_message_id,
        "trusted_origin" => trusted_origin,
        "scope" => visible_reply_scope,
        "phase" => visible_reply_phase,
        "guard" => visible_reply_guard,
        "repair" => repair_request?
      } = view

      session_config =
        SalixAgent.PlatformCapabilities.scope_config(session_config, %{
          agent_id: context.agent_id,
          session_id: session_id,
          role: session_config.role,
          source_message_id: source_message_id,
          source_message_ids: source_message_ids,
          reply_source_scope: SalixAgent.TerminalReply.source_scope(session),
          trusted_origin: trusted_origin
        })

      context =
        context
        |> Map.put(:visible_reply_phase, visible_reply_phase)
        |> Map.put(:visible_reply_scope, visible_reply_scope)
        |> Map.put(
          :guard_tool_config,
          Map.take(session_config, [
            :role,
            :tenant_id,
            :group_id,
            :tool_disclosure,
            :skill_projection_revision,
            :plugin_projection,
            :plugin_projection_revision
          ])
        )

      specs = session_config.tool_specs

      # Activity v2 cannot mint or infer its own response identity. The actor
      # durably installs this exact scope before Round starts, so the first
      # Thinking frame and every later frame share the visible-reply identity.
      unless context[:persistence_gate],
        do: ActivityEvent.thinking(context.agent_id, session_id, nil, visible_reply_scope)

      # A streaming draft reaches the conversation's audience while the model is
      # still writing, which is necessarily before it has finished declaring
      # what the reply drew on — so nothing can have authorized it yet, and the
      # dispatch check that refuses the completed send (§9) arrives after the
      # text has been seen. Clearing a draft does not unsee it, so under
      # `enforce` the draft waits for the decision.
      ifc_withholds_draft? =
        not SalixAgent.IFC.draft_before_decision?(
          SalixAgent.IFC.mode_for(session_config.tenant_id, session_config.group_id)
        )

      inspector_withholds_draft? =
        SalixAgent.InspectorPolicy.restricted?(%{tool_disclosure: session_config.tool_disclosure})

      # Token deltas fan out via the Notifier while the round runs.
      # Best-effort: Notifier.notify rescues, so a bad consumer never breaks a round.
      on_delta = fn text ->
        record_first_delta(text)

        if not repair_request? and persistence_ready?(context) do
          SalixAgent.Notifier.notify(context.agent_id, {:delta, session_id, text})
        end
      end

      # Raw tool JSON never becomes public. The scoped projector may decode only
      # the semantic plain-text prefix of one exact internal send to this source
      # conversation; every other fragment remains private provider data.
      on_tool_delta = fn fragment ->
        record_first_delta(fragment[:fragment])

        unless repair_request? or not is_map(visible_reply_scope) or ifc_withholds_draft? or
                 inspector_withholds_draft? do
          if persistence_ready?(context) do
            stream =
              Process.get(@send_message_draft_stream_key, SendMessageDraftStream.new())

            {stream, action} =
              SendMessageDraftStream.consume(
                stream,
                fragment,
                visible_reply_scope
              )

            Process.put(@send_message_draft_stream_key, stream)

            case action do
              {:publish, cumulative_text} ->
                publish_visible_reply_text(
                  context.agent_id,
                  session_id,
                  visible_reply_scope,
                  cumulative_text
                )

              :noop ->
                :ok
            end
          end
        end
      end

      # Only provider-designated public summaries may enter ActivityEvent.
      # Anthropic thinking and chat-completions reasoning content are private
      # raw reasoning: they are neither accumulated nor copied into a public
      # payload. The generic Thinking event emitted at round start is enough to
      # represent activity while such private reasoning streams.
      Process.delete(@reasoning_activity_key)

      on_reasoning_delta = fn
        %ReasoningDelta{visibility: :public_summary, text: text}
        when is_binary(text) and text != "" ->
          record_first_delta(text)

          if not repair_request? and persistence_ready?(context) do
            # last_emit nil = nothing emitted yet (monotonic time can be
            # negative, so no sentinel arithmetic).
            {tail, last_emit} = Process.get(@reasoning_activity_key, {"", nil})

            tail =
              String.slice(
                tail <> text,
                -@reasoning_tail_max_chars,
                @reasoning_tail_max_chars
              )

            now = System.monotonic_time(:millisecond)

            if last_emit == nil or now - last_emit >= @reasoning_activity_throttle_ms do
              ActivityEvent.thinking(
                context.agent_id,
                session_id,
                tail,
                visible_reply_scope
              )

              Process.put(@reasoning_activity_key, {tail, now})
            else
              Process.put(@reasoning_activity_key, {tail, last_emit})
            end
          end

        %ReasoningDelta{visibility: :private_reasoning, text: text} ->
          record_first_delta(text)

        _unknown_or_legacy_payload ->
          :ok
      end

      stream_opts = stream_llm_opts(llm_opts, on_tool_delta, on_reasoning_delta)

      # What `stream_opts` cannot say. Provider config is resolved per template
      # (`LlmResolver.resolve_runtime/1`: model, protocol, key, base url) and
      # names no agent, session or round, while the round's own identity lives
      # in `meter_ctx` below and never reached the dispatch seam. The archive
      # therefore recorded every round with four empty ids on one shared
      # `agent::inbox` stream until this was passed explicitly.
      archive_identity = [
        agent_id: context.agent_id,
        session_id: session_id,
        round_id: trace_ctx.round_id
      ]

      {config, image_ctx, protocol} =
        request_config(
          context,
          session_id,
          session,
          session_config,
          activation_delta,
          stream_opts,
          archive_identity
        )

      {:request, config,
       %{
         context: context,
         session_id: session_id,
         llm_opts: llm_opts,
         opts: opts,
         session: session,
         session_config: session_config,
         trace_ctx: trace_ctx,
         meter_ctx: meter_ctx,
         authorization: authorization,
         activation_delta: activation_delta,
         source_message_ids: source_message_ids,
         visible_reply_phase: visible_reply_phase,
         visible_reply_guard: visible_reply_guard,
         visible_reply_scope: visible_reply_scope,
         specs: specs,
         platform: platform,
         on_delta: on_delta,
         stream_opts: stream_opts,
         archive_identity: archive_identity,
         image_ctx: image_ctx,
         protocol: protocol
       }}
    else
      {:error, _} = err -> err
    end
  end

  @doc false
  # The second half of a round: the provider call for the request and facts
  # the kernel built, in a dependency job. It answers `{:llm_pending, pending}`;
  # the owner receives the response.
  def start(prep, request, facts) do
    %{
      context: context,
      session_id: session_id,
      llm_opts: llm_opts,
      opts: opts,
      session: session,
      session_config: session_config,
      meter_ctx: meter_ctx,
      authorization: authorization,
      activation_delta: activation_delta,
      source_message_ids: source_message_ids,
      visible_reply_phase: visible_reply_phase,
      visible_reply_guard: visible_reply_guard,
      visible_reply_scope: visible_reply_scope,
      specs: specs,
      platform: platform,
      on_delta: on_delta,
      stream_opts: stream_opts,
      archive_identity: archive_identity
    } = prep

    request_input =
      if prep.protocol == :neutral,
        do: request,
        else: {:encoded_provider_request, prep.protocol, request}

    trace_ctx = request_trace_ctx(prep.trace_ctx, facts)

    try do
      provider_request = fn ->
        # Archive boundaries 2 and 3 are NOT emitted here: they live in the
        # `SalixAgent.LLM` dispatch seam, so compaction, title generation
        # and the eval judge are covered by the same code rather than by
        # remembering to instrument each call site. What the seam cannot
        # derive on its own is passed to it — see `archive_identity`.
        try do
          case SalixAgent.OwnershipCell.check(context.agent_id) do
            :ok ->
              response =
                LLM.complete_stream(request_input, specs, on_delta, stream_opts, archive_identity)

              # Record provider completion before waiting on speculative persistence.
              case Process.get(@llm_meter_tracker_key) do
                %{} = tracker ->
                  Process.put(
                    @llm_meter_tracker_key,
                    Map.put(tracker, :provider_completed_at, System.monotonic_time(:millisecond))
                  )

                _ ->
                  :ok
              end

              response

            {:error, :fenced} ->
              raise "runtime fenced before provider dispatch"
          end
        after
          _ = persistence_ready?(context)
        end
      end

      CommaLog.log("llm_request", %{
        agent_id: context.agent_id,
        session_id: session_id,
        platform: platform,
        tool_count: length(specs),
        model: llm_opt(llm_opts, :model),
        protocol: llm_opt(llm_opts, :protocol),
        base_url: llm_opt(llm_opts, :base_url)
      })

      # Defensive stale-response guard. Normal inbound input is queued and
      # materialized by activation before Round starts; if a committed user
      # message appears past this snapshot, some exceptional path wrote stable
      # input during the provider call and the response did not see it.
      id_snapshot = session_next_message_id(session)

      # The runtime's own identity for the input this round answers, shared
      # by every round of the activation chain; phase facts carry it so a
      # reader can group a chain exactly.
      activation_key = InternalSession.current_activation_key(session, source_message_ids)

      case session_config[:miniskill_timing] do
        %{started_at_ms: started, ended_at_ms: ended} ->
          SalixAgent.PhaseTelemetry.emit(:miniskill, meter_ctx, activation_key, started, ended)

        _ ->
          :ok
      end

      SalixAgent.PhaseTelemetry.emit_delivery_wait(
        meter_ctx,
        opts,
        activation_key,
        SalixAgent.PhaseTelemetry.earliest_delivered_at_ms(session, source_message_ids)
      )

      case await_authorization(authorization, context.agent_id) do
        {:error, :runtime_fenced} ->
          {:error, :fenced}

        {:error, {:billing_unavailable, _decision} = reason} ->
          {:error, reason}

        {:error, reason} ->
          {:error, {:billing_unavailable, fee_control_error_decision(meter_ctx, reason)}}

        decision ->
          meter_ctx = LLMMetering.capture_decision(meter_ctx, decision)

          stream_progress = SalixAgent.StreamProgress.new()

          pending = %{
            session_id: session_id,
            facts: facts,
            id_snapshot: id_snapshot,
            next_queue_id_snapshot: InternalSession.get(session, :next_queue_id) || 1,
            llm_opts: llm_opts,
            trace_ctx: trace_ctx,
            meter_ctx: meter_ctx,
            role: session_config.role,
            tool_disclosure: session_config.tool_disclosure,
            activation_delta: activation_delta,
            source_message_ids: source_message_ids,
            tenant_id: session_config.tenant_id,
            group_id: session_config.group_id,
            skill_projection_revision: session_config.skill_projection_revision,
            plugin_projection: session_config.plugin_projection,
            plugin_projection_revision: session_config.plugin_projection_revision,
            visible_reply_phase: visible_reply_phase,
            visible_reply_guard: visible_reply_guard,
            visible_reply_scope: visible_reply_scope,
            phase_activation_key: activation_key,
            stream_progress: stream_progress
          }

          observability_context = SystemsObservability.Context.capture()

          dependency = fn ->
            SystemsObservability.Context.run(observability_context, fn ->
              # The job writes the stream's progress here; the owner reads it
              # from `pending` if it has to kill the job at the deadline.
              SalixAgent.StreamProgress.install(stream_progress)

              SalixAgent.RouterRequestMonitor.started(
                context.agent_id,
                session_id,
                source_message_ids
              )

              SalixAgent.PhaseTelemetry.emit_pre_dispatch(meter_ctx, opts, activation_key)
              started = System.monotonic_time(:millisecond)

              {response, meter_meta} =
                metered_provider_call(meter_ctx, stream_opts, started, provider_request)

              {response, meter_meta.execution_timing["duration_ms"], meter_meta}
            end)
          end

          case DependencyJob.start(:llm, session_config.tenant_id, dependency) do
            {:ok, job} ->
              pending =
                Map.merge(pending, %{dependency_job: job, ref: job.ref, pid: job.pid})

              {:ok, context, {:llm_pending, pending}}

            {:error, :dependency_saturated} ->
              {:error, {:dependency_saturated, :llm}}

            {:error, reason} ->
              {:error, reason}
          end
      end
    after
      Task.shutdown(authorization, :brutal_kill)
    end
    |> restore_idle(prep)
    |> finish_round(context, session_id, opts)
  end

  defp restore_idle({:error, _} = error, %{opts: opts} = prep) do
    if opts[:restore_idle],
      do: clear_active_status_after_round_error(error, prep.context, prep.session_id),
      else: error
  end

  defp restore_idle(result, _prep), do: result

  # The configuration of the kernel's `round_request`: the request's provider
  # configuration, delta, and disclosure, and the facts its response carries.
  # The kernel builds the request: the stored prompt snapshot, the compaction
  # context, the activation delta, and the request generation. Stored image
  # refs inline as native image input through `request_reader/1`; other
  # attachments are announced as notes that the agent reads with its tools.
  defp request_config(
         context,
         session_id,
         session,
         session_config,
         activation_delta,
         stream_opts,
         archive_identity
       ) do
    {protocol, cfg, images?} = LLM.request_config(stream_opts, archive_identity)

    image_ctx = %{
      agent_id: context.agent_id,
      session_id: session_id,
      tenant_id: session_config.tenant_id,
      group_id: session_config.group_id,
      model_supports_images: images?,
      async_result_resolver: fn seq ->
        resolve_async_result_for_request(context.agent_id, session_id, session, seq)
      end
    }

    config = %{
      "role" => session_config.role || "worker",
      "canonical_router" => SalixAgent.TerminalReply.canonical_router?(session),
      "restricted" =>
        SalixAgent.InspectorPolicy.restricted?(%{tool_disclosure: session_config.tool_disclosure}),
      "guard_config" => true,
      "nonce" => System.unique_integer([:positive]),
      "delta" => activation_delta,
      "available" => false,
      "disclosure" => request_disclosure(session_config.tool_disclosure),
      "protocol" => protocol,
      "cfg" => cfg,
      "tools" => session_config.tool_specs,
      "mode" => "stream"
    }

    {config, image_ctx, protocol}
  end

  # The kernel reads only the tool names of the disclosure, for the
  # current-source interaction reminder. The full catalog is hundreds of
  # kilobytes, and the round request carries it into the kernel on each step.
  defp request_disclosure(%{"tools" => tools}) when is_list(tools) do
    %{
      "tools" =>
        Enum.map(tools, fn
          %{} = tool -> Map.take(tool, ["name"])
          other -> other
        end)
    }
  end

  defp request_disclosure(disclosure), do: disclosure

  @doc false
  # The reader the kernel's `round_request` asks for images and results.
  def request_reader(%{image_ctx: image_ctx}), do: SalixAgent.ImageRefs.reader(image_ctx)

  # The round's trace: its ids, and the request generation the kernel
  # captured with the request.
  defp request_trace_ctx(trace_ctx, facts), do: Map.merge(trace_ctx, facts["trace"] || %{})

  defp round_session(context, _session_id, opts) do
    case Keyword.get(opts, :prepared_activation) do
      %{session: session} when InternalSession.is_session(session) ->
        {:ok, revision_state(context)}

      nil ->
        {:ok, revision_state(context)}

      _invalid ->
        {:error, :invalid_prepared_activation}
    end
  end

  defp round_session_config(context, session, platform, opts) do
    SystemsObservability.Trace.with_span(
      :salix_round_config,
      %{component: "salix_agent", surface: SystemsObservability.Context.current_surface()},
      fn -> traced_round_session_config(context, session, platform, opts) end
    )
  end

  defp traced_round_session_config(context, session, platform, opts) do
    case Keyword.get(opts, :prepared_activation) do
      %{session_config: session_config} when is_map(session_config) ->
        {:ok, session_config}

      nil ->
        case opts[:resolved_round_config] do
          %{session_config: config} ->
            {:ok, config}

          _ ->
            AgentActor.runtime_session_config(context.agent_id, %{
              platform: platform,
              session_context: session
            })
        end

      _invalid ->
        {:error, :invalid_prepared_activation}
    end
  end

  defp resolve_async_result_for_request(agent_id, session_id, session, seq)
       when is_integer(seq) and seq > 0 do
    case InternalSession.query(session, :async_result_by_seq, seq) do
      %{} = record -> {:ok, record}
      nil -> InternalSessionStore.fetch_archived_record(agent_id, session_id, session, seq)
    end
  end

  defp resolve_async_result_for_request(_agent_id, _session_id, _session, _seq),
    do: {:error, :not_found}

  defp ensure_session_prompt_snapshot(
         context,
         session_id,
         session_config,
         opts
       ) do
    case Keyword.get(opts, :prepared_activation) do
      %{session: session} when InternalSession.is_session(session) ->
        {:ok, context, session}

      nil ->
        ensure_session_prompt_snapshot_from_store(context, session_id, session_config)

      _invalid ->
        {:error, :invalid_prepared_activation}
    end
  end

  defp ensure_session_prompt_snapshot_from_store(context, session_id, session_config) do
    session = revision_state(context)

    case prepare_prompt_snapshot(session, session_config) do
      {[], _effective_prompt} ->
        {:ok, context, session}

      {events, _effective_prompt} ->
        with {:ok, context} <- commit_events(context, session_id, events) do
          {:ok, context, revision_state(context)}
        end
    end
  end

  @doc false
  def prepare_prompt_snapshot(session, session_config) when InternalSession.is_session(session),
    do: InternalSession.prepare_prompt_snapshot(session, session_config.system_prompt)

  defp context_provider_activation(context, session_id, session, session_config) do
    SystemsObservability.Trace.with_span(
      :salix_round_context_providers,
      %{component: "salix_agent", surface: SystemsObservability.Context.current_surface()},
      fn -> traced_context_provider_activation(context, session_id, session, session_config) end
    )
  end

  defp traced_context_provider_activation(context, session_id, session, session_config) do
    base = ContextProviders.prepare_activation_delta(session, session_config)
    knowledge = ProjectKnowledgeContext.prepare(context.agent_id, session_id, session)

    {:ok, session, merge_activation_delta(base, knowledge)}
  end

  defp merge_activation_delta(:none, :none), do: nil

  defp merge_activation_delta({:delta, delta}, :none), do: delta

  defp merge_activation_delta(:none, {:messages, messages}), do: %{messages: messages}

  defp merge_activation_delta({:delta, delta}, {:messages, messages}) do
    Map.update(delta, :messages, messages, &(&1 ++ messages))
  end

  @doc false
  # The loop host of a model response, after the checks a response needs
  # before the kernel reads it: the session's revision and local ownership.
  def response_host(context, pending, response, duration_ms, meter_meta \\ %{})

  def response_host(%SalixStore.Agent.Owned{}, _pending, _response, _duration_ms, _meter_meta),
    do: {:error, :agent_lease_not_session_runtime_context}

  def response_host(context, pending, response, duration_ms, meter_meta) do
    session_id = pending.session_id

    context =
      context
      |> Map.put(:visible_reply_phase, pending[:visible_reply_phase] || :clean)
      |> Map.put(:visible_reply_scope, pending[:visible_reply_scope])

    with :ok <- require_session_context(context, session_id),
         {:ok, context} <- require_revision(context, session_id) do
      log_llm_response(context, session_id, response, duration_ms)

      meter_ctx =
        SalixAgent.PhaseTelemetry.execution_meter_context(pending[:meter_ctx] || %{}, meter_meta)

      SalixAgent.PhaseTelemetry.emit(
        :response_pickup,
        meter_ctx,
        pending[:phase_activation_key],
        SalixAgent.PhaseTelemetry.response_at_ms(meter_ctx, duration_ms),
        meter_meta[:actor_received_at_ms] || SalixAgent.PhaseTelemetry.now_ms()
      )

      # Phase telemetry: response handling is measured from the provider's
      # own completion instant, so the actor mailbox wait is inside it.
      context =
        context
        |> Map.put(
          :phase_response_at_ms,
          SalixAgent.PhaseTelemetry.response_at_ms(meter_ctx, duration_ms)
        )
        |> Map.put(:phase_activation_key, pending[:phase_activation_key])

      # The provider call may have run for minutes: re-check local ownership
      # before interpreting the response or executing any tool. The response
      # DID arrive and was billed by the provider, so it is metered/charged
      # even when the round is then abandoned as fenced.
      with :ok <- OwnershipCell.check(context.agent_id),
           :ok <- SalixAgent.Control.ensure_not_stopped(context.agent_id) do
        {:ok, respond_host(context, pending, response, duration_ms, meter_meta, meter_ctx)}
      else
        {:error, reason} ->
          _ =
            LLMMetering.after_llm_call(
              llm_meter_result(meter_ctx, response, duration_ms, "fenced", meter_meta)
            )

          {:error, reason}
      end
    end
  end

  @guard_config_keys [
    :role,
    :tenant_id,
    :group_id,
    :tool_disclosure,
    :skill_projection_revision,
    :plugin_projection,
    :plugin_projection_revision
  ]

  defp respond_host(context, pending, response, duration_ms, meter_meta, meter_ctx) do
    loop_host(context, pending.session_id, %{
      llm_opts: pending.llm_opts,
      trace_ctx: Map.put(pending.trace_ctx, :execution_timing, meter_meta[:execution_timing]),
      meter_ctx: meter_ctx,
      activation_delta: pending[:activation_delta],
      source_message_ids: pending[:source_message_ids] || [],
      guard_tool_config:
        pending
        |> Map.take(@guard_config_keys)
        |> Map.put(:role, pending[:role] || "worker")
        |> Map.put(:tool_disclosure, pending[:tool_disclosure] || %{}),
      response: response,
      duration_ms: duration_ms,
      meter_meta: meter_meta
    })
  end

  @doc false
  # The configuration and loop host of a request that did not start: the
  # context-overflow failure after a recovery without progress.
  def failure_config(context, session_id) do
    host = loop_host(context, session_id, %{})
    {facts_config(host), host}
  end

  defp loop_host(context, session_id, fields) do
    Map.merge(
      %{
        context: context,
        session_id: session_id,
        llm_opts: nil,
        trace_ctx: nil,
        meter_ctx: %{},
        activation_delta: nil,
        source_message_ids: InternalSession.query(loop_state(context), :current_source_ids),
        guard_tool_config: context[:guard_tool_config],
        billing_context: %{},
        async_pending: [],
        speculative: nil,
        workspace: nil
      },
      fields
    )
  end

  # The round configuration whose facts the kernel builds (`round_facts`).
  defp facts_config(host) do
    session = loop_state(host.context)
    config = host.guard_tool_config || %{}

    %{
      "vphase" => visible_phase(host),
      "source_ids" => host.source_message_ids,
      "restricted" =>
        SalixAgent.InspectorPolicy.restricted?(%{tool_disclosure: config[:tool_disclosure]}),
      "role" => config[:role],
      "canonical_router" => SalixAgent.TerminalReply.canonical_router?(session),
      "guard_config" => is_map(host.guard_tool_config)
    }
  end

  defp round_facts(host, id_snapshot, guard) do
    config = Map.put(facts_config(host), "nonce", System.unique_integer([:positive]))
    InternalSession.query(loop_state(host.context), :round_facts, {config, id_snapshot, guard})
  end

  # A session that does not exist yet is born by its first commit; the kernel
  # decides over the empty session until then.
  defp loop_state(%{revision: %Revision{state: state}}), do: state
  defp loop_state(context), do: InternalSession.new(context.agent_id, context.session_id)

  defp visible_phase(host), do: host.context[:visible_reply_phase] || :clean
  defp visible_scope(host), do: host.context[:visible_reply_scope]

  # ---- the effects of a round ----
  #
  # The kernel's session driver (`session_step`) sequences rounds and the
  # agent loop (`loop_step`); the owning actor performs each effect.
  # `effect/4` answers the effects of a round's loop. A loop step with a
  # commit is one transaction: a storage conflict rebuilds the step on the
  # fresh session.

  @doc false
  # One effect of a round's loop: `{:answer, value, host, driver}`, or
  # `{:rerouted, host, state, driver, effect}` when a rebuilt commit took
  # another branch.
  def effect(host, state, driver, effect) do
    case effect do
      {:notify, _, _} = notice ->
        {:answer, :ok, notify(host, notice), driver}

      {:commit, events, opts, mode} ->
        case loop_commit(host, state, driver, events, opts, mode) do
          {:ok, host, driver} ->
            {:answer, :ok, host, driver}

          {:rerouted, host, state, driver, effect} ->
            {:rerouted, host, state, driver, effect}

          {:error, _} = error ->
            if is_map(mode) and mode["cancel_draft_on_error"], do: cancel_visible_reply(host)
            {:answer, error, host, driver}
        end

      {:build_record, spec} ->
        {host, record} = build_record(host, spec)
        {:answer, {:record, record}, host, driver}

      {:run_tools, calls, flags} ->
        {host, results} = run_tools(host, calls, flags)
        {:answer, {:tools_done, results, host.async_pending != []}, host, driver}

      {:store_results, pending, results} ->
        host = Map.put(host, :tool_commit_started_ms, SalixAgent.PhaseTelemetry.now_ms())

        case store_results(host, pending, results) do
          {:ok, host, events, hwm, base, stored} ->
            {:answer, {:results_stored, events, hwm, base, stored}, host, driver}

          error ->
            cancel_visible_reply(host)
            {:answer, error, host, driver}
        end

      {:commit_planned_results, pending, results} ->
        host = Map.put(host, :tool_commit_started_ms, SalixAgent.PhaseTelemetry.now_ms())

        case commit_planned_tool_results(host, pending, results) do
          {:ok, context} ->
            {:answer, :continue, %{host | context: context}, driver}

          error ->
            cancel_visible_reply(host)
            {:answer, error, host, driver}
        end

      # The round's facts. A notice or failure round takes its request
      # generation from them.
      {:round, facts} ->
        host =
          if host.trace_ctx,
            do: host,
            else: %{host | trace_ctx: request_trace_ctx(new_trace_context(), facts)}

        {:answer, :ok, host, driver}

      {:fact, :canonical_router} ->
        {:answer, SalixAgent.TerminalReply.canonical_router?(state), host, driver}
    end
  end

  @doc false
  # The result of a round that stopped with `outcome`.
  def round_result(host, outcome) do
    result =
      case outcome do
        :async_tools_started -> {:ok, host.context, {:async_tools_started, host.async_pending}}
        :committed -> {:ok, host.context}
        {:error, reason} -> {:error, reason}
        outcome -> {:ok, host.context, outcome}
      end

    guard_finished(host, result)
  end

  @doc false
  # A round whose loop failed. A guard round ends here.
  def round_failed(host, reason), do: guard_finished(host, {:error, reason})

  # A guard round runs no model call, so its outcome is its round's end.
  defp guard_finished(%{guard_round: opts} = host, result),
    do: finish_round(result, host.context, host.session_id, opts)

  defp guard_finished(_host, result), do: result

  defp loop_commit(host, _state, driver, events, opts, %{"speculative" => true}) do
    %{agent_id: agent_id, revision: revision} = host.context

    with {:ok, written} <- InternalSessionStore.write_revision(revision, events, opts),
         {:ok, task} <-
           InternalSessionStore.start_durable_fence(agent_id, host.session_id, written) do
      # The canonical batch passed authorization and schema checks. Resource
      # admission still runs at the Tools seam. Results wait for this revision.
      executed =
        try do
          execute_internal_tool_calls(host.calls, host.ctx)
        catch
          kind, reason ->
            InternalSessionStore.await_durable_fence(task)
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      case InternalSessionStore.await_durable_fence(task) do
        {:ok, committed} ->
          host = %{host | context: Map.put(host.context, :revision, committed)}
          {:ok, %{host | speculative: executed}, driver}

        error ->
          {_results, pending} = executed
          SalixAgent.Tools.cancel_speculative_reads(agent_id, pending)
          error
      end
    end
  end

  # A commit that meets a newer session asks the driver to rebuild the loop
  # step against it.
  defp loop_commit(host, _state, driver, events, opts, mode) do
    host = Map.put(host, :commit_started_ms, SalixAgent.PhaseTelemetry.now_ms())
    %{agent_id: agent_id} = host.context

    case SessionDriver.commit(
           agent_id,
           host.session_id,
           host.context[:revision],
           driver,
           {events, opts, mode}
         ) do
      {:ok, revision, driver} ->
        {:ok, %{host | context: Map.put(host.context, :revision, revision)}, driver}

      {:rerouted, revision, driver, effect} ->
        host = %{host | context: Map.put(host.context, :revision, revision)}
        {:rerouted, host, revision.state, driver, effect}

      {:error, _} = error ->
        error
    end
  end

  defp notify(host, {:notify, kind, data}) do
    %{context: context, session_id: session_id} = host
    agent_id = context.agent_id

    case {kind, data} do
      {:meter, status} ->
        LLMMetering.after_llm_call(
          llm_meter_result(
            host.meter_ctx,
            host.response,
            host.duration_ms,
            status,
            host.meter_meta
          )
        )

      {:steered, discarded} ->
        CommaLog.log("round_steered", %{
          agent_id: agent_id,
          session_id: session_id,
          discarded: discarded
        })

      {:draft, :cancel} ->
        cancel_visible_reply(host)

      {:draft, {:cancel_unless_source_send, calls}} ->
        unless SendMessageDraftStream.exact_source_send?(
                 calls,
                 visible_scope(host),
                 visible_phase(host)
               ),
               do: cancel_visible_reply(host)

      {:report, :provider_reply_obligation_rejection} ->
        Salix.Telemetry.emit_operation(
          "salix_agent",
          "provider_reply_obligation_rejection",
          operation_surface(context, []),
          "rejected",
          0
        )

      {:report, status} ->
        trace_ctx = if status == "llm_failed", do: nil, else: host.trace_ctx

        emit_agent_run(
          context,
          loop_state(context),
          session_id,
          trace_ctx,
          host.meter_ctx,
          status
        )

      {:activity, :idle} ->
        ActivityEvent.idle(agent_id, session_id, visible_scope(host))

      {:activity, :idle_unscoped} ->
        ActivityEvent.idle(agent_id, session_id)

      {:activity, :llm_failed} ->
        ActivityEvent.llm_failed(agent_id, session_id, visible_scope(host))

      {:activity, {:tool_calls_started, calls}} ->
        ActivityEvent.tool_calls_started(
          agent_id,
          session_id,
          VisibleReplyPolicy.sanitize_activity_calls(calls, visible_phase(host)),
          visible_scope(host)
        )

      {:telemetry, phase} ->
        started =
          case phase do
            :tool_commit -> host[:tool_commit_started_ms]
            :boundary -> host[:commit_started_ms]
            _ -> context[:phase_response_at_ms]
          end

        SalixAgent.PhaseTelemetry.emit(
          phase,
          host.meter_ctx,
          context[:phase_activation_key],
          started
        )

      {:timers, {events, true}} ->
        register_read_timers(agent_id, events)

      {:timers, {events, false}} ->
        register_committed_timers(agent_id, events)

      {:observations, results} ->
        Tools.emit_deferred_tool_observations(results)

      {:guard_parked, {guard, detail}} ->
        log_guard_parked(host, guard, detail)

      {:llm_parked, {streak, meta}} ->
        Logger.error(
          "internal session #{agent_id}/#{session_id} llm failed #{streak} consecutive " <>
            "times at the same transcript position; parking until new session input " <>
            "(category=#{SalixAgent.LLM.Error.category(meta)})"
        )

        CommaLog.log("llm_round_parked", %{
          agent_id: agent_id,
          session_id: session_id,
          consecutive_failures: streak,
          error_category: SalixAgent.LLM.Error.category(meta)
        })
    end

    host
  end

  defp log_guard_parked(host, "runaway_guard_parked", streak) do
    Logger.error(
      "internal session #{host.context.agent_id}/#{host.session_id} produced #{streak} consecutive " <>
        "non-settling assistant rounds for the same unacked input; " <>
        "retiring this execution and its reply obligations as failed"
    )

    CommaLog.log("session_runaway_guard_parked", %{
      agent_id: host.context.agent_id,
      session_id: host.session_id,
      consecutive_unsettled_rounds: streak
    })
  end

  defp log_guard_parked(host, "repeated_tool_result_parked", {streak, tool}) do
    Logger.error(
      "internal session #{host.context.agent_id}/#{host.session_id} received #{streak} identical " <>
        "results in a row from #{tool}; ending this execution with one failure-notification attempt"
    )

    CommaLog.log("session_repeated_tool_result_parked", %{
      agent_id: host.context.agent_id,
      session_id: host.session_id,
      tool_name: tool,
      consecutive_repeated_tool_results: streak
    })
  end

  defp log_guard_parked(host, "input_round_budget_parked", rounds) do
    Logger.error(
      "internal session #{host.context.agent_id}/#{host.session_id} used #{rounds} model rounds on " <>
        "one input without fresh input; ending this execution with one failure-notification attempt"
    )

    CommaLog.log("session_input_round_budget_parked", %{
      agent_id: host.context.agent_id,
      session_id: host.session_id,
      rounds_since_fresh_input: rounds,
      input_round_cap: SalixAgent.InternalSession.State.input_round_cap()
    })
  end

  # The transcript record for a provider output, positioned at the session's
  # next message id. Provider formatting and tool contexts stay host-side.
  # The kernel builds the record (`LoopHost.loopRecord`): the activation's
  # runtime messages, the assistant event at the next id after them, and for a
  # tool turn the intent and its terminal-reply scope. The host adds its facts
  # (trace, model, IFC label) and plans admission and speculation.
  defp build_record(host, spec) do
    session = loop_state(host.context)

    case spec["mode"] do
      "final" ->
        %{"record" => record} =
          InternalSession.query(session, :loop_record, {spec, record_facts(host, nil)})

        {host, record}

      "tools" ->
        ctx = tool_context(host, session, spec["decision_outcome"])
        calls = spec["calls"]

        # What the model wrote this round is labelled by what it says it drew
        # on: the join of the sources declared on this round's effects (§3.3,
        # last row). A round that declares nothing joins the whole context.
        facts =
          host
          |> record_facts(SalixAgent.IFC.Check.round_label(calls, ctx))
          |> Map.merge(%{
            "role" => ctx[:role],
            "canonical_router" =>
              ctx[:role] == "router" and SalixAgent.TerminalReply.canonical_router?(session),
            "source_ids" => ctx.source_message_ids
          })

        %{"record" => record, "scope" => scope} =
          InternalSession.query(session, :loop_record, {spec, facts})

        aid = record["aid"]

        ctx =
          ctx
          |> Map.put(:terminal_reply_context, scope)
          |> Map.put(:assistant_message_id, aid)

        {admission, ctx} =
          case plan_tool_admission(session, record["intent"], calls, ctx, aid) do
            {:ok, events, hwm} ->
              {%{"events" => events, "hwm" => hwm}, Map.put(ctx, :planned_async_intent, true)}

            :fallback ->
              {nil, ctx}
          end

        # A small batch of replayable reads runs while its intent commits.
        speculative =
          admission != nil and length(calls) <= 4 and
            Enum.all?(
              SalixAgent.Tools.prepare_for_dispatch(calls, ctx),
              &SalixAgent.Tools.replayable_read?(tool_name(&1))
            )

        host =
          host
          |> Map.merge(%{ctx: ctx, calls: calls, billing_context: ctx.billing_context})

        {host, %{record | "admission" => admission, "speculative" => speculative}}
    end
  end

  # The host's facts for a record: the activation's runtime payloads, the trace
  # and model of this request, the provider states it adopted, and the label.
  defp record_facts(host, ifc_label) do
    delta = host.activation_delta

    %{
      "leading" => if(is_map(delta), do: delta.messages, else: []),
      "trace" => host.trace_ctx,
      "model" => llm_opt(host.llm_opts, :model),
      "provider_states" => ContextProviders.adopted_provider_state(delta),
      "ifc_label" => ifc_label
    }
  end

  defp tool_context(host, session, terminal_decision_outcome) do
    config = host.guard_tool_config
    source_message_ids = host.source_message_ids
    {source_message_id, trusted_origin} = current_turn_source(session, source_message_ids)
    ifc_mode = SalixAgent.IFC.mode_for(config[:tenant_id], config[:group_id])

    %{
      model_supports_images: llm_opt(host.llm_opts, :supports_images) == true,
      agent_id: host.context.agent_id,
      session_id: host.session_id,
      # Keep the singular current wakeable authority for provider calls while
      # carrying the full activation provenance set.
      source_message_id: source_message_id,
      source_message_ids: source_message_ids,
      reply_source_scope: SalixAgent.TerminalReply.source_scope(session),
      trusted_origin: trusted_origin,
      trusted_origins: current_turn_trusted_origins(session, source_message_ids),
      triage_scopes:
        SalixAgent.IFC.Context.organization_scopes(
          session,
          source_message_ids,
          "triage_investigation"
        ),
      organization_scopes:
        SalixAgent.IFC.Context.organization_scopes(session, source_message_ids),
      # The labelled view of this session and this activation. Nothing is
      # filtered out of the prompt by it; it exists so an effect can be checked
      # against the sources it declares (§7).
      ifc_mode: ifc_mode,
      ifc:
        ifc_mode != :off &&
          SalixAgent.IFC.Context.build(session,
            source_message_id: source_message_id,
            source_message_ids: source_message_ids,
            trusted_origin: trusted_origin
          ),
      tenant_id: config[:tenant_id],
      group_id: config[:group_id],
      skill_projection_revision: config[:skill_projection_revision],
      plugin_projection: config[:plugin_projection],
      plugin_projection_revision: config[:plugin_projection_revision],
      role: config[:role],
      runtime_kind: :internal,
      tool_disclosure: config[:tool_disclosure],
      llm_tool_envelope: true,
      terminal_decision_outcome: terminal_decision_outcome,
      trace_ctx: host.trace_ctx,
      billing_context: session_billing_context(session),
      defer_tool_observations: true,
      visible_reply_phase: visible_phase(host),
      visible_reply_scope: visible_scope(host)
    }
  end

  defp run_tools(host, calls, %{"mode" => "model_turn"} = flags) do
    started = SalixAgent.PhaseTelemetry.now_ms()
    {results, pending} = host.speculative || execute_internal_tool_calls(calls, host.ctx)

    SalixAgent.PhaseTelemetry.emit(
      :tool_batch,
      host.meter_ctx,
      host.context[:phase_activation_key],
      started
    )

    pending = retain_visible_reply_until_async_terminal(pending, calls, host.context)

    ActivityEvent.tool_calls_finished(
      host.context.agent_id,
      host.session_id,
      results,
      visible_scope(host)
    )

    pending =
      if flags["planned"],
        do: Enum.map(pending, &Map.put(&1, :round_progress_event, flags["progress_event"])),
        else: pending

    {%{host | async_pending: pending, speculative: nil}, results}
  end

  defp run_tools(host, calls, %{"mode" => "runtime_failure_notice", "aid" => aid}) do
    current = loop_state(host.context)

    ctx =
      current
      |> SalixAgent.GuardFailureReply.context(host.guard_tool_config, host.context)
      |> Map.merge(%{runtime_failure_delivery: true, trace_ctx: host.trace_ctx})
      |> Map.put(:assistant_message_id, aid)

    # The kernel builds the scope `guardNotice` authorized the notice under.
    router = ctx[:role] == "router" and SalixAgent.TerminalReply.canonical_router?(current)

    ctx =
      Map.put(
        ctx,
        :terminal_reply_context,
        InternalSession.query(current, :notice_reply_scope, {aid, ctx[:role], router})
      )

    {results, pending} = SessionToolDispatch.execute_with_async_window(calls, ctx)
    {%{host | async_pending: pending, billing_context: ctx.billing_context}, results}
  end

  # The workspace commit runs once per batch; a retried transaction reuses it
  # and projects the results again against the fresh session.
  defp store_results(host, kpending, results) do
    pending = host_pending(host, kpending)

    with {:ok, host, stored, candidates, stored_at_ms} <-
           workspace_results(host, pending, results) do
      session = loop_state(host.context)

      envelope_fun = fn projected_results ->
        model_tool_result_envelope(session, pending, candidates, projected_results, stored_at_ms)
      end

      with {:ok, projection} <-
             ToolResultProjection.plan(candidates, envelope_fun, @tool_result_envelope_max_bytes),
           {:ok, result_events, hwm} <-
             tool_events(session, pending, projection.projected_results) do
        stored_events =
          bind_stored_result_events(projection.stored_events, host.session_id, stored_at_ms)

        {:ok, host, stored_events ++ result_events, hwm, session_next_message_id(session), stored}
      end
    end
  end

  defp workspace_results(
         %{workspace: {results, stored, candidates, at}} = host,
         _pending,
         results
       ),
       do: {:ok, host, stored, candidates, at}

  defp workspace_results(host, pending, input) do
    results = VisibleReplyPolicy.label_results(input)

    with :ok <- SalixAgent.ToolSideEffects.validate_results(results),
         {:ok, results} <-
           SalixAgent.WorkspaceEvents.commit_results(
             host.context.agent_id,
             host.session_id,
             results,
             "tool-result",
             billing_context: pending.meter_ctx.billing_context,
             entrypoint: "storage_write",
             actor_type: pending.meter_ctx.actor_type
           ),
         {:ok, candidates} <- prepare_tool_result_candidates(results) do
      at = System.system_time(:millisecond)
      {:ok, %{host | workspace: {input, results, candidates, at}}, results, candidates, at}
    end
  end

  defp host_pending(host, kpending) do
    %{
      session_id: host.session_id,
      calls: kpending["calls"],
      assistant_message_id: kpending["aid"],
      trace_ctx: host.trace_ctx,
      meter_ctx: %{billing_context: host.billing_context, actor_type: host[:actor_type] || "tool"},
      presentation_checkpoint: kpending["checkpoint"]
    }
  end

  @doc false
  def commit_tool_results(%SalixStore.Agent.Owned{}, _pending, _results),
    do: {:error, :agent_lease_not_session_runtime_context}

  def commit_tool_results(context, pending, results) when is_list(results) do
    with :ok <- require_session_context(context, pending.session_id) do
      InternalSessionFleet.commit_tool_results(
        context.agent_id,
        pending.session_id,
        context,
        pending,
        results
      )
    end
  end

  @doc false
  # The loop host and loop event that commit a pending batch's results.
  def results_host(context, pending, results) do
    meter_ctx = Map.get(pending, :meter_ctx, %{})

    host =
      context
      |> Map.put(:visible_reply_phase, pending[:visible_reply_phase] || :clean)
      |> loop_host(pending.session_id, %{
        trace_ctx: pending.trace_ctx,
        billing_context: Map.get(meter_ctx, :billing_context, %{}),
        actor_type: Map.get(meter_ctx, :actor_type, "tool")
      })

    kpending = %{
      "calls" => pending[:calls],
      "aid" => pending[:assistant_message_id],
      "track" => pending[:track_runaway_progress] == true,
      "checkpoint" => pending[:presentation_checkpoint]
    }

    {host, {:commit_results, kpending, results, round_facts(host, nil, nil)}}
  end

  defp commit_planned_tool_results(host, kpending, results) do
    live = MapSet.new(host.async_pending, & &1.tool_call_id)
    agent_id = host.context.agent_id

    results
    |> Enum.reject(&MapSet.member?(live, &1[:id] || &1["id"]))
    |> Enum.reduce_while({:ok, host.context}, fn result, {:ok, context} ->
      call_id = result[:id] || result["id"]
      session = loop_state(context)

      completion =
        InternalSession.get(session, :async_tool_calls)[call_id]
        |> Map.put(:session_id, host.session_id)
        |> Map.put(:tool_call_id, call_id)
        |> Map.put(:tool_name, result[:name] || result["name"])
        |> Map.put(:billing_context, host.billing_context)
        |> Map.put(:round_progress_event, kpending["progress_event"])

      with {:ok, events, observed, workspace} <-
             SalixAgent.SessionToolExecution.prepare_internal_async_commit(
               agent_id,
               host.session_id,
               completion,
               result,
               session
             ),
           {:ok, revision} <-
             InternalSessionStore.commit_revision(
               agent_id,
               host.session_id,
               context.revision,
               events,
               [],
               fn ->
                 SalixAgent.WorkspaceEvents.commit_prepared_result(
                   agent_id,
                   host.session_id,
                   workspace
                 )
               end
             ) do
        register_committed_timers(agent_id, events)
        SalixAgent.SessionToolExecution.emit_async(agent_id, completion, observed)
        {:cont, {:ok, Map.put(context, :revision, revision)}}
      else
        error -> {:halt, error}
      end
    end)
  end

  # The running result and recovery record share the assistant intent CAS.
  # Control-only and oversized batches retain their existing result path.
  defp plan_tool_admission(session, intent, calls, ctx, aid) do
    SystemsObservability.Trace.with_span(
      :salix_round_admission,
      %{component: "salix_agent", surface: SystemsObservability.Context.current_surface()},
      fn -> do_plan_tool_admission(session, intent, calls, ctx, aid) end
    )
  end

  defp do_plan_tool_admission(session, intent, calls, ctx, aid) do
    pending = %{
      session_id: ctx.session_id,
      trace_ctx: ctx.trace_ctx,
      assistant_message_id: aid,
      calls: calls
    }

    calls = calls |> Enum.with_index() |> Enum.map(fn {call, i} -> put_call_index(call, i) end)

    with true <- ctx.visible_reply_phase == :clean and calls != [],
         true <-
           Enum.all?(calls, fn call ->
             id = call[:id] || call["id"]
             is_binary(id) and id != ""
           end),
         false <- Enum.any?(calls, &(tool_name(&1) == "wait_for")),
         {:ok, results} <- SessionToolDispatch.plan_async_intent(calls, ctx),
         projected = InternalSession.apply_events(session, intent),
         envelope =
           model_tool_result_envelope(
             projected,
             pending,
             [],
             results,
             System.system_time(:millisecond)
           ),
         true <- byte_size(Jason.encode!(envelope)) <= @tool_result_envelope_max_bytes,
         {:ok, events, hwm} <- tool_events(projected, pending, results) do
      {:ok, events, hwm}
    else
      _ -> :fallback
    end
  end

  defp execute_internal_tool_calls(tool_calls, ctx) do
    {wait_results, executable_calls} =
      tool_calls
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {call, index}, {waits, executable} ->
        call = put_call_index(call, index)

        if tool_name(call) == "wait_for" do
          {[run_wait_for_call(call, ctx) | waits], executable}
        else
          {waits, [call | executable]}
        end
      end)

    wait_results = Enum.reverse(wait_results)
    executable_calls = Enum.reverse(executable_calls)
    {executed_results, pending} = execute_internal_tool_group(executable_calls, ctx)

    results =
      (wait_results ++ executed_results)
      |> VisibleReplyPolicy.label_results()
      |> Map.new(&{result_call_index(&1), &1})

    ordered_results =
      0..(length(tool_calls) - 1)
      |> Enum.map(&Map.fetch!(results, &1))

    {ordered_results, pending}
  end

  defp execute_internal_tool_group([], _ctx), do: {[], []}

  # Archive boundaries 4 and 5 are emitted inside `SalixAgent.Tools`, so every
  # tool path is covered — this one, the scheduled-task path above, and
  # SessionToolExecution — rather than only the ones remembered here.
  defp execute_internal_tool_group(calls, ctx) do
    case VisibleReplyPolicy.sanitize_scheduled_task_failure_calls(calls, ctx) do
      {:ok, sanitized} ->
        {results, pending} =
          SessionToolDispatch.execute_with_async_window(sanitized, ctx)

        results = Enum.map(results, &VisibleReplyPolicy.mark_scheduled_task_failure_result/1)
        {results, VisibleReplyPolicy.stamp_pending_origin(pending, ctx.visible_reply_phase)}

      :not_scheduled_task_failure ->
        SessionToolDispatch.execute_with_async_window(calls, ctx)
    end
  end

  defp result_call_index(result),
    do: result[:call_index] || result["call_index"]

  defp put_call_index(call, index) when is_map(call) do
    call
    |> Map.put(:call_index, index)
    |> Map.put("call_index", index)
  end

  defp run_wait_for_call(call, ctx) do
    id = call[:id] || call["id"] || "wait-for-" <> random_hex(4)
    args = call[:args] || call["args"] || %{}
    started_at = System.system_time(:millisecond)
    started = System.monotonic_time(:millisecond)

    try do
      case SalixAgent.Tools.AsyncOps.wait_for(args, ctx) do
        {content, events} when is_list(events) ->
          %{
            id: id,
            name: "wait_for",
            content: content,
            error: false,
            input: Jason.encode!(args),
            output: content,
            status: "completed",
            duration_ms: System.monotonic_time(:millisecond) - started,
            started_at: started_at,
            call_index: call[:call_index] || call["call_index"],
            events: events
          }
          |> collect_wait_for_observation(ctx)
      end
    rescue
      e ->
        content = "error: #{Exception.message(e)}"

        %{
          id: id,
          name: "wait_for",
          content: content,
          error: true,
          input: Jason.encode!(args),
          output: content,
          status: "error",
          duration_ms: System.monotonic_time(:millisecond) - started,
          started_at: started_at,
          call_index: call[:call_index] || call["call_index"],
          error_class: SalixAgent.Tools.exception_error_class(e),
          events: []
        }
        |> collect_wait_for_observation(ctx)
    end
  end

  defp collect_wait_for_observation(result, ctx) do
    attrs =
      ctx
      |> Map.take([
        :agent_id,
        :session_id,
        :tenant_id,
        :group_id,
        :trace_ctx,
        :billing_context,
        :actor_type
      ])
      |> Map.merge(%{async: false})

    case SalixAgent.ToolTelemetry.terminal_fact(result, attrs) do
      {:ok, fact} ->
        if Map.get(ctx, :defer_tool_observations) == true do
          Map.put(result, :tool_observations, [fact])
        else
          SalixAgent.ToolTelemetry.emit_fact(fact)
          result
        end

      :skip ->
        result

      {:error, _reason} ->
        result
    end
  end

  defp emit_agent_run(context, session, session_id, trace_ctx, meter_ctx, status) do
    attrs =
      (meter_ctx || %{})
      |> Map.merge(%{
        agent_id: context.agent_id,
        salix_agent_id: context.agent_id,
        session_id: session_id,
        session: session,
        trace_ctx: trace_ctx,
        status: status
      })

    SalixAgent.RunTelemetry.emit_agent_run(attrs)
  end

  defp tool_name(call), do: to_string(call[:name] || call["name"] || "")

  defp prepare_tool_result_candidates(results) do
    Enum.reduce_while(results, {:ok, []}, fn result, {:ok, candidates} ->
      result_ref = SalixStore.Ids.new_tool_result_ref()

      case ToolResultProjection.prepare(result, result_ref) do
        {:ok, candidate} -> {:cont, {:ok, candidates ++ [candidate]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # The budget covers the complete serialized batch of model-facing tool
  # messages, not just each content string. Apply the exact candidate event
  # batch to the current session projection so seq/id/trace metadata and the
  # context read projection are all counted. Canonical source records are
  # included first because that is the order committed by the owner CAS.
  defp model_tool_result_envelope(
         session,
         pending,
         candidates,
         projected_results,
         stored_at_ms
       ) do
    stored_events =
      projected_stored_result_events(
        candidates,
        projected_results,
        pending.session_id,
        stored_at_ms
      )

    case tool_events(session, pending, projected_results) do
      {:ok, result_events, _hwm} ->
        tool_message_ids =
          result_events
          |> Enum.filter(&(&1["type"] == "tool_result"))
          |> Enum.map(& &1["message_id"])
          |> Enum.uniq()

        tool_messages =
          session
          |> InternalSession.apply_events(stored_events ++ result_events)
          |> SalixAgent.Compaction.context_where({:tool_ids, tool_message_ids})

        %{"tool_results" => tool_messages}

      {:error, reason} ->
        raise ArgumentError, "invalid projected tool-result envelope: #{inspect(reason)}"
    end
  end

  defp projected_stored_result_events(
         candidates,
         projected_results,
         session_id,
         stored_at_ms
       ) do
    candidates
    |> Enum.zip(projected_results)
    |> Enum.flat_map(fn {candidate, projected_result} ->
      capsule_content = candidate |> ToolResultProjection.capsule() |> Jason.encode!()
      content = projected_result[:content] || projected_result["content"]

      if content == capsule_content do
        [ToolResultProjection.stored_event(candidate)]
      else
        []
      end
    end)
    |> bind_stored_result_events(session_id, stored_at_ms)
  end

  defp bind_stored_result_events(events, session_id, stored_at_ms) do
    Enum.map(events, fn event ->
      event
      |> Map.put("session_id", session_id)
      |> Map.put("stored_at_ms", stored_at_ms)
    end)
  end

  # The committed Session and eager work candidate already preserve the running
  # reads and their deadline. Timer projection I/O must not hold their results
  # in the owner's mailbox. Bound outstanding projection tasks per node; at
  # capacity use the existing synchronous path.
  defp register_read_timers(agent_id, events) do
    context = SystemsObservability.Context.capture()

    case Task.Supervisor.start_child(SalixAgent.WaitTimerTasks, fn ->
           SystemsObservability.Context.run(context, fn ->
             register_committed_timers(agent_id, events)
           end)
         end) do
      {:ok, _pid} -> :ok
      {:error, _reason} -> register_committed_timers(agent_id, events)
    end
  end

  defp register_committed_timers(agent_id, events) do
    case SalixAgent.Waits.register_timers_from_events(agent_id, events) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("round wait timer registration failed after commit: #{inspect(reason)}")
        :ok
    end
  end

  defp require_session_context(%{session_id: session_id}, session_id)
       when is_binary(session_id),
       do: :ok

  defp require_session_context(%{session_id: actual}, expected),
    do: {:error, {:session_runtime_context_mismatch, expected, actual}}

  defp require_session_context(_context, session_id),
    do: {:error, {:session_runtime_context_missing, session_id}}

  @doc false
  def tool_error_results(calls, reason, error_class \\ "tool_error") do
    Enum.map(calls, fn call ->
      name = call[:name] || call["name"]
      id = call[:id] || call["id"]
      args = call[:args] || call["args"] || %{}
      message = "tool crashed: #{inspect(reason)}"

      %{
        id: id,
        name: name,
        content: message,
        error: true,
        input: Jason.encode!(args),
        output: message,
        status: "error",
        duration_ms: 0,
        error_class: error_class,
        error_message: message,
        events: []
      }
    end)
  end

  defp set_status(context, session_id, status) do
    commit_events(context, session_id, [
      %{"type" => "status", "session_id" => session_id, "status" => status}
    ])
  end

  # ---- the resident revision ----
  #
  # The owning actor is the only writer of its session, so one revision read
  # per owner callback is the whole truth for that callback. The round carries
  # the revision in its context, reads the session from it instead of from the
  # store, and commits every transition against it. A CAS conflict (an
  # ownership transfer, a foreign write) is the one case that re-reads.

  # A session that does not exist yet has no revision: its first commit
  # creates it through the store's birth path, and the revision is read once
  # right after.
  defp ensure_revision(%{revision: %Revision{}} = context, _session_id, _opts), do: {:ok, context}

  defp ensure_revision(context, session_id, opts) do
    case Keyword.get(opts, :prepared_activation) do
      %{revision: %Revision{} = revision} ->
        {:ok, Map.put(context, :revision, revision)}

      _ ->
        case InternalSessionStore.read_revision(context.agent_id, session_id) do
          {:ok, revision} -> {:ok, Map.put(context, :revision, revision)}
          {:error, :not_found} -> {:ok, Map.delete(context, :revision)}
          {:error, _} = err -> err
        end
    end
  end

  defp require_revision(context, session_id) do
    case ensure_revision(context, session_id, []) do
      {:ok, %{revision: %Revision{}} = context} -> {:ok, context}
      {:ok, _context} -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  defp revision_state(%{revision: %Revision{state: state}}), do: state

  defp commit_events(context, session_id, events, opts \\ [])

  defp commit_events(%{revision: %Revision{} = revision} = context, session_id, events, opts) do
    case InternalSessionStore.commit_revision(
           context.agent_id,
           session_id,
           revision,
           events,
           opts
         ) do
      {:ok, revision} -> {:ok, Map.put(context, :revision, revision)}
      {:error, _} = err -> err
    end
  end

  defp commit_events(context, session_id, events, opts) do
    with {:ok, _session} <-
           InternalSessionStore.commit(context.agent_id, session_id, events, opts),
         {:ok, revision} <- InternalSessionStore.read_revision(context.agent_id, session_id) do
      {:ok, Map.put(context, :revision, revision)}
    end
  end

  defp tag_pre_llm_error({:error, reason}, stage),
    do: {:error, {:visible_reply_pre_llm_error, stage, reason}}

  defp tag_pre_llm_error(result, _stage), do: result

  # The kernel builds the batch: one `tool_result` event per result at
  # consecutive message ids, the results' side-effect events, reply-obligation
  # resolutions, and the batch settlement (`LoopHost.toolBatchEvents`).
  defp tool_events(session, pending, results) do
    InternalSession.query(session, :tool_batch_events, {
      %{"checkpoint" => pending[:presentation_checkpoint]},
      results,
      Map.take(pending.trace_ctx, [:turn_id, :round_id, :request_id, :trace_id])
    })
  end

  # ---- helpers ----

  # Selected provider-config fields for the llm_request log line. NEVER widen
  # this to the whole opts — they carry credentials (api_key).
  defp llm_opt(opts, key) when is_map(opts), do: opts[key] || opts[Atom.to_string(key)]
  defp llm_opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp llm_opt(_opts, _key), do: nil

  defp disable_dispatch_metering(opts) when is_list(opts),
    do: Keyword.put(opts, :metering_disabled, true)

  defp disable_dispatch_metering(opts) when is_map(opts),
    do: Map.put(opts, :metering_disabled, true)

  defp disable_dispatch_metering(_opts), do: %{metering_disabled: true}

  # Streaming call opts: dispatch metering off plus private tool-argument and
  # reasoning-delta callbacks. Only the exact semantic send-message projector
  # may publish text from the former.
  defp stream_llm_opts(llm_opts, on_tool_delta, on_reasoning_delta) do
    llm_opts
    |> disable_dispatch_metering()
    |> put_opt(:on_tool_delta, on_tool_delta)
    |> put_opt(:on_reasoning_delta, on_reasoning_delta)
  end

  defp put_opt(opts, key, value) when is_list(opts), do: Keyword.put(opts, key, value)
  defp put_opt(opts, key, value) when is_map(opts), do: Map.put(opts, key, value)

  defp publish_visible_reply_text(agent_id, session_id, scope, cumulative)
       when is_binary(cumulative) do
    previous = Process.get(@visible_reply_draft_key, "")

    if previous == "" and cumulative != "" do
      ActivityEvent.typing(agent_id, session_id, scope)
    end

    Process.put(@visible_reply_draft_key, cumulative)
    VisibleReply.publish_delta(agent_id, session_id, scope, cumulative, nil)
  end

  defp retain_visible_reply_until_async_terminal(pending, tool_calls, context)
       when is_list(pending) do
    scope = context[:visible_reply_scope]
    phase = context[:visible_reply_phase] || :clean

    if pending != [] and SendMessageDraftStream.exact_source_send?(tool_calls, scope, phase) do
      Enum.map(pending, &Map.put(&1, :visible_reply_scope, scope))
    else
      pending
    end
  end

  defp cancel_visible_reply(%{context: context, session_id: session_id}) do
    case context[:visible_reply_scope] do
      %{} = scope -> VisibleReply.cancel(context.agent_id, session_id, scope)
      _ -> :ok
    end
  end

  defp metered_provider_call(meter_ctx, llm_opts, started, fun) do
    billing = meter_ctx[:billing_context] || %{}

    SystemsObservability.Trace.with_span(
      :salix_llm,
      %{
        component: "salix_agent",
        operation: "request",
        surface: billing["surface"] || billing[:surface] || "system",
        provider: meter_ctx[:provider] || "other",
        model_key: meter_ctx[:model] || "other"
      },
      fn -> do_metered_provider_call(meter_ctx, llm_opts, started, fun) end,
      kind: :client
    )
  end

  defp do_metered_provider_call(meter_ctx, llm_opts, started, fun) do
    execution_started = SalixAgent.ExecutionTiming.start()
    meter_ctx = Map.put(meter_ctx, :started_at_ms, elem(execution_started, 0))

    Process.put(@llm_meter_tracker_key, %{
      started_at: started,
      attempt_started_at: nil,
      attempts: 0,
      request_first_token_at: nil,
      first_token_ms: nil,
      history_context: meter_ctx,
      execution_started: execution_started
    })

    try do
      observe_request_history(
        meter_ctx,
        SalixAgent.ExecutionTiming.running(execution_started),
        true
      )

      response = retry_llm_provider_call(meter_ctx, fun, 0)

      execution_timing =
        SalixAgent.ExecutionTiming.finish_at(
          execution_started,
          Process.get(@llm_meter_tracker_key)[:provider_completed_at] ||
            System.monotonic_time(:millisecond),
          Process.get(@llm_meter_tracker_key).request_first_token_at
        )

      LLM.emit_logical_request(llm_opts, response)
      observe_request_history(meter_ctx, execution_timing, false)
      {response, Map.put(llm_meter_tracker_meta(), :execution_timing, execution_timing)}
    rescue
      exception ->
        observe_request_history(
          meter_ctx,
          SalixAgent.ExecutionTiming.finish(execution_started),
          false
        )

        LLM.emit_logical_request(llm_opts, {:error, exception})

        duration_ms = System.monotonic_time(:millisecond) - started
        meter_meta = llm_meter_tracker_meta()

        _ =
          LLMMetering.after_llm_call(
            llm_meter_error(meter_ctx, exception, duration_ms, meter_meta)
          )

        reraise exception, __STACKTRACE__
    catch
      kind, reason ->
        observe_request_history(
          meter_ctx,
          SalixAgent.ExecutionTiming.finish(execution_started),
          false
        )

        LLM.emit_logical_request(llm_opts, {:error, {kind, reason}})

        duration_ms = System.monotonic_time(:millisecond) - started
        meter_meta = llm_meter_tracker_meta()

        _ =
          LLMMetering.after_llm_call(
            llm_meter_error(meter_ctx, {kind, reason}, duration_ms, meter_meta)
          )

        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      Process.delete(@llm_meter_tracker_key)
      Process.delete(@visible_reply_draft_key)
      Process.delete(@send_message_draft_stream_key)
    end
  end

  defp observe_request_history(context, timing, live) do
    if is_binary(context[:request_id]) do
      record = SalixAgent.ExecutionSurface.record(context.request_id, "model", timing, %{}, live)
      SalixAgent.ExecutionSurface.observe(context, record)
    end
  end

  defp retry_llm_provider_call(meter_ctx, fun, retries_done) do
    llm_meter_attempt_started()
    result = safe_llm_provider_call(fun)
    # From here the attempt has returned and the branches below record its
    # fact; a deadline kill after this point must not report it again.
    SalixAgent.StreamProgress.settle()

    case result do
      {:ok, {:error, _reason} = response} ->
        maybe_retry_llm_provider_call(meter_ctx, fun, retries_done, response, fn -> response end)

      {:ok, response} ->
        response

      {:raise, exception, stacktrace} ->
        maybe_retry_llm_provider_call(meter_ctx, fun, retries_done, exception, fn ->
          reraise exception, stacktrace
        end)

      {:throw, kind, reason, stacktrace} ->
        maybe_retry_llm_provider_call(meter_ctx, fun, retries_done, {kind, reason}, fn ->
          :erlang.raise(kind, reason, stacktrace)
        end)
    end
  end

  defp safe_llm_provider_call(fun) do
    {:ok, fun.()}
  rescue
    exception -> {:raise, exception, __STACKTRACE__}
  catch
    kind, reason -> {:throw, kind, reason, __STACKTRACE__}
  end

  defp llm_meter_attempt_started do
    Process.put(@visible_reply_draft_key, "")
    Process.delete(@send_message_draft_stream_key)

    case Process.get(@llm_meter_tracker_key) do
      %{} = tracker ->
        Process.put(@llm_meter_tracker_key, %{
          tracker
          | attempt_started_at: System.monotonic_time(:millisecond),
            attempts: tracker.attempts + 1,
            first_token_ms: nil
        })

        SalixAgent.StreamProgress.begin_attempt(tracker.attempts + 1)

      _ ->
        :ok
    end
  end

  # Every delta site records through here, so the two first-token facts cannot
  # drift apart. They answer the same question over different spans:
  # `request_first_token_at` covers the logical request, survives retries and
  # feeds the session's execution timing; `first_token_ms` restarts with each
  # attempt and feeds `llm_call_events_v2.first_token_ms`.
  #
  # Metering used to stamp only on a text delta. A round that answers with a
  # tool call and no prose therefore measured nothing, so the models that make
  # the most tool calls were the ones the dashboard could say the least about.
  defp record_first_delta(text) do
    record_request_first_delta(text)
    record_llm_first_delta(text)
    record_content_progress(text)
  end

  # Text, tool-argument and reasoning deltas all count as content the round
  # received, as opposed to response bytes the transport saw. The owner reads
  # this after killing the job to tell an answer that was still being
  # written from a provider heartbeating over an empty stream.
  defp record_content_progress(text) when is_binary(text) and text != "",
    do: SalixAgent.StreamProgress.observe_content()

  defp record_content_progress(_text), do: :ok

  defp record_request_first_delta(text) when is_binary(text) and text != "" do
    case Process.get(@llm_meter_tracker_key) do
      %{request_first_token_at: nil} = tracker ->
        first = System.monotonic_time(:millisecond)

        Process.put(@llm_meter_tracker_key, %{
          tracker
          | request_first_token_at: first
        })

        observe_request_history(
          tracker.history_context,
          SalixAgent.ExecutionTiming.running(tracker.execution_started, first),
          true
        )

      _ ->
        :ok
    end
  end

  defp record_request_first_delta(_), do: :ok

  defp record_llm_first_delta(text) when is_binary(text) and text != "" do
    case Process.get(@llm_meter_tracker_key) do
      %{attempt_started_at: attempt_started_at, first_token_ms: nil} = tracker
      when is_integer(attempt_started_at) ->
        first_token_ms = max(System.monotonic_time(:millisecond) - attempt_started_at, 0)
        Process.put(@llm_meter_tracker_key, %{tracker | first_token_ms: first_token_ms})

      _ ->
        :ok
    end
  end

  defp record_llm_first_delta(_text), do: :ok

  defp llm_meter_tracker_meta do
    case Process.get(@llm_meter_tracker_key) do
      %{attempts: attempts, first_token_ms: first_token_ms} when attempts > 0 ->
        %{attempts: attempts, first_token_ms: first_token_ms}

      _ ->
        %{attempts: 1, first_token_ms: nil}
    end
  end

  defp maybe_retry_llm_provider_call(meter_ctx, fun, retries_done, reason, on_exhausted) do
    retry_number = retries_done + 1
    delay_ms = llm_retry_delay_ms(retry_number, reason)
    {attempt_duration_ms, attempt_started_ms} = llm_attempt_timing()

    # The attempt that just failed is attempt number `retry_number`; the
    # fact says what the loop does about it so the row explains the
    # request's attempt count on its own.
    record_attempt = fn outcome, delay ->
      SalixAgent.AttemptTelemetry.emit(
        meter_ctx,
        retry_number,
        @llm_request_max_retries + 1,
        outcome,
        reason,
        delay,
        attempt_duration_ms,
        attempt_started_ms
      )
    end

    cond do
      not retryable_llm_error?(reason) or retries_done >= @llm_request_max_retries ->
        record_attempt.(:exhausted, 0)
        on_exhausted.()

      # The provider asked for a wait the request deadline cannot hold:
      # retrying early would only spend the attempt inside the same window.
      not retry_within_budget?(delay_ms, remaining_request_budget_ms()) ->
        record_attempt.(:abandoned, delay_ms)
        log_llm_request_retry_abandoned(meter_ctx, retry_number, delay_ms, reason)
        on_exhausted.()

      true ->
        record_attempt.(:retry, delay_ms)
        log_llm_request_retry(meter_ctx, retry_number, delay_ms, reason)
        Process.sleep(delay_ms)
        retry_llm_provider_call(meter_ctx, fun, retry_number)
    end
  end

  # Provider-classified permanent failures (HTTP 4xx contract errors — an
  # oversized request, an invalid parameter) never heal by resending the same
  # payload; retrying only burns time and rate limit. Overflow recovery is
  # the exhausted path's job (auto-compaction), not the retry loop's.
  defp retryable_llm_error?({:error, reason}), do: retryable_llm_error?(reason)
  defp retryable_llm_error?(%{"retryable" => false}), do: false
  defp retryable_llm_error?(_reason), do: true

  @doc "How many provider attempts one logical model request may make."
  @spec llm_request_max_attempts() :: pos_integer()
  def llm_request_max_attempts, do: @llm_request_max_retries + 1

  @doc false
  # The wait before retry number `retry_number` (1-based): exponential from
  # the ordinary or the rate-limit base, capped at one minute, and never less
  # than the provider's own `Retry-After`. The provider's figure is not
  # capped: waiting less than it asked only spends the attempt inside the same
  # rate-limit window. A wait the request deadline cannot hold abandons the
  # retry instead (`retry_within_budget?/2`).
  @spec llm_retry_delay_ms(pos_integer(), term()) :: non_neg_integer()
  def llm_retry_delay_ms(retry_number, reason) do
    base =
      if rate_limited_llm_error?(reason),
        do: rate_limit_retry_base_ms(),
        else: @llm_request_retry_base_ms

    local = min(base * exponential_multiplier(retry_number), @llm_retry_delay_cap_ms)
    max(local, provider_retry_delay_ms(reason))
  end

  @doc false
  @spec retry_within_budget?(non_neg_integer(), non_neg_integer() | :infinity) :: boolean()
  def retry_within_budget?(_delay_ms, :infinity), do: true
  def retry_within_budget?(delay_ms, remaining_ms), do: delay_ms < remaining_ms

  # `{duration_ms, started_at_ms}` of the attempt that just ended, from the
  # meter tracker's monotonic attempt start; both nil-safe for callers
  # outside the round loop.
  defp llm_attempt_timing do
    now_wall = SalixAgent.AttemptTelemetry.now_ms()

    case Process.get(@llm_meter_tracker_key) do
      %{attempt_started_at: started} when is_integer(started) ->
        duration = max(System.monotonic_time(:millisecond) - started, 0)
        {duration, now_wall - duration}

      _ ->
        {0, now_wall}
    end
  end

  # Time left on the logical request's deadline, from the meter tracker that
  # `run_llm_provider_call/3` installs; absent (a caller outside the round
  # loop) means no bound.
  defp remaining_request_budget_ms do
    case Process.get(@llm_meter_tracker_key) do
      %{started_at: started_at} when is_integer(started_at) ->
        elapsed = System.monotonic_time(:millisecond) - started_at
        max(SalixAgent.LLM.request_timeout_ms() - elapsed, 0)

      _ ->
        :infinity
    end
  end

  defp rate_limited_llm_error?({:error, reason}), do: rate_limited_llm_error?(reason)

  defp rate_limited_llm_error?(%{} = reason) when not is_struct(reason),
    do: (reason["status"] || reason[:status]) in @llm_rate_limit_statuses

  defp rate_limited_llm_error?(_reason), do: false

  defp rate_limit_retry_base_ms do
    case Application.get_env(:salix_agent, :llm_rate_limit_retry_base_ms) do
      ms when is_integer(ms) and ms >= 0 -> ms
      _ -> @llm_rate_limit_retry_base_ms
    end
  end

  defp provider_retry_delay_ms({:error, reason}), do: provider_retry_delay_ms(reason)

  defp provider_retry_delay_ms(%{"retry_after_ms" => delay}) when is_integer(delay),
    do: max(delay, 0)

  defp provider_retry_delay_ms(_), do: 0

  defp exponential_multiplier(retry_number) do
    retry_number
    |> Kernel.-(1)
    |> max(0)
    |> then(&:math.pow(2, &1))
    |> round()
  end

  defp log_llm_request_retry(meter_ctx, retry_number, delay_ms, reason) do
    Logger.warning(
      "internal session #{meter_ctx[:agent_id]}/#{meter_ctx[:session_id]} llm request failed; retry=#{retry_number}/#{@llm_request_max_retries} delay_ms=#{delay_ms}: #{retry_reason_preview(reason)}"
    )

    CommaLog.log("llm_request_retry", %{
      agent_id: meter_ctx[:agent_id],
      session_id: meter_ctx[:session_id],
      retry: retry_number,
      max_retries: @llm_request_max_retries,
      delay_ms: delay_ms,
      reason: retry_reason_preview(reason)
    })
  end

  defp log_llm_request_retry_abandoned(meter_ctx, retry_number, delay_ms, reason) do
    Logger.warning(
      "internal session #{meter_ctx[:agent_id]}/#{meter_ctx[:session_id]} llm request failed; retry=#{retry_number}/#{@llm_request_max_retries} needs delay_ms=#{delay_ms} beyond the request deadline, giving up: #{retry_reason_preview(reason)}"
    )

    CommaLog.log("llm_request_retry_abandoned", %{
      agent_id: meter_ctx[:agent_id],
      session_id: meter_ctx[:session_id],
      retry: retry_number,
      max_retries: @llm_request_max_retries,
      delay_ms: delay_ms,
      reason: retry_reason_preview(reason)
    })
  end

  defp retry_reason_preview(reason) do
    reason
    |> inspect(limit: 20, printable_limit: 2048)
    |> String.slice(0, 2048)
  end

  defp log_llm_response(context, session_id, response, duration_ms) do
    fields =
      case response do
        {:final, content} ->
          %{kind: "final", content: content}

        {:final, content, _provider_meta, _trace_meta} ->
          %{kind: "final", content: content, provider_meta: true}

        {:error, %{} = meta} ->
          %{kind: "error", llm_error: meta}

        {:assistant, content, tool_calls} ->
          %{
            kind: "assistant",
            content: content,
            tool_calls: Enum.map(tool_calls, &normalize_call/1)
          }

        {:assistant, content, tool_calls, _provider_meta} ->
          %{
            kind: "assistant",
            content: content,
            tool_calls: Enum.map(tool_calls, &normalize_call/1),
            provider_meta: true
          }

        other ->
          %{kind: "unexpected", raw: other}
      end

    CommaLog.log(
      "llm_response",
      Map.merge(fields, %{
        agent_id: context.agent_id,
        session_id: session_id,
        duration_ms: duration_ms
      })
    )
  end

  defp llm_meter_context(
         context,
         session,
         session_id,
         llm_opts,
         trace_ctx,
         runtime_config
       ) do
    billing_context = session_billing_context(session)

    %{
      model_purpose: :agent_main,
      agent_id: context.agent_id,
      salix_agent_id: context.agent_id,
      session_id: session_id,
      tenant_id: runtime_config[:tenant_id],
      group_id: runtime_config[:group_id],
      turn_id: trace_ctx.turn_id,
      round_id: trace_ctx.round_id,
      request_id: trace_ctx.request_id,
      trace_id: trace_ctx.trace_id,
      model: llm_opt(llm_opts, :model),
      protocol: llm_opt(llm_opts, :protocol),
      provider: LLMProvider.provider(llm_opts),
      tenant_account_pool: SalixAgent.AccountPool.owns_route?(llm_opts),
      credential_scope: llm_opt(llm_opts, :credential_scope),
      app_revision: SalixAgent.AppRevision.value(),
      started_at_ms: System.system_time(:millisecond),
      billing_context: billing_context,
      actor_type: billing_context["actor_type"] || billing_context[:actor_type] || "user",
      entrypoint: billing_context["entrypoint"] || billing_context[:entrypoint] || "agent_round"
    }
  end

  defp llm_meter_result(ctx, response, duration_ms, status, meter_meta) do
    meta = response_meta(response)
    llm_error = meta["llm_error"] || meta[:llm_error]
    status = if match?({:error, %{}}, response), do: "error", else: status

    ctx
    |> Map.merge(%{
      status: status,
      stale: status == "stale",
      duration_ms: duration_ms,
      completed_at_ms: System.system_time(:millisecond),
      response_kind: elem(response, 0),
      usage: meta["usage"] || meta[:usage] || %{},
      provider_model: meta["model"] || meta[:model]
    })
    |> Map.merge(Map.delete(meter_meta, :execution_timing))
    |> maybe_put(:llm_error, llm_error)
    |> maybe_put(:error_type, llm_error_category(llm_error))
    |> maybe_put(:http_status, llm_error_status(llm_error))
  end

  defp llm_meter_error(ctx, reason, duration_ms, meter_meta) do
    Map.merge(ctx, %{
      status: "error",
      stale: false,
      duration_ms: duration_ms,
      completed_at_ms: System.system_time(:millisecond),
      error: inspect(reason),
      error_type: llm_exception_error_type(reason)
    })
    |> Map.merge(meter_meta)
  end

  defp llm_error_category(%{} = meta), do: meta["category"] || meta[:category] || "unknown"
  defp llm_error_category(_), do: nil

  defp llm_error_status(%{} = meta), do: meta["status"] || meta[:status]
  defp llm_error_status(_), do: nil

  defp llm_exception_error_type(%{__struct__: _}), do: "exception"

  defp llm_exception_error_type({kind, _reason}) when kind in [:throw, :exit, :error],
    do: "exception"

  defp llm_exception_error_type(_), do: "exception"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp response_meta({:final, _content, meta}) when is_map(meta), do: meta

  defp response_meta({:final, _content, _provider_meta, meta}) when is_map(meta), do: meta

  defp response_meta({:assistant, _content, _calls, _provider_meta, meta}) when is_map(meta),
    do: meta

  defp response_meta({:error, %{} = meta}), do: %{"llm_error" => meta}

  defp response_meta(_response), do: %{}

  defp session_billing_context(nil), do: %{}

  defp session_billing_context(session) when InternalSession.is_session(session),
    do: InternalSession.get(session, :billing_context) || %{}

  defp session_billing_context(session) when is_map(session),
    do: Map.get(session, :billing_context) || Map.get(session, "billing_context") || %{}

  # Group context may contain identified no-wake user-role carriers. Preserve
  # them in the activation-wide provenance set, but never let one replace the
  # last wakeable source used for provider provenance and status.
  defp current_turn_source(session, source_message_ids)
       when is_list(source_message_ids) and source_message_ids != [],
       do: InternalSession.query(session, :current_turn_source, source_message_ids)

  defp current_turn_source(_session, _source_message_ids), do: {nil, nil}

  # ScheduledTaskFailure.tla models the activation-wide provenance set: a
  # later ordinary Task message must not erase an earlier due window, and two
  # overdue windows in one catch-up activation remain independently settleable.
  defp current_turn_trusted_origins(session, source_message_ids)
       when is_list(source_message_ids) and source_message_ids != [],
       do: InternalSession.query(session, :current_turn_trusted_origins, source_message_ids)

  defp current_turn_trusted_origins(_session, _source_message_ids), do: []

  defp fee_control_error_decision(context, reason) do
    %{
      allowed?: false,
      would_block: true,
      reason: "fee_control_error",
      error: inspect(reason),
      mode: :enforce,
      resource_kind: :llm,
      action: :start,
      provider: context[:provider],
      sku: context[:sku],
      billing_account_id: get_in(context, [:billing_context, "billing_account_id"])
    }
  end

  defp session_next_message_id(session) when InternalSession.is_session(session),
    do: InternalSession.next_message_id(session)

  defp normalize_call(%{} = c),
    do: %{
      "id" => c[:id] || c["id"],
      "name" => c[:name] || c["name"],
      "args" => c[:args] || c["args"] || %{}
    }

  # The round's ids. The kernel adds the request generation it captures with
  # the request, never the later assistant append position (modeled in
  # tla/salix/CompactionInputBoundary.tla).
  defp new_trace_context do
    id = random_hex(16)

    %{
      turn_id: "turn-" <> id,
      round_id: "round-" <> id,
      request_id: "req-" <> id,
      trace_id: random_hex(16)
    }
  end

  defp random_hex(bytes), do: :crypto.strong_rand_bytes(bytes) |> Base.encode16(case: :lower)
end
