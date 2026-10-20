import type { StationAgentState, StationCardShown } from "@comma/core/contract";
import type { useCommaMessages } from "@comma/i18n/react";

type Messages = ReturnType<typeof useCommaMessages>;

/** An agent's state in words. */
export function agentStateText(messages: Messages, state: StationAgentState): string {
  const detail = state.detail;
  switch (state.status) {
    case "running":
      return messages.stations_agent_running();
    case "queued":
      return messages.stations_agent_queued();
    case "done":
      return detail
        ? messages.stations_agent_done_with({ detail })
        : messages.stations_agent_done();
    case "needs_you":
      return detail
        ? messages.stations_agent_needs_you_with({ detail })
        : messages.stations_agent_needs_you();
    case "failed":
      return messages.stations_agent_failed({
        why: failureText(messages, state.failure),
      });
    case "stopped_unexpectedly":
      return messages.stations_agent_stopped_unexpectedly();
    case "stopped":
      return messages.stations_agent_stopped();
    case "waiting":
      return detail
        ? messages.stations_agent_waiting_for({ detail })
        : messages.stations_agent_waiting();
    case "watching":
      return messages.stations_agent_watching();
    default:
      return messages.stations_agent_idle();
  }
}

function failureText(messages: Messages, failure: StationAgentState["failure"]) {
  switch (failure) {
    case "rate_limit":
      return messages.stations_failure_rate_limit();
    case "auth":
      return messages.stations_failure_auth();
    case "model":
      return messages.stations_failure_model();
    case "exited":
      return messages.stations_failure_exited();
    default:
      return messages.stations_failure_other();
  }
}

/** Who decides a card, in words. */
export function deciderText(messages: Messages, card: StationCardShown): string {
  const decider = card.decider;
  if (decider.kind === "you") return messages.stations_card_decider_you();
  if (decider.kind === "other")
    return messages.stations_card_decider_other({ name: decider.name });
  return messages.stations_card_decider_none();
}
