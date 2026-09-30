defmodule SalixAgent.SessionToolExecution do
  @moduledoc false

  # Modeled in tla/salix/InternalToolCompletionOwner.tla. This value is part
  # of the durable running-call protocol, not only process-local poll state.
  @direct_poll_owner "direct_poll"
  @reader_tool "tool_call.get_result"
  @capability_tools ~w(permission.request location.request oauth.request_authorization runtime.auth ifc.request_declassification)
  @tool_result_projection_key "_tool_result_projection"
  @tool_result_envelope_max_bytes SalixAgent.ToolResultProjection.model_envelope_max_bytes()

  alias SalixAgent.{
    AgentActor,
    AsyncToolResults,
    Compaction,
    ExternalSessionStore,
    InternalSessionStore,
    ProviderReplyObligation,
    SessionToolDispatch,
    ToolResultProjection,
    VisibleReplyPolicy
  }

  alias SalixAgent.InternalSession

  require InternalSession

  def execute(agent_id, session_id, runtime_kind, source_message_ids, tool_name, attrs) do
    with {:ok, context} <- session_context(agent_id, session_id, runtime_kind),
         {:ok, config} <-
           AgentActor.runtime_session_config(agent_id, %{
             platform: context_value(context, :platform),
             session_context: context,
             runtime_kind: runtime_kind
           }) do
      source_message_ids =
        case normalize_source_ids(source_message_ids) do
          [] when runtime_kind == :internal ->
            InternalSession.query(context, :current_source_ids)

          [] ->
            normalize_source_ids(context_value(context, :active_external_source_message_ids))

          current ->
            current
        end

      trusted_origin = trusted_origin(context, source_message_ids)
      {args, ifc} = SalixAgent.IFC.Declaration.lift(attrs || %{})

      tool_call =
        %{id: "http-tool:" <> random_id(), name: tool_name, args: args}
        |> then(&if(ifc, do: Map.put(&1, :ifc, ifc), else: &1))

      ctx =
        tool_context(
          agent_id,
          session_id,
          runtime_kind,
          source_message_ids,
          trusted_origin,
          config,
          context
        )

      with {:ok, admission} <- admit_direct_capability(tool_call, ctx, runtime_kind) do
        {[result], pending_async} =
          SessionToolDispatch.execute_with_async_window([tool_call], ctx)

        result = close_inline_admission(result, pending_async, admission)

        {result, pending_async} =
          stamp_direct_poll_ownership(result, pending_async, runtime_kind)

        persist_inline? =
          is_map(admission) and pending_async == [] and not external_callback_handoff?(result)

        result_source =
          if persist_inline?,
            do: AsyncToolResults.operation_source(:internal),
            else: operation_source(runtime_kind, "http-tool")

        with :ok <- validate_result(result),
             {:ok, result} <-
               SalixAgent.WorkspaceEvents.commit_result(
                 agent_id,
                 session_id,
                 result,
                 result_source,
                 store_result: persist_inline?
               ) do
          {:ok, SalixAgent.Tools.strip_deferred_tool_observations(result), pending_async,
           result[:events] || result["events"] || [], result}
        end
      end
    end
  end

  # Direct capability calls need the same durable address as assistant-owned
  # dispatch. The request may be created before its callback handoff is committed.
  defp admit_direct_capability(%{name: name} = call, ctx, :internal)
       when name in @capability_tools do
    case SessionToolDispatch.plan_async_intent([call], ctx) do
      {:ok, [planned]} ->
        {planned, []} = stamp_direct_poll_ownership(planned, [], :internal)
        events = planned[:events] || planned["events"] || []

        case InternalSessionStore.commit(ctx.agent_id, ctx.session_id, events) do
          {:ok, _} -> {:ok, Enum.find(events, &(&1["type"] == "async_tool_call_started"))}
          {:error, _} = error -> error
        end

      :fallback ->
        {:ok, nil}
    end
  end

  defp admit_direct_capability(_call, _ctx, _runtime_kind), do: {:ok, nil}

  defp close_inline_admission(result, [], admission) when is_map(admission) do
    if external_callback_handoff?(result) do
      result
    else
      events = AsyncToolResults.internal_poll_events(admission, result)
      Map.put(result, :events, events)
    end
  end

  defp close_inline_admission(result, _pending, _admission), do: result

  def complete_surface(agent_id, session_id, runtime_kind, call, tool_call_id, result, meta) do
    result =
      result
      |> normalize_surface_result(tool_call_id, meta)
      |> VisibleReplyPolicy.inherit_result_origin(call)
      |> VisibleReplyPolicy.inherit_result_origin(meta)
      |> drop_policy_transition_fields()
      |> VisibleReplyPolicy.label_result()

    stored = SalixAgent.Tools.strip_deferred_tool_observations(result)

    # Archive boundary 5, callback arm. A THIRD settlement path, distinct from
    # both Tools.execute and begin_async_tool_terminal: a result arriving from
    # off-node via SalixAgent.complete_async_tool_call/6. Its producers include
    # human capability approvals and OAuth grant callbacks — among the most
    # audit-relevant items in the system.
    #
    # Everything is passed RAW; the emitter extracts. Digging into `call` here
    # is what broke the JavaScript-host wake path, because `call` can be a
    # keyword list and Access on one rejects binary keys.
    SalixAgent.EventArchive.Emit.callback_tool_result(
      agent_id,
      session_id,
      call,
      tool_call_id,
      meta,
      result
    )

    with :ok <- validate_result(result),
         {:ok, committed} <-
           SalixAgent.WorkspaceEvents.commit_result(
             agent_id,
             session_id,
             stored,
             operation_source(runtime_kind, "surface-async-tool-result")
           ) do
      pending =
        call
        |> Map.put("session_id", session_id)
        |> Map.put("tool_call_id", tool_call_id)
        |> Map.put("tool_name", value(meta, "tool_name") || call["tool_name"])

      callback_handoff? = external_callback_handoff?(committed)

      events =
        cond do
          callback_handoff? and direct_poll_owned?(runtime_kind, pending) ->
            direct_poll_handoff_events(pending, committed)

          callback_handoff? ->
            # The process-local job only discovered that the business tool has
            # handed ownership to an external callback. Keep the same running
            # tool-call identity and replace its lifecycle metadata; emitting an
            # async_tool_call_completed event here would falsely terminalize it.
            callback_handoff_events(runtime_kind, pending, committed)

          direct_poll_owned?(runtime_kind, pending) ->
            SalixAgent.AsyncToolResults.internal_poll_events(pending, committed)

          true ->
            runtime_kind
            |> async_events(pending, committed)
            |> visible_reply_policy_events(agent_id, session_id, runtime_kind, committed)
        end

      events =
        maybe_append_provider_reply_resolution(
          events,
          runtime_kind,
          pending,
          committed,
          callback_handoff?
        )

      {:ok, events,
       %{
         "status" =>
           if(callback_handoff?,
             do: "running",
             else: SalixAgent.AsyncToolResults.status(committed)
           ),
         "tool_call_id" => tool_call_id
       }, pending, result}
    end
  end

  # FORMAL-SPEC: tla/salix/InternalAsyncResultProjection.tla. For an oversized
  # internal async result, WorkspaceEvents first owns the stable source/ref;
  # the returned event list publishes source + terminal + capsule in one
  # Session CAS, and recovered_internal_events/2 reuses that exact identity.
  def commit_async(agent_id, session_id, runtime_kind, pending, result) do
    result =
      result
      |> Map.put_new(:id, pending.tool_call_id)
      |> VisibleReplyPolicy.inherit_result_origin(pending)
      |> drop_policy_transition_fields()
      |> VisibleReplyPolicy.label_result()

    observed_result = result

    with {:ok, result} <-
           prepare_async_tool_result_projection(
             agent_id,
             session_id,
             runtime_kind,
             pending,
             result
           ),
         stored = SalixAgent.Tools.strip_deferred_tool_observations(result),
         :ok <- validate_result(result),
         {:ok, committed} <-
           SalixAgent.WorkspaceEvents.commit_result(
             agent_id,
             session_id,
             stored,
             SalixAgent.AsyncToolResults.operation_source(runtime_kind),
             store_result: true
           ),
         callback_handoff? = external_callback_handoff?(committed),
         {:ok, events} <-
           committed_async_events(
             agent_id,
             session_id,
             runtime_kind,
             pending,
             committed,
             callback_handoff?
           ) do
      events =
        maybe_append_provider_reply_resolution(
          events,
          runtime_kind,
          pending,
          committed,
          callback_handoff?
        )

      {:ok, events, observed_result}
    end
  end

  @doc false
  # Mutation-free results and their content share the Session terminal CAS.
  # Actual workspace mutations retain their durable operation receipt, which
  # must complete before the Session terminal can become authoritative.
  def prepare_internal_async_commit(
        agent_id,
        session_id,
        pending,
        result,
        session
      )
      when InternalSession.is_session(session) do
    result =
      result
      |> Map.put_new(:id, pending.tool_call_id)
      |> VisibleReplyPolicy.inherit_result_origin(pending)
      |> drop_policy_transition_fields()
      |> VisibleReplyPolicy.label_result()

    observed_result = result

    with {:ok, result} <- prepare_async_tool_result_projection(session, pending, result),
         stored = SalixAgent.Tools.strip_deferred_tool_observations(result),
         :ok <- validate_result(result),
         {:ok, committed, workspace_commit} <-
           SalixAgent.WorkspaceEvents.prepare_result_commit(
             agent_id,
             session_id,
             stored,
             SalixAgent.AsyncToolResults.operation_source(:internal),
             store_result: true,
             session_result: not external_callback_handoff?(stored),
             billing_context: value(pending, "billing_context") || %{},
             entrypoint: "storage_write",
             actor_type: value(pending, "actor_type") || "tool"
           ),
         callback_handoff? = external_callback_handoff?(committed),
         {:ok, events} <-
           committed_internal_async_events(
             session,
             pending,
             committed,
             callback_handoff?
           ) do
      events =
        maybe_append_provider_reply_resolution(
          events,
          :internal,
          pending,
          committed,
          callback_handoff?
        )

      events =
        SalixAgent.TerminalReply.settle(session, pending, observed_result, events) ||
          SalixAgent.TerminalReply.settle_onboarding_async(
            session,
            pending,
            observed_result,
            events
          ) || events

      events = List.wrap(pending[:round_progress_event]) ++ events

      {:ok, events, observed_result, workspace_commit}
    end
  end

  def emit_result(result), do: SalixAgent.Tools.emit_deferred_tool_observations([result])

  @doc false
  def recovered_internal_events(pending, result) when is_map(pending) and is_map(result) do
    callback_handoff? = external_callback_handoff?(result)

    events =
      cond do
        callback_handoff? and direct_poll_owned?(:internal, pending) ->
          direct_poll_handoff_events(pending, result)

        callback_handoff? ->
          callback_handoff_events(:internal, pending, result)

        direct_poll_owned?(:internal, pending) ->
          SalixAgent.AsyncToolResults.internal_poll_events(pending, result)

        true ->
          recovered_internal_terminal_events(pending, result)
      end

    maybe_append_provider_reply_resolution(
      events,
      :internal,
      pending,
      result,
      callback_handoff?
    )
  end

  def recovered_internal_events(pending, result, session) do
    events = recovered_internal_events(pending, result)

    SalixAgent.TerminalReply.settle(session, pending, result, events) ||
      SalixAgent.TerminalReply.settle_onboarding_async(session, pending, result, events) || events
  end

  defp prepare_async_tool_result_projection(
         _agent_id,
         _session_id,
         runtime_kind,
         _pending,
         result
       )
       when runtime_kind != :internal do
    {:ok, drop_tool_result_projection(result)}
  end

  defp prepare_async_tool_result_projection(agent_id, session_id, :internal, pending, result) do
    cond do
      valid_tool_result_projection?(result) ->
        {:ok, result}

      value(pending, "tool_name") == @reader_tool ->
        {:ok, drop_tool_result_projection(result)}

      direct_poll_owned?(:internal, pending) or external_callback_handoff?(result) ->
        {:ok, drop_tool_result_projection(result)}

      true ->
        with {:ok, session} <- InternalSessionStore.read(agent_id, session_id) do
          prepare_async_tool_result_projection(session, pending, result)
        end
    end
  end

  defp prepare_async_tool_result_projection(session, pending, result)
       when InternalSession.is_session(session) do
    cond do
      valid_tool_result_projection?(result) ->
        {:ok, result}

      value(pending, "tool_name") == @reader_tool ->
        {:ok, drop_tool_result_projection(result)}

      direct_poll_owned?(:internal, pending) or external_callback_handoff?(result) ->
        {:ok, drop_tool_result_projection(result)}

      true ->
        stored_at_ms = System.system_time(:millisecond)

        events =
          AsyncToolResults.internal_events(
            pending,
            result,
            async_projection_event_opts(
              stored_at_ms,
              %{"result" => AsyncToolResults.stored_result(result)}
            )
          )
          |> internal_visible_reply_policy_events(session, result)

        envelope =
          internal_runtime_message_envelope(session, events, value(pending, "tool_call_id"))

        if encoded_bytes(envelope) > @tool_result_envelope_max_bytes do
          {:ok,
           result
           |> drop_tool_result_projection()
           |> Map.put(@tool_result_projection_key, %{
             "result_ref" => SalixStore.Ids.new_tool_result_ref(),
             "stored_at_ms" => stored_at_ms
           })}
        else
          {:ok, drop_tool_result_projection(result)}
        end
    end
  end

  defp committed_async_events(
         agent_id,
         session_id,
         runtime_kind,
         pending,
         committed,
         callback_handoff?
       ) do
    cond do
      callback_handoff? and direct_poll_owned?(runtime_kind, pending) ->
        {:ok, direct_poll_handoff_events(pending, committed)}

      callback_handoff? ->
        # Zero-wait tool admission makes even quick callback setup run behind
        # a process-local dependency token. Finishing that setup transfers
        # ownership; it is not the business tool's terminal completion.
        {:ok, callback_handoff_events(runtime_kind, pending, committed)}

      direct_poll_owned?(runtime_kind, pending) ->
        # A direct internal caller owns terminal observation through the exact
        # durable tool_call_id. Persist side effects and that terminal, but do
        # not create unsolicited model input or a visible-reply transition.
        {:ok, AsyncToolResults.internal_poll_events(pending, committed)}

      runtime_kind == :internal and value(pending, "tool_name") != @reader_tool and
          valid_tool_result_projection?(committed) ->
        with {:ok, session} <- InternalSessionStore.read(agent_id, session_id),
             {:ok, events} <-
               projected_internal_terminal_events(session, pending, committed) do
          {:ok, events}
        end

      true ->
        {:ok,
         runtime_kind
         |> async_events(pending, committed)
         |> visible_reply_policy_events(agent_id, session_id, runtime_kind, committed)}
    end
  end

  defp committed_internal_async_events(session, pending, committed, callback_handoff?) do
    cond do
      callback_handoff? and direct_poll_owned?(:internal, pending) ->
        {:ok, direct_poll_handoff_events(pending, committed)}

      callback_handoff? ->
        {:ok, callback_handoff_events(:internal, pending, committed)}

      direct_poll_owned?(:internal, pending) ->
        {:ok, AsyncToolResults.internal_poll_events(pending, committed)}

      value(pending, "tool_name") != @reader_tool and
          valid_tool_result_projection?(committed) ->
        projected_internal_terminal_events(session, pending, committed)

      true ->
        {:ok,
         :internal
         |> async_events(pending, committed)
         |> VisibleReplyPolicy.async_completion_events(session, committed)}
    end
  end

  defp projected_internal_terminal_events(session, pending, result) do
    with {:ok, projection} <- tool_result_projection(result),
         {:ok, candidate} <-
           ToolResultProjection.prepare(
             value(pending, "tool_name"),
             result,
             projection.result_ref
           ) do
      projected_result = ToolResultProjection.capsule_result(candidate)

      events =
        internal_projection_events(
          InternalSession.session_id(session),
          pending,
          projected_result,
          candidate,
          projection,
          true
        )
        |> internal_visible_reply_policy_events(session, result)

      envelope =
        internal_runtime_message_envelope(
          session,
          events,
          value(pending, "tool_call_id")
        )

      if encoded_bytes(envelope) <= @tool_result_envelope_max_bytes do
        {:ok, events}
      else
        {:error, :async_tool_result_projection_exceeds_budget}
      end
    end
  end

  defp recovered_internal_terminal_events(pending, result) do
    case tool_result_projection(result) do
      {:ok, projection} ->
        with {:ok, candidate} <-
               ToolResultProjection.prepare(
                 value(pending, "tool_name"),
                 result,
                 projection.result_ref
               ) do
          projected_result = ToolResultProjection.capsule_result(candidate)

          internal_projection_events(
            value(pending, "session_id"),
            pending,
            projected_result,
            candidate,
            projection,
            true
          )
        else
          _ -> AsyncToolResults.internal_events(pending, result)
        end

      :none ->
        AsyncToolResults.internal_events(pending, result)
    end
  end

  defp internal_projection_events(
         session_id,
         pending,
         projected_result,
         candidate,
         projection,
         stored?
       ) do
    stored_events =
      if stored? do
        [bind_stored_result_event(candidate, session_id, projection.stored_at_ms)]
      else
        []
      end

    result_payload =
      if stored? do
        ToolResultProjection.capsule(candidate)
      else
        %{"result" => AsyncToolResults.stored_result(projected_result)}
      end

    stored_events ++
      AsyncToolResults.internal_events(
        pending,
        projected_result,
        async_projection_event_opts(projection.stored_at_ms, result_payload)
      )
  end

  defp internal_visible_reply_policy_events(events, session, result) do
    VisibleReplyPolicy.async_completion_events(events, session, result)
  end

  defp internal_runtime_message_envelope(session, events, tool_call_id) do
    projected = InternalSession.apply_events(session, events)
    queue_limit = max(InternalSession.query(projected, :input_queue_length), 1)

    {materialize_events, _wake?, _hwm} =
      InternalSession.materialize_pending_input_events(projected, queue_limit)

    target_runtime_message_id = "tool-call-result:" <> to_string(tool_call_id)

    runtime_message =
      projected
      |> InternalSession.apply_events(drop_trailing_acks(materialize_events))
      |> Compaction.context_where({:runtime_message_id, target_runtime_message_id})
      |> List.first()

    case runtime_message do
      %{} = message ->
        # ImageRefs.inline/2 removes this archive-only pointer immediately
        # before provider dispatch. Size the same final message list.
        [message |> Map.delete(:result_seq) |> Map.delete("result_seq")]

      _ ->
        # Some visible-reply phases intentionally suppress the internal
        # notification. With no provider-facing row, the exact envelope is
        # empty and there is nothing to spill.
        []
    end
  end

  # A trailing queue_ack changes only the queue, the result references and the
  # activity status, and the provider context reads none of them. Applying it
  # would prune references across the whole transcript for a sizing projection.
  defp drop_trailing_acks(events) do
    events
    |> Enum.reverse()
    |> Enum.drop_while(&(is_map(&1) and &1["type"] == "queue_ack"))
    |> Enum.reverse()
  end

  defp async_projection_event_opts(stored_at_ms, result_payload) do
    [
      completed_at_ms: stored_at_ms,
      created_at: div(stored_at_ms, 1_000),
      notification_result_payload: result_payload
    ]
  end

  defp bind_stored_result_event(candidate, session_id, stored_at_ms) do
    candidate
    |> ToolResultProjection.stored_event()
    |> Map.put("session_id", session_id)
    |> Map.put("stored_at_ms", stored_at_ms)
  end

  defp tool_result_projection(result) when is_map(result) do
    case result[@tool_result_projection_key] || result[:_tool_result_projection] do
      %{} = projection ->
        result_ref = projection["result_ref"] || projection[:result_ref]
        stored_at_ms = projection["stored_at_ms"] || projection[:stored_at_ms]

        if SalixStore.Ids.valid_tool_result_ref?(result_ref) and
             is_integer(stored_at_ms) and stored_at_ms >= 0 do
          {:ok, %{result_ref: result_ref, stored_at_ms: stored_at_ms}}
        else
          :none
        end

      _ ->
        :none
    end
  end

  defp tool_result_projection(_result), do: :none

  defp valid_tool_result_projection?(result),
    do: match?({:ok, _projection}, tool_result_projection(result))

  defp drop_tool_result_projection(result) when is_map(result) do
    result
    |> Map.delete(@tool_result_projection_key)
    |> Map.delete(:_tool_result_projection)
  end

  defp encoded_bytes(value), do: value |> Jason.encode!() |> byte_size()

  @doc false
  def callback_handoff_result?(result) when is_map(result),
    do: external_callback_handoff?(result)

  def callback_handoff_result?(_result), do: false

  def emit_async(agent_id, pending, result) do
    deferred = SalixAgent.Tools.deferred_tool_observations(result)
    if deferred != [], do: emit_result(result)

    unless Enum.any?(deferred, &(value(&1, "source_key") == pending.tool_call_id)) do
      attrs =
        pending
        |> Map.take([
          :session_id,
          :tool_call_id,
          :tool_name,
          :call_index,
          :started_at,
          :trace_ctx,
          :tenant_id,
          :group_id,
          :billing_context,
          :actor_type
        ])
        |> Map.merge(%{agent_id: agent_id, async: true})

      SalixAgent.ToolTelemetry.emit_tool_call(result, attrs)
    end
  end

  def emit_surface(agent_id, session_id, tool_call_id, result, meta) do
    attrs =
      %{
        agent_id: agent_id,
        session_id: session_id,
        tool_call_id: tool_call_id,
        tool_name: value(meta, "tool_name"),
        call_index: value(meta, "call_index"),
        started_at: value(meta, "started_at"),
        trace_ctx: value(meta, "trace_ctx"),
        tenant_id: value(meta, "tenant_id"),
        group_id: value(meta, "group_id"),
        billing_context: value(meta, "billing_context") || %{},
        actor_type: value(meta, "actor_type") || "tool",
        async: true
      }
      |> Map.reject(fn {_key, value} -> value in [nil, ""] end)

    SalixAgent.ToolTelemetry.emit_tool_call(result, attrs)
  end

  defp session_context(agent_id, session_id, :external),
    do: ExternalSessionStore.session_context(agent_id, session_id)

  defp session_context(agent_id, session_id, :internal),
    do: InternalSessionStore.read(agent_id, session_id)

  defp tool_context(
         agent_id,
         session_id,
         runtime_kind,
         source_message_ids,
         trusted_origin,
         config,
         context
       ) do
    # The external runtime crosses the same authorization boundary as an
    # internal round, so it carries the same labelled activation
    # (docs/verification.md).
    ifc_mode = SalixAgent.IFC.mode_for(config.tenant_id, config.group_id)

    %{
      agent_id: agent_id,
      session_id: session_id,
      source_message_id: List.last(source_message_ids),
      source_message_ids: source_message_ids,
      trusted_origins: trusted_origins(context, source_message_ids),
      ifc_mode: ifc_mode,
      triage_scopes:
        SalixAgent.IFC.Context.organization_scopes(
          context,
          source_message_ids,
          "triage_investigation"
        ),
      organization_scopes:
        SalixAgent.IFC.Context.organization_scopes(context, source_message_ids),
      ifc:
        ifc_mode != :off &&
          SalixAgent.IFC.Context.build(context,
            source_message_id: List.last(source_message_ids),
            source_message_ids: source_message_ids,
            trusted_origin: trusted_origin
          ),
      tenant_id: config.tenant_id,
      group_id: config.group_id,
      skill_projection_revision: config.skill_projection_revision,
      plugin_projection: config.plugin_projection,
      plugin_projection_revision: config.plugin_projection_revision,
      role: config.role,
      runtime_kind: runtime_kind,
      tool_disclosure: config.tool_disclosure,
      defer_tool_observations: true,
      visible_reply_phase: visible_reply_phase(runtime_kind, context),
      visible_reply_guard: visible_reply_guard(runtime_kind, context)
    }
    |> maybe_put_trusted_origin(trusted_origin)
  end

  defp stamp_direct_poll_ownership(result, pending, :internal) do
    result =
      update_result_events(result, fn
        %{"type" => "async_tool_call_started"} = event ->
          Map.put(event, "completion_owner", @direct_poll_owner)

        event ->
          event
      end)

    pending = Enum.map(pending, &Map.put(&1, :completion_owner, @direct_poll_owner))
    {result, pending}
  end

  defp stamp_direct_poll_ownership(result, pending, _runtime_kind), do: {result, pending}

  defp update_result_events(result, fun) do
    cond do
      is_list(result[:events]) -> Map.update!(result, :events, &Enum.map(&1, fun))
      is_list(result["events"]) -> Map.update!(result, "events", &Enum.map(&1, fun))
      true -> result
    end
  end

  defp trusted_origin(context, source_message_ids) do
    context
    |> trusted_origins(List.wrap(List.last(source_message_ids)))
    |> List.first()
  end

  defp trusted_origins(context, source_message_ids)
       when InternalSession.is_session(context),
       do: InternalSession.query(context, :current_turn_trusted_origins, source_message_ids)

  defp trusted_origins(context, source_message_ids) do
    active = context_value(context, :active_external_trusted_origins) || %{}
    active_origins = Enum.map(source_message_ids, &Map.get(active, &1)) |> Enum.filter(&is_map/1)

    messages =
      case context_value(context, :input_messages) do
        inputs when is_list(inputs) ->
          inputs

        _ ->
          last_ack = context_value(context, :last_ack_message_id) || 0

          context
          |> context_value(:messages)
          |> List.wrap()
          |> Enum.filter(&((value(&1, "id") || 0) > last_ack))
      end

    (active_origins ++
       Enum.flat_map(
         messages,
         &SalixAgent.ToolCallProvenance.message_origins(&1, source_message_ids)
       ))
    |> Enum.uniq()
  end

  defp maybe_put_trusted_origin(context, origin) when is_map(origin),
    do: Map.put(context, :trusted_origin, origin)

  defp maybe_put_trusted_origin(context, _origin), do: context

  defp visible_reply_phase(:internal, context),
    do: InternalSession.visible_reply_phase(context)

  defp visible_reply_phase(_runtime_kind, _context), do: :clean

  defp visible_reply_guard(:internal, context),
    do: InternalSession.visible_reply_guard(context)

  defp visible_reply_guard(_runtime_kind, _context), do: :clean

  defp validate_result(result),
    do: SalixAgent.ToolSideEffects.validate_events(result[:events] || result["events"] || [])

  defp async_events(:external, pending, result),
    do: SalixAgent.AsyncToolResults.external_events(pending, result)

  defp async_events(:internal, pending, result),
    do: SalixAgent.AsyncToolResults.internal_events(pending, result)

  # A process-local start or an external-callback handoff is not a visible
  # response. Resolve only alongside the durable terminal transition, across
  # live completion, surface completion, and crash recovery.
  defp maybe_append_provider_reply_resolution(
         events,
         :internal,
         pending,
         result,
         false
       ) do
    result =
      if value(result, "status") in [nil, ""] do
        Map.put(result, :status, SalixAgent.AsyncToolResults.status(result))
      else
        result
      end

    session_id = value(pending, "session_id")

    events ++
      ProviderReplyObligation.resolution_events(session_id, result, pending) ++
      ProviderReplyObligation.card_obligation_events(session_id, result, pending)
  end

  defp maybe_append_provider_reply_resolution(events, _runtime, _pending, _result, _handoff),
    do: events

  defp direct_poll_owned?(:internal, pending),
    do: value(pending, "completion_owner") == @direct_poll_owner

  defp direct_poll_owned?(_runtime_kind, _pending), do: false

  defp external_callback_handoff?(result) when is_map(result) do
    value(result, "status") == "async_running" and
      Enum.any?(result[:events] || result["events"] || [], fn
        %{"type" => "async_tool_call_started"} -> true
        _event -> false
      end)
  end

  defp callback_handoff_events(runtime_kind, pending, result) do
    side_effects =
      Enum.map(result[:events] || result["events"] || [], fn
        %{"type" => "async_tool_call_started"} = event ->
          SalixAgent.ToolCallProvenance.inherit(event, pending)

        %{"type" => "wait_set", "wait" => wait} = event when is_map(wait) ->
          Map.put(event, "wait", SalixAgent.ToolCallProvenance.inherit(wait, pending))

        event ->
          event
      end)

    notification = callback_handoff_notification(runtime_kind, pending, result)

    case runtime_kind do
      # Modeled in tla/salix/ExternalRuntimeToolWake.tla. The wakeable delivery
      # clears the external session's durable wait. Keep the independently
      # stored status projection in the same transition by journaling that
      # clear explicitly before the notification.
      :external ->
        side_effects ++
          [%{"type" => "wait_clear", "session_id" => value(pending, "session_id")}, notification]

      :internal ->
        side_effects ++ [notification]
    end
  end

  defp direct_poll_handoff_events(pending, result) do
    Enum.map(result[:events] || result["events"] || [], fn
      %{"type" => "async_tool_call_started"} = event ->
        event
        |> Map.put("completion_owner", value(pending, "completion_owner"))
        |> SalixAgent.ToolCallProvenance.inherit(pending)

      %{"type" => "wait_set", "wait" => wait} = event when is_map(wait) ->
        Map.put(event, "wait", SalixAgent.ToolCallProvenance.inherit(wait, pending))

      event ->
        event
    end)
  end

  defp callback_handoff_notification(runtime_kind, pending, result) do
    session_id = value(pending, "session_id")
    tool_call_id = value(pending, "tool_call_id")
    tool_name = value(pending, "tool_name") || value(result, "name")
    runtime_message_id = "tool-call-handoff:" <> tool_call_id

    content =
      %{
        "type" => "tool_call_handoff",
        "tool_call_id" => tool_call_id,
        "tool_name" => tool_name,
        "status" => "running",
        "summary" => "tool setup completed and is awaiting external completion",
        "message" =>
          "tool setup completed after returning early; use the included result and wait for the external callback before treating the call as complete"
      }
      |> Map.merge(
        result
        |> SalixAgent.AsyncToolResults.stored_result()
        |> SalixAgent.AsyncToolResults.notification_result_payload()
      )
      |> Jason.encode!()

    case runtime_kind do
      :internal ->
        %{
          "type" => "queue_append",
          "session_id" => session_id,
          "kind" => "runtime_message",
          "dedupe_key" => runtime_message_id,
          "wake" => true,
          "created_at" => System.system_time(:second),
          "payload" =>
            %{
              "runtime_message_id" => runtime_message_id,
              "type" => "tool_call_handoff",
              "summary" => "tool #{tool_name || "tool"} is awaiting external completion",
              "content" => content,
              "source_tool_call_id" => tool_call_id
            }
            |> SalixAgent.ToolCallProvenance.inherit(pending)
        }

      :external ->
        %{
          "type" => "delivery",
          "session_id" => session_id,
          "source_message_id" => runtime_message_id,
          "role" => "runtime",
          "kind" => "runtime_message",
          "runtime_message_id" => runtime_message_id,
          "runtime_message_type" => "tool_call_handoff",
          "source_tool_call_id" => tool_call_id,
          "summary" => "tool #{tool_name || "tool"} is awaiting external completion",
          "content" => content,
          "created_at" => System.system_time(:second)
        }
        |> put_optional(
          "trusted_origin",
          value(pending, "trusted_origin")
        )
        |> put_optional("trusted_origins", value(pending, "trusted_origins"))
        |> put_optional(
          "trusted_origin_source_message_ids",
          value(pending, "trusted_origin_source_message_ids")
        )
    end
  end

  defp visible_reply_policy_events(events, _agent_id, _session_id, runtime_kind, _result)
       when runtime_kind != :internal,
       do: events

  defp visible_reply_policy_events(events, agent_id, session_id, :internal, result) do
    case InternalSessionStore.read(agent_id, session_id) do
      {:ok, session} ->
        VisibleReplyPolicy.async_completion_events(events, session, result)

      {:error, _reason} ->
        Enum.reject(events, &runtime_notification?/1)
    end
  end

  defp runtime_notification?(%{"type" => "queue_append", "kind" => "runtime_message"}),
    do: true

  defp runtime_notification?(_event), do: false

  defp operation_source(:external, suffix), do: "external-" <> suffix
  defp operation_source(:internal, suffix), do: suffix

  defp normalize_surface_result(result, tool_call_id, meta) do
    result = Map.delete(result, :__struct__)
    tool_name = value(meta, "tool_name") || value(result, "name")

    result
    |> Map.put(:id, tool_call_id)
    |> maybe_put_tool_name(tool_name)
  end

  defp maybe_put_tool_name(result, tool_name) when is_binary(tool_name) and tool_name != "" do
    result |> Map.put_new(:name, tool_name) |> Map.put_new("name", tool_name)
  end

  defp maybe_put_tool_name(result, _tool_name), do: result

  defp drop_policy_transition_fields(result) when is_map(result),
    do: result |> Map.delete(:repair_outcome) |> Map.delete("repair_outcome")

  defp context_value(context, key) when InternalSession.is_session(context),
    do: InternalSession.get(context, key)

  defp context_value(context, key) when is_map(context),
    do: Map.get(context, key) || Map.get(context, to_string(key))

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  defp value(_map, _key), do: nil

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, _key, ""), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp normalize_source_ids(ids),
    do: ids |> List.wrap() |> Enum.filter(&(is_binary(&1) and &1 != "")) |> Enum.uniq()

  defp random_id, do: :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
end
