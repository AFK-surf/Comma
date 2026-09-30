/**
 * Client presentation state for one transient Participant draft.
 *
 * Modeled in tla/salix/TransientDraftDelivery.tla. Canonical Messages are
 * intentionally outside this transient Participant-draft reducer.
 */

import type { ChatAssistantDraft, ChatMessage } from "./conversationChannel";

export type VisibleReplyDraftFrame = {
  conversationId: string;
  delta?: string | undefined;
  draftId: string;
  kind: "cancelled" | "completed" | "delta" | "started";
  responseKey: string;
  revision?: number | undefined;
  sourceMessageIds: readonly string[];
  text: string;
};

type CancelledReplyFence = {
  responseKey: string;
  sourceMessageIds: readonly string[];
  validThroughIncarnation: number;
};

type ReplyIdentity = Pick<CancelledReplyFence, "responseKey" | "sourceMessageIds">;

export type VisibleReplyPresentationState = {
  activeDraft: ChatAssistantDraft | undefined;
  activeDraftIncarnation: number | undefined;
  /** At most one cancellation crosses one reconnect to fence queued duplicates. */
  cancelledReplyFence: CancelledReplyFence | undefined;
  incarnation: number;
  snapshotReady: boolean;
};

export type VisibleReplyDraftReduction = {
  presentation: VisibleReplyPresentationState;
  restartStream: boolean;
};

export const idleVisibleReplyPresentationState: VisibleReplyPresentationState = {
  activeDraft: undefined,
  activeDraftIncarnation: undefined,
  cancelledReplyFence: undefined,
  incarnation: 0,
  snapshotReady: false,
};

/**
 * Starts one local SSE attempt without disturbing the visible draft. Old
 * callbacks are fenced by the channel's incarnation check; this state waits
 * for the new attempt's authoritative first snapshot before accepting drafts.
 */
export function beginVisibleReplyStream(
  state: VisibleReplyPresentationState,
  incarnation: number
): VisibleReplyPresentationState {
  if (incarnation <= state.incarnation) {
    return state;
  }

  return {
    ...state,
    activeDraft: state.activeDraft,
    activeDraftIncarnation: state.activeDraftIncarnation,
    cancelledReplyFence:
      state.cancelledReplyFence &&
      incarnation <= state.cancelledReplyFence.validThroughIncarnation
        ? state.cancelledReplyFence
        : undefined,
    incarnation,
    snapshotReady: false,
  };
}

export function reduceVisibleReplyDraft(
  state: VisibleReplyPresentationState,
  incarnation: number,
  frame: VisibleReplyDraftFrame
): VisibleReplyDraftReduction {
  if (incarnation !== state.incarnation || !state.snapshotReady) {
    return unchanged(state);
  }

  const cancelled = state.cancelledReplyFence;
  if (matchesReply(cancelled, frame)) {
    // Preserve the existing one-reconnect cancellation fence. The response
    // key belongs to an activation, so this cannot permanently end later sends.
    return unchanged(state);
  }

  const active = state.activeDraft;
  if (active?.responseKey === frame.responseKey) {
    if (!sameOrderedIds(active.sourceMessageIds, frame.sourceMessageIds)) {
      return unchanged(state);
    }

    if (frame.kind === "cancelled") {
      return {
        presentation: {
          ...state,
          // Cancellation ends Participant ownership, but it does not remove
          // the renderer slot. Keep the final cumulative pixels until the
          // replacement snapshot atomically installs the canonical Message.
          // This prevents a blank render and preserves the React node across
          // the draft -> Message handoff.
          activeDraft: active,
          activeDraftIncarnation: state.activeDraftIncarnation,
          cancelledReplyFence: {
            responseKey: frame.responseKey,
            sourceMessageIds: [...frame.sourceMessageIds],
            validThroughIncarnation: incarnation + 1,
          },
        },
        restartStream: true,
      };
    }

    if (active.status === "completed") {
      // Completion is monotonic for content updates. Participant cancellation
      // fences further frames; the next authoritative snapshot retires the
      // presentation atomically with any canonical Message replacement.
      return unchanged(state);
    }

    const merged = mergeCumulativeFrame(
      active,
      state.activeDraftIncarnation === incarnation,
      frame
    );
    const nextDraft = toDraft(
      frame,
      merged.text,
      frame.kind === "completed" ? "completed" : "streaming",
      merged.revision
    );
    if (sameDraft(active, nextDraft)) {
      return unchanged(state);
    }

    return changed(state, nextDraft, incarnation);
  }

  if (frame.kind === "cancelled") {
    // Without an active identity there is no exact source binding to compare.
    // Recording this frame would let an unrelated cancellation poison a later
    // valid response with the same key.
    return unchanged(state);
  }

  if (active?.status === "completed") {
    // The server serializes unresolved visible replies. A second response may
    // not displace an accepted completion before its canonical snapshot.
    return unchanged(state);
  }

  if (active && frame.kind !== "started") {
    // A new response starts with `started` in each SSE incarnation. Reject an
    // unrelated delta/completion instead of guessing that it supersedes the
    // currently visible stream.
    return unchanged(state);
  }

  if (!active && frame.kind !== "started") {
    return unchanged(state);
  }

  return changed(
    state,
    toDraft(frame, frame.text, "streaming", frame.revision),
    incarnation
  );
}

