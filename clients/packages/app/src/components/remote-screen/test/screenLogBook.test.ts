// What the logs pane holds (screenLogBook.ts): at most SHOWN_LINES shown and as many held while paused, a crash
// remembered until cleared, and a new stream's lines (which count from 0 again) shown afresh.
import type { ScreenLogLine } from "@comma/core-client";
import { describe, expect, it } from "vitest";
import {
  SHOWN_LINES,
  addLogLines,
  clearLogs,
  emptyLogBook,
  pauseLogs,
  restartLogs,
} from "../screenLogBook";

const lines = (from: number, count: number, crash = false): ScreenLogLine[] =>
  Array.from({ length: count }, (_, i) => ({
    seq: from + i,
    at: "",
    level: "Info",
    app: "Demo",
    text: `l${from + i}`,
    ...(crash ? { crash: true as const } : {}),
  }));

describe("screenLogBook", () => {
  it("shows at most so many lines, and holds as many while paused", () => {
    let book = addLogLines(emptyLogBook, lines(0, SHOWN_LINES + 10));
    expect(book.lines).toHaveLength(SHOWN_LINES);
    expect(book.lines[0]!.seq).toBe(10);
    book = addLogLines(
      pauseLogs(book, true),
      lines(SHOWN_LINES + 10, SHOWN_LINES + 5),
      7
    );
    expect(book.held).toHaveLength(SHOWN_LINES);
    expect(book.lines.at(-1)!.seq).toBe(SHOWN_LINES + 9);
    expect(book.dropped).toBe(7);
    book = pauseLogs(book, false);
    expect([book.lines.length, book.held.length]).toEqual([SHOWN_LINES, 0]);
    expect(book.lines.at(-1)!.seq).toBe(2 * SHOWN_LINES + 14);
  });

  it("remembers a crash until cleared, and a new stream starts afresh", () => {
    let book = addLogLines(emptyLogBook, lines(0, 1, true));
    expect(book.crashed).toBe(true);
    book = clearLogs(book);
    expect([book.crashed, book.lines.length]).toEqual([false, 0]);
    expect(addLogLines(book, lines(0, 1)).lines).toHaveLength(0);
    book = restartLogs(pauseLogs(book, true));
    expect(book.paused).toBe(true);
    expect(addLogLines(book, lines(0, 2)).held).toHaveLength(2);
  });
});
