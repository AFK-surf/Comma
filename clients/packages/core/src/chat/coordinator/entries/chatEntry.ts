import { Effect } from "effect";
import type { ChatEnv, TimerHandle } from "../../env";
import type {
  ChatRuntimeSession,
  ChatTarget,
  ConversationProjection,
} from "@comma/chat-contract";
import type { CommaLocale } from "@comma/i18n";
import type { CommaConversation } from "../../api";
import {
  ConversationChannel,
  channelEnv,
  type ChatMessage,
  type ConversationChannelState,
} from "../../runtime";
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
  releaseTimer: TimerHandle | undefined;
  /** Timers and time for what this entry waits on. */
  env: ChatEnv;
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
  env: ChatEnv;
  getClientDeviceId: ChatCoordinatorOptions["getClientDeviceId"];
  locale: CommaLocale;
  onCanonicalMessagesAppended: ChatCoordinatorOptions["onCanonicalMessagesAppended"];
  onLocalFilesCommitted: ChatCoordinatorOptions["onLocalFilesCommitted"];
  transcodeAttachment: ChatCoordinatorOptions["transcodeAttachment"];
  store: ChatCoordinatorOptions["store"];
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
  const kept = host.store?.seed(target);
  const channel = new ConversationChannel({
    api: boundary.api,
    getClientDeviceId: () => host.getClientDeviceId?.(target.workspaceId),
    conversationId: target.conversationId,
    groupId: target.groupId,
    env: channelEnv(host.env, host.transcodeAttachment),
    ...(kept ? { initialState: kept.state } : {}),
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
    env: host.env,
    revision: 0,
    subscribers: new Map(),
    surfaceProjections: new Map(),
    workspaceId: target.workspaceId,
  };
  entry.releaseSubscription = channel.subscribe(() => {
    host.store?.changed(target, channel.getSnapshot());
    onChanged(entry);
  });
  // What was being sent when the device stopped goes again, with the same request id: the server keeps it once.
  for (const clientRequestId of kept?.resend ?? [])
    host.env.runner.fork(Effect.ignore(channel.retry(clientRequestId)));
  return entry;
}
