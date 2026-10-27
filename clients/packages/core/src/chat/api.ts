// The Comma API as chat uses it: the requests a conversation, its sends, its files and the workspace's chat make.
// The core answers them through the host (chat/http.ts), for the account's session; nothing here holds a credential.
import type { ChatTaskRunChoice, ManualTaskStatus } from "@comma/chat-contract";
import { Data, type Effect } from "effect";
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
  SalixMessage,
} from "../comma/api-schemas.ts";

export type {
  CommaConversation,
  CommaConversationEvent,
  CommaConversationKind,
  CommaConversationListEvent,
  SalixContentBlock,
  SalixMessage,
} from "../comma/api-schemas.ts";

/** A body the server refused, as it said why. */
export type CommaApiErrorBody = { error?: unknown; [key: string]: unknown };

/** A chat command that was refused or could not be done, as a person reads it (`message`). */
export class ChatError extends Data.TaggedError("ChatError")<{
  readonly message: string;
  readonly cause?: unknown;
}> {
  constructor(message: string, options?: { readonly cause?: unknown }) {
    super(
      options?.cause === undefined ? { message } : { message, cause: options.cause }
    );
  }
}

/** A request the server answered with an error status (`status`), and its body. */
export class CommaApiError extends Error {
  readonly status: number;
  readonly body: CommaApiErrorBody | undefined;

  constructor(status: number, message: string, body?: CommaApiErrorBody) {
    super(message);
    this.name = "CommaApiError";
    this.status = status;
    this.body = body;
  }
}

/** A file on this device registered for a send (Electron): the server reads it through the device, not an upload. */
export type CommaLocalFileRef = {
  displayName: string;
  localFileRef: string;
  mediaType: string;
  size: number;
};

/**
 * The requests chat makes, as effects: each is the core's request underneath. One that the server refused fails with a
 * CommaApiError; one that got no answer with a plain Error (the network). Interrupting one stops it.
 */
export interface ChatApi {
  readonly bootstrapWorkspace: Effect.Effect<CommaWorkspaceBootstrap, Error>;
  readonly listWorkspaces: Effect.Effect<CommaWorkspace[], Error>;
  ensureGroupChat(groupId: string): Effect.Effect<CommaConversation, Error>;
  acceptTaskReview(
    groupId: string,
    conversationId: string,
    reviewVersion: number
  ): Effect.Effect<CommaConversation, Error>;
  setTaskStatus(
    groupId: string,
    conversationId: string,
    status: ManualTaskStatus,
    expectedUpdatedAt: number
  ): Effect.Effect<CommaConversation, Error>;
  /** Runs a Task on another model, perhaps in another place; refused (422 `task_run_refused`) with why. */
  setTaskRun(
    groupId: string,
    conversationId: string,
    run: ChatTaskRunChoice
  ): Effect.Effect<CommaConversation, Error>;
  pollConversation(
    groupId: string,
    conversationId: string,
    opts?: { etag?: string }
  ): Effect.Effect<
    { conversation?: CommaConversation; etag?: string; notModified: boolean },
    Error
  >;
  /**
   * A page of a conversation's canonical messages by seq: the newest `limit`, those before seq `before`, or those
   * after seq `after`. `covered` is the seq range the page proves read (hidden messages included), `bounds` the
   * conversation's first and last seq.
   */
  listMessages(
    groupId: string,
    conversationId: string,
    /** `view: "activity"` cuts each message to what a Task's Activity reads. */
    query: { limit: number; before?: number; after?: number; view?: "activity" }
  ): Effect.Effect<CommaMessagePage, Error>;
  listWorkspaceSkills(workspaceId: string): Effect.Effect<CommaSkill[], Error>;
  uploadGroupFile(
    groupId: string,
    attrs: { data: Blob; name: string }
  ): Effect.Effect<CommaGroupFile, Error>;
  /**
   * Uploads a file a pick left with the host (`localFileRef`), its bytes read from there as they are sent. Absent where
   * the host cannot (`Host.uploadsLocalFiles`).
   */
  uploadLocalFile?(
    groupId: string,
    attrs: { localFileRef: string; name: string; size: number }
  ): Effect.Effect<CommaGroupFile, Error>;
  /** Stores attachment `index` of a message in the Group as a composer file, by reference to its blob. */
  storeConversationFile(
    groupId: string,
    file: { conversationId: string; messageId: string; index: number }
  ): Effect.Effect<CommaGroupFile, Error>;
  fetchGroupFile(groupId: string, path: string): Effect.Effect<Blob, Error>;
  fetchAgentBlob(
    groupId: string,
    agentId: string,
    ref: SalixBlobRef
  ): Effect.Effect<Blob, Error>;
  sendMessage(
    groupId: string,
    conversationId: string,
    attrs: {
      text: string;
      clientRequestId?: string;
      clientDeviceId?: string;
      replyToMessageId?: string;
      localFiles?: CommaLocalFileRef[];
      /** The question card the message answers: sent as its `question_answer` block. */
      questionAnswer?: {
        questionMessageId: string;
        choiceIds: string[];
        other?: string | undefined;
        skipped: boolean;
      };
      skills?: { location: string }[];
    }
  ): Effect.Effect<CommaConversation, Error>;
  streamConversationEvents(
    groupId: string,
    conversationId: string,
    opts: {
      waitMs?: number;
      onEvent: (event: CommaConversationEvent, eventName: string) => void;
    }
  ): Effect.Effect<void, Error>;
  streamConversationListEvents(
    groupId: string,
    opts: {
      conversationId?: string;
      onParticipantStatuses?: (event: CommaTaskParticipantStatuses) => void;
      waitMs?: number;
      onEvent: (event: CommaConversationListEvent) => void;
    }
  ): Effect.Effect<void, Error>;
}

/** The engine's name for the API it is given. */
export type CommaApiClient = ChatApi;

/** A seq range, both ends read. */
export type CommaSeqRange = { first: number; last: number };

export type CommaMessagePage = {
  messages: SalixMessage[];
  covered: CommaSeqRange | undefined;
  bounds: CommaSeqRange | undefined;
  hasOlder: boolean;
};
