import { beforeEach, expect, it } from "vitest";
import { savedDocumentEdits } from "../savedDocumentEdits";

beforeEach(() => {
  localStorage.clear();
  savedDocumentEdits.reload();
});

it("keeps a person's edits of a document on the device: a window that starts again has them", () => {
  savedDocumentEdits.set("plan", "# Plan\n\nMine.\n");
  expect(savedDocumentEdits.get("plan")).toBe("# Plan\n\nMine.\n");

  savedDocumentEdits.reload();
  expect(savedDocumentEdits.get("plan")).toBe("# Plan\n\nMine.\n");
  expect(savedDocumentEdits.sent("plan")).toBe(false);

  savedDocumentEdits.delete("plan");
  savedDocumentEdits.reload();
  expect(savedDocumentEdits.get("plan")).toBeUndefined();
});

it("remembers that a message carried the edits, until the person edits again", () => {
  savedDocumentEdits.set("plan", "one");
  savedDocumentEdits.markSent("plan");
  savedDocumentEdits.reload();
  expect(savedDocumentEdits.sent("plan")).toBe(true);

  // The message was refused: the edits wait for the next one.
  savedDocumentEdits.markSent("plan", false);
  expect(savedDocumentEdits.sent("plan")).toBe(false);

  savedDocumentEdits.markSent("plan");
  savedDocumentEdits.set("plan", "two");
  expect(savedDocumentEdits.sent("plan")).toBe(false);
});

it("keeps the edits of the documents edited last, and a very long text for this window only", () => {
  for (let index = 0; index < 20; index += 1)
    savedDocumentEdits.set(`doc-${index}`, `text ${index}`);
  expect(savedDocumentEdits.get("doc-0")).toBeUndefined();
  expect(savedDocumentEdits.get("doc-19")).toBe("text 19");

  const long = "x".repeat(400_001);
  savedDocumentEdits.set("long", long);
  expect(savedDocumentEdits.get("long")).toBe(long);
  savedDocumentEdits.reload();
  expect(savedDocumentEdits.get("long")).toBeUndefined();
  expect(savedDocumentEdits.get("doc-19")).toBe("text 19");
});

it("hears of the edits another window of the app saved, and reads them", () => {
  let heard = 0;
  const stop = savedDocumentEdits.subscribe(() => {
    heard += 1;
  });
  savedDocumentEdits.set("plan", "mine");
  expect(heard).toBe(1);

  // The document's own window saves: this window is told by the device's storage, and has the new text.
  localStorage.setItem(
    "comma.document-edits",
    JSON.stringify([["plan", { markdown: "from the other window" }]])
  );
  window.dispatchEvent(new StorageEvent("storage", { key: "comma.document-edits" }));
  expect(heard).toBe(2);
  expect(savedDocumentEdits.get("plan")).toBe("from the other window");
  stop();
});
