defmodule SalixAgent.QueueYieldGuard do
  @moduledoc """
  Ends a Router's answered activation when a person is queued behind it.

  One Router session serves a workspace in one queue: a person who writes while
  another activation is open waits until it ends
  (`VerifiedKernel.Session.Query.Materialize.materializeBatch`), and an active
  Router never yields to them. `SalixAgent.QueuePressure` tells the model, but
  only as a signal. On staging on 2026-11-06 a Router that had already answered
  its person kept the activation open for nine more minutes on bookkeeping of
  its own, after seeing the queue, and two people waited 407 s and 429 s
  before their first model call.

  The guard leaves admission and IFC alone. It engages for a round when all of
  these hold on the session the round's response is accepted against:

  - the session is a Router's;
  - every person in the open activation is a Slack source whose reply target
    the runtime tracks, and none of those targets is still pending, so each of
    them has had their reply (only Slack keeps reply targets; an activation
    with another provider's person, or a Triage handoff, is never guarded);
  - a person's request (a provider user or a Comma user) is queued.

  While it is engaged, a call other than one that answers, delegates or ends
  the turn (`allowed?/1`) is refused as guidance (`queued_person`). The
  refusal runs nothing, so an accepted async call keeps running and its result
  still arrives; a guidance-only round does not count towards turn retirement,
  and the round's own guards still bound repeats.
  """

  require SalixAgent.InternalSession
  alias SalixAgent.{InternalSession, ProviderReplyObligation, QueuePressure}

  @reason "queued_person"

  # Answer, delegate, wait, or end the turn. `wait_for` already yields to a
  # queued person; `send_message` continues an existing Task or answers a
  # Comma user. Each allowed call either settles the activation or hands work
  # away, and the round guards (five identical results, `input_round_cap`)
  # bound any repetition, so none of them keeps a queued person waiting.
  @allowed ~w(end_turn wait_for im_api.internal.task.create im_api.internal.send_message)
  @allowed_provider_ops ~w(reply_message reply_text update_message add_reaction
                           post_task_card open_task_topic leave_thread)

  def reason, do: @reason

  @doc "Whether a round accepted against `session` runs under the guard."
  def engaged?(session, role) when InternalSession.is_session(session) do
    role in ["router", :router] and queued_person?(session) and answered?(session)
  end

  def engaged?(_session, _role), do: false

  @doc "The guard for a round accepted against `session`: the queued count, or nil."
  def check(session, role) do
    if engaged?(session, role), do: queued_count(session)
  end

  @doc "Whether a call to `name` is still allowed while the guard is engaged."
  def allowed?(name) when is_binary(name) do
    name in @allowed or
      case String.split(name, ".") do
        ["im_api", provider, op] -> provider != "internal" and op in @allowed_provider_ops
        _ -> false
      end
  end

  def allowed?(_name), do: false

  @doc "The guidance a refused call returns."
  def guidance(count) do
    "#{count} queued #{if count == 1, do: "person waits", else: "people wait"} behind this activation, " <>
      "and everyone in it has had their reply, so the runtime ran nothing for this call. " <>
      "Do not continue other work here: give remaining work to a Task with " <>
      "im_api.internal.task.create, or call end_turn. " <>
      "Running async calls keep running and report later."
  end

  @doc "How many people are queued, for the guidance text."
  def queued_count(session), do: session |> queued_people() |> length()

  defp queued_person?(session), do: queued_people(session) != []

  defp queued_people(session), do: QueuePressure.people(session)

  defp answered?(session) do
    ids = InternalSession.active_human_source_ids(session)

    origins =
      if ids == [],
        do: [],
        else: InternalSession.current_turn_trusted_origins(session, ids)

    pending =
      session
      |> ProviderReplyObligation.pending()
      |> Enum.reject(&(&1["kind"] == "task_card"))

    origins != [] and Enum.all?(origins, &answered_slack_person?(&1, pending))
  end

  defp answered_slack_person?(%{"provider" => "slack"} = origin, pending) do
    context = origin["provider_context"] || %{}
    thread = context["thread_ts"] || context["message_ts"]

    is_nil(origin["triage_delegation"]) and context["event_type"] != "meeting.summary_requested" and
      is_binary(context["channel_id"]) and is_binary(thread) and
      not Enum.any?(pending, fn target ->
        target["connect_id"] == context["connect_id"] and
          target["channel"] == context["channel_id"] and target["thread_ts"] == thread
      end)
  end

  defp answered_slack_person?(_origin, _pending), do: false
end
