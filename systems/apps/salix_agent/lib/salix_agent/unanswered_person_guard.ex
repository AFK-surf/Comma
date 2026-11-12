defmodule SalixAgent.UnansweredPersonGuard do
  @moduledoc """
  Refuses a Router's `end_turn` with `outcome=done` that leaves the person of
  its activation with nothing.

  Ending a turn does not continue its work later: the runtime acknowledges
  the activation's sources, and nothing wakes the Router for that request
  again unless the person writes. In production a Router ran one probing
  command for a person, saw queue pressure, and ended with `done`, no reply
  and no Task ("the next human message continues"); she waited two hours.

  The guard engages for a model response when all of these hold on the
  session the response arrives against:

  - the session is a Router's, and its visible-reply phase is clean;
  - the response is one standalone `end_turn` with `outcome=done`, no
    `reply`, and `no_reply` not `true` (`no_reply` declares deliberate
    silence, and the runtime trusts that declaration);
  - the open activation (inputs after the ACK) has a person source: a
    trusted origin whose sender is a provider user or a Comma user
    (`SalixAgent.QueuePressure.person_origin?/1`), of any provider;
  - in that activation the Router has made no attempt to reach anyone or to
    hand the work on: no message-sending call (a provider send or reply, a
    Comma message, a Task card or topic, an `end_turn` carrying a reply),
    no `im_api.internal.task.create`, no `wait_for`, and no async call still
    running. A refused or failed attempt counts, since the IFC help and the
    `end_turn` contract tell the model to settle after a refused explanation.

  It fails open when it cannot see the whole activation: when compaction
  covers a message after the ACK, or the transcript cannot be read.

  `outcome=blocked` is never refused. The kernel settles a standalone valid
  `end_turn` before any tool dispatch (`VerifiedKernel.AgentLoop.TurnOutcome`),
  so the guard acts on the response itself: `guard/4` turns the call into a
  refused guidance call (`unanswered_person`). The kernel then runs it as a
  tool turn, dispatch runs nothing and returns the guidance, and the record
  keeps the model's own `end_turn` (`model_calls/1`). As with
  `SalixAgent.QueueYieldGuard`, a guidance-only round does not count towards
  turn retirement, and the repeated-result guard bounds repeats.
  """

  require SalixAgent.InternalSession
  alias SalixAgent.{InternalSession, QueuePressure}

  @reason "unanswered_person"

  # Calls that reach a person or another Agent, as the kernel's
  # `conversationSendTool` (`Session.Query.Compaction`) reads them, plus the
  # visible Task surfaces and message edits.
  @send_ops ~w(send_message send_text send_dm reply_message reply_text post_message
               post_channel_message say update_message send_file post_task_card
               open_task_topic)
  @handoff ~w(wait_for im_api.internal.task.create im_api.internal.send_message)

  def reason, do: @reason

  @doc "The guidance a refused `end_turn` returns."
  def guidance do
    "The person in this activation has received no reply, and no Task carries their request. " <>
      "Ending the turn does not continue it later: nothing wakes you for this request again " <>
      "unless they write. Do one of these: put the answer, or a short note on what is done and " <>
      "what is blocked, in end_turn's reply={tool,params}; or create a Task for the remaining " <>
      "work with im_api.internal.task.create; or, only when silence is deliberate, call " <>
      "end_turn with no_reply: true. Use outcome=blocked with a reason when nothing can progress."
  end

  @doc """
  The model response the kernel reads: `response` unchanged, or with its
  `end_turn` turned into refused guidance when the guard engages.
  """
  def guard(response, session, role, phase \\ :clean)

  def guard(response, session, role, phase) when InternalSession.is_session(session) do
    with {:ok, [call], put} <- calls(response),
         true <- refuse?(call, session, role, phase) do
      put.([refusal(call)])
    else
      _ -> response
    end
  end

  def guard(response, _session, _role, _phase), do: response

  @doc """
  The calls a tool record keeps: a refused `end_turn` is recorded as the
  model made it, so its history shows the call and the guidance answering it.
  """
  def model_calls(calls) when is_list(calls) do
    if Enum.any?(calls, &refusal?/1),
      do: Enum.map(calls, &model_call/1),
      else: nil
  end

  def model_calls(_calls), do: nil

  defp refuse?(call, session, role, phase) do
    role in ["router", :router] and phase == :clean and unanswered_done?(call) and
      person_waiting?(session) and nothing_attempted?(session)
  end

  defp unanswered_done?(call) do
    args = field(call, :args)

    field(call, :name) == "end_turn" and is_map(args) and field(args, :outcome) == "done" and
      is_nil(field(args, :reply)) and field(args, :no_reply) != true
  end

  defp person_waiting?(session) do
    case InternalSession.active_human_source_ids(session) do
      [] ->
        false

      ids ->
        session
        |> InternalSession.current_turn_trusted_origins(ids)
        |> Enum.any?(
          &(QueuePressure.person_origin?(&1) and is_nil(field(&1, :triage_delegation)))
        )
    end
  end

  defp nothing_attempted?(session) do
    ack = InternalSession.last_ack_message_id(session) || 0
    compacted = InternalSession.compacted_through(session) || 0

    with true <- is_integer(ack) and is_integer(compacted) and compacted <= ack,
         false <- running_async?(session),
         messages when is_list(messages) <- InternalSession.get(session, :messages) do
      not Enum.any?(messages, &attempt?(&1, ack))
    else
      _unseen -> false
    end
  end

  defp running_async?(session) do
    case InternalSession.get(session, :async_tool_calls) do
      calls when is_map(calls) ->
        Enum.any?(calls, fn {_id, record} -> field(record, :status) in ["running", :running] end)

      _none ->
        false
    end
  end

  defp attempt?(message, ack) do
    id = field(message, :id)

    is_integer(id) and id > ack and field(message, :role) == "assistant" and
      message |> field(:tool_calls) |> List.wrap() |> Enum.any?(&reaches?/1)
  end

  defp reaches?(call) when is_map(call) do
    args = field(call, :args)
    args = if is_map(args), do: args, else: %{}

    case field(call, :name) do
      "end_turn" -> not is_nil(field(args, :reply))
      "call" -> reaching_tool?(field(args, :tool))
      name -> reaching_tool?(name)
    end
  end

  defp reaches?(_call), do: false

  defp reaching_tool?(name) when is_binary(name) do
    name in @handoff or
      case String.split(name, ".") do
        ["im_api", provider, op] -> provider != "internal" and op in @send_ops
        _ -> false
      end
  end

  defp reaching_tool?(_name), do: false

  defp refusal(call) do
    call
    |> Map.drop([:reply_intent, "reply_intent"])
    |> Map.put(:name, "call")
    |> Map.delete("name")
    |> Map.put(:guidance_error, guidance())
    |> Map.put(:guidance_tool, "end_turn")
    |> Map.put(:guidance_reason, @reason)
  end

  defp refusal?(call), do: is_map(call) and field(call, :guidance_reason) == @reason

  defp model_call(call) do
    if refusal?(call),
      do: %{id: field(call, :id), name: "end_turn", args: field(call, :args)},
      else: call
  end

  defp calls({:assistant, content, calls}) when is_list(calls),
    do: {:ok, calls, &{:assistant, content, &1}}

  defp calls({:assistant, content, calls, provider_meta}) when is_list(calls),
    do: {:ok, calls, &{:assistant, content, &1, provider_meta}}

  defp calls({:assistant, content, calls, provider_meta, trace_meta}) when is_list(calls),
    do: {:ok, calls, &{:assistant, content, &1, provider_meta, trace_meta}}

  defp calls(_response), do: :none

  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp field(_map, _key), do: nil
end
