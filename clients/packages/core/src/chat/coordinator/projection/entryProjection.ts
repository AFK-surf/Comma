import type { ChatRuntimeSession, ConversationProjection } from "@comma/chat-contract";
import { toConversationProjection } from "../../runtime";
import type { ChatEntry } from "../entries/chatEntry";
import { unresolvedIntakeFailureRows } from "../intake/intakeOutcomes";
import { materializeSurfaceProjection } from "./surfaceProjection";

/**
 * The entry's wire session, cached on the entry until it next changes. It is made of what the chat contract took where
 * it came in (a server's answer, a kept conversation as `ChatPersistence.seed` reads it), so it is not checked again.
 */
export function projectEntry(key: string, entry: ChatEntry): ChatRuntimeSession {
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
  };
  return entry.projection;
}
