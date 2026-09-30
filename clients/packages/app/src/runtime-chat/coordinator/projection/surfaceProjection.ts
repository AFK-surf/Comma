import type { ConversationProjection } from "@comma/chat-contract";
import type { ConversationObservationState } from "../../../chat-runtime";

/**
 * One surface's view of the conversation after it cleared its presentation:
 * only what the channel first observed at or after the clear stays visible.
 */
export function materializeSurfaceProjection(
  state: ConversationProjection,
  observation: ConversationObservationState,
  minVisibleObservationSequence: number
): ConversationProjection {
  const messageIsVisible = (message: ConversationProjection["messages"][number]) =>
    (observation.messageFirstObservedSequences.get(message.messageId) ?? 0) >=
    minVisibleObservationSequence;
  const pendingIsVisible = (pending: ConversationProjection["pending"][number]) =>
    (observation.pendingFirstObservedSequences.get(pending.clientRequestId) ?? 0) >=
    minVisibleObservationSequence;
  const messages = state.messages.filter(messageIsVisible);
  const serverMessages = state.serverMessages.filter(messageIsVisible);
  const pending = state.pending.filter(pendingIsVisible);
  const assistantDraft =
    state.assistantDraft &&
    (observation.assistantDraftFirstObservedSequence ?? 0) >=
      minVisibleObservationSequence
      ? state.assistantDraft
      : undefined;
  const projectionVisible =
    assistantDraft !== undefined ||
    serverMessages.length > 0 ||
    messages.length > 0 ||
    pending.length > 0;

  const localAwaitingTurnVisible = Boolean(
    state.locallyAwaitingReply === true &&
    state.awaitingTurnKey &&
    (pending.some((item) => item.clientRequestId === state.awaitingTurnKey) ||
      messages.some(
        (message) =>
          (message.clientRequestId ?? message.messageId) === state.awaitingTurnKey
      ))
  );

  return {
    ...state,
    activity: projectionVisible ? state.activity : undefined,
    assistantDraft,
    awaitingReply: projectionVisible ? state.awaitingReply : false,
    awaitingSince: projectionVisible ? state.awaitingSince : undefined,
    awaitingTimedOut: projectionVisible ? state.awaitingTimedOut : false,
    awaitingTurnKey: projectionVisible ? state.awaitingTurnKey : undefined,
    locallyAwaitingReply: localAwaitingTurnVisible,
    errorKind: projectionVisible ? state.errorKind : undefined,
    messages,
    pending,
    serverMessages,
    syncWarning: projectionVisible ? state.syncWarning : undefined,
  };
}
