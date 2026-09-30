defmodule SalixAgent.InternalSession.State do
  @moduledoc """
  The wire envelope of one internal runtime session.

  The session itself lives in the verified kernel and is reached through
  `SalixAgent.InternalSession`; the runtime never reads or writes these
  fields. This struct names the fields of the stored snapshot and admits
  hand-built states at the import boundary (`SalixAgent.InternalSession.open/1`).
  It also validates events before they reach the kernel.

  Durable state for one internal runtime session.

  This is intentionally not a map of sessions. The owner identity is
  `{agent_id, session_id}`, and every transcript message, wait, async tool call,
  compaction record, event, dedupe entry, and message id counter in this struct
  belongs only to that one session.
  """

  alias __MODULE__

  # Circuit breaker for wake-driven LLM retry loops: once this many consecutive
  # `llm_call_failed` session events were recorded at the current transcript
  # position, the session stops re-activating for transcript continuation and
  # parks until new input advances the transcript. Configurable; 0 disables.
  @llm_failure_activation_cap 3

  # Circuit breaker for consecutive non-settling assistant rounds, including
  # guidance-only dispatch results. The session counter resets on a committed
  # admitted tool result (including failure or async start), newly materialized
  # wakeable input, or an advancing accepted ACK, never on a proposed tool call.
  # At the cap, the runtime fails the current activation and retires its replies.
  # Queued input and accepted async work are not acknowledged or cancelled.
  @runaway_unsettled_round_cap 2
  # Consecutive identical tool results (same tool, same input, same outcome)
  # before the session parks. Polling tools repeat by design and are exempt.
  @repeated_tool_result_cap 5
  # Assistant rounds one input may consume before the session parks. Only
  # fresh input (a user message or a runtime notice that is not the loop's
  # own tool completion or wait timeout) starts the count over, so a model
  # that keeps searching and polling forever is bounded even when every
  # round differs. Derived from the transcript; 0 disables.
  @input_round_cap 120

  defstruct agent_id: nil,
            session_id: nil,
            name: "Default",
            hidden: false,
            created_at: nil,
            last_activity_at: nil,
            status: :idle,
            activity_status: :paused,
            activity_status_updated_at: nil,
            activity_revision: nil,
            last_ack_message_id: 0,
            terminal_reply_ack_hwm: nil,
            runtime_failure_reply: nil,
            queue_ack_id: 0,
            next_queue_id: 1,
            input_queue: [],
            next_message_id: 1,
            input_dedupe: MapSet.new(),
            conversation_sources: %{},
            summary_sequence: 0,
            compacted_through: 0,
            summary: nil,
            provider_compaction: nil,
            compaction_failure: nil,
            visible_reply_repair: nil,
            visible_reply_activation_scope: nil,
            visible_reply_intent: nil,
            visible_reply_egress_facts: %{},
            provider_reply_obligations: %{},
            messages: [],
            events: [],
            wait: nil,
            async_tool_calls: %{},
            storage_revision: nil,
            # Runtime ownership fence (docs/release-operations.md):
            # the agent-root epoch of the last committing owner, stamped on
            # every commit and checked against the local ownership cell before
            # any write. A regression is a terminal :fenced, never a rebase.
            # 0 = legacy/unstamped. `runtime_node` is diagnostic only.
            runtime_epoch: 0,
            runtime_node: nil,
            work_index_token: nil,
            work_index_reasons: [],
            platform: nil,
            billing_context: %{},
            task_origin: nil,
            source_agent_id: nil,
            source_session_id: nil,
            source_schedule_id: nil,
            system_prompt: nil,
            context_provider_states: %{},
            miniskills: %{},
            live_context_bytes: nil,
            storage_format: 1,
            last_seq: 0,
            compacted_seq: 0,
            archived_through: 0,
            archive_chunks: [],
            segment_catalog: [],
            flush_id: nil,
            async_results: [],
            async_result_refs: %{},
            redactions: [],
            llm_failure_streak: nil,
            context_overflow_recovery: nil,
            runaway_unsettled_streak: nil,
            repeated_tool_result_streak: nil,
            input_round_streak: nil,
            active_source_message_ids: [],
            last_compaction_recovery: nil,
            compact_results: %{},
            fork_request_id: nil

  @type status :: :idle | :active
  @type activity_status :: :paused | :thinking | :execution | :messaging | :waiting | :failed
  @type t :: %State{}

  # Format-2 storage coordinates (docs/storage-search.md):
  # every transcript message and fact is stamped with a monotone log position
  # `seq` at append time. Seqs are the storage coordinate — archive
  # eligibility, catalog span bounds, and result addressing key off them —
  # and are fixed at first assignment forever. Message ids keep their LLM/context
  # semantics untouched; the two coordinate spaces never compare. Watermark
  # invariant: `archived_through <= compacted_seq <= last_seq`.
  # Legacy snapshots retain their source format while being read. The write
  # boundary fixes legacy coordinates and publishes only format 3 in one CAS.

  @doc """
  `:ok`, or the first invalid event's `{:error, reason}`. The verified kernel
  owns the rules (`VerifiedKernel.Session.WriteValidation`).
  """
  @spec validate_events([map()]) :: :ok | {:error, term()}
  def validate_events(events),
    do:
      SalixVerifiedKernel.Session.query(
        SalixVerifiedKernel.Session.open(%{__struct__: __MODULE__}),
        :validate_events,
        events
      )

  def llm_failure_activation_cap,
    do:
      Application.get_env(:salix_agent, :llm_failure_activation_cap, @llm_failure_activation_cap)

  def runaway_unsettled_round_cap,
    do:
      Application.get_env(
        :salix_agent,
        :runaway_unsettled_round_cap,
        @runaway_unsettled_round_cap
      )

  def repeated_tool_result_cap,
    do: Application.get_env(:salix_agent, :repeated_tool_result_cap, @repeated_tool_result_cap)

  def input_round_cap,
    do: Application.get_env(:salix_agent, :input_round_cap, @input_round_cap)
end
