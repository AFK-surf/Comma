import { act, renderHook } from "@comma/test-utils/render";
import { expect, it, vi } from "vitest";
import type { ComputeNodeState } from "@comma/native-bridge";

const mock = vi.hoisted(() => ({
  listener: undefined as ((state: ComputeNodeState) => void) | undefined,
  configure: vi.fn(),
  get: vi.fn(),
}));
vi.mock("@comma/native-bridge", async (original) => ({
  ...(await original<object>()),
  getNativeBridge: () => bridge,
}));
const bridge = {
  platform: "electron",
  computeNode: {
    state: {
      subscribe: (listener: (state: ComputeNodeState) => void) => {
        mock.listener = listener;
        return () => {
          mock.listener = undefined;
        };
      },
      get: mock.get,
    },
    configure: mock.configure,
  },
};
import { useComputeNode } from "../useComputeNode";
const state = (confirmationId: string, revision: number, bindingWorkspaceId?: string) =>
  ({
    confirmationId,
    revision,
    bindingWorkspaceId,
    desiredEnabled: !!bindingWorkspaceId,
  }) as ComputeNodeState;
it("accepts a new account's lower revision and rejects late old command results and errors", async () => {
  const { result } = renderHook(() => useComputeNode());
  act(() => mock.listener?.(state("A:1", 90, "private-A")));
  let resolve!: (state: ComputeNodeState) => void;
  mock.configure.mockImplementationOnce(
    () =>
      new Promise<ComputeNodeState>((done) => {
        resolve = done;
      })
  );
  let pending!: Promise<ComputeNodeState | undefined>;
  act(() => {
    pending = result.current.configure({
      desiredEnabled: true,
      workspaceId: "private-A",
    });
  });
  act(() => mock.listener?.(state("B:2", 1)));
  expect(result.current.state?.bindingWorkspaceId).toBeUndefined();
  await act(async () => {
    resolve(state("A:1", 100, "private-A"));
    expect(await pending).toBeUndefined();
  });
  expect(result.current.state?.confirmationId).toBe("B:2");
  let reject!: (error: Error) => void;
  mock.configure.mockImplementationOnce(
    () =>
      new Promise((_done, fail) => {
        reject = fail;
      })
  );
  act(() => {
    pending = result.current.configure({ desiredEnabled: true, workspaceId: "B" });
  });
  act(() => mock.listener?.(state("A:3", 2)));
  await act(async () => {
    reject(new Error("private B failure"));
    await pending;
  });
  expect(result.current.error).toBeUndefined();
  expect(mock.get).not.toHaveBeenCalled();
  expect(result.current.state?.confirmationId).toBe("A:3");
});
