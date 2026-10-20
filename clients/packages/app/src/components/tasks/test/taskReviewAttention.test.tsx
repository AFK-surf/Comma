import { flush } from "@comma/test-utils/fake-clock";
import { act, renderHook } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { describe, expect, it } from "vitest";
import {
  taskReviewNeedsAttention,
  useMarkTaskReviewSeen,
  useTaskReviewSeenMarks,
} from "../taskReviewAttention";

/** The hooks over a core whose `taskReviewSeen` marks are `marks` (the test changes them with `say`). */
function seenMarks(initial: Record<string, number> = {}) {
  let marks = initial;
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "marks" && topic.kind === "taskReviewSeen"
        ? { marks }
        : undefined,
  });
  const view = renderHook(
    () => ({ marks: useTaskReviewSeenMarks(), mark: useMarkTaskReviewSeen() }),
    { wrapper: ({ children }) => core.wrap(children) }
  );
  const say = (next: Record<string, number>) => {
    marks = next;
    act(() => core.changed("marks"));
  };
  return { view, core, say };
}

describe("taskReviewAttention", () => {
  it("needs attention until viewed, then re-arms on a newer update", async () => {
    const { view, core, say } = seenMarks();
    await flush();
    expect(taskReviewNeedsAttention(view.result.current.marks, "cnv-1", 100)).toBe(
      true
    );

    act(() => view.result.current.mark("cnv-1", 100));
    await flush();
    expect(core.sentTo("marks.mark")).toEqual([
      { kind: "taskReviewSeen", entries: [["cnv-1", 100]] },
    ]);
    say({ "cnv-1": 100 });
    await flush();
    const seen = view.result.current.marks;
    expect(taskReviewNeedsAttention(seen, "cnv-1", 100)).toBe(false);
    expect(taskReviewNeedsAttention(seen, "cnv-1", 101)).toBe(true);
    expect(taskReviewNeedsAttention(seen, "cnv-other", 1)).toBe(true);
  });

  it("keeps the marks object while nothing changes", async () => {
    const { view } = seenMarks({ "cnv-1": 100 });
    await flush();
    const first = view.result.current.marks;
    view.rerender();
    expect(view.result.current.marks).toBe(first);
  });

  it("hands marks kept in localStorage before the core to it once, and drops them", async () => {
    window.localStorage.setItem(
      "comma.taskReviewSeen",
      JSON.stringify({ "cnv-1": 100 })
    );
    const { core } = seenMarks();
    await flush();
    expect(core.sentTo("marks.mark")).toEqual([
      { kind: "taskReviewSeen", entries: [["cnv-1", 100]] },
    ]);
    expect(window.localStorage.getItem("comma.taskReviewSeen")).toBeNull();
  });

  it("hands over nothing from a corrupted stored payload", async () => {
    window.localStorage.setItem("comma.taskReviewSeen", "{not json");
    const { view, core } = seenMarks();
    await flush();
    expect(core.sentTo("marks.mark")).toEqual([
      { kind: "taskReviewSeen", entries: [] },
    ]);
    expect(view.result.current.marks.size).toBe(0);
  });
});
