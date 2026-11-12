defmodule SalixAgent.TurnOutcome do
  @moduledoc false
  require SalixAgent.InternalSession

  alias SalixAgent.InternalSession

  @input_schema %{
    "type" => "object",
    "properties" => %{
      "outcome" => %{"type" => "string", "enum" => ["done", "blocked"]},
      "reason" => %{"type" => "string", "maxLength" => 2_000},
      "no_reply" => %{
        "type" => "boolean",
        "description" =>
          "True when you deliberately send no reply to the people in this activation: they asked for silence, or nothing they said needs an answer. Leave it out when work continues in a Task or a wait and a reply will still come. Ending the turn continues nothing by itself."
      },
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
        "Settle with done when requested work is complete, optionally carrying the final current-source reply in reply={tool,params}. The reply is sent before settlement; do not send it again. Ending the turn does not continue its work later: nothing wakes you for this request again unless the person writes. A done with no reply is refused while a person in this activation has had no reply and no Task carries their request: send the answer or a short status note in reply, create a Task for the remaining work, or set no_reply=true when silence is deliberate. Use blocked plus a reason only when no authorized action can progress. After an IFC refusal that leaves a person's request unanswered, send a generic explanation with sources: [] before settling, unless they told you not to reply. If that send is refused too, settle; the blocked reason is private. Optional clues are not blockers: continue available searches or independent work after asking. Use wait_for for a running tool or Task. This must be the only tool call in the response.",
      "input_schema" => @input_schema
    }

  @doc "`InternalSession.decision_required?/1`: an unacked settled assistant tail."
  def decision_required?(session), do: is_integer(pending_assistant_id(session))

  @doc "`InternalSession.pending_assistant_id/1`."
  def pending_assistant_id(session) when InternalSession.is_session(session),
    do: InternalSession.pending_assistant_id(session)
end
