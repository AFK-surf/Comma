import {
  chatRuntimeSessionSchema,
  sideChatMessageWindow,
  type ChatRuntimeSession,
  type ConversationProjection,
  type SideChatSession,
} from "@comma/chat-contract";
import { toConversationProjection } from "../../../chat-runtime";
import { REJECTED_PROJECTION, type ChatEntry } from "../entries/chatEntry";
import { unresolvedIntakeFailureRows } from "../intake/intakeOutcomes";
import { materializeSurfaceProjection } from "./surfaceProjection";

const RENDERER_MESSAGE_WINDOW = 500;

/**
 * The entry's wire session, cached on the entry until it next changes;
 * undefined while the wire contract rejects it.
 */
export function projectEntry(
  key: string,
  entry: ChatEntry
): ChatRuntimeSession | undefined {
  if (entry.runtimeProjection === REJECTED_PROJECTION) return undefined;
  if (entry.runtimeProjection) return entry.runtimeProjection;
  const state = projectRendererState(entry);
  const observation =
    entry.surfaceProjections.size > 0 ? entry.channel.getObservationState() : undefined;
  const surfaceProjections = [...entry.surfaceProjections.entries()]
    .toSorted(([left], [right]) => left.localeCompare(right))
    .map(([subscriberId, projection]) => ({
      generation: projection.generation,
      state: materializeSurfaceProjection(
        state,
        observation!,
        projection.minVisibleObservationSequence
      ),
      subscriberId,
    }));
  const session: ChatRuntimeSession = {
    conversationId: entry.conversationId,
    groupId: entry.groupId,
    draftEpoch: entry.draftEpoch,
    ...(entry.draftOwnerSurfaceId
      ? { draftOwnerSurfaceId: entry.draftOwnerSurfaceId }
      : {}),
    key,
    refs: entry.subscribers.size,
    revision: entry.revision,
    state,
    ...(surfaceProjections.length > 0 ? { surfaceProjections } : {}),
    workspaceId: entry.workspaceId,
  };
  // A retained channel can outlive a server rollout and briefly hold a
  // projection produced by the previous wire contract. Keep the global
  // state envelope usable for every other Conversation while the same
  // channel replaces that projection from its next canonical snapshot. The
  // check runs here, once per rebuild: a publish for one session must not
  // re-validate every other session's cached, unchanged projection.
  if (!chatRuntimeSessionSchema.safeParse(session).success) {
    entry.runtimeProjection = REJECTED_PROJECTION;
    return undefined;
  }
  entry.runtimeProjection = session;
  return session;
}

function projectRendererState(entry: ChatEntry): ConversationProjection {
  if (entry.projection) return entry.projection;
  const state = toConversationProjection(entry.channel.getSnapshot(), {
    groupId: entry.groupId,
    workspaceId: entry.workspaceId,
  });
  const intakeFailures = unresolvedIntakeFailureRows(entry.attachmentIntakeFailures);
  // Claim to settle, not dialog open to dialog closed: the files are
  // imported after the dialog closes, and a Renderer that stopped waiting
  // at that point would skip the outcome entirely.
  const attachmentIntakeInFlight = entry.attachmentIntakes.size > 0;
  entry.projection = {
    ...state,
    ...(attachmentIntakeInFlight ? { attachmentIntakeInFlight } : {}),
    draftAttachments: [...state.draftAttachments, ...intakeFailures],
    messages: trailing(state.messages, RENDERER_MESSAGE_WINDOW),
    pending: trailing(state.pending, RENDERER_MESSAGE_WINDOW),
    serverMessages: trailing(state.serverMessages, RENDERER_MESSAGE_WINDOW),
  };
  return entry.projection;
}

/** The side chat view of an entry, while its session is current. */
export function projectSideChatSession(
  entry: ChatEntry | undefined
): SideChatSession | undefined {
  return entry?.boundary.isCurrent() ? projectSideChatEntry(entry) : undefined;
}

function projectSideChatEntry(entry: ChatEntry): SideChatSession {
  const state = entry.channel.getSnapshot();
  return {
    conversationId: entry.conversationId,
    groupId: entry.groupId,
    revision: entry.revision,
    state: {
      ...(state.assistantDraft ? { assistantDraft: state.assistantDraft } : {}),
      awaitingReply: state.awaitingReply,
      ...(state.errorKind ? { errorKind: state.errorKind } : {}),
      messages: trailing(state.messages, sideChatMessageWindow),
    },
    workspaceId: entry.workspaceId,
  };
}

function trailing<T>(items: T[], limit: number): T[] {
  return items.length > limit ? items.slice(-limit) : items;
}
