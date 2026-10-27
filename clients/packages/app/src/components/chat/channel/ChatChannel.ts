import type {
  ChatConversationFile,
  ChatTaskRunChoice,
  ManualTaskStatus,
} from "@comma/chat-contract";
import type {
  AttachmentUploadInput,
  ChatImagePreviewRef,
  ConversationChannelState,
  LocalFilePreview,
} from "@comma/core/chat";

type Listener = () => void;

/** How a person answers a question card: choices picked, their own words, or a skip. */
export type QuestionCardAnswer = {
  questionMessageId: string;
  choiceIds: string[];
  other?: string;
  skipped?: boolean;
};

export type ChatSendOptions = {
  consumeDraft?: boolean;
  /** Files that go with this message alone, apart from the draft. */
  files?: { bytes: Uint8Array; name: string; size: number }[];
  replyToMessageId?: string;
  skills?: { location: string }[];
};

/** A window's channel on one conversation (CoreConversationChannel): what it shows, and what a person does in it. */
export interface ChatChannel {
  acceptTaskReview(reviewVersion: number): unknown;
  /** Files for the draft, or with `questionMessageId` for that question card's other answer. */
  attachFiles(files: AttachmentUploadInput[], questionMessageId?: string): unknown;
  /** Message attachments for the draft, by reference: the server stores each one's blob as a composer file. */
  attachConversationFiles?(files: ChatConversationFile[]): unknown;
  /** Whether this host re-encodes HEIC/HEIF into JPEG before upload. */
  readonly transcodesImages?: boolean;
  clearPresentation?(): unknown;
  discard(clientRequestId: string): unknown;
  getSnapshot(): ConversationChannelState;
  pickAttachments?: (() => unknown) | undefined;
  previewLocalFile?(
    previewRef: ChatImagePreviewRef,
    signal?: AbortSignal
  ): Promise<LocalFilePreview | undefined>;
  refresh(): unknown;
  /** Reads a Task's history before the transcript held, for its Activity alone (`chatView.readTaskActivity`). */
  readTaskActivity?(): unknown;
  removeAttachment(id: string, questionMessageId?: string): void;
  setTaskStatus(status: ManualTaskStatus, expectedUpdatedAt: number): unknown;
  /** Runs the Task on another model (`chatView.setTaskRun`); fails with why not. */
  setTaskRun?(run: ChatTaskRunChoice): Promise<unknown>;
  retry(clientRequestId: string): unknown;
  retryAttachment(id: string, questionMessageId?: string): void;
  /**
   * Answers a question card: the core words the answer and sends it as one message that replies to the question
   * (`chatView.answerQuestion`).
   */
  answerQuestion?(answer: QuestionCardAnswer): Promise<unknown>;
  /**
   * `consumeDraft: false` sends without consuming the composer draft or its
   * staged attachments.
   */
  send(text: string, options?: ChatSendOptions): unknown;
  setDraft(draft: string): unknown;
  /**
   * Adds `text` to the draft once the chat is ready, unless the draft has it;
   * sends nothing. Fails when the chat cannot load or is not ready within 10 s.
   */
  prefillDraft(text: string): Promise<unknown>;
  start(): void;
  stop(): void;
  subscribe(listener: Listener): () => void;
}
