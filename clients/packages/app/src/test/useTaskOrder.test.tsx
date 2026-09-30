import { act, renderHook, screen, waitFor } from "@testing-library/react";
import { Toaster, toast } from "@comma/ui";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { ReactNode } from "react";
import type { CommaApiClient } from "../api";
import { useTaskOrder, type TaskOrderRef } from "../components/tasks/useTaskOrder";

const TASKS: readonly TaskOrderRef[] = [
  { conversationId: "cnv_a", id: "grp_1:cnv_a" },
  { conversationId: "cnv_b", id: "grp_1:cnv_b" },
];

function apiStub(overrides: Partial<CommaApiClient> = {}) {
  return {
    getTaskOrder: vi.fn(async () => ({ orders: { done: ["cnv_b", "cnv_a"] } })),

    putTaskOrder: vi.fn(async () => ({ orders: {} })),
    ...overrides,
  } as unknown as CommaApiClient;
}

const withToaster = ({ children }: { children: ReactNode }) => (
  <>
    {children}
    <Toaster />
  </>
);

describe("useTaskOrder", () => {
  afterEach(() => {
    toast.dismiss();
  });

  it("loads the stored arrangement and projects it onto the cards' view ids", async () => {
    const api = apiStub();
    const { result } = renderHook(() => useTaskOrder(api, "grp_1", TASKS));

    await waitFor(() => {
      expect(result.current.orders).toEqual({
        done: ["grp_1:cnv_b", "grp_1:cnv_a"],
      });
    });
    expect(api.getTaskOrder).toHaveBeenCalledWith("grp_1");
  });

  it("preserves a hidden archived task's slot while visible cards are reordered", async () => {
    const api = apiStub({
      getTaskOrder: vi.fn(async () => ({
        orders: { done: ["cnv_a", "cnv_hidden", "cnv_b"] },
      })),
    });
    const { result } = renderHook(() => useTaskOrder(api, "grp_1", TASKS));
    await waitFor(() =>
      expect(result.current.orders.done).toEqual(["grp_1:cnv_a", "grp_1:cnv_b"])
    );
    act(() => result.current.setBucketOrder("done", ["grp_1:cnv_b", "grp_1:cnv_a"]));
    expect(api.putTaskOrder).toHaveBeenCalledWith("grp_1", "done", [
      "cnv_b",
      "cnv_hidden",
      "cnv_a",
    ]);
  });

  it("applies a drop locally at once and persists canonical conversation ids", async () => {
    const api = apiStub();
    const { result } = renderHook(() => useTaskOrder(api, "grp_1", TASKS));

    act(() => {
      result.current.setBucketOrder("backlog", ["grp_1:cnv_a", "grp_1:cnv_b"]);
    });

    expect(result.current.orders["backlog"]).toEqual(["grp_1:cnv_a", "grp_1:cnv_b"]);
    // The wire order is written in conversation ids, never in projection ids.
    expect(api.putTaskOrder).toHaveBeenCalledWith("grp_1", "backlog", [
      "cnv_a",
      "cnv_b",
    ]);
  });

  it("keeps a completed drop when the older initial load replies afterward", async () => {
    let resolveInitial: (value: { orders: Record<string, string[]> }) => void;
    const api = apiStub({
      getTaskOrder: vi.fn(
        () =>
          new Promise((resolve) => {
            resolveInitial = resolve;
          })
      ) as unknown as CommaApiClient["getTaskOrder"],
    });
    const { result } = renderHook(() => useTaskOrder(api, "grp_1", TASKS));

    act(() => {
      result.current.setBucketOrder("backlog", ["grp_1:cnv_b", "grp_1:cnv_a"]);
    });
    expect(result.current.orders["backlog"]).toEqual(["grp_1:cnv_b", "grp_1:cnv_a"]);

    await act(async () => {
      resolveInitial!({ orders: { backlog: ["cnv_a", "cnv_b"] } });
      await Promise.resolve();
    });

    // The user's completed drop is newer than this initial read and stays put.
    expect(result.current.orders["backlog"]).toEqual(["grp_1:cnv_b", "grp_1:cnv_a"]);
  });

  it("serializes same-bucket writes across a hook remount", async () => {
    let resolveFirst!: (value: { orders: Record<string, string[]> }) => void;
    let resolveSecond!: (value: { orders: Record<string, string[]> }) => void;
    const api = apiStub({
      putTaskOrder: vi.fn(
        (_groupId: string, _bucket: string, ids: string[]) =>
          new Promise((resolve) => {
            if (ids[0] === "cnv_b") resolveFirst = resolve;
            else resolveSecond = resolve;
          })
      ) as unknown as CommaApiClient["putTaskOrder"],
    });

    const firstHook = renderHook(() => useTaskOrder(api, "grp_1", TASKS));
    act(() => {
      firstHook.result.current.setBucketOrder("backlog", [
        "grp_1:cnv_b",
        "grp_1:cnv_a",
      ]);
    });
    expect(api.putTaskOrder).toHaveBeenCalledTimes(1);
    firstHook.unmount();

    const secondHook = renderHook(() => useTaskOrder(api, "grp_1", TASKS));
    act(() => {
      secondHook.result.current.setBucketOrder("backlog", [
        "grp_1:cnv_a",
        "grp_1:cnv_b",
      ]);
    });

    // A remounted surface shares the same logical writer lane. The newer PUT
    // cannot overtake the old request and then be overwritten by its reply.
    expect(api.putTaskOrder).toHaveBeenCalledTimes(1);

    await act(async () => {
      resolveFirst({ orders: { backlog: ["cnv_b", "cnv_a"] } });
      await Promise.resolve();
    });
    await waitFor(() => expect(api.putTaskOrder).toHaveBeenCalledTimes(2));
    expect(api.putTaskOrder).toHaveBeenLastCalledWith("grp_1", "backlog", [
      "cnv_a",
      "cnv_b",
    ]);

    await act(async () => {
      resolveSecond({ orders: { backlog: ["cnv_a", "cnv_b"] } });
      await Promise.resolve();
    });
    secondHook.unmount();
  });

  it("keeps the placed order on a failed save and says so", async () => {
    const api = apiStub({
      putTaskOrder: vi.fn(async () => {
        throw new Error("offline");
      }) as unknown as CommaApiClient["putTaskOrder"],
    });
    const { result } = renderHook(() => useTaskOrder(api, "grp_1", TASKS), {
      wrapper: withToaster,
    });

    act(() => {
      result.current.setBucketOrder("done", ["grp_1:cnv_a"]);
    });

    // The cards the user just placed never snap back under their pointer.
    expect(result.current.orders["done"]).toEqual(["grp_1:cnv_a"]);
    expect(await screen.findByTestId("tasks-order-save-failed")).toHaveTextContent(
      "Couldn’t save the task order"
    );
  });

  it("resets and refetches when the group changes, ignoring stale replies", async () => {
    let resolveFirst: (value: { orders: Record<string, string[]> }) => void;
    const api = apiStub({
      getTaskOrder: vi.fn((groupId: string) =>
        groupId === "grp_old"
          ? new Promise((resolve) => {
              resolveFirst = resolve;
            })
          : Promise.resolve({ orders: { backlog: ["cnv_new"] } })
      ) as unknown as CommaApiClient["getTaskOrder"],
    });
    const { rerender, result } = renderHook(
      ({ groupId }: { groupId: string }) =>
        useTaskOrder(api, groupId, [
          { conversationId: "cnv_new", id: "cnv_new" },
          { conversationId: "cnv_stale", id: "cnv_stale" },
        ]),
      { initialProps: { groupId: "grp_old" } }
    );

    rerender({ groupId: "grp_new" });
    await waitFor(() => {
      expect(result.current.orders).toEqual({ backlog: ["cnv_new"] });
    });

    // The old group's late reply must not clobber the new group's arrangement.
    act(() => {
      resolveFirst!({ orders: { done: ["cnv_stale"] } });
    });
    await waitFor(() => {
      expect(result.current.orders).toEqual({ backlog: ["cnv_new"] });
    });
  });
});
