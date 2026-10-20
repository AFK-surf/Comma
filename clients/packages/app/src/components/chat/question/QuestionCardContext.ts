import { createContext } from "react";
import type { AttachmentUploadInput, DraftAttachment } from "@comma/core/chat";
import type { QuestionCardAnswer } from "../channel/ChatChannel";
import type { LocalFilePreviewLoader } from "../thread/attachments/useLocalFilePreviews";

/** What a question card in the live conversation can do: answer, and add or drop images for its other answer. */
export type QuestionCardActions = {
  answer(answer: QuestionCardAnswer): Promise<unknown>;
  attach(questionMessageId: string, files: AttachmentUploadInput[]): unknown;
  removeAttachment(questionMessageId: string, attachmentId: string): unknown;
  retryAttachment(questionMessageId: string, attachmentId: string): unknown;
  previewLocalFile?: LocalFilePreviewLoader | undefined;
};

/** Set by the conversation view: a card without it (a Task's report) is shown, not answered. */
export const QuestionCardActionsContext = createContext<
  QuestionCardActions | undefined
>(undefined);

/** The images added to each question card's other answer, by question message id. */
export const QuestionCardAttachmentsContext = createContext<
  Readonly<Record<string, readonly DraftAttachment[]>>
>({});
