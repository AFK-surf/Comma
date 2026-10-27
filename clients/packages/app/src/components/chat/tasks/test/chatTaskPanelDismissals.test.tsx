import { flush } from "@comma/test-utils/fake-clock";
import { act, renderHook } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { describe, expect, it, vi } from "vitest";
import {
  useDismissedPanelTasks,
  usePanelTaskDismissal,
  useRefreshPanelDismissalsWhenAttended,
} from "../chatTaskPanelDismissals";

/**
 * The hooks, for a panel that shows Tasks cnv-1 and cnv-2, over a core whose `chatTaskDismissed` marks are `marks`
 * (the test changes them with `say`).
 */
function dismissals() {
  let marks: Record<string, number> = {};
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "marks" && topic.kind === "chatTaskDismissed"
        ? { marks }
        : undefined,
  });
  let renders = 0;
  const view = renderHook(
    () => {
      renders += 1;
      useRefreshPanelDismissalsWhenAttended();
      return {
        dismissed: useDismissedPanelTasks(["cnv-1", "cnv-2"]),
        dismiss: usePanelTaskDismissal(),
      };
    },
    { wrapper: ({ children }) => core.wrap(children) }
  );
  const say = (next: Record<string, number>) => {
    marks = next;
    act(() => core.changed("marks"));
  };
  return { view, core, say, renders: () => renders };
}

describe("chatTaskPanelDismissals", () => {
  it("acknowledges a task at the run it shows, and an unknown run at 0", async () => {
    const { view, core, say } = dismissals();
    await flush();
    expect(view.result.current.dismissed.has("cnv-1")).toBe(false);
    act(() => view.result.current.dismiss("cnv-1", 42));
    // A Task from before the server kept its runs: 0, never the device's time.
    act(() => view.result.current.dismiss("cnv-2", 0));
    await flush();
    expect(core.sentTo("marks.mark")).toEqual([
      { kind: "chatTaskDismissed", entries: [["cnv-1", 42]] },
      { kind: "chatTaskDismissed", entries: [["cnv-2", 0]] },
    ]);
    say({ "cnv-1": 42 });
    await flush();
    expect(view.result.current.dismissed.get("cnv-1")).toBe(42);
  });

  it("keeps the map while nothing changes", async () => {
    const { view, say } = dismissals();
    say({ "cnv-1": 1 });
    await flush();
    const first = view.result.current.dismissed;
    say({ "cnv-1": 1 });
    await flush();
    expect(view.result.current.dismissed.get("cnv-1")).toBe(1);
    expect(first.get("cnv-1")).toBe(1);
  });

  it("renders for none of the acknowledgements of Tasks it does not show", async () => {
    const { view, say, renders } = dismissals();
    say({ "cnv-1": 1 });
    await flush();
    const shown = view.result.current.dismissed;
    const before = renders();
    say({ "cnv-1": 1, "cnv-other": 7 });
    await flush();
    expect(renders()).toBe(before);
    expect(view.result.current.dismissed).toBe(shown);
    expect(view.result.current.dismissed.has("cnv-other")).toBe(false);
    say({ "cnv-1": 1, "cnv-2": 3, "cnv-other": 7 });
    await flush();
    expect(view.result.current.dismissed.get("cnv-2")).toBe(3);
  });

  it("reads them again when the reader comes back to the window", async () => {
    const { core } = dismissals();
    await flush();
    vi.spyOn(document, "hasFocus").mockReturnValue(true);
    act(() => window.dispatchEvent(new Event("focus")));
    await flush();
    expect(core.sentTo("marks.refresh")).toEqual([{ kind: "chatTaskDismissed" }]);
    vi.restoreAllMocks();
  });

  it("hands acknowledgements kept in localStorage before the core to it once", async () => {
    window.localStorage.setItem(
      "comma.chatTaskPanelDismissed",
      JSON.stringify(["cnv-1"])
    );
    const { core } = dismissals();
    await flush();
    expect(core.sentTo("marks.mark")).toEqual([
      { kind: "chatTaskDismissed", ids: ["cnv-1"] },
    ]);
    expect(window.localStorage.getItem("comma.chatTaskPanelDismissed")).toBeNull();
  });
});
