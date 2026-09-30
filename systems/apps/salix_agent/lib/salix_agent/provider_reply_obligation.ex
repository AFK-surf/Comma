defmodule SalixAgent.ProviderReplyObligation do
  @moduledoc """
  Durable, provider-owned obligations for canonical Router sessions.

  Two target kinds share one map and reminder, but only Task cards fence ACKs:
  a plain reply reminder (retired by exact successful egress or settlement) and a
  `task_card` target (one successful `im_api.slack.post_task_card` for the
  exact Task conversation created from a Slack-sourced activation).

  The state is deliberately independent of transcript records: format-2
  compaction may archive every delivery and tool result while an unresolved
  Task-card obligation still fences the session ACK; ordinary reply reminders
  survive until explicit settlement.

  The obligation map itself is kernel state. `normalize/1`, `key/1`,
  `pending/1`, `pending_count/1`, `blocking_count/1`, and `admission_full?/3`
  are kernel queries; the reducers that used to build the next map here are
  kernel events. The kernel also selects and renders request reminders, and
  derives the resolution and candidate events from settled tool results.
  """

  require SalixAgent.InternalSession
  alias SalixAgent.InternalSession

  @doc """
  Kernel helper `normalize_obligation`: the canonical target, or nil.

  The card identity is the Task conversation alone: the Router may publish the
  card to any thread it owns, so channel/thread there are only the suggested
  source and never part of the resolution key.
  """
  def normalize(raw), do: InternalSession.normalize_obligation(raw)

  @doc false
  def normalize_map(raw) when is_map(raw) do
    raw
    |> Map.values()
    |> Enum.reduce(%{}, fn value, acc ->
      case normalize(value) do
        %{"key" => key} = target -> Map.put(acc, key, target)
        nil -> acc
      end
    end)
  end

  def normalize_map(_raw), do: %{}

  @doc "Kernel query `pending_obligations`: every hot target, ordered by key."
  def pending(state), do: session_query(state, :pending_obligations, nil, [])

  @doc "Kernel query `pending_obligation_count`."
  def pending_count(state), do: session_query(state, :pending_obligation_count, nil, 0)

  @doc false
  def pending?(state), do: pending_count(state) > 0

  @doc "Kernel query `blocking_obligation_count`: only Task cards fence an ACK."
  def blocking_count(state), do: session_query(state, :blocking_obligation_count, nil, 0)

  @doc false
  def blocking?(state), do: blocking_count(state) > 0

  @doc false
  def append_reminder(messages, state) when is_list(messages),
    do: session_query(state, :provider_request_part, {:obligation_reminder, messages}, messages)

  @doc """
  Reject admission before commit when accepted distinct reply targets would
  exceed the same configured bound used for the session input queue.

  Current hot obligations and not-yet-materialized queued obligations both
  count. A same-target burst stays admissible because targets coalesce.
  """
  def admission_full?(session, payload, limit),
    do: session_query(session, :obligation_admission_full?, {payload, limit}, false)

  @doc """
  Build resolution events for a successful Slack egress.

  A visible-response operation to an exact reply target resolves that target;
  a successful `im_api.slack.post_task_card` additionally resolves the
  `task_card` obligation for its exact conversation_id. `fallback` supports
  durable/process-local async call records whose terminal result does not
  repeat the original tool name or input. The kernel derives the events
  (`LoopHost.resolutionEvents`).
  """
  def resolution_events(session_id, result, fallback \\ nil)

  def resolution_events(session_id, result, fallback)
      when is_binary(session_id) and is_map(result),
      do: session_id |> obligation_events(result, fallback) |> elem(0)

  def resolution_events(_session_id, _result, _fallback), do: []

  @doc """
  The configured bound on the union of hot obligations and distinct queued
  targets. Shared with delivery admission so the two cannot drift.
  """
  def admission_limit,
    do: Application.get_env(:salix_agent, :session_input_queue_limit, 1000)

  @doc """
  Build the candidate add event for a Slack Task-card obligation.

  Every successful non-Triage `im_api.internal.task.create` emits one candidate
  carrying only the server-authored conversation_id, on both the synchronous tool-batch
  path and the async auto-wait settlement path. The event freezes the
  admission limit configured at generation time so replay stays deterministic.
  Whether the activation is Slack-sourced — and whether the bounded map has
  room — is decided at apply time, where the full session state is available.
  A successfully authorized Triage delegation is internal investigation, not a
  card promise, even if another human source is pending. The kernel derives
  the event (`LoopHost.cardObligationEvents`).
  """
  def card_obligation_events(session_id, result, fallback \\ nil)

  def card_obligation_events(session_id, result, fallback)
      when is_binary(session_id) and is_map(result),
      do: session_id |> obligation_events(result, fallback) |> elem(1)

  def card_obligation_events(_session_id, _result, _fallback), do: []

  # Only the fields the derivation reads cross the kernel boundary: a pending
  # async record also carries process identities.
  @source_fields [:name, :tool_name, :input, :args, "name", "tool_name", "input", "args"]
  @result_fields [:error, :status, :guidance_reason, :content | @source_fields] ++
                   ["error", "status", "guidance_reason", "content"]

  defp obligation_events(session_id, result, fallback),
    do:
      InternalSession.result_obligation_events(
        session_id,
        Map.take(result, @result_fields),
        obligation_source(fallback)
      )

  defp obligation_source(source) when is_map(source) do
    base = Map.take(source, @source_fields)

    case Map.get(source, "call") || Map.get(source, :call) do
      call when is_map(call) -> Map.put(base, "call", Map.take(call, @source_fields))
      _ -> base
    end
  end

  defp obligation_source(_source), do: nil

  @doc "Kernel helper `obligation_key`: the canonical digest of one target."
  def key(target), do: InternalSession.obligation_key(target)

  defp session_query(session, name, args, _fallback)
       when InternalSession.is_session(session),
       do: InternalSession.query(session, name, args)
end
