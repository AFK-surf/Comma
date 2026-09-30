import type {
  AttachmentUploadInput,
  ChatImagePreviewRef,
  ConversationChannelState,
  LocalFilePreview,
} from "../../components/chat/model/conversationChannel";

type Listener = () => void;

export type ChatSendOptions = {
  consumeDraft?: boolean;
  replyToMessageId?: string;
  skills?: { location: string }[];
};

/**
 * Renderer sequencing for the Main-owned transaction modeled in
 * tla/connector/AttachmentSendIntent.tla. This layer orders commands but
 * never owns the authoritative draft epoch or terminal intake outcome.
 */
export interface ChatChannel {
  acceptTaskReview(reviewVersion: number): unknown;
  attachFiles(files: AttachmentUploadInput[]): void;
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
  removeAttachment(id: string): void;
  retry(clientRequestId: string): unknown;
  retryAttachment(id: string): void;
  /**
   * `consumeDraft: false` sends without consuming the composer draft or its
   * staged attachments. Electron Main uses this when the sending surface does
   * not own the shared draft; the web channel honors the flag directly.
   */
  send(text: string, options?: ChatSendOptions): unknown;
  setDraft(draft: string): unknown;
  start(): void;
  stop(): void;
  subscribe(listener: Listener): () => void;
}
