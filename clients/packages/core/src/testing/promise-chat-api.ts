// A chat API for tests written with promises: each request a test answers by hand (a promise it resolves or
// rejects), the way the engine's requests used to look. Each becomes the effect the engine runs; interrupting it
// aborts the signal the request was given (the ones that took one: a poll, an upload, a stream), as the host's
// request stops.
import { Effect } from "effect";
import type { ManualTaskStatus } from "@comma/chat-contract";
import type { ChatApi, CommaLocalFileRef } from "../chat/api.ts";
import type {
  CommaConversation,
  CommaConversationEvent,
  CommaConversationListEvent,
  CommaGroupFile,
  CommaSkill,
  CommaTaskParticipantStatuses,
  CommaWorkspace,
  CommaWorkspaceBootstrap,
  SalixBlobRef,
} from "../comma/api-schemas.ts";

/** The chat API as a test answers it: each request a promise, given a signal that stops it. */
export interface PromiseChatApi {
  bootstrapWorkspace(options?: {
    signal?: AbortSignal;
  }): Promise<CommaWorkspaceBootstrap>;
  listWorkspaces(options?: { signal?: AbortSignal }): Promise<CommaWorkspace[]>;
  ensureGroupChat(
    groupId: string,
    options?: { signal?: AbortSignal }
  ): Promise<CommaConversation>;
  acceptTaskReview(
    groupId: string,
    conversationId: string,
    reviewVersion: number
  ): Promise<CommaConversation>;
  setTaskStatus(
    groupId: string,
    conversationId: string,
    status: ManualTaskStatus,
    expectedUpdatedAt: number
  ): Promise<CommaConversation>;
  pollConversation(
    groupId: string,
    conversationId: string,
    opts?: { etag?: string; signal?: AbortSignal }
  ): Promise<{ conversation?: CommaConversation; etag?: string; notModified: boolean }>;
  listWorkspaceSkills(workspaceId: string): Promise<CommaSkill[]>;
  uploadGroupFile(
    groupId: string,
    attrs: { data: Blob; name: string; signal?: AbortSignal }
  ): Promise<CommaGroupFile>;
  fetchGroupFile(
    groupId: string,
    path: string,
    options?: { signal?: AbortSignal }
  ): Promise<Blob>;
  fetchAgentBlob(
    groupId: string,
    agentId: string,
    ref: SalixBlobRef,
    options?: { signal?: AbortSignal }
  ): Promise<Blob>;
  sendMessage(
    groupId: string,
    conversationId: string,
    attrs: {
      text: string;
      clientRequestId?: string;
      clientDeviceId?: string;
      replyToMessageId?: string;
      localFiles?: CommaLocalFileRef[];
      skills?: { location: string }[];
    }
  ): Promise<CommaConversation>;
  streamConversationEvents(
    groupId: string,
    conversationId: string,
    opts: {
      signal?: AbortSignal;
      waitMs?: number;
      onEvent: (event: CommaConversationEvent, eventName: string) => void;
    }
  ): Promise<void>;
  streamConversationListEvents(
    groupId: string,
    opts: {
      conversationId?: string;
      onParticipantStatuses?: (event: CommaTaskParticipantStatuses) => void;
      signal?: AbortSignal;
      waitMs?: number;
      onEvent: (event: CommaConversationListEvent) => void;
    }
  ): Promise<void>;
}

/** Where each request that took a signal had its options. */
const signalAt: Partial<Record<keyof ChatApi, number>> = {
  pollConversation: 2,
  streamConversationEvents: 2,
  streamConversationListEvents: 1,
  uploadGroupFile: 1,
};

/** The members that are Effects rather than functions: the fake's method runs each time one runs. */
const effectMembers = new Set<string>(["bootstrapWorkspace", "listWorkspaces"]);

export function promiseChatApi(fake: object): ChatApi {
  const methods = fake as Record<string, unknown>;
  return new Proxy({} as ChatApi, {
    get(_, name: string) {
      const method = methods[name];
      if (typeof method !== "function") return undefined;
      const at = signalAt[name as keyof ChatApi];
      const run = (...args: unknown[]) =>
        // A fake fails as its promise did: the test throws what the real API would fail with.
        // @effect-diagnostics-next-line globalErrorInEffectCatch:off
        Effect.tryPromise({
          try: (signal) => {
            const call = [...args];
            if (at !== undefined)
              call[at] = { ...(call[at] as object | undefined), signal };
            return Promise.resolve(
              (method as (...a: unknown[]) => unknown).apply(fake, call)
            );
          },
          catch: (error) => error as Error,
        });
      return effectMembers.has(name) ? run() : run;
    },
  });
}
