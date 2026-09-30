import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  markTaskReviewSeen,
  readTaskReviewSeenMarks,
  subscribeTaskReviewSeen,
  taskReviewNeedsAttention,
} from "../taskReviewAttention";

describe("taskReviewAttention", () => {
  beforeEach(() => {
    // The module cache keys off the raw stored string, so clearing storage
    // is enough to invalidate marks left by earlier tests.
    window.localStorage.clear();
  });

  it("needs attention until viewed, then re-arms on a newer update", () => {
    const before = readTaskReviewSeenMarks();
    expect(taskReviewNeedsAttention(before, "cnv-1", 100)).toBe(true);

    markTaskReviewSeen("cnv-1", 100);
    const seen = readTaskReviewSeenMarks();
    expect(taskReviewNeedsAttention(seen, "cnv-1", 100)).toBe(false);
    expect(taskReviewNeedsAttention(seen, "cnv-1", 101)).toBe(true);
    expect(taskReviewNeedsAttention(seen, "cnv-other", 1)).toBe(true);
  });

  it("never moves a mark backwards", () => {
    markTaskReviewSeen("cnv-1", 200);
    markTaskReviewSeen("cnv-1", 150);
    expect(readTaskReviewSeenMarks().get("cnv-1")).toBe(200);
  });

  it("notifies subscribers and keeps snapshot identity stable between writes", () => {
    const listener = vi.fn();
    const unsubscribe = subscribeTaskReviewSeen(listener);
    const first = readTaskReviewSeenMarks();
    expect(readTaskReviewSeenMarks()).toBe(first);

    markTaskReviewSeen("cnv-1", 100);
    expect(listener).toHaveBeenCalledTimes(1);
    expect(readTaskReviewSeenMarks()).not.toBe(first);

    unsubscribe();
    markTaskReviewSeen("cnv-2", 100);
    expect(listener).toHaveBeenCalledTimes(1);
  });

  it("survives a corrupted stored payload", () => {
    window.localStorage.setItem("comma.taskReviewSeen", "{not json");
    expect(readTaskReviewSeenMarks().size).toBe(0);
    markTaskReviewSeen("cnv-1", 100);
    expect(readTaskReviewSeenMarks().get("cnv-1")).toBe(100);
  });

  it("evicts the oldest marks past the cap", () => {
    for (let index = 0; index < 301; index += 1) {
      markTaskReviewSeen(`cnv-${index}`, index + 1);
    }
    const marks = readTaskReviewSeenMarks();
    expect(marks.size).toBe(300);
    expect(marks.has("cnv-0")).toBe(false);
    expect(marks.get("cnv-300")).toBe(301);
  });
});
