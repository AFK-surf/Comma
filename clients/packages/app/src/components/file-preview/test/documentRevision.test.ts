import { describe, expect, it } from "vitest";
import {
  advanceDocumentPlayback,
  documentCaretMark,
  documentPlaybackFrame,
  documentPlaybackStep,
  documentRevisionSpan,
} from "../documentRevision";

const typed = (previous: string, next: string) => {
  const span = documentRevisionSpan(previous, next);
  const frames: string[] = [];
  const step = documentPlaybackStep(span.insert.length);
  for (let count = 0; ; count = advanceDocumentPlayback(span.insert, count, step)) {
    frames.push(documentPlaybackFrame(span, count));
    if (count >= span.insert.length) return { span, frames };
  }
};
const plain = (frame: string) => frame.replace(documentCaretMark, "");

describe("a document's new version, typed in", () => {
  it("types a first version from the empty page and ends with its exact text", () => {
    const next = "# Plan\n\nFirst, the plugin.\n\n- one\n- two\n";
    const { frames } = typed("", next);
    expect(plain(frames.at(-1)!)).toBe(next);
    // Every frame is the start of the document: nothing is shown ahead of the caret.
    for (const frame of frames) expect(next.startsWith(plain(frame))).toBe(true);
  });

  it("types only the lines that changed, and keeps the text around them", () => {
    const previous =
      "# Plan\n\nThe plugin talks to the desktop.\n\n## Risks\n\nNone yet.\n";
    const next = "# Plan\n\nThe plugin talks to the server.\n\n## Risks\n\nNone yet.\n";
    const { span, frames } = typed(previous, next);
    expect(span).toEqual({
      head: "# Plan\n\n",
      insert: "The plugin talks to the server.\n",
      tail: "\n## Risks\n\nNone yet.\n",
    });
    expect(plain(frames.at(-1)!)).toBe(next);
    for (const frame of frames) {
      expect(plain(frame).startsWith("# Plan\n\n")).toBe(true);
      // The text after the change stays whole, on lines of its own.
      expect(frame.endsWith("\n\n## Risks\n\nNone yet.\n")).toBe(true);
    }
  });

  it("puts the caret after the last word typed", () => {
    const span = documentRevisionSpan("", "# Plan\n\nFirst.\n");
    expect(documentPlaybackFrame(span, 5)).toBe(`# Pla${documentCaretMark}`);
    expect(documentPlaybackFrame(span, span.insert.length)).toBe(
      `# Plan\n\nFirst.${documentCaretMark}\n`
    );
  });

  it("leaves a line of syntax alone as it is, so a fence still closes its code", () => {
    const next = "Run it:\n\n```sh\nmake\n```\n";
    const span = documentRevisionSpan("", next);
    expect(documentPlaybackFrame(span, next.length)).toBe(next);
    expect(documentPlaybackFrame(span, "Run it:\n\n```sh".length)).toBe(
      "Run it:\n\n```sh"
    );
    expect(documentPlaybackFrame(span, "Run it:\n\n---".length)).not.toContain(
      `---${documentCaretMark}`
    );
  });

  it("never stops between the two halves of one character", () => {
    const insert = "a😀b";
    expect(advanceDocumentPlayback(insert, 0, 2)).toBe(3);
    expect(advanceDocumentPlayback(insert, 3, 2)).toBe(4);
  });

  it("types a long change in a bounded number of frames", () => {
    const { frames } = typed("", "word ".repeat(10_000));
    expect(frames.length).toBeLessThanOrEqual(82);
  });
});
