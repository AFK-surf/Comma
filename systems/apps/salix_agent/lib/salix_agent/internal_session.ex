defmodule SalixAgent.InternalSession do
  @moduledoc """
  The internal runtime session, owned by the Lean kernel.

  A session is an opaque handle to an immutable kernel value.
  The Actor and storage CAS select the current committed revision.
  Elixir cannot read or mutate resident memory directly. Every
  transition is an event applied through `apply_events/2`, and every derived
  value is a kernel query. The state crosses the boundary as data only at the
  storage boundary (`load/1`, `persist/1`) and through `export/1`, which exists
  for tests and one-off tools.

  Handles are immutable: each transition returns a new handle and older
  handles stay valid. Handles can travel between processes. They cannot be
  serialized; persist the session instead.
  """

  alias SalixVerifiedKernel.Session, as: Kernel

  @opaque t :: Kernel.handle()

  defguard is_session(value)
           when is_tuple(value) and tuple_size(value) == 4 and elem(value, 0) == :verified_kernel and
                  elem(value, 2) == :session_state

  @materialize_input_batch_size 100

  ## Lifecycle

  @doc "A normalized fresh session, as `State.new/3` built it."
  @spec new(String.t(), String.t(), map()) :: t()
  def new(agent_id, session_id, attrs \\ %{}) when is_map(attrs),
    do: Kernel.new(agent_id, session_id, attrs)

  @doc "Admits a state map as given. For tests, imports, and migrations."
  @spec open(map()) :: t()
  def open(state) when is_map(state), do: Kernel.open(state)

  @envelope_keys SalixAgent.InternalSession.State.__struct__()
                 |> Map.from_struct()
                 |> Map.keys()
                 |> Enum.flat_map(&[&1, Atom.to_string(&1)])

  @doc """
  Admits only the state's named fields of a caller-assembled map: an external
  runtime context or a per-call tool context. Whatever else the map carries
  (runtime identities, host data) never becomes session state.
  """
  @spec open_envelope(map()) :: t()
  def open_envelope(map) when is_map(map), do: open(Map.take(map, @envelope_keys))

  @doc "The state as data, for tests and one-off tools."
  @spec export(t()) :: map()
  def export(session) when is_session(session), do: Kernel.export(session)

  @doc "Admits a stored snapshot (decompressed ETF bytes) and normalizes it."
  @spec load(binary()) :: {:ok, t()} | {:error, :invalid_snapshot}
  def load(bytes) when is_binary(bytes), do: Kernel.load(bytes)

  @doc """
  Admits stored snapshot bytes exactly as written, without normalization.
  For repair tools that must not change what they did not touch.
  """
  @spec admit(binary()) :: {:ok, t()} | {:error, :invalid_snapshot}
  def admit(bytes) when is_binary(bytes), do: Kernel.admit(bytes)

  @doc "The snapshot ETF bytes of the persistable state."
  @spec persist(t()) :: binary()
  def persist(session) when is_session(session), do: Kernel.persist(session)

  @doc "`State.normalize/1`."
  @spec normalize(t()) :: t()
  def normalize(session) when is_session(session) do
    {:ok, next} = Kernel.lifecycle(session, :normalize)
    next
  end

  @doc "`InternalSessionFormat.prepare_write/1`."
  @spec prepare_write(t()) :: {:ok, t()} | {:error, term()}
  def prepare_write(session) when is_session(session),
    do: Kernel.lifecycle(session, :prepare_write)

  @doc "`State.fork_from/3`."
  @spec fork(t(), String.t(), map()) :: {:ok, t()} | {:error, :fork_cutoff_below_compaction}
  def fork(session, session_id, attrs \\ %{}) when is_session(session) and is_map(attrs),
    do: Kernel.lifecycle(session, :fork, {session_id, attrs})

  @spec fork_inline_result_seqs(t(), map()) :: [pos_integer()]
  def fork_inline_result_seqs(session, attrs) when is_session(session) and is_map(attrs),
    do: query(session, :fork_inline_result_seqs, attrs)

  ## Commands

  @doc "Applies events in order. Every event is a kernel transition."
  @spec apply_events(t(), [map()]) :: t()
  def apply_events(session, []) when is_session(session), do: session

  def apply_events(session, events) when is_session(session) and is_list(events),
    do: Kernel.apply_batch(session, events, &emit_kernel_operation/2)

  @spec apply_event(t(), map()) :: t()
  def apply_event(session, event) when is_session(session) and is_map(event) do
    started = System.monotonic_time()

    try do
      next = session |> Kernel.step(event) |> settle()
      emit_kernel_operation("ok", started)
      next
    catch
      kind, reason ->
        emit_kernel_operation("error", started)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @doc """
  Host bookkeeping written around a commit: any of `agent_id`, `runtime_epoch`,
  `runtime_node`, `activity_revision`, `storage_revision`, `flush_id`,
  `work_index_token`, `work_index_reasons`.
  """
  @spec stamp(t(), map() | keyword()) :: t()
  def stamp(session, fields) when is_session(session) do
    fields = Map.new(fields, fn {key, value} -> {to_string(key), value} end)
    apply_events(session, [Map.put(fields, "type", "session_stamp")])
  end

  @doc "`State.put_work_index/3`."
  @spec put_work_index(t(), String.t() | nil, [String.t()]) :: t()
  def put_work_index(session, token, reasons),
    do: stamp(session, work_index_token: token, work_index_reasons: reasons)

  @doc "`State.bump_hwm/2`."
  @spec bump_hwm(t(), non_neg_integer() | nil) :: t()
  def bump_hwm(session, hwm) when is_session(session) and is_integer(hwm) and hwm >= 0,
    do: apply_events(session, [%{"type" => "bump_hwm", "hwm" => hwm}])

  def bump_hwm(session, _hwm) when is_session(session), do: session

  ## Reads

  @doc false
  def start_command(cursor, command, args, checkpoint),
    do: Kernel.start_command(cursor, command, args, checkpoint, &emit_kernel_operation/2)

  @doc false
  def command_step(input, operation, result),
    do: Kernel.command_step(input, operation, result, &emit_kernel_operation/2)

  @doc false
  defdelegate command_revision(input), to: Kernel

  @doc false
  defdelegate start_revision(session, etag), to: Kernel

  @doc false
  defdelegate read_revision(agent_id, session_id, read), to: Kernel

  @doc false
  defdelegate revision_view(cursor), to: Kernel

  @doc false
  defdelegate revision_pending?(cursor), to: Kernel

  @doc false
  defdelegate revision_baseline(cursor), to: Kernel

  @doc false
  defdelegate revision_metadata(cursor), to: Kernel

  @doc false
  def write_revision(cursor, events, hwm),
    do: Kernel.write_revision(cursor, events, hwm, &emit_kernel_operation/2)

  @doc false
  def plan_revision(cursor, mode),
    do: Kernel.plan_revision(cursor, mode, &emit_kernel_operation/2)

  @doc false
  defdelegate start_pending_revision(session, etag), to: Kernel

  @doc false
  def write_pending_revision(pending, events, hwm),
    do: Kernel.write_pending_revision(pending, events, hwm, &emit_kernel_operation/2)

  @doc false
  defdelegate pending_working(pending), to: Kernel

  @doc false
  defdelegate pending_baseline(pending), to: Kernel

  @doc false
  defdelegate pending_metadata(pending), to: Kernel

  @doc false
  defdelegate start_revision_fence(pending, key), to: Kernel

  @doc false
  defdelegate fence_prepared_state(fence), to: Kernel

  @doc false
  def stamp_revision_fence(fence, metadata),
    do: Kernel.stamp_revision_fence(fence, metadata, &emit_kernel_operation/2)

  @doc false
  defdelegate encode_revision_fence(fence), to: Kernel

  @doc false
  defdelegate resume_revision_fence(fence, result), to: Kernel

  @doc false
  defdelegate resume_revision_fence_cursor(fence, result), to: Kernel

  @doc "One field of the state. Transcript fields are large; prefer the derived queries."
  @spec get(t(), atom()) :: term()
  def get(session, field) when is_session(session) and is_atom(field),
    do: Kernel.get(session, field)

  @doc "A derived value. See the kernel README query catalog."
  @spec query(t(), atom(), term()) :: term()
  def query(session, name, args \\ nil) when is_session(session) and is_atom(name),
    do: Kernel.query(session, name, args)

  @doc "A derived value that reads external data through `read`."
  @spec query(t(), atom(), term(), (term() -> term())) :: term()
  def query(session, name, args, read)
      when is_session(session) and is_atom(name) and is_function(read, 1),
      do: Kernel.query(session, name, args, read)

  @doc false
  def match_archive_prefix(session, landed, window) when is_session(session) do
    # Bound FFI input to this segment, not the entire remaining archive window.
    prefix = Enum.take(window, length(landed))

    Kernel.query(session, :archive_match_prefix, {landed, prefix}, fn
      {:deterministic_etf, value} ->
        :erlang.term_to_binary(value, [:deterministic, {:minor_version, 1}])
    end)
  end

  @doc false
  def archive_publication(session, line, io) when is_session(session),
    do: Kernel.archive_publication(session, line, io)

  @doc false
  def start_storage_commit(session, key, base) when is_session(session),
    do: Kernel.start_storage_commit(session, key, base)

  @doc false
  defdelegate resume_storage_commit(cursor, result), to: Kernel

  def agent_id(session), do: get(session, :agent_id)
  def session_id(session), do: get(session, :session_id)
  def status(session), do: get(session, :status)
  def wait(session), do: get(session, :wait)
  def storage_format(session), do: get(session, :storage_format)
  def storage_revision(session), do: get(session, :storage_revision)
  def flush_id(session), do: get(session, :flush_id)
  def work_index_token(session), do: get(session, :work_index_token)
  def next_message_id(session), do: get(session, :next_message_id)
  def last_ack_message_id(session), do: get(session, :last_ack_message_id)
  def compacted_through(session), do: get(session, :compacted_through)
  def archived_through(session), do: get(session, :archived_through)

  def derived_state(session), do: query(session, :derived_state)
  def waiting?(session), do: query(session, :waiting?)
  def llm_retry_at_ms(session), do: query(session, :llm_retry_at_ms)
  def recovery_wait(session), do: query(session, :recovery_wait)
  def activity_status(session), do: query(session, :activity_status)
  def activity_issue(session), do: query(session, :activity_issue)
  def monitored_activity_signature(session), do: query(session, :monitored_activity_signature)
  def context_byte_size(session), do: query(session, :context_byte_size)
  def estimated_tokens(session), do: query(session, :estimated_tokens)
  def observed_prompt_tokens(session), do: query(session, :observed_prompt_tokens)
  def work_reasons(session), do: query(session, :work_reasons)
  def has_unacked_wakeable_input?(session), do: query(session, :has_unacked_wakeable_input?)
  def unacked_queue_items(session), do: query(session, :unacked_queue_items)

  @spec materialize_pending_input_events(t(), pos_integer()) ::
          {[map()], boolean(), non_neg_integer()}
  def materialize_pending_input_events(session, limit \\ @materialize_input_batch_size)
      when is_integer(limit) and limit > 0,
      do: query(session, :materialize_pending_input_events, limit)

  def yieldable_provider_wait?(session), do: query(session, :yieldable_provider_wait?)
  def wait_identity(session), do: query(session, :wait_identity)
  def active_human_source_ids(session), do: query(session, :active_human_source_ids)

  def needs_transcript_continuation?(session), do: query(session, :needs_transcript_continuation?)
  def visible_reply_repair_required?(session), do: query(session, :visible_reply_repair_required?)

  def visible_reply_repair_exhausted?(session),
    do: query(session, :visible_reply_repair_exhausted?)

  def pending_visible_reply?(session), do: query(session, :pending_visible_reply?)

  def current_activation_key(session, source_ids \\ []),
    do: query(session, :current_activation_key, source_ids)

  def consecutive_unsettled_rounds(session), do: query(session, :consecutive_unsettled_rounds)

  def runaway_unsettled_rounds_exhausted?(session),
    do: query(session, :runaway_unsettled_rounds_exhausted?)

  def consecutive_repeated_tool_results(session),
    do: query(session, :consecutive_repeated_tool_results)

  def repeated_tool_results_exhausted?(session),
    do: query(session, :repeated_tool_results_exhausted?)

  def repeated_tool_result_tool(session), do: query(session, :repeated_tool_result_tool)
  def rounds_since_fresh_input(session), do: query(session, :rounds_since_fresh_input)

  def input_round_budget_exhausted?(session),
    do: query(session, :input_round_budget_exhausted?)

  def consecutive_llm_failures(session), do: query(session, :consecutive_llm_failures)
  def llm_failures_exhausted?(session), do: query(session, :llm_failures_exhausted?)
  def llm_failure_terminal?(session), do: query(session, :llm_failure_terminal?)
  def has_unprocessed_stable_work?(session), do: query(session, :has_unprocessed_stable_work?)
  def has_pending_stable_input?(session), do: query(session, :has_pending_stable_input?)

  def lookup_async_call(session, ref) when is_binary(ref),
    do: query(session, :lookup_async_call, ref)

  def covered_seq(session, compacted_through), do: query(session, :covered_seq, compacted_through)
  def total_message_count(session), do: query(session, :total_message_count)
  def masked_messages(session), do: query(session, :masked_messages)
  def pending_assistant_id(session), do: query(session, :pending_assistant_id)
  def decision_required?(session), do: query(session, :decision_required?)
  def consecutive_timeouts(session), do: query(session, :consecutive_timeouts)
  def visible_reply_phase(session), do: query(session, :visible_reply_phase)
  def visible_reply_guard(session), do: query(session, :visible_reply_guard)

  def derive_visible_reply_scope(session, source_message_ids) when is_list(source_message_ids),
    do: query(session, :derive_visible_reply_scope, source_message_ids)

  def current_source_message_ids(session), do: query(session, :current_source_message_ids)
  def pending_obligations(session), do: query(session, :pending_obligations)
  def pending_obligation_count(session), do: query(session, :pending_obligation_count)
  def pending_obligations?(session), do: pending_obligation_count(session) > 0
  def blocking_obligation_count(session), do: query(session, :blocking_obligation_count)
  def blocking_obligations?(session), do: blocking_obligation_count(session) > 0

  def obligation_admission_full?(session, payload, limit),
    do: query(session, :obligation_admission_full?, {payload, limit})

  def should_compact?(session, threshold, context_tokens, model \\ nil),
    do: query(session, :should_compact?, {threshold, context_tokens, model})

  def prepare_prompt_snapshot(session, configured_prompt),
    do: query(session, :prepare_prompt_snapshot, configured_prompt)

  def provider_states(session), do: query(session, :provider_states)

  def conversation_sources(session), do: query(session, :conversation_sources)

  # Runtime consumers (see the README query catalog).
  def session_json(session, agent_id), do: query(session, :session_json, agent_id)
  def compact_result_for(session, source_id), do: query(session, :compact_result_for, source_id)
  def emergency_compact_through_id(session), do: query(session, :emergency_compact_through_id)
  def lineage_source_session_id(session), do: query(session, :lineage_source_session_id)

  def title_has_assistant?(session), do: query(session, :title_has_assistant?)
  def title_source_content(session), do: query(session, :title_source_content)
  def latest_compaction_recovery(session), do: query(session, :latest_compaction_recovery)

  def internal_session_billing_entries(session, model, provider_type),
    do: query(session, :internal_session_billing_entries, {model, provider_type})

  def input_dedupe_member?(session, source_id),
    do: query(session, :input_dedupe_member?, source_id)

  def session_snapshot_id(session), do: query(session, :session_snapshot_id)

  # Round, actor, terminal reply, and telemetry (see the README query catalog).
  def fresh_wakeable_input?(session, id_snapshot),
    do: query(session, :fresh_wakeable_input?, id_snapshot)

  def current_source_ids(session), do: query(session, :current_source_ids)

  def current_turn_trusted_origins(session, source_ids) when is_list(source_ids),
    do: query(session, :current_turn_trusted_origins, source_ids)

  def current_turn_source(session, source_ids) when is_list(source_ids),
    do: query(session, :current_turn_source, source_ids)

  def async_result_by_seq(session, seq), do: query(session, :async_result_by_seq, seq)

  def earliest_delivered_at_ms(session, source_ids) when is_list(source_ids),
    do: query(session, :earliest_delivered_at_ms, source_ids)

  def input_queue_length(session), do: query(session, :input_queue_length)

  def duplicate_delivery?(session, source_message_id),
    do: query(session, :duplicate_delivery?, source_message_id)

  def wait_expired?(session), do: query(session, :wait_expired?)

  def completion_target(session, tool_call_id),
    do: query(session, :completion_target, tool_call_id)

  def terminal_reply_source_scope(session), do: query(session, :terminal_reply_source_scope)

  def terminal_reply_reminder_active?(session),
    do: query(session, :terminal_reply_reminder_active?)

  def terminal_reply_matches?(session, binding),
    do: query(session, :terminal_reply_matches?, binding)

  def terminal_reply_running?(session), do: query(session, :terminal_reply_running?)

  def onboarding_source_message_id(session, source_id),
    do: query(session, :onboarding_source_message_id, source_id)

  def onboarding_send_completed?(session, last_ack),
    do: query(session, :onboarding_send_completed?, last_ack)

  # Compaction and context providers (see the README query catalog).
  def compaction_live_messages(session), do: query(session, :compaction_live_messages)
  def request_live_messages(session), do: query(session, :request_live_messages)
  def compaction_context_prefix(session), do: query(session, :compaction_context_prefix)
  def provider_compaction_items(session), do: query(session, :provider_compaction_items)

  def unfinished_activation_start_id(session, messages) when is_list(messages),
    do: query(session, :unfinished_activation_start_id, messages)

  def auto_compaction_block_result(session, fingerprint, last_id, now),
    do: query(session, :auto_compaction_block_result, {fingerprint, last_id, now})

  def async_result_record(session, seq) when is_integer(seq),
    do: query(session, :async_result_record, seq)

  def adopted_llm_context?(session), do: query(session, :adopted_llm_context?)
  def latest_user_input_message(session), do: query(session, :latest_user_input_message)

  # Repair and visible reply policy (see the README query catalog).
  def repair_scan(session), do: query(session, :repair_scan)

  def visible_reply_async_completion_facts(session, result),
    do: query(session, :visible_reply_async_completion_facts, result)

  # IFC context and project knowledge (see the README query catalog).
  def ifc_context(session, source_message_id, source_message_ids, trusted_origin),
    do: query(session, :ifc_context, {source_message_id, source_message_ids, trusted_origin})

  def ifc_organization_scopes(session, source_message_ids, kind) when is_list(source_message_ids),
    do: query(session, :ifc_organization_scopes, {source_message_ids, kind})

  def project_knowledge_question(session), do: query(session, :project_knowledge_question)

  def project_knowledge_activation_boundary(session),
    do: query(session, :project_knowledge_activation_boundary)

  def project_knowledge_committed?(session, runtime_message_id),
    do: query(session, :project_knowledge_committed?, runtime_message_id)

  # Backups and migrations (see the README query catalog).
  def terminal_results_from_backup(session), do: query(session, :terminal_results_from_backup)

  ## Stateless helpers served by the kernel

  def human_source_origin?(origin), do: stateless(:human_source_origin?, origin)
  def valid_activation_scope?(scope), do: stateless(:valid_activation_scope?, scope)
  def scopes_equivalent?(left, right), do: stateless(:scopes_equivalent?, {left, right})
  def normalize_obligation(raw), do: stateless(:normalize_obligation, raw)
  def obligation_key(target), do: stateless(:obligation_key, target)
  def recovery_policy(args), do: stateless(:recovery_policy, args)
  def presentation_policy(operation, args), do: stateless(:presentation_policy, {operation, args})
  def scheduled_presentation(args), do: stateless(:scheduled_presentation, args)
  def initial_attributes(payload), do: stateless(:initial_attributes, payload)
  def request_projection(args), do: stateless(:provider_request_part, args)
  def settlement_completed?(events), do: stateless(:settlement_completed?, events)

  # Stateless queries run over an empty state envelope.
  @stateless_state %{__struct__: SalixAgent.InternalSession.State}
  defp stateless(name, args), do: Kernel.query(Kernel.open(@stateless_state), name, args)

  @doc """
  `{resolutions, card_obligations}`: the provider reply obligation events of
  one settled tool result. `fallback` is the durable call record of an async
  completion.
  """
  def result_obligation_events(session_id, result, fallback) when is_binary(session_id),
    do:
      Kernel.query(
        Kernel.open(Map.put(@stateless_state, :session_id, session_id)),
        :result_obligation_events,
        {result, fallback}
      )

  @doc "`{result, events}` of a compaction request that settles without running."
  def compaction_result_events(session_id, status, reason, source_message_id)
      when is_binary(session_id),
      do:
        Kernel.query(
          Kernel.open(Map.put(@stateless_state, :session_id, session_id)),
          :compaction_result_events,
          {status, reason, source_message_id}
        )

  @doc "The facts of the loop's activation and wait-timeout entries."
  def activation_facts, do: stateless(:activation_facts, nil)

  @doc "The context window of a model configuration, as the kernel measures it."
  def compaction_window(config), do: stateless(:compaction_window, config)

  ## Observations

  defp settle({:done, next}), do: next
  defp settle(pending), do: pending |> Kernel.settle() |> settle()

  defp emit_kernel_operation(outcome, started) do
    Salix.Telemetry.emit_operation(
      "salix_agent",
      "session_kernel",
      SystemsObservability.Context.current_surface(),
      outcome,
      System.monotonic_time() - started
    )
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
