defmodule BridgeForTeams.TriagePeerReviewObservation do
  @moduledoc false

  # These are test observations, not production workflow enforcement. Session
  # ordering proves receipt/relay before revision, not factual quality or that
  # the relay accurately preserves the report; those need full-content review.
  def ordered_revision?(messages, review_task, report, original_task, revision, baseline_count) do
    receipt = returned_index(messages, review_task, report)
    revised = returned_index(messages, original_task, revision)

    relays =
      messages
      |> Enum.with_index()
      |> Enum.flat_map(fn {message, index} ->
        for call <- value(message, :tool_calls) || [],
            index >= baseline_count,
            relay_to?(call, original_task),
            do: index
      end)

    case relays do
      [relay] ->
        is_integer(receipt) and is_integer(revised) and
          baseline_count <= receipt and receipt < relay and relay < revised

      _ ->
        false
    end
  end

  def provider_allowed?(state, now) do
    state.provider_calls < Map.get(state, :provider_call_limit, 40) and now < state.deadline
  end

  def request_identity do
    # Round sets this in the same process before calling LLM's dispatch funnel.
    # Missing identity stays missing (e.g. compaction), never inferred from opts.
    case Process.get({SalixAgent.Round, :llm_meter_tracker}) do
      %{history_context: context} ->
        Map.take(context, [:agent_id, :session_id, :round_id, :request_id])

      _ ->
        %{}
    end
  end

  defp returned_index(messages, task, result) do
    Enum.find_index(messages, fn message ->
      origin = value(message, :trusted_origin) || %{}

      value(message, :role) == "user" and origin["provider"] == "internal" and
        origin["conversation_id"] == task and origin["message_id"] == result
    end)
  end

  defp relay_to?(call, original_task) do
    args = value(call, :args) || %{}

    args["tool"] == "im_api.internal.send_message" and
      get_in(args, ["params", "conversation_id"]) == original_task
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, to_string(key)))
end
