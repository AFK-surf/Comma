defmodule SalixAgent.FollowupReplyGuard do
  @moduledoc """
  Holds a Router's first outbound reply when a follow-up from the same
  conversation or thread arrived while the model was generating that reply.

  While an open activation has not yet sent a reply or handed work to a Task,
  `VerifiedKernel.Session.Query.Materialize.materializeBatch` merges new wakeable
  messages of the same `originThread` into the current activation at the next
  round boundary. A message that arrives while the model call itself is in
  flight is not yet in the prompt the model answered, so executing its send or
  `end_turn` immediately would emit a partial first reply and start a second
  activation for the follow-up.

  When `active_unanswered_thread/1` names the open activation's thread and an
  unacked wakeable human message in `input_queue` shares that thread, this guard
  turns any outbound send call or `end_turn` (except a standalone `blocked`
  without `reply`) in the model response into `queued_followup` guidance.
  Non-sending calls in the same response still run, nothing is sent externally,
  and the next round materializes the follow-up so the model sends one combined
  answer.
  """

  require SalixAgent.InternalSession
  alias SalixAgent.InternalSession

  @reason "queued_followup"

  @send_ops ~w(send_message send_text send_dm reply_message reply_text reply_image
               reply_file reply_video post_message post_channel_message say
               update_message send_photo send_document send_image send_file
               post_task_card open_task_topic)

  def reason, do: @reason

  @doc "The guidance returned for a held send or `end_turn`."
  def guidance do
    "A follow-up message arrived in this conversation while you were preparing this reply, " <>
      "and nothing was sent yet. That message joins this activation on the next round. " <>
      "Read all messages of this activation together and send one combined reply."
  end

  @doc """
  The model response the kernel reads: `response` unchanged, or with premature
  outbound sends / `end_turn` turned into `queued_followup` guidance.
  """
  def guard(response, session, role, phase \\ :clean)

  def guard(response, session, role, phase) when InternalSession.is_session(session) do
    with true <- role in ["router", :router] and phase == :clean,
         {:ok, calls, put} when calls != [] <- calls(response),
         thread when is_list(thread) <- InternalSession.active_unanswered_thread(session),
         true <- queued_same_thread?(session, thread),
         {guarded, true} <- guard_calls(calls) do
      put.(guarded)
    else
      _ -> response
    end
  end

  def guard(response, _session, _role, _phase), do: response

  @doc """
  The calls a tool record keeps: a refused call is recorded as the model made it.
  """
  def model_calls(calls) when is_list(calls) do
    if Enum.any?(calls, &refusal?/1),
      do: Enum.map(calls, &model_call/1),
      else: nil
  end

  def model_calls(_calls), do: nil

  defp queued_same_thread?(session, thread) do
    session
    |> InternalSession.unacked_queue_items()
    |> List.wrap()
    |> Enum.any?(fn item ->
      wakeable_human_item?(item) and
        InternalSession.origin_thread(origin_of(item)) == thread
    end)
  end

  defp guard_calls([call]) do
    if intercept_end_turn?(call) or intercept_reaching?(call) do
      {[refusal(call)], true}
    else
      {[call], false}
    end
  end

  defp guard_calls(calls) do
    Enum.map_reduce(calls, false, fn call, changed? ->
      if intercept_reaching?(call) do
        {refusal(call), true}
      else
        {call, changed?}
      end
    end)
  end

  defp intercept_end_turn?(call) when is_map(call) do
    args = decode_args(field(call, :args))

    is_nil(field(call, :guidance_reason)) and field(call, :name) == "end_turn" and
      (not is_nil(field(args, :reply)) or
         (field(args, :outcome) == "done" and field(args, :no_reply) != true))
  end

  defp intercept_end_turn?(_call), do: false

  defp intercept_reaching?(call) when is_map(call) do
    if is_nil(field(call, :guidance_reason)) do
      name = field(call, :name)
      args = decode_args(field(call, :args))
      target = if name == "call", do: field(args, :tool), else: name
      reaching_tool?(target)
    else
      false
    end
  end

  defp intercept_reaching?(_call), do: false

  defp reaching_tool?(name)
       when name in ["im_api.internal.send_message", "im_api.internal.task.create"],
       do: true

  defp reaching_tool?(name) when is_binary(name) do
    case String.split(String.trim(name), ".") do
      ["im_api", provider, op] -> provider != "internal" and op in @send_ops
      _ -> false
    end
  end

  defp reaching_tool?(_name), do: false

  defp refusal(call) do
    original_name = field(call, :name) || "call"
    args = decode_args(field(call, :args))

    target =
      cond do
        original_name == "end_turn" -> "end_turn"
        original_name == "call" and is_binary(field(args, :tool)) -> field(args, :tool)
        true -> original_name
      end

    call
    |> Map.drop([:reply_intent, "reply_intent", :terminal_reply, "terminal_reply"])
    |> Map.put(:name, "call")
    |> Map.delete("name")
    |> Map.put(:guidance_error, guidance())
    |> Map.put(:guidance_tool, target)
    |> Map.put(:guidance_reason, @reason)
  end

  defp refusal?(call), do: is_map(call) and field(call, :guidance_reason) == @reason

  defp model_call(call) do
    if refusal?(call) do
      guidance_tool = field(call, :guidance_tool)
      args = decode_args(field(call, :args))

      name =
        cond do
          guidance_tool == "end_turn" -> "end_turn"
          Map.has_key?(args, "tool") or Map.has_key?(args, :tool) -> "call"
          is_binary(guidance_tool) and guidance_tool != "" -> guidance_tool
          true -> "call"
        end

      %{id: field(call, :id), name: name, args: field(call, :args)}
    else
      call
    end
  end

  defp wakeable_human_item?(item) when is_map(item) do
    wake = field(item, :wake)
    payload = payload_of(item)
    origin = origin_of(item)
    obligation = field(payload, :provider_reply_obligation)

    wake != false and field(item, :kind) == "user_message" and
      (InternalSession.human_source_origin?(origin) or
         (is_map(obligation) and external_provider?(field(obligation, :provider))))
  end

  defp wakeable_human_item?(_item), do: false

  defp external_provider?(provider) when is_binary(provider) do
    trimmed = String.trim(provider)
    trimmed != "" and trimmed != "internal"
  end

  defp external_provider?(_provider), do: false

  defp origin_of(item) do
    case field(payload_of(item), :trusted_origin) do
      origin when is_map(origin) -> origin
      _ -> %{}
    end
  end

  defp payload_of(item) do
    case field(item, :payload) do
      payload when is_map(payload) -> payload
      _ -> %{}
    end
  end

  defp decode_args(args) when is_map(args), do: args

  defp decode_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_args(_args), do: %{}

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
