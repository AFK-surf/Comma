import { describe, expect, it } from "vitest";
import {
  CONVERSATION_TURN_WINDOW,
  expandWindowStart,
  initialWindowStart,
  isPinnedToBottom,
  resolveWindowStart,
  restoredScrollTop,
  shouldFillTurnWindow,
  shouldLoadOlderTurns,
  shouldRearmOlderTurnLoad,
  startKeyAfterSlide,
} from "../conversationTurnWindow";

describe("conversationTurnWindow", () => {
  it("opens on the latest rounds instead of the full history", () => {
    expect(initialWindowStart(20)).toBe(20 - CONVERSATION_TURN_WINDOW.initialTurns);
    expect(initialWindowStart(3)).toBe(0);
    expect(initialWindowStart(0)).toBe(0);
  });

  it("resolves a missing start key back to the latest rounds", () => {
    const turnKeys = ["a", "b", "c", "d", "e", "f", "g", "h"];
    expect(
      resolveWindowStart({
        startKey: "missing",
        turnKeys,
      })
    ).toBe(2);
    expect(
      resolveWindowStart({
        startKey: "c",
        turnKeys,
      })
    ).toBe(2);
  });

  it("pulls the window back to cover a required older turn", () => {
    expect(
      resolveWindowStart({
        requiredTurnKeys: new Set(["b"]),
        startKey: "f",
        turnKeys: ["a", "b", "c", "d", "e", "f", "g"],
      })
    ).toBe(1);
  });

  it("expands older turns by one page and stops at the start", () => {
    expect(expandWindowStart(14)).toEqual({
      expanded: CONVERSATION_TURN_WINDOW.pageTurns,
      start: 6,
    });
    expect(expandWindowStart(3)).toEqual({ expanded: 3, start: 0 });
    expect(expandWindowStart(0)).toEqual({ expanded: 0, start: 0 });
  });

  it("loads older turns only when the user has left the bottom and reached the top", () => {
    const overflowing = { clientHeight: 480, scrollHeight: 2400, scrollTop: 0 };
    expect(
      shouldLoadOlderTurns({
        hasOlder: true,
        metrics: overflowing,
        pending: false,
        pinnedToBottom: false,
      })
    ).toBe(true);
    expect(
      shouldLoadOlderTurns({
        hasOlder: true,
        metrics: overflowing,
        pending: false,
        pinnedToBottom: true,
      })
    ).toBe(false);
    expect(
      shouldLoadOlderTurns({
        hasOlder: true,
        metrics: { clientHeight: 0, scrollHeight: 0, scrollTop: 0 },
        pending: false,
        pinnedToBottom: false,
      })
    ).toBe(false);
  });

  it("fills the viewport only after the scrollport has a real size", () => {
    expect(
      shouldFillTurnWindow({
        hasOlder: true,
        metrics: { clientHeight: 0, scrollHeight: 0, scrollTop: 0 },
        pending: false,
      })
    ).toBe(false);
    expect(
      shouldFillTurnWindow({
        hasOlder: true,
        metrics: { clientHeight: 720, scrollHeight: 400, scrollTop: 0 },
        pending: false,
      })
    ).toBe(true);
    expect(
      shouldFillTurnWindow({
        hasOlder: true,
        metrics: { clientHeight: 720, scrollHeight: 1600, scrollTop: 800 },
        pending: false,
      })
    ).toBe(false);
  });

  it("keeps the visible messages still when older turns are prepended", () => {
    expect(restoredScrollTop(48, 1000, 1800)).toBe(848);
    expect(restoredScrollTop(48, 1800, 1800)).toBe(48);
  });

  it("slides the window forward one turn when pinned", () => {
    const turnKeys = Array.from({ length: 21 }, (_, index) => `t${index}`);
    // A window already at the tail size advances with the tail.
    expect(startKeyAfterSlide(turnKeys, 14)).toBe("t15");
    // A grown window (older turns loaded) slides by ONE turn, keeping its
    // size, instead of resetting to the tail: a reset evicts turns the fill
    // logic immediately re-mounts, which paints as a full-thread flash.
    expect(startKeyAfterSlide(turnKeys, 4)).toBe("t5");
    // Windows at or below the initial size never shrink past the tail start.
    expect(startKeyAfterSlide(turnKeys, 20)).toBe("t15");
    expect(startKeyAfterSlide(["a", "b", "c"], 0)).toBe("a");
    expect(
      isPinnedToBottom({ clientHeight: 480, scrollHeight: 2400, scrollTop: 1920 })
    ).toBe(true);
    expect(
      isPinnedToBottom({ clientHeight: 480, scrollHeight: 2400, scrollTop: 800 })
    ).toBe(false);
    expect(
      isPinnedToBottom({ clientHeight: 0, scrollHeight: 2400, scrollTop: 0 })
    ).toBe(true);
  });

  it("rearms older-turn loading only after the user leaves the top edge", () => {
    expect(
      shouldRearmOlderTurnLoad({ clientHeight: 480, scrollHeight: 2400, scrollTop: 0 })
    ).toBe(false);
    expect(
      shouldRearmOlderTurnLoad({
        clientHeight: 480,
        scrollHeight: 2400,
        scrollTop: 241,
      })
    ).toBe(true);
    expect(
      shouldRearmOlderTurnLoad({ clientHeight: 0, scrollHeight: 0, scrollTop: 241 })
    ).toBe(false);
  });
});