export function reconcileVisibleReplySnapshot(
  state: VisibleReplyPresentationState,
  incarnation: number,
  _messages: readonly ChatMessage[],
  participantDraft?: VisibleReplyDraftFrame | null
): VisibleReplyPresentationState {
  if (incarnation !== state.incarnation) {
    return state;
  }

  // Canonical rows are independent of Participant drafts. A late Message
  // cannot end a current response, and an empty owner snapshot does not end
  // the activation: the same activation may legitimately send again.
  const ready: VisibleReplyPresentationState = {
    ...state,
    activeDraft: undefined,
    activeDraftIncarnation: undefined,
    incarnation,
    snapshotReady: true,
  };

  // An unavailable/invalid Participant read (or an older server) cannot retire
  // a response by absence. Clear the transient display without preventing a
  // later reliable snapshot from replaying that same live draft.
  if (!participantDraft) return ready;
  if (matchesReply(state.cancelledReplyFence, participantDraft)) return ready;

  const sameResponse = matchesReply(state.activeDraft, participantDraft);
  return reduceVisibleReplyDraft(
    {
      ...ready,
      activeDraft: sameResponse ? state.activeDraft : undefined,
      activeDraftIncarnation: sameResponse ? state.activeDraftIncarnation : undefined,
    },
    incarnation,
    participantDraft
  ).presentation;
}

function matchesReply(identity: ReplyIdentity | undefined, frame: ReplyIdentity) {
  return (
    identity?.responseKey === frame.responseKey &&
    sameOrderedIds(identity.sourceMessageIds, frame.sourceMessageIds)
  );
}

export function sameOrderedIds(left: readonly string[], right: readonly string[]) {
  return (
    left.length === right.length &&
    left.every((messageId, index) => messageId === right[index])
  );
}

/**
 * Stable presentation identity shared by reducer, turn ownership, React keys,
 * and Markdown playback. The opaque server key is scoped by the exact ordered
 * source binding; neither part is sufficient on its own.
 */
export function visibleReplyIdentityKey(
  responseKey: string,
  sourceMessageIds: readonly string[]
) {
  return `response:${JSON.stringify([responseKey, sourceMessageIds])}`;
}

/**
 * Stable user-turn identity shared by the channel projection and thread
 * layout. Pending and acknowledged copies of one local send keep the same
 * client request id, so the turn does not remount at acknowledgement.
 */
export function conversationMessageTurnKey(message: ChatMessage) {
  return message.clientRequestId ?? message.messageId;
}

/**
 * Resolve an exact ordered source binding to its last user source. The server
 * may bind one activation to more than one user input; the newest bound input
 * owns the visible response. Arrival order and "latest user" are never used.
 */
export function sourceOwnerTurnKey(
  messages: readonly ChatMessage[],
  sourceMessageIds: readonly string[]
) {
  const userTurnKeys = new Map(
    messages
      .filter((message) => message.role === "user")
      .map(
        (message) => [message.messageId, conversationMessageTurnKey(message)] as const
      )
  );

  for (let index = sourceMessageIds.length - 1; index >= 0; index -= 1) {
    const owner = userTurnKeys.get(sourceMessageIds[index]!);
    if (owner !== undefined) return owner;
  }

  return undefined;
}

/**
 * A bounded transcript may no longer contain the source row. In that case the
 * response keeps a deterministic composite-owned orphan turn, shared by
 * Activity, draft and canonical presentation.
 */
export function initialResponseOwnerTurnKey(
  messages: readonly ChatMessage[],
  responseIdentityKey: string,
  sourceMessageIds: readonly string[]
) {
  return (
    sourceOwnerTurnKey(messages, sourceMessageIds) ?? `orphan:${responseIdentityKey}`
  );
}

function mergeCumulativeFrame(
  current: ChatAssistantDraft,
  sameIncarnation: boolean,
  next: VisibleReplyDraftFrame
) {
  if (
    sameIncarnation &&
    current.revision !== undefined &&
    next.revision === current.revision + 1 &&
    next.delta !== undefined &&
    next.text.length === current.text.length + next.delta.length
  ) {
    return {
      revision: next.revision,
      text: current.text + next.delta,
    };
  }

  if (next.text.startsWith(current.text)) {
    return { revision: next.revision, text: next.text };
  }
  if (current.text.startsWith(next.text)) {
    return {
      revision: current.text === next.text ? next.revision : undefined,
      text: current.text,
    };
  }

  // Draft frames are cumulative. A conflicting frame is stale or malformed;
  // retaining the visible prefix avoids both regression and a full repaint.
  // The full-prefix scan is only the recovery path for a revision gap or a
  // legacy frame; continuous revision+delta frames stay O(delta).
  return { revision: undefined, text: current.text };
}

function toDraft(
  frame: VisibleReplyDraftFrame,
  text: string,
  status: ChatAssistantDraft["status"],
  revision: number | undefined
): ChatAssistantDraft {
  return {
    conversationId: frame.conversationId,
    draftId: frame.draftId,
    responseKey: frame.responseKey,
    revision,
    sourceMessageIds: [...frame.sourceMessageIds],
    status,
    text,
  };
}

function changed(
  state: VisibleReplyPresentationState,
  activeDraft: ChatAssistantDraft,
  incarnation: number
): VisibleReplyDraftReduction {
  return {
    presentation: { ...state, activeDraft, activeDraftIncarnation: incarnation },
    restartStream: false,
  };
}

function unchanged(state: VisibleReplyPresentationState): VisibleReplyDraftReduction {
  return { presentation: state, restartStream: false };
}

function sameDraft(left: ChatAssistantDraft, right: ChatAssistantDraft) {
  return (
    left.conversationId === right.conversationId &&
    left.draftId === right.draftId &&
    left.responseKey === right.responseKey &&
    left.revision === right.revision &&
    left.status === right.status &&
    left.text === right.text &&
    sameOrderedIds(left.sourceMessageIds, right.sourceMessageIds)
  );
}
