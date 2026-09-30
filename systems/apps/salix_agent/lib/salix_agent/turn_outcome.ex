defmodule SalixAgent.TurnOutcome do
  @moduledoc false
  require SalixAgent.InternalSession

  alias SalixAgent.InternalSession

  @input_schema %{
    "type" => "object",
    "properties" => %{
      "outcome" => %{"type" => "string", "enum" => ["done", "blocked"]},
      "reason" => %{"type" => "string", "maxLength" => 2_000},
      "reply" => %{
        "type" => "object",
        "description" =>
          "Optional current-source reply to send before settlement. Use the same disclosed IM or Comma operation and its provider params. A failed or refused send leaves the turn open.",
        "properties" => %{
          "tool" => %{"type" => "string"},
          "params" => %{"type" => "object"},
          "ifc" => SalixAgent.IFC.Declaration.schema()
        },
        "required" => ["tool", "params"]
      }
    },
    "required" => ["outcome"]
  }

  def spec,
    do: %{
      "name" => "end_turn",
      "description" =>
        "Settle with done when requested work is complete, optionally carrying the final current-source reply in reply={tool,params}. The reply is sent before settlement; do not send it again. Use blocked plus a reason only when no authorized action can progress. No successful send is required after an IFC refusal; the blocked reason is private. Optional clues are not blockers: continue available searches or independent work after asking. Use wait_for for a running tool or Task. This must be the only tool call in the response.",
      "input_schema" => @input_schema
    }

  def append_reminder(messages, session, enabled?),
    do:
      InternalSession.query(session, :provider_request_part, {:turn_reminder, messages, enabled?})

  @doc "`InternalSession.decision_required?/1`: an unacked settled assistant tail."
  def decision_required?(session), do: is_integer(pending_assistant_id(session))

  @doc "`InternalSession.pending_assistant_id/1`."
  def pending_assistant_id(session) when InternalSession.is_session(session),
    do: InternalSession.pending_assistant_id(session)
end
