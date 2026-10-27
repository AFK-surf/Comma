import { act, renderHook } from "@comma/test-utils/render";
import { beforeEach, expect, it, vi } from "vitest";

const mock = vi.hoisted(() => ({ candidates: vi.fn(), recover: vi.fn() }));
vi.mock("@comma/native-bridge", async (original) => ({
  ...(await original<object>()),
  getNativeBridge: () => ({
    computeNode: { recoveryCandidates: mock.candidates, recover: mock.recover },
  }),
}));
import { useComputeRecoverySection } from "../useComputeRecoverySection";

const candidate = {
  key: "installation-a",
  label: "Mac A",
  workspaceId: "workspace-a",
  endpoint: "https://service.example",
};
beforeEach(() => {
  vi.resetAllMocks();
  mock.recover.mockResolvedValue(undefined);
});

it("selects a unique candidate for inline confirmation and recovers only on confirm", async () => {
  mock.candidates.mockResolvedValue({
    candidates: [candidate],
    confirmationId: "session-a",
  });
  const recovered = vi.fn();
  const { result } = renderHook(() =>
    useComputeRecoverySection("workspace-a", "session-a", recovered)
  );
  expect(mock.candidates).not.toHaveBeenCalled();
  await act(() => result.current.discover());
  expect(mock.recover).not.toHaveBeenCalled();
  expect(result.current.selected?.key).toBe(candidate.key);
  await act(async () => result.current.confirm());
  expect(mock.recover).toHaveBeenCalledWith({
    key: candidate.key,
    confirmationId: "session-a",
  });
  expect(recovered).toHaveBeenCalled();
});

it("does not infer uniqueness from a partial page or its final page", async () => {
  mock.candidates
    .mockResolvedValueOnce({
      candidates: [candidate],
      confirmationId: "session-a",
      nextCursor: "page-2",
    })
    .mockResolvedValueOnce({
      candidates: [{ ...candidate, key: "installation-b" }],
      confirmationId: "session-a",
    });
  const { result } = renderHook(() =>
    useComputeRecoverySection("workspace-a", "session-a", vi.fn())
  );
  await act(() => result.current.discover());
  expect(
    result.current.page?.candidates.some((item) => item.key === candidate.key)
  ).toBe(true);
  await act(() => result.current.discover("page-2"));
  expect(result.current.selected).toBeUndefined();
  expect(mock.recover).not.toHaveBeenCalled();
  expect(mock.candidates).toHaveBeenLastCalledWith({
    workspaceId: "workspace-a",
    cursor: "page-2",
  });
});

it("discards discovery from an earlier Session before confirming a candidate", async () => {
  let resolve!: (value: unknown) => void;
  mock.candidates.mockImplementation(
    () =>
      new Promise((done) => {
        resolve = done;
      })
  );
  const recovered = vi.fn();
  const { result, rerender } = renderHook(
    ({ session }) => useComputeRecoverySection("workspace-a", session, recovered),
    { initialProps: { session: "session-a" } }
  );
  let pending!: Promise<void>;
  act(() => {
    pending = result.current.discover();
  });
  rerender({ session: "session-b" });
  await act(async () => {
    resolve({ candidates: [candidate], confirmationId: "session-a" });
    await pending;
  });
  expect(mock.recover).not.toHaveBeenCalled();
  expect(recovered).not.toHaveBeenCalled();
});
