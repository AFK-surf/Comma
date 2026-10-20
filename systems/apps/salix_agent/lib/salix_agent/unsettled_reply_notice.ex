defmodule SalixAgent.UnsettledReplyNotice do
  @moduledoc """
  Tells the model that its last response did not end the turn.

  A response with no tool call, plain text or empty, leaves the turn open
  (`SalixAgent.TurnOutcome.decision_required?/1`), and the runtime asks the
  model again. Without a newer message that request ends with the model's own
  response. Anthropic models refuse it as assistant prefill (HTTP 400, "This
  model does not support assistant message prefill", or "The final block in
  an assistant message cannot be thinking" when the response held only
  reasoning). On staging on 2026-10-08 a Task Worker's empty responses met that
  refusal six rounds in a row, and the Worker stopped without a report.

  While the turn is open, each continuation gets one runtime message. The
  request then ends with the runtime's message, which says why the model is
  asked again. The unsettled-round guard still bounds the continuations.
  """

  alias SalixAgent.InternalSession
  require SalixAgent.InternalSession

  @doc "The runtime messages for the activation about to run."
  @spec prepare(term()) :: [map()]
  def prepare(session) do
    if InternalSession.is_session(session) and InternalSession.decision_required?(session),
      do: [payload()],
      else: []
  end

  defp payload do
    %{
      "runtime_message_id" => "unsettled-reply:" <> SystemsRuntime.Proc.uuid(),
      "runtime_message_type" => "unsettled_reply",
      "content_kind" => "model_context",
      "summary" => "the previous response did not end the turn",
      "content" =>
        "Your previous response had no tool call, so nobody received it and the turn is still open. " <>
          "If the work is done, call end_turn with outcome done, carrying reply={tool,params} when the result is still unsent. " <>
          "If no authorized action can progress, call end_turn with outcome blocked and a reason. " <>
          "Otherwise continue the work with a tool.",
      "created_at" => SystemsClock.system_time(:second),
      "source_refs" => %{"providers" => ["unsettled_reply"]}
    }
  end
end
