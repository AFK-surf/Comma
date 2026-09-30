defmodule SalixVerifiedKernel.Native do
  @moduledoc false
  @on_load :load_nif

  def load_nif do
    path = :filename.join(:code.priv_dir(:salix_verified_kernel), ~c"verified_kernel")
    :erlang.load_nif(path, 0)
  end

  def invoke_etf(_bytes), do: :erlang.nif_error(:not_loaded)

  @doc """
  Runs one Session request against the resident state referenced by the first
  argument (`nil` when there is none). Returns `{resident | nil, response}`.
  The resident state never crosses the boundary as data.
  """
  def session(_resident, _bytes), do: :erlang.nif_error(:not_loaded)

  # `SalixVerifiedKernel.Terminal`: a resident terminal emulator state.
  def terminal_new(_cols, _rows), do: :erlang.nif_error(:not_loaded)
  def terminal_feed(_terminal, _bytes), do: :erlang.nif_error(:not_loaded)
  def terminal_resize(_terminal, _cols, _rows), do: :erlang.nif_error(:not_loaded)
  def terminal_snapshot(_terminal), do: :erlang.nif_error(:not_loaded)
  def terminal_app_cursor(_terminal), do: :erlang.nif_error(:not_loaded)
end

defmodule SalixVerifiedKernel do
  @moduledoc """
  ETF transport for the verified kernel. The versioned envelope selects a domain
  and operation. C copies bytes; Lean owns domain transitions. Session states
  stay resident in the Lean heap and cross the boundary by reference.
  """

  # Lean may emit these atoms without receiving them in the input envelope.
  @protocol_atoms [
    :accepted_input,
    # The agent loop (`loop_step`): effects, notices, facts and outcomes.
    :notify,
    :commit,
    :stop,
    :continue,
    :hwm,
    :build_record,
    :run_tools,
    :store_results,
    :commit_planned_results,
    :meter,
    :steered,
    :draft,
    :cancel,
    :cancel_unless_source_send,
    :report,
    :activity,
    :idle,
    :idle_unscoped,
    :llm_failed,
    :tool_calls_started,
    :telemetry,
    :finalize,
    :response_commit,
    :tool_commit,
    :boundary,
    :guard_parked,
    :llm_parked,
    :timers,
    :observations,
    :effect,
    :other,
    :error,
    :guard_failure_parked,
    :guard_failure_foreign_running_work,
    :context_overflow,
    :round_boundary,
    :async_tools_started,
    :committed,
    :ignored,
    :fact,
    :canonical_router,
    :delegates_busy,
    :write,
    :materialize,
    :until_wake,
    :expire,
    :run,
    :set_timer,
    :cancel_timer,
    :wait_for,
    :retry,
    :wait_extended,
    :id,
    :name,
    :args,
    :content,
    :runtime_failure_reply,
    :invalid_tool_side_effect_event,
    :not_a_list,
    :not_a_map,
    :nothing_to_archive,
    :advance,
    :read_segment,
    :create_segment,
    :segment_encode_failed,
    :segment_read_failed,
    :segment_write_failed,
    :deterministic_etf,
    :segment_divergence,
    :archive_ahead,
    :request_batch,
    :request_image,
    :request_result,
    :user_attachment,
    :provider_attachment,
    :image_read,
    :native_content_trusted,
    :protocol,
    :model,
    :api_key,
    :auth_token,
    :base_url,
    :max_tokens,
    :prompt_caching,
    :store,
    :include,
    :context_management,
    :reasoning,
    :thinking,
    :response_format,
    :prompt_cache_key,
    :default_headers,
    :first_event,
    :streaming,
    :transient,
    :opened,
    :text,
    :tool,
    :private_reasoning,
    :public_summary,
    :index,
    :fragment,
    :session_active,
    :no_new_live_messages,
    :visible_reply_repair_required,
    :staged_async_result_read_failed,
    :llm_activation_retry_base_ms,
    :check_progress,
    :onboarding?,
    :provider_reply_obligation_rejection,
    :not_scheduled_task_failure,
    :keep,
    :final,
    :assistant,
    :replace_calls,
    :wait,
    :time,
    :resume,
    :salix_agent,
    :valid_response_identity?,
    :valid_terminal_scope?,
    :repair_budget,
    :target_tool,
    :label_results,
    :stamp_result_origin,
    :inherit_result_origin,
    :pending_origin_patch,
    :visible_reply_origin,
    :sanitize_activity_calls,
    :append_repair_reminder,
    :role,
    :report,
    :llm_failed,
    :outcome,
    :effects,
    :activation_scope_missing,
    :activation_scope_mismatch,
    :activation_required,
    :session_busy,
    :session_waiting,
    :session_has_background_tool_work,
    :visible_reply_repair_exhausted,
    :activate,
    :append,
    :authorization,
    :check_router,
    :committed,
    :expire,
    :fallback,
    false,
    :hwm,
    :interrupted,
    :invalid_response_identity,
    :label_result,
    :log,
    :materialize,
    :model_only_result?,
    :no_tool_transition,
    :private_result?,
    :recover,
    :repair_origin?,
    :repair_required?,
    :resume_stable_input,
    :round_pre_llm,
    :run,
    :runtime,
    :sanitize_context,
    :transition,
    :transition_events,
    true,
    :unrepaired_active_round,
    :user,
    :user_reportable_result?,
    :visible_reply_scope,
    :yield,
    :return,
    :perform,
    :write,
    :on_conflict,
    :invalid_session_log_role,
    :checkpoint,
    :action,
    :stage,
    :settled,
    :visible_reply_append_retry,
    :completion_readback,
    :llm_handoff,
    :settlement,
    :workspace,
    :notify,
    :draft_clear,
    :random,
    :authorize,
    :visible_reply_authorization_retry,
    :visible_reply_pre_llm_error,
    :round_status_activation,
    :accept,
    :duplicate,
    :saturated,
    :replaced_scope,
    :retired_scope,
    :visible_reply_scope_changed,
    :window_seq_gap,
    :stale_compaction_snapshot,
    :stale_compaction_view,
    :expected_storage_format,
    :actual_storage_format,
    :expected_summary_sequence,
    :actual_summary_sequence,
    :expected_compacted_through,
    :actual_compacted_through,
    :agent_loop,
    :ready,
    :await_intent,
    :await_tools,
    :await_results,
    :settled,
    :commit_intent,
    :execute_tools,
    :commit_results,
    :continue,
    :stop,
    :ignore,
    :park,
    :terminal_reply,
    :contained_failure,
    :repair_exhausted,
    :async_pause,
    :round_boundary,
    :pause,
    :process,
    :running,
    :retained,
    :retired,
    :accept_result,
    :accept_timeout,
    :accept_down,
    :initial,
    :retry,
    :exhausted,
    :"Elixir.MapSet",
    :"Elixir.SalixIFC.Activation",
    :"Elixir.SalixIFC.Effect",
    :"Elixir.SalixIFC.Evidence",
    :"Elixir.SalixIFC.Facts",
    :"Elixir.SalixIFC.Item",
    :"Elixir.SalixIFC.Label",
    :"Elixir.SalixIFC.Policy",
    :"Elixir.SalixIFC.Reason",
    :"Elixir.SalixIFC.Receipt",
    :__struct__,
    :activation,
    :activation_valid,
    :agent,
    :agent_private,
    :allow,
    :allow_public_sources_only,
    :any,
    :api_key,
    :as_internal,
    :atom_connect,
    :atom_kind,
    :atom_subset,
    :atom_valid,
    :atoms,
    :clause,
    :command,
    :compaction_label,
    :consume,
    :context,
    :comma_user,
    :data,
    :decide,
    :deny,
    :destination,
    :detail,
    :direct,
    :duplicate_item_ref,
    :effect,
    :effect_valid,
    :error,
    :external,
    :external_principal_denied,
    :facts,
    :facts_external,
    :facts_member,
    :facts_members,
    :facts_membership,
    :facts_placement,
    :facts_revision,
    :facts_scope_kind,
    :facts_within,
    false,
    :flow,
    :flow_denied,
    :in_place,
    :in_place_and_receipt,
    :instruction,
    :internal,
    :invalid_input,
    :item_valid,
    :items,
    :label_atoms,
    :label_bottom,
    :label_equal,
    :label_join,
    :label_join_all,
    :label_new,
    :label_no_human,
    :label_public,
    :label_restricted,
    :label_runtime_only,
    :map,
    :members,
    :membership_revisions,
    :membership_unknown,
    :never,
    :none,
    :ok,
    :own_thread_only,
    :policy_in_place,
    :policy_instruction,
    :policy_receipt,
    :principal_authority,
    :principal_connect,
    :principal_valid,
    :provider_user,
    :public,
    :public_egress_denied,
    :reader,
    :reader_atom,
    :readers_subset,
    :receipt,
    :receipt_already_used,
    :receipt_covers,
    :receipt_only,
    :receipt_valid_at,
    :receipt_unavailable,
    :ref,
    :request,
    :request_not_command,
    :request_outside_activation,
    :request_principal_mismatch,
    :request_without_principal,
    :requester,
    :room,
    :schedule,
    :scope,
    :sealed,
    :shared,
    :source_failures,
    :sources,
    :space,
    :system,
    true,
    :trust_requester_instruction,
    :unknown,
    :unknown_request_ref,
    :unknown_source_ref,
    :writer_not_authorized,
    :writers_unknown,
    :"Elixir.SalixAgent.InternalSession.State",
    :opened,
    # State envelope fields minted by `new` and `fork`.
    :activity_revision,
    :agent_id,
    :archive_chunks,
    :archived_through,
    :async_result_refs,
    :async_results,
    :async_tool_calls,
    :billing_context,
    :compact_results,
    :compacted_seq,
    :compacted_through,
    :compaction_failure,
    :context_provider_states,
    :conversation_source,
    :conversation_sources,
    :conversation_source_gap,
    :events,
    :flush_id,
    :fork_request_id,
    :hidden,
    :input_dedupe,
    :input_queue,
    :input_round_streak,
    :last_ack_message_id,
    :last_activity_at,
    :last_compaction_recovery,
    :last_seq,
    :live_context_bytes,
    :context_overflow_recovery,
    :messages,
    :name,
    :next_message_id,
    :next_queue_id,
    :platform,
    :provider_compaction,
    :provider_reply_obligations,
    :queue_ack_id,
    :redactions,
    :repeated_tool_result_streak,
    :runaway_unsettled_streak,
    :runtime_epoch,
    :runtime_node,
    :segment_catalog,
    :source_agent_id,
    :source_schedule_id,
    :source_session_id,
    :storage_revision,
    :summary_sequence,
    :system_prompt,
    :task_origin,
    :terminal_reply_ack_hwm,
    :runtime_failure_reply,
    :visible_reply_activation_scope,
    :visible_reply_egress_facts,
    :visible_reply_intent,
    :work_index_reasons,
    :work_index_token,
    :value,
    :failed,
    :lifecycle,
    :query,
    :op,
    :comma_internal_session,
    :invalid_snapshot,
    :unsupported_storage_format,
    :fork_cutoff_below_compaction,
    :legacy_normalization_failed,
    :duplicate_legacy_seq,
    :missing_legacy_reference,
    :queued,
    :stopped,
    :clean,
    :repair_required,
    :repair_exhausted,
    :required,
    :completed,
    :archived,
    :invalid_wait,
    :compaction_threshold,
    :session_input_queue_limit,
    :visible_reply_repair_budget,
    :external_callback_tool_call,
    :process_local_background_tool_run,
    :active,
    :active_source_message_ids,
    :activity,
    :activity_status,
    :activity_status_updated_at,
    :already_resolved,
    :archived,
    :args,
    :argument,
    :badarg,
    :badarith,
    :badkey,
    :badmap,
    :cache_read_input_tokens,
    :cache_write_input_tokens,
    :cas,
    :case_clause,
    :codec,
    :commit_indeterminate,
    :completed_at,
    :config,
    :content,
    :content_kind,
    :created_at,
    :deadline_ms,
    :dedupe_key,
    :delivered_at_ms,
    :diagnostic_visibility,
    :do_not_send_to_llm,
    :done,
    :duration_ms,
    :elapsed_ms,
    :enum_filter_tail,
    :enum_map_tail,
    :enum_reduce_tail,
    :error_class,
    :error_message,
    :execution,
    :execution_timing,
    :failed,
    :failed_llm_call,
    :failed_tool_calls,
    :function_clause,
    :guidance_reason,
    :id,
    :idempotency_key,
    :idle,
    :ifc,
    :input,
    :input_time,
    :input_tokens,
    :invalid_observation,
    :invalid_host_event,
    :loop_order,
    :round_order,
    :invalid_session_id,
    :invalid_session_snapshot,
    :session_agent_id_mismatch,
    :session_id_mismatch,
    :session_key_mismatch,
    :invalid_term,
    :invalid_term_depth,
    :kind,
    :llm_failure_activation_cap,
    :llm_failure_streak,
    :message_id,
    :messaging,
    :model,
    nil,
    :no_wake,
    :not_found,
    :not_scheduled,
    :observe,
    :observe_time,
    :output,
    :output_tokens,
    :overdue_ms,
    :paused,
    :pending,
    :pending_external_callback_tool_calls,
    :provider_meta,
    :public_summary,
    :queue_id,
    :raised,
    :reason,
    :reduce,
    :repair_outcome,
    :repeated_tool_result_cap,
    :request_compacted_through,
    :request_id,
    :request_input_through,
    :request_summary_sequence,
    :response_identity,
    :result_ref,
    :result_seq,
    :resume,
    :retryable,
    :role,
    :round_id,
    :roundtrip,
    :runaway_unsettled_round_cap,
    :runtime_message_id,
    :salix_agent,
    :schema,
    :scheduled,
    :seq,
    :session,
    :session_id,
    :source,
    :source_call,
    :source_message_id,
    :source_message_ids,
    :source_refs,
    :source_tool_call_id,
    :started_at,
    :status,
    :step,
    :storage_format,
    :summary,
    :thinking,
    :time,
    :timeout_seconds,
    :tool_call_id,
    :tool_call_ids,
    :tool_calls,
    :tool_name,
    :trace_id,
    :transcript_hwm,
    :transfer_start,
    :transfer_resume,
    :trusted_attachment_refs,
    :trusted_origin,
    :trusted_origin_source_message_ids,
    :trusted_origins,
    :turn_id,
    :type,
    :visible_reply_origin,
    :visible_reply_phase,
    :visible_reply_repair,
    :wait,
    :wait_id,
    :waiting,
    :wire,
    # Historical Session ETF snapshots retain this atom, without an execution path.
    :workflow_context
  ]

  # Every identifier-shaped string literal of the Lean runtime. The runtime
  # writes atoms from these literals, directly (`a "x"`) or through helpers
  # that take a string (`fail "x"`, `notify "x"`). Responses decode with
  # `:safe`, which rejects an atom the VM does not know, so a host that loads
  # only this application must know them all. The set is static and bounded.
  # An atom the runtime builds from an input key is written only when the
  # input already carried that atom.
  @lean_sources Path.wildcard(Path.join(__DIR__, "../runtime/VerifiedKernel/**/*.lean"))
  for source <- @lean_sources, do: @external_resource(source)

  if @lean_sources == [] do
    raise "the Lean runtime sources are missing; they name the atoms the kernel writes"
  end

  @lean_atoms for source <- @lean_sources,
                  [_, name] <- Regex.scan(~r/"([A-Za-z_][A-Za-z0-9_?!.]*)"/, File.read!(source)),
                  uniq: true,
                  do: String.to_atom(name)

  # An exported literal keeps these atoms in the loaded BEAM module even when
  # compiler optimization removes unused expressions.
  @doc false
  def protocol_atoms, do: @protocol_atoms

  @doc false
  def lean_atoms, do: @lean_atoms

  def invoke(domain, operation, payload) when is_atom(domain) and is_atom(operation) do
    bytes = :erlang.term_to_binary({1, domain, 1, operation, payload}, minor_version: 2)
    response = SalixVerifiedKernel.Native.invoke_etf(bytes)
    decode_response(response)
  end

  @doc false
  def invoke_session(resident, operation, payload) when is_atom(operation) do
    bytes = :erlang.term_to_binary({1, :session, 1, operation, payload}, minor_version: 2)
    {next, response} = SalixVerifiedKernel.Native.session(resident, bytes)

    case decode_response(response) do
      {:ok, result} -> {:ok, next, result}
      error -> error
    end
  end

  @doc false
  def invoke_provider_stream(resident, operation, payload) do
    bytes = :erlang.term_to_binary({1, :provider, 1, operation, payload}, minor_version: 2)
    {next, response} = SalixVerifiedKernel.Native.session(resident, bytes)
    {next, decode_response(response)}
  end

  @doc false
  def invoke_session_archive(resident, operation, payload) do
    bytes = :erlang.term_to_binary({1, :session_archive, 1, operation, payload}, minor_version: 2)
    {next, response} = SalixVerifiedKernel.Native.session(resident, bytes)

    case decode_response(response) do
      {:ok, result} -> {:ok, next, result}
      error -> error
    end
  end

  @doc false
  def invoke_session_commit(resident, operation, payload) do
    bytes = :erlang.term_to_binary({1, :session_commit, 1, operation, payload}, minor_version: 2)
    {next, response} = SalixVerifiedKernel.Native.session(resident, bytes)

    case decode_response(response) do
      {:ok, result} -> {:ok, next, result}
      error -> error
    end
  end

  @doc false
  def invoke_session_batch(resident, operation, payload) do
    bytes = :erlang.term_to_binary({1, :session_batch, 1, operation, payload}, minor_version: 2)
    {next, response} = SalixVerifiedKernel.Native.session(resident, bytes)

    case decode_response(response) do
      {:ok, result} -> {:ok, next, result}
      error -> error
    end
  end

  @doc false
  def invoke_session_pending(resident, operation, payload) do
    bytes = :erlang.term_to_binary({1, :session_pending, 1, operation, payload}, minor_version: 2)
    {next, response} = SalixVerifiedKernel.Native.session(resident, bytes)

    case decode_response(response) do
      {:ok, result} -> {:ok, next, result}
      error -> error
    end
  end

  @doc false
  def invoke_session_fence(resident, operation, payload) do
    bytes = :erlang.term_to_binary({1, :session_fence, 1, operation, payload}, minor_version: 2)
    {next, response} = SalixVerifiedKernel.Native.session(resident, bytes)

    case decode_response(response) do
      {:ok, result} -> {:ok, next, result}
      error -> error
    end
  end

  @doc false
  def invoke_session_revision(resident, operation, payload) do
    bytes =
      :erlang.term_to_binary({1, :session_revision, 1, operation, payload}, minor_version: 2)

    {next, response} = SalixVerifiedKernel.Native.session(resident, bytes)

    case decode_response(response) do
      {:ok, result} -> {:ok, next, result}
      error -> error
    end
  end

  @doc false
  def invoke_session_read(resident, operation, payload) do
    bytes = :erlang.term_to_binary({1, :session_read, 1, operation, payload}, minor_version: 2)
    {next, response} = SalixVerifiedKernel.Native.session(resident, bytes)

    case decode_response(response) do
      {:ok, result} -> {:ok, next, result}
      error -> error
    end
  end

  @doc false
  def invoke_session_command_driver(resident, operation, payload) do
    bytes =
      :erlang.term_to_binary({1, :session_command_driver, 1, operation, payload},
        minor_version: 2
      )

    {next, response} = SalixVerifiedKernel.Native.session(resident, bytes)

    case decode_response(response) do
      {:ok, result} -> {:ok, next, result}
      error -> error
    end
  end

  defp decode_response(response) do
    {term, used} = :erlang.binary_to_term(response, [:safe, :used])

    if used != byte_size(response), do: raise(ArgumentError, "kernel returned trailing bytes")

    case term do
      {1, :ok, result} -> {:ok, result}
      {1, :error, owner, code} -> {:error, owner, code}
      _ -> raise "invalid kernel response"
    end
  end
