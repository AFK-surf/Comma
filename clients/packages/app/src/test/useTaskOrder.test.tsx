import { act, renderHook, screen, waitFor } from "@testing-library/react";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { Toaster, toast } from "@comma/ui/components/toast";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { ReactNode } from "react";
import { useTaskOrder, type TaskOrderRef } from "../components/tasks/useTaskOrder";

const TASKS: readonly TaskOrderRef[] = [
  { conversationId: "cnv_a", id: "grp_1:cnv_a" },
  { conversationId: "cnv_b", id: "grp_1:cnv_b" },
];

function renderOrder(
  arranged: Record<string, string[]>,
  set: (params: unknown) => unknown = () => null
) {
  const calls = vi.fn(set);
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "taskOrder"
        ? { orders: arranged, sections: sections(arranged) }
        : undefined,
    calls: (name, params) => (name === "taskOrder.set" ? calls(params) : null),
  });
  const hook = renderHook(() => useTaskOrder("grp_1", TASKS), {
    wrapper: ({ children }: { children: ReactNode }) =>
      core.wrap(
        <>
          {children}
          <Toaster />
        </>
      ),
  });
  return { core, calls, ...hook };
}

/** The core's sections of `arranged`, bucket → conversation ids. */
function sections(arranged: Record<string, string[]>) {
  return Object.entries(arranged).map(([bucket, ids]) => ({ bucket, ids }));
}

describe("useTaskOrder", () => {
  afterEach(() => {
    toast.dismiss();
  });

  it("shows the core's board order on the cards' view ids", async () => {
    const { result } = renderOrder({ done: ["cnv_b", "cnv_hidden", "cnv_a"] });
    await waitFor(() =>
      expect(result.current.orders).toEqual({ done: ["grp_1:cnv_b", "grp_1:cnv_a"] })
    );
  });

  it("shows a drop at once and hands the core the shown cards in conversation ids", async () => {
    const { calls, result } = renderOrder({});
    act(() => {
      result.current.setBucketOrder("needs_review", ["grp_1:cnv_b", "grp_1:cnv_a"]);
    });
    expect(result.current.orders["needs_review"]).toEqual([
      "grp_1:cnv_b",
      "grp_1:cnv_a",
    ]);
    await waitFor(() =>
      expect(calls).toHaveBeenCalledWith({
        group: "grp_1",
        bucket: "needs_review",
        visible: ["cnv_b", "cnv_a"],
      })
    );
  });

  it("keeps the placed order when the save fails, and says so", async () => {
    const { core, result } = renderOrder({}, () => {
      throw new Error("offline");
    });
    act(() => {
      result.current.setBucketOrder("done", ["grp_1:cnv_a"]);
    });
    expect(await screen.findByTestId("tasks-order-save-failed")).toHaveTextContent(
      "Couldn’t save the task order"
    );
    // The core keeps the drop it could not save.
    act(() =>
      core.emit("taskOrder", {
        orders: { done: ["cnv_a"] },
        sections: [{ bucket: "done", ids: ["cnv_a"] }],
      })
    );
    await waitFor(() => expect(result.current.orders["done"]).toEqual(["grp_1:cnv_a"]));
  });
});
