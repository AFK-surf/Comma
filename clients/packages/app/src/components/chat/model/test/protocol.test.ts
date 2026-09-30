import { describe, expect, it } from "vitest";
import {
  ATTACHED_ONLY_TEXT,
  QUOTED_TEXT_HEADER,
  composeMessageWithAttachments,
  composeMessageWithQuotes,
  isCommaContextMessage,
  parseAttachmentsBlock,
  parseQuotedTextBlock,
  stripCommaProtocolMarkers,
} from "../protocol";

describe("chat protocol display helpers", () => {
  it("strips tail protocol markers while keeping the user-visible head", () => {
    expect(
      stripCommaProtocolMarkers(
        "hello\n\n[[comma-protocol]]\nThe user tagged these skills"
      )
    ).toBe("hello");
    expect(
      stripCommaProtocolMarkers("line 1\nline 2\n[[comma-protocol]]\nsecret")
    ).toBe("line 1\nline 2");
  });

  it("keeps existing fence stripping and context detection semantics", () => {
    expect(stripCommaProtocolMarkers("visible\n```comma:hidden\nx\n```")).toBe(
      "visible"
    );
    expect(stripCommaProtocolMarkers("visible\n```comma:hidden\nx")).toBe("visible");
    expect(stripCommaProtocolMarkers("[[comma-protocol]]\nsecret")).toBe("");
    expect(isCommaContextMessage("  [[comma-context]]\nhidden")).toBe(true);
  });

  it("composes and parses attached-files blocks at the message tail", () => {
    const text = composeMessageWithAttachments("please read", [
      { name: "report.csv", path: "/uploads/1-report.csv" },
      { name: "diagram.png", path: "/uploads/2-diagram.png" },
    ]);

    expect(text).toContain("Attached files in your workspace:");
    expect(parseAttachmentsBlock(text)).toEqual({
      body: "please read",
      attachments: [
        { name: "report.csv", path: "/uploads/1-report.csv" },
        { name: "diagram.png", path: "/uploads/2-diagram.png" },
      ],
    });
  });

  it("puts quoted passages ahead of the body and parses them back off", () => {
    const text = composeMessageWithQuotes("这段是什么意思？", [
      "圆橡皮，中间留出金属箍空隙。",
    ]);

    expect(text).toBe(
      `${QUOTED_TEXT_HEADER}\n> 圆橡皮，中间留出金属箍空隙。\n\n这段是什么意思？`
    );
    expect(parseQuotedTextBlock(text)).toEqual({
      body: "这段是什么意思？",
      quotes: ["圆橡皮，中间留出金属箍空隙。"],
    });
  });

  it("round-trips multi-line, blank-line, and already-quoted passages", () => {
    const quote = "first line\n\n> already quoted\nlast line";
    const text = composeMessageWithQuotes("look", [quote, "second passage"]);

    expect(parseQuotedTextBlock(text)).toEqual({
      body: "look",
      quotes: [quote, "second passage"],
    });
  });

  it("keeps a quote-only message and leaves unquoted text untouched", () => {
    const quoteOnly = composeMessageWithQuotes("", ["just this"]);
    expect(parseQuotedTextBlock(quoteOnly)).toEqual({
      body: "",
      quotes: ["just this"],
    });

    expect(composeMessageWithQuotes("plain", [])).toBe("plain");
    expect(parseQuotedTextBlock("plain")).toEqual({ body: "plain", quotes: [] });
    // A bare header with no quoted line is ordinary prose, not a quote block.
    expect(parseQuotedTextBlock(`${QUOTED_TEXT_HEADER}\nnot quoted`)).toEqual({
      body: `${QUOTED_TEXT_HEADER}\nnot quoted`,
      quotes: [],
    });
  });

  it("keeps quotes and attachments on opposite ends of one message", () => {
    const text = composeMessageWithAttachments(
      composeMessageWithQuotes("please read", ["quoted passage"]),
      [{ name: "report.csv", path: "/uploads/1-report.csv" }]
    );
    const withoutAttachments = parseAttachmentsBlock(text);

    expect(withoutAttachments.attachments).toEqual([
      { name: "report.csv", path: "/uploads/1-report.csv" },
    ]);
    expect(parseQuotedTextBlock(withoutAttachments.body)).toEqual({
      body: "please read",
      quotes: ["quoted passage"],
    });
  });

  it("hides the attachment-only fallback body after parsing", () => {
    const text = composeMessageWithAttachments("", [
      { name: "notes.txt", path: "/uploads/1-notes.txt" },
    ]);

    expect(text.startsWith(ATTACHED_ONLY_TEXT)).toBe(true);
    expect(parseAttachmentsBlock(text)).toEqual({
      body: "",
      attachments: [{ name: "notes.txt", path: "/uploads/1-notes.txt" }],
    });
  });
});
