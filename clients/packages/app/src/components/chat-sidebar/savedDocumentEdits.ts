// A person's own edits of a document, saved on this device as they are made. The edits are the whole document,
// kept by the version they are of (`conversationFileSourceKey`). They are there when the person comes back to the
// document, in this window or after the app starts again. Nothing is sent for them alone: the chat's next message
// carries the document as a file, and Comma works from it.
//
// Every window of the app on the device has the same edits: a document edited in a window of its own is as it was
// left there when it is back in its panel. A window hears of what another saved (`subscribe`).
//
// Bounds: the device keeps the edits of `maxEdits` documents, the oldest go first, and one document's text up to
// `maxStoredLength` letters. A longer text is kept until the window closes.
const storageKey = "comma.document-edits";
const maxEdits = 16;
const maxStoredLength = 400_000;

type SavedEdit = {
  markdown: string;
  /** A message has carried the edits: they are shown until they arrive as the document's newest version. */
  sent?: true | undefined;
};

let held: Map<string, SavedEdit> | undefined;
const listeners = new Set<() => void>();
const say = () => {
  for (const listener of listeners) listener();
};
// Another window saved: what this one holds is read anew.
if (typeof window !== "undefined")
  window.addEventListener("storage", (event) => {
    if (event.key !== storageKey && event.key !== null) return;
    held = undefined;
    say();
  });

function edits() {
  if (held) return held;
  held = new Map();
  try {
    const stored: unknown = JSON.parse(localStorage.getItem(storageKey) ?? "[]");
    if (Array.isArray(stored))
      for (const one of stored) {
        const [key, edit] = Array.isArray(one) ? (one as unknown[]) : [];
        const markdown = (edit as SavedEdit | undefined)?.markdown;
        if (typeof key === "string" && typeof markdown === "string")
          held.set(key, {
            markdown,
            ...((edit as SavedEdit).sent === true ? { sent: true } : {}),
          });
      }
  } catch {
    // What the device kept cannot be read: the documents are as their files are.
  }
  return held;
}

function keep() {
  try {
    localStorage.setItem(
      storageKey,
      JSON.stringify(
        [...edits()].filter(([, edit]) => edit.markdown.length <= maxStoredLength)
      )
    );
  } catch {
    // The device takes no more: the edits stay with this window.
  }
}

export const savedDocumentEdits = {
  /** The person's edits of this version, as the whole document. */
  get: (key: string) => edits().get(key)?.markdown,
  /** Saves the person's edits of this version: no message has carried them. */
  set(key: string, markdown: string) {
    const all = edits();
    all.delete(key);
    if (all.size >= maxEdits) all.delete(all.keys().next().value!);
    all.set(key, { markdown });
    keep();
    say();
  },
  /** The version is as its file is again. */
  delete(key: string) {
    if (!edits().delete(key)) return;
    keep();
    say();
  },
  /** The edits no message has carried, each with the version it is of. */
  unsent: (): [key: string, markdown: string][] =>
    [...edits()].flatMap(([key, edit]) =>
      edit.sent ? [] : [[key, edit.markdown] as [string, string]]
    ),
  /** Whether a message has carried the edits of this version. */
  sent: (key: string) => edits().get(key)?.sent === true,
  /** Says a message carried (or, with false, did not after all carry) the edits of this version. */
  markSent(key: string, sent = true) {
    const edit = edits().get(key);
    if (!edit || (edit.sent === true) === sent) return;
    edits().set(key, { markdown: edit.markdown, ...(sent ? { sent: true } : {}) });
    keep();
    say();
  },
  /** Calls `listener` when the edits change, in this window or another. */
  subscribe(listener: () => void) {
    listeners.add(listener);
    return () => {
      listeners.delete(listener);
    };
  },
  /** Reads what the device keeps anew, as a window that starts does. */
  reload() {
    held = undefined;
    say();
  },
};