end

defmodule SalixVerifiedKernel.Session do
  @moduledoc """
  Session operations over the explicit pure-data schema. The caller supplies
  clock and configuration observations. Custom Elixir protocols are not called.

  The Session state is resident in the kernel. `open/1`, `new/3`, and `load/1`
  admit a state once; `step/2`, `resume/2`, `lifecycle/3`, and `query/3` work
  by reference; `persist/1` and `export/1` return data. A continuation token
  holds a reference to the resident state and only data otherwise, so
  observations never copy the state.

  `step/2` also accepts a state map for one transition and returns the next
  state as data; that form opens and exports around a single transition.
  """

  @typedoc "A reference to a Session state resident in the kernel."
  @type handle :: {:verified_kernel, 1, :session_state, reference()}

  @typedoc "A pending observation over a resident state."
  @type token :: {:verified_kernel, 1, :session, reference(), term(), :resident | :state}

  @type outcome(next) ::
          {:done, next}
          | {:observe_time, token()}
          | {:observe_config, atom(), atom(), term(), token()}

  defguard is_handle(value)
           when is_tuple(value) and tuple_size(value) == 4 and elem(value, 0) == :verified_kernel and
                  elem(value, 2) == :session_state

  @doc "Admits a Session state into the kernel, as given, and returns its handle."
  @spec open(map()) :: handle()
  def open(state) when is_map(state) do
    {:ok, resident, :opened} = drive(nil, :open, state)
    handle(resident)
  end

  @doc "Returns the resident Session state as data. For tests and one-off tools."
  @spec export(handle()) :: map()
  def export({:verified_kernel, 1, :session_state, resident}) do
    {:ok, _resident, state} = drive(resident, :export, nil)
    state
  end

  @doc "`State.new/3`: a normalized fresh session."
  @spec new(String.t(), String.t(), map()) :: handle()
  def new(agent_id, session_id, attrs \\ %{}) when is_map(attrs) do
    {:done, handle} =
      settle(nil |> drive(:new, {{agent_id, session_id, attrs}, prelude()}) |> outcome(:resident))

    handle
  end

  @doc "Admits stored snapshot bytes exactly as written, without normalization."
  @spec admit(binary()) :: {:ok, handle()} | {:error, :invalid_snapshot}
  def admit(bytes) when is_binary(bytes) do
    case settle(nil |> drive(:admit, bytes) |> outcome(:resident)) do
      {:done, handle} -> {:ok, handle}
      {:failed, reason} -> {:error, reason}
    end
  end

  @doc "Admits a stored snapshot (ETF bytes, already decompressed) and normalizes it."
  @spec load(binary()) :: {:ok, handle()} | {:error, :invalid_snapshot}
  def load(bytes) when is_binary(bytes) do
    case settle(nil |> drive(:load, {bytes, prelude()}) |> outcome(:resident)) do
      {:done, handle} -> {:ok, handle}
      {:failed, reason} -> {:error, reason}
    end
  end

  @doc "The snapshot ETF bytes of the persistable state, `{:comma_internal_session, 3, state}`."
  @spec persist(handle()) :: binary()
  def persist({:verified_kernel, 1, :session_state, resident}) do
    {:ok, _resident, bytes} = drive(resident, :persist, nil)
    bytes
  end

  @doc """
  Runs a lifecycle operation (`:normalize`, `:prepare_write`, `:fork`) over the
  resident state. `{:ok, handle}` on success, `{:error, reason}` when the
  operation reports a failure.
  """
  @spec lifecycle(handle(), atom(), term()) :: {:ok, handle()} | {:error, term()}
  def lifecycle({:verified_kernel, 1, :session_state, resident}, name, args \\ nil)
      when is_atom(name) do
    case settle(resident |> drive(:lifecycle, {name, args, prelude()}) |> outcome(:resident)) do
      {:done, handle} -> {:ok, handle}
      {:failed, reason} -> {:error, reason}
    end
  end

  @doc "Runs a query over the resident state and returns its value."
  @spec query(handle(), atom(), term()) :: term()
  def query({:verified_kernel, 1, :session_state, resident}, name, args \\ nil)
      when is_atom(name) do
    {:value, value} =
      settle(resident |> drive(:query, {name, args, prelude()}) |> outcome(:resident))

    value
  end

  @doc "Runs a resident query with a request-local external data reader."
  def query({:verified_kernel, 1, :session_state, resident}, name, args, read)
      when is_atom(name) and is_function(read, 1) do
    query_result(drive(resident, :query, {name, args, prelude()}), read)
  end

  @doc false
  def archive_publication({:verified_kernel, 1, :session_state, resident}, line, io) do
    archive_result(SalixVerifiedKernel.invoke_session_archive(resident, :start, line), io)
  end

  @doc false
  def start_storage_commit({:verified_kernel, 1, :session_state, resident}, key, base) do
    case SalixVerifiedKernel.invoke_session_commit(resident, :start, {key, base}) do
      {:ok, cursor, {:cas, _, _, _} = request} ->
        {{:verified_kernel, 1, :storage_commit, cursor}, request}

      {:ok, _cursor, {:error, reason}} ->
        raise_kernel(reason)
    end
  end

  @doc false
  def resume_storage_commit({:verified_kernel, 1, :storage_commit, cursor}, result) do
    {:ok, _state, response} = SalixVerifiedKernel.invoke_session_commit(cursor, :resume, result)
    response
  end

  @doc false
  def apply_batch(session, events, report \\ fn _, _ -> :ok end)
  def apply_batch(session, [], _report), do: session

  def apply_batch({:verified_kernel, 1, :session_state, resident}, events, report)
      when is_list(events) and is_function(report, 2) do
    invoke = &SalixVerifiedKernel.invoke_session_batch/3
    invoke.(resident, :start, events) |> batch_next(report, invoke) |> handle()
  end

  @doc false
  def start_pending_revision({:verified_kernel, 1, :session_state, resident}, etag) do
    {:ok, pending, {:done}} = SalixVerifiedKernel.invoke_session_pending(resident, :init, etag)
    {:verified_kernel, 1, :pending_revision, pending}
  end

  @doc false
  def start_revision({:verified_kernel, 1, :session_state, resident}, etag) do
    operation = if is_nil(etag), do: :fresh, else: :init

    {:ok, cursor, {:done}} =
      SalixVerifiedKernel.invoke_session_revision(resident, operation, etag)

    {:verified_kernel, 1, :session_revision, cursor}
  end

  @doc false
  def read_revision(agent_id, session_id, read) when is_function(read, 2) do
    SalixVerifiedKernel.invoke_session_read(nil, :start, {agent_id, session_id})
    |> read_revision_result(read)
  end

  defp read_revision_result({:ok, cursor, {:read, key}}, read) do
    read.(key, fn result ->
      SalixVerifiedKernel.invoke_session_read(cursor, :read_result, {result, prelude()})
      |> read_revision_result(read)
    end)
  end

  defp read_revision_result({:ok, cursor, {:observe, :time}}, read) do
    SalixVerifiedKernel.invoke_session_read(
      cursor,
      :resume,
      {:observed_time, System.system_time(:millisecond)}
    )
    |> read_revision_result(read)
  end

  defp read_revision_result({:ok, cursor, {:observe, {:config, app, key, default}}}, read) do
    SalixVerifiedKernel.invoke_session_read(
      cursor,
      :resume,
      {:observed_config, Application.get_env(app, key, default)}
    )
    |> read_revision_result(read)
  end

  defp read_revision_result({:ok, cursor, {:loaded}}, _read),
    do: {:ok, {:verified_kernel, 1, :session_revision, cursor}}

  defp read_revision_result({:ok, _cursor, {:error, reason}}, _read), do: {:error, reason}

  @doc false
  def revision_view({:verified_kernel, 1, :session_revision, cursor}) do
    {:ok, state, {:revision, etag, pending}} =
      SalixVerifiedKernel.invoke_session_revision(cursor, :working, nil)

    {handle(state), etag, pending}
  end

  @doc false
  def revision_pending?({:verified_kernel, 1, :session_revision, cursor}) do
    {:ok, _cursor, {:pending, pending}} =
      SalixVerifiedKernel.invoke_session_revision(cursor, :is_pending, nil)

    pending
  end

  @doc false
  def revision_baseline({:verified_kernel, 1, :session_revision, cursor}) do
    {:ok, baseline, {:done}} =
      SalixVerifiedKernel.invoke_session_revision(cursor, :baseline, nil)

    {:verified_kernel, 1, :session_revision, baseline}
  end

  @doc false
  def revision_metadata({:verified_kernel, 1, :session_revision, cursor}) do
    {:ok, _cursor, {:metadata, events, hwm}} =
      SalixVerifiedKernel.invoke_session_revision(cursor, :metadata, nil)

    {events, hwm}
  end

  @doc false
  def write_revision({:verified_kernel, 1, :session_revision, cursor}, events, hwm, report) do
    invoke = &SalixVerifiedKernel.invoke_session_revision/3
    result = invoke.(cursor, :write, {events, hwm})
    {:verified_kernel, 1, :session_revision, batch_next(result, report, invoke)}
  end

  @doc false
  def plan_revision({:verified_kernel, 1, :session_revision, cursor}, mode, report) do
    SalixVerifiedKernel.invoke_session_revision(cursor, :plan, {mode, prelude()})
    |> plan_next(report)
  end

  defp plan_next({:ok, cursor, {:planned, {outcome, changed}}}, _report),
    do: {{:verified_kernel, 1, :session_revision, cursor}, outcome, changed}

  defp plan_next({:ok, _cursor, {:error, reason}}, _report), do: raise_kernel(reason)

  defp plan_next({:ok, cursor, {:next}}, report) do
    cursor
    |> batch_event(report, &SalixVerifiedKernel.invoke_session_revision/3)
    |> plan_next(report)
  end

  defp plan_next(result, report) do
    result
    |> batch_observe(&SalixVerifiedKernel.invoke_session_revision/3)
    |> plan_next(report)
  end

  @doc false
  def start_command(
        {:verified_kernel, 1, :session_revision, cursor},
        command,
        args,
        checkpoint,
        report
      ) do
    SalixVerifiedKernel.invoke_session_command_driver(
      cursor,
      :start,
      {{command, args, checkpoint}, prelude()}
    )
    |> command_next(report)
  end

  @doc false
  def command_step({:verified_kernel, 1, :command_driver, cursor}, operation, result, report) do
    SalixVerifiedKernel.invoke_session_command_driver(cursor, operation, result)
    |> command_next(report)
  end

  @doc false
  def command_revision({:verified_kernel, 1, :command_driver, cursor}) do
    {:ok, revision, {:done}} =
      SalixVerifiedKernel.invoke_session_command_driver(cursor, :revision, nil)

    {:verified_kernel, 1, :session_revision, revision}
  end

  defp command_next({:ok, cursor, {:next}}, report) do
    cursor
    |> batch_event(report, &SalixVerifiedKernel.invoke_session_command_driver/3)
    |> command_next(report)
  end

  defp command_next(result, report) do
    case batch_observe(result, &SalixVerifiedKernel.invoke_session_command_driver/3) do
      {:ok, _cursor, {:next}} = next -> command_next(next, report)
      {:ok, _cursor, {:raised, reason}} -> raise_kernel(reason)
      {:ok, cursor, response} -> {{:verified_kernel, 1, :command_driver, cursor}, response}
    end
  end

  @doc false
  def write_pending_revision(
        {:verified_kernel, 1, :pending_revision, pending},
        events,
        hwm,
        report
      ) do
    invoke = &SalixVerifiedKernel.invoke_session_pending/3
    result = invoke.(pending, :write, {events, hwm})
    {:verified_kernel, 1, :pending_revision, batch_next(result, report, invoke)}
  end

  @doc false
  def pending_working({:verified_kernel, 1, :pending_revision, pending}) do
    {:ok, working, {:done}} = SalixVerifiedKernel.invoke_session_pending(pending, :working, nil)
    handle(working)
  end

  @doc false
  def pending_baseline({:verified_kernel, 1, :pending_revision, pending}) do
    {:ok, baseline, {:baseline, etag}} =
      SalixVerifiedKernel.invoke_session_pending(pending, :baseline, nil)

    {handle(baseline), etag}
  end

  @doc false
  def pending_metadata({:verified_kernel, 1, :pending_revision, pending}) do
    {:ok, _pending, {:metadata, events, hwm}} =
      SalixVerifiedKernel.invoke_session_pending(pending, :metadata, nil)

    {events, hwm}
  end

  @doc false
  def start_revision_fence({:verified_kernel, 1, :command_driver, input}, key) do
    invoke = &SalixVerifiedKernel.invoke_session_command_driver/3

    case input |> invoke.(:fence_start, {key, prelude()}) |> batch_observe(invoke) do
      {:ok, fence, {:prepared}} -> {:ok, {:verified_kernel, 1, :command_driver, fence}}
      {:ok, _fence, {:rejected, reason}} -> {:error, reason}
    end
  end

  def start_revision_fence({:verified_kernel, 1, kind, pending}, key)
      when kind in [:pending_revision, :session_revision] do
    invoke = &SalixVerifiedKernel.invoke_session_fence/3

    case pending |> invoke.(:start, {key, prelude()}) |> batch_observe(invoke) do
      {:ok, fence, {:prepared}} -> {:ok, {:verified_kernel, 1, :revision_fence, fence}}
      {:ok, _fence, {:error, reason}} -> {:error, reason}
    end
  end

  @doc false
  def fence_prepared_state({:verified_kernel, 1, :command_driver, input}) do
    {:ok, state, {:done}} =
      SalixVerifiedKernel.invoke_session_command_driver(input, :fence_view, nil)

    handle(state)
  end

  def fence_prepared_state({:verified_kernel, 1, :revision_fence, fence}) do
    {:ok, state, {:done}} = SalixVerifiedKernel.invoke_session_fence(fence, :view, nil)
    handle(state)
  end

  @doc false
  def stamp_revision_fence({:verified_kernel, 1, kind, fence}, metadata, report)
      when kind in [:revision_fence, :command_driver] do
    invoke = fence_invoke(kind)
    result = invoke.(fence, :stamp, metadata)
    {:verified_kernel, 1, kind, fence_metadata_next(result, report, invoke)}
  end

  defp fence_invoke(:revision_fence), do: &SalixVerifiedKernel.invoke_session_fence/3
  defp fence_invoke(:command_driver), do: &SalixVerifiedKernel.invoke_session_command_driver/3

  defp fence_metadata_next({:ok, fence, {:stamped}}, _report, _invoke), do: fence

  defp fence_metadata_next({:ok, fence, {:next}}, report, invoke) do
    fence
    |> batch_event(report, invoke)
    |> fence_metadata_next(report, invoke)
  end

  @doc false
  def encode_revision_fence({:verified_kernel, 1, kind, fence})
      when kind in [:revision_fence, :command_driver] do
    case fence_invoke(kind).(fence, :encode, nil) do
      {:ok, committing, {:cas, _, _, _} = request} ->
        {{:verified_kernel, 1, kind, committing}, request}

      {:ok, _fence, {:error, reason}} ->
        raise_kernel(reason)

      {:ok, _fence, {:rejected, reason}} ->
        raise_kernel(reason)
    end
  end

  @doc false
  def resume_revision_fence({:verified_kernel, 1, :revision_fence, fence}, result) do
    case SalixVerifiedKernel.invoke_session_fence(fence, :cas_result, result) do
      {:ok, state, {:ok, etag}} -> {:ok, handle(state), etag}
      {:ok, state, {:error, reason}} -> {:error, if(state, do: handle(state)), reason}
    end
  end

  @doc false
  def resume_revision_fence_cursor({:verified_kernel, 1, :command_driver, input}, result) do
    case SalixVerifiedKernel.invoke_session_command_driver(input, :cas_result, result) do
      {:ok, confirmed, {:committed}} ->
        {:ok, {:verified_kernel, 1, :command_driver, confirmed}}

      {:ok, rejected, {:rejected, reason}} ->
        {:ok, candidate, {:done}} =
          SalixVerifiedKernel.invoke_session_command_driver(rejected, :candidate, nil)

        {:error, handle(candidate), reason}

      {:ok, nil, {:error, reason}} ->
        {:error, nil, reason}
    end
  end

  def resume_revision_fence_cursor({:verified_kernel, 1, :revision_fence, fence}, result) do
    case SalixVerifiedKernel.invoke_session_fence(fence, :cas_revision, result) do
      {:ok, cursor, {:committed}} -> {:ok, {:verified_kernel, 1, :session_revision, cursor}}
      {:ok, state, {:error, reason}} -> {:error, if(state, do: handle(state)), reason}
    end
  end

  defp batch_next({:ok, resident, {:done}}, _report, _invoke), do: resident
  defp batch_next({:ok, _resident, {:raised, reason}}, _report, _invoke), do: raise_kernel(reason)

  defp batch_next({:ok, resident, {:next}}, report, invoke) do
    resident |> batch_event(report, invoke) |> batch_next(report, invoke)
  end

  defp batch_event(resident, report, invoke) do
    started = System.monotonic_time()

    completed =
      try do
        resident
        |> invoke.(:run, prelude())
        |> batch_observe(invoke)
      catch
        kind, reason ->
          report_batch(report, "error", started)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    report_batch(report, "ok", started)
    completed
  end

  defp batch_observe({:ok, resident, {:observe, :time}}, invoke),
    do:
      resident
      |> invoke.(
        :resume,
        {:ok, System.system_time(:millisecond)}
      )
      |> batch_observe(invoke)

  defp batch_observe({:ok, resident, {:observe, {:config, app, key, default}}}, invoke),
    do:
      resident
      |> invoke.(
        :resume,
        {:ok, Application.get_env(app, key, default)}
      )
      |> batch_observe(invoke)

  defp batch_observe({:ok, _resident, {:raised, reason}}, _invoke), do: raise_kernel(reason)
  defp batch_observe({:ok, _resident, {:error, _reason}} = result, _invoke), do: result

  defp batch_observe({:ok, _resident, {phase, _value}} = result, _invoke)
       when phase in [:validate_write, :effect, :rejected, :planned],
       do: result

  defp batch_observe({:ok, _resident, {:return, _result, _checkpoint}} = result, _invoke),
    do: result

  defp batch_observe({:ok, _resident, {phase}} = result, _invoke)
       when phase in [:done, :next, :prepared, :stamped, :fence, :committed],
       do: result

  defp report_batch(report, outcome, started) do
    report.(outcome, started)
  catch
    _, _ -> :ok
  end

  defp archive_result({:ok, _resident, {:advance, event}}, _io), do: {:advance, event}
  defp archive_result({:ok, _resident, {:ok, :nothing_to_archive} = result}, _io), do: result
  defp archive_result({:ok, _resident, {:error, _} = error}, _io), do: error

  defp archive_result({:ok, resident, request}, io) do
    observation =
      case request do
        {:request_batch, requests} -> Enum.map(requests, io)
        request -> io.(request)
      end

    archive_result(SalixVerifiedKernel.invoke_session_archive(resident, :resume, observation), io)
  end

  defp query_result({:ok, _resident, {:value, value}}, _read), do: value

  defp query_result({:ok, resident, {:observe, request, token}}, read) do
    value =
      case request do
        :time -> System.system_time(:millisecond)
        {:config, app, key, default} -> Application.get_env(app, key, default)
        {:request_batch, requests} -> Enum.map(requests, read)
        request -> read.(request)
      end

    query_result(drive(resident, :resume, {token, {:ok, value}}), read)
  end

  defp query_result({:ok, _resident, {:raised, reason}}, _read), do: raise_kernel(reason)

  @doc "Reads one field of the resident state."
  @spec get(handle(), atom()) :: term()
  def get({:verified_kernel, 1, :session_state, resident}, field) when is_atom(field) do
    {:ok, _resident, {:value, value}} = drive(resident, :get, field)
    value
  end

  @doc "Applies one event to a resident state, or resumes a continuation."
  @spec step(
          handle() | token() | map(),
          map() | {:observed_time, integer()} | {:observed_config, term()}
        ) ::
          outcome(handle() | map())
  def step({:verified_kernel, 1, :session_state, resident}, event) when is_map(event),
    do: resident |> drive(:step, {event, prelude()}) |> outcome(:resident)

  def step({:verified_kernel, 1, :session, resident, token, mode}, {:observed_time, now})
      when is_integer(now),
      do: resident |> drive(:resume, {token, {:ok, now}}) |> outcome(mode)

  def step({:verified_kernel, 1, :session, resident, token, mode}, {:observed_config, value}),
    do: resident |> drive(:resume, {token, {:ok, value}}) |> outcome(mode)

  def step(state, event) when is_map(state) and is_map(event) do
    {:verified_kernel, 1, :session_state, resident} = open(state)
    resident |> drive(:step, event) |> outcome(:state)
  end

  # Configuration the kernel may ask for, with the kernel's own defaults. The
  # host answers these and the clock ahead of every call, so the common case
  # needs no continuation round trip and no replay of the computation.
  @config_keys [
    llm_failure_activation_cap: 3,
    runaway_unsettled_round_cap: 2,
    repeated_tool_result_cap: 5,
    input_round_cap: 120,
    compaction_threshold: nil
  ]

  @doc false
  def prelude do
    [
      {:ok_for, :time, System.system_time(:millisecond)}
      | Enum.map(@config_keys, fn {key, default} ->
          {:ok_for, {:config, :salix_agent, key}, Application.get_env(:salix_agent, key, default)}
        end)
    ]
  end

  @doc "Supplies clock and configuration observations until an outcome is final."
  def settle({:observe_time, token}),
    do: settle(step(token, {:observed_time, System.system_time(:millisecond)}))

  def settle({:observe_config, app, key, default, token}),
    do: settle(step(token, {:observed_config, Application.get_env(app, key, default)}))

  def settle(final), do: final

  defp handle(resident), do: {:verified_kernel, 1, :session_state, resident}

  defp outcome({:ok, resident, result}, mode) do
    case result do
      {:done} when mode == :resident ->
        {:done, handle(resident)}

      {:done} ->
        {:done, export(handle(resident))}

      {:value, value} ->
        {:value, value}

      {:failed, reason} ->
        {:failed, reason}

      {:observe, :time, token} ->
        {:observe_time, {:verified_kernel, 1, :session, resident, token, mode}}

      {:observe, {:config, app, key, default}, token} ->
        {:observe_config, app, key, default,
         {:verified_kernel, 1, :session, resident, token, mode}}

      {:raised, reason} ->
        raise_kernel(reason)
    end
  end

  defp drive(resident, operation, payload) do
    case SalixVerifiedKernel.invoke_session(resident, operation, payload) do
      {:ok, _next, _result} = ok ->
        ok

      {:error, :wire, code} ->
        raise ArgumentError, "invalid Session data: " <> code

      {:error, :session, "invalid_state"} ->
        raise ArgumentError,
              "invalid Session data: Session accepts pure ETF data, the State envelope, and MapSet data only"

      {:error, owner, code} ->
        raise "verified kernel #{owner}: #{code}"
    end
  end

  defp raise_kernel({:schema, [message]}),
    do: raise(ArgumentError, "invalid Session data: " <> message)

  defp raise_kernel({:argument, [message]}), do: raise(ArgumentError, message)
  defp raise_kernel({:badmap, [value]}), do: raise(BadMapError, term: value)
  defp raise_kernel({:badkey, [key, value]}), do: raise(KeyError, key: key, term: value)
  defp raise_kernel({:badarith, []}), do: :erlang.error(:badarith)
  defp raise_kernel({:badarg, _}), do: :erlang.error(:badarg)
  defp raise_kernel({:function_clause, _}), do: raise(FunctionClauseError)
  defp raise_kernel({:case_clause, [value]}), do: raise(CaseClauseError, term: value)

  defp raise_kernel({:enum_map_tail, []}),
    do: raise(FunctionClauseError, module: Enum, function: :"-map/2-lists^map/1-1-", arity: 2)

  defp raise_kernel({:enum_reduce_tail, []}),
    do:
      raise(FunctionClauseError, module: Enum, function: :"-reduce/3-lists^foldl/2-0-", arity: 3)

  defp raise_kernel({:enum_filter_tail, []}),
    do: raise(FunctionClauseError, module: Enum, function: :filter_list, arity: 2)

  defp raise_kernel(reason), do: raise("verified kernel: #{inspect(reason)}")
end
