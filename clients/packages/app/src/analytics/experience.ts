import type { ConversationViewState } from "../components/chat/composer/conversationDraft";
import { sourceOwnerTurnKey } from "@comma/core/chat";
import { uiClock } from "@comma/ui/clock";
import {
  captureCommaExperience,
  commaAnalyticsIdentity,
  type ChatSurface,
} from "./client";

/**
 * Observes one visible surface. Only canonical source Message IDs leave the observer.
 * Each duration ends when the window shows something, so the UI clock measures it.
 */
export function createConversationAnalytics(surface: ChatSurface) {
  let previous: ConversationViewState | undefined;
  let identity = commaAnalyticsIdentity();
  let openedAt = uiClock.monotonic();
  let ready = false;
  let reconnectAt: number | undefined;
  let awaiting:
    | { key: string; startedAt: number; firstVisible: boolean; timedOut: boolean }
    | undefined;

  return (state: ConversationViewState, visible: boolean) => {
    const currentIdentity = commaAnalyticsIdentity();
    if (
      !visible ||
      currentIdentity !== identity ||
      (previous?.conversation !== undefined &&
        previous.conversation.id !== state.conversation?.id)
    ) {
      previous = undefined;
      awaiting = undefined;
      reconnectAt = undefined;
      ready = false;
      openedAt = uiClock.monotonic();
      identity = currentIdentity;
    }
    if (!visible) return;
    const now = uiClock.monotonic();
    const wasReady = ready;
    if (!ready && state.status === "ready") {
      ready = true;
      captureCommaExperience("comma_conversation_ready", {
        surface,
        duration_ms: Math.round(now - openedAt),
      });
    }
    // Hydration is a baseline, not a new send/response or a fresh failure.
    if (previous && wasReady) {
      if (state.connection !== previous.connection) {
        if (state.connection === "reconnecting") reconnectAt = now;
        captureCommaExperience("comma_connection_state_changed", {
          surface,
          state: state.connection,
          duration_ms:
            state.connection === "live" && reconnectAt !== undefined
              ? Math.round(now - reconnectAt)
              : undefined,
        });
        if (state.connection === "live") reconnectAt = undefined;
      }
      if (
        state.awaitingReply &&
        state.awaitingTurnKey &&
        state.awaitingTurnKey !== previous.awaitingTurnKey
      ) {
        awaiting = {
          key: state.awaitingTurnKey,
          startedAt: now,
          firstVisible: false,
          timedOut: false,
        };
      }
      if (awaiting) {
        const draft = state.assistantDraft;
        if (
          !awaiting.firstVisible &&
          draft?.text.trim() &&
          sourceOwnerTurnKey(state.messages, draft.sourceMessageIds) === awaiting.key
        ) {
          awaiting.firstVisible = true;
          captureCommaExperience("comma_reply_first_visible", {
            surface,
            source_message_id: draft.sourceMessageIds
              .toReversed()
              .find((id) =>
                state.messages.some(
                  (message) => message.role === "user" && message.messageId === id
                )
              ),
            duration_ms: Math.round(now - awaiting.startedAt),
          });
        }
        if (
          !awaiting.firstVisible &&
          !awaiting.timedOut &&
          state.awaitingTimedOut &&
          state.awaitingTurnKey === awaiting.key
        ) {
          awaiting.timedOut = true;
          captureCommaExperience("comma_reply_wait_timed_out", {
            surface,
            duration_ms: Math.round(now - awaiting.startedAt),
          });
        }
      }
      const participant = state.participantStatus;
      if (
        participant?.state === "error" &&
        (previous.participantStatus?.state !== "error" ||
          previous.participantStatus.updatedAt !== participant.updatedAt)
      ) {
        captureCommaExperience("comma_participant_failed", {
          surface,
          error_kind:
            participant.issue === "runtime_failed" ? "runtime_failed" : "other",
        });
      }
    }
    previous = state;
  };
}
