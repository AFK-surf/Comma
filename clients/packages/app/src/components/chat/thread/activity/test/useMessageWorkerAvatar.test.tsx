import { act, renderHook } from "@testing-library/react";
import { afterEach, expect, it, vi } from "vitest";
import { useMessageWorkerAvatar } from "../useMessageWorkerAvatar";
import { workerMeshGradientStyle } from "../workerAvatar";

afterEach(() => vi.unstubAllGlobals());

it("does not show a previous Worker's color while the new identity resolves", async () => {
  const pending: Array<(value: ArrayBuffer) => void> = [];
  vi.stubGlobal("crypto", {
    subtle: {
      digest: vi.fn(() => new Promise<ArrayBuffer>((resolve) => pending.push(resolve))),
    },
  });
  const { result, rerender } = renderHook(
    ({ id }: { id: string | undefined }) => useMessageWorkerAvatar(id),
    { initialProps: { id: "worker-a" as string | undefined } }
  );
  rerender({ id: "worker-b" });
  await act(async () => pending[0]!(new Uint8Array([1]).buffer));
  expect(result.current).toBeUndefined();
  await act(async () => pending[1]!(new Uint8Array([2]).buffer));
  expect(result.current).toEqual(workerMeshGradientStyle("actor_Ag"));
  rerender({ id: undefined });
  expect(result.current).toBeUndefined();
});

it("keeps the fallback avatar if Web Crypto fails", async () => {
  vi.stubGlobal("crypto", {
    subtle: { digest: vi.fn().mockRejectedValue(new Error("unavailable")) },
  });
  const { result } = renderHook(() => useMessageWorkerAvatar("worker"));
  await act(async () => {});
  expect(result.current).toBeUndefined();
});
