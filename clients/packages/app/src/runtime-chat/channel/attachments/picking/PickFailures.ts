import type {
  AttachmentUploadInput,
  DraftAttachment,
} from "../../../../components/chat/model/conversationChannel";

/**
 * Failed picks, shown as failed draft attachment rows until removed, retried,
 * or superseded by Main's projection, with the files a failed selection held.
 */
export class PickFailures {
  readonly #rows = new Map<string, DraftAttachment>();
  readonly #selections = new Map<string, AttachmentUploadInput[]>();

  get size() {
    return this.#rows.size;
  }

  rows() {
    return this.#rows.values();
  }

  record(id: string, row: DraftAttachment) {
    this.#rows.set(id, row);
  }

  recordSelection(id: string, files: AttachmentUploadInput[], row: DraftAttachment) {
    this.#selections.set(id, files);
    this.#rows.set(id, row);
  }

  /** Drops a row; whether it was shown. */
  resolve(id: string) {
    return this.#rows.delete(id);
  }

  /** Drops a row the user removed, with its selection; whether it was shown. */
  remove(id: string) {
    this.#selections.delete(id);
    return this.#rows.delete(id);
  }

  /** Takes a failed selection's files, and its row, to select them again. */
  takeSelection(id: string) {
    const files = this.#selections.get(id);
    if (files) {
      this.#selections.delete(id);
      this.#rows.delete(id);
    }
    return files;
  }

  clear() {
    this.#rows.clear();
    this.#selections.clear();
  }
}
