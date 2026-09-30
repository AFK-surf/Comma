import type {
  ChatRuntimeSession,
  ChatTarget,
  ConversationProjection,
} from "@comma/chat-contract";
import type { CommaLocale } from "@comma/i18n";
import type { CommaConversation } from "../../../api";
import {
  ConversationChannel,
  type ChatMessage,
  type ConversationChannelState,
} from "../../../chat-runtime";
import type { ChatCoordinatorOptions } from "../hostContract";
import type {
  ChatAttachmentIntakeFailure,
  ChatEntryAttachmentIntake,
} from "../intake/intakeOutcomes";
import type { ChatSessionBoundary } from "./sessionBoundary";

/**
 * Cached in place of a runtime projection the wire contract rejected, so the
 * verdict is reached once per rebuild rather than once per publish.
 */
export const REJECTED_PROJECTION: unique symbol = Symbol("rejected-projection");

/** One retained conversation: its channel and everything Main owns about it. */
export type ChatEntry = {
  attachmentIntakes: Map<string, ChatEntryAttachmentIntake>;
  attachmentIntakeFailures: Map<string, ChatAttachmentIntakeFailure>;
  activeSendIntent: ChatSendIntentReservation | undefined;
  committedSendIntents: Set<string>;
  inFlightSendIntents: Set<string>;
  boundary: ChatSessionBoundary;
  channel: ConversationChannel;
  conversationId: string;
  groupId: string;
  draftEpoch: number;
  draftOwnerSurfaceId: string | undefined;
  key: string;
  /** The channel state last projected, to tell a draft-only emit apart. */
  observedState: ConversationChannelState;
  projection: ConversationProjection | undefined;
  runtimeProjection: ChatRuntimeSession | typeof REJECTED_PROJECTION | undefined;
  releaseTimer: ReturnType<typeof setTimeout> | undefined;
  releaseSubscription: () => void;
  revision: number;
  subscribers: Map<string, string>;
  surfaceProjections: Map<string, SurfaceProjectionState>;
  workspaceId: string;
};

export type ChatSendIntentReservation = {
  committing: boolean;
  draftEpoch: number;
  leaseId: string;
  sendIntentId: string;
  subscriberId: string;
  surfaceId: string;
};

export type SurfaceProjectionState = {
  generation: number;
  lastUsed: number;
  minVisibleObservationSequence: number;
};

/** The host hooks every retained conversation channel is built with. */
export type ChatChannelHost = {
  getClientDeviceId: ChatCoordinatorOptions["getClientDeviceId"];
  locale: CommaLocale;
  onCanonicalMessagesAppended: ChatCoordinatorOptions["onCanonicalMessagesAppended"];
  onLocalFilesCommitted: ChatCoordinatorOptions["onLocalFilesCommitted"];
  transcodeAttachment: ChatCoordinatorOptions["transcodeAttachment"];
};

export function chatKey(target: ChatTarget) {
  return `${target.groupId}/${target.conversationId}`;
}

/** A new entry whose channel reports every change to `onChanged`. */
export function createChatEntry(
  target: ChatTarget,
  boundary: ChatSessionBoundary,
  host: ChatChannelHost,
  onChanged: (entry: ChatEntry) => void
): ChatEntry {
  const channel = new ConversationChannel({
    api: boundary.api,
    getClientDeviceId: () => host.getClientDeviceId?.(target.workspaceId),
    conversationId: target.conversationId,
    groupId: target.groupId,
    env: {
      transcodeAttachment: host.transcodeAttachment,
      visibility: alwaysVisible,
    },
    locale: host.locale,
    ...(host.onLocalFilesCommitted
      ? { onLocalFilesCommitted: host.onLocalFilesCommitted }
      : {}),
    ...(host.onCanonicalMessagesAppended
      ? {
          onCanonicalMessagesAppended: (input: {
            conversation: CommaConversation;
            messages: readonly ChatMessage[];
          }) => {
            host.onCanonicalMessagesAppended?.({ ...input, target });
          },
        }
      : {}),
    workspaceId: target.workspaceId,
  });
  const entry: ChatEntry = {
    attachmentIntakes: new Map(),
    attachmentIntakeFailures: new Map(),
    activeSendIntent: undefined,
    committedSendIntents: new Set(),
    inFlightSendIntents: new Set(),
    boundary,
    channel,
    conversationId: target.conversationId,
    groupId: target.groupId,
    draftEpoch: 0,
    draftOwnerSurfaceId: undefined,
    key: chatKey(target),
    observedState: channel.getSnapshot(),
    projection: undefined,
    runtimeProjection: undefined,
    releaseSubscription: () => {},
    releaseTimer: undefined,
    revision: 0,
    subscribers: new Map(),
    surfaceProjections: new Map(),
    workspaceId: target.workspaceId,
  };
  entry.releaseSubscription = channel.subscribe(() => onChanged(entry));
  return entry;
}

const alwaysVisible = {
  isVisible: () => true,
  subscribe: () => () => {},
};
