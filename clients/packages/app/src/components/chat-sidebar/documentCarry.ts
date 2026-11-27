// What the chat's next message carries of the documents a person edited: each document's version as the person
// left it, with the pictures they put in it. It is read when the message is sent, from what the device has saved
// (`savedDocumentEdits`) and the conversation as it is then. Nothing is staged ahead: a panel that is closed, a
// document in a window of its own, or a version the person moved away from cannot leave a stale version to send.
//
// Only edits of a document's newest version are carried. Edits of an earlier version stay with that version: a
// message that carried them would put them over the newer one.
import type { ChatMessage } from "@comma/core/chat";
import { conversationFileSourceKey } from "../../runtime-files/fileSources";
import {
  createChatDraftSelection,
  type ChatDraftSelection,
} from "../chat/composer/draftSelections";
import { documentPictureNames } from "../file-preview/documentEditorModel";
import { savedDocumentEdits } from "./savedDocumentEdits";
import { documentVersionsIn } from "./sentDocuments";

/** A picture a reader put in a document. Its bytes are read once, for the message that takes it. */
export type StagedDocumentPicture = { file: File; bytes?: Uint8Array | undefined };

/**
 * The pictures readers put in documents in this window: by the conversation and the document's name
 * (`conversationId\nfileName`), each under the file name the document names it by.
 */
export const stagedDocumentPictures = new Map<
  string,
  Map<string, StagedDocumentPicture>
>();

/** The parts of a version's key (`conversationFileSourceKey`) that say which document it is of. */
function documentOf(key: string) {
  try {
    const parts: unknown = JSON.parse(key);
    if (!Array.isArray(parts)) return undefined;
    const [groupId, conversationId, , , fileName] = parts as unknown[];
    return typeof groupId === "string" &&
      typeof conversationId === "string" &&
      typeof fileName === "string"
      ? { groupId, conversationId, fileName }
      : undefined;
  } catch {
    return undefined;
  }
}

/**
 * The versions of documents that the next message of `conversationId` carries: the person's saved edits of each
 * document's newest version there, which no message has carried.
 */
export function documentVersionsToCarry(
  conversationId: string | undefined,
  messages: readonly ChatMessage[]
): ChatDraftSelection[] {
  if (conversationId === undefined) return [];
  return savedDocumentEdits.unsent().flatMap(([key, markdown]) => {
    const document = documentOf(key);
    if (document?.conversationId !== conversationId) return [];
    const newest = documentVersionsIn(messages, document)?.at(-1);
    if (!newest || conversationFileSourceKey(newest.source) !== key) return [];
    const bytes = new TextEncoder().encode(markdown);
    // With the version go the pictures it names that no message has carried yet, where their bytes are read.
    const staged = stagedDocumentPictures.get(
      `${conversationId}\n${document.fileName}`
    );
    const images = documentPictureNames(markdown).flatMap((name) => {
      const picture = staged?.get(name);
      return picture?.bytes
        ? [{ bytes: picture.bytes, name, size: picture.bytes.length }]
        : [];
    });
    return [
      createChatDraftSelection({
        note: "",
        about: {
          kind: "document-version",
          fileName: document.fileName,
          reference: key,
          file: { bytes, name: document.fileName, size: bytes.length },
          ...(images.length > 0 ? { images } : {}),
        },
      }),
    ];
  });
}
