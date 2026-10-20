import { act, renderHook } from "@comma/test-utils/render";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import type { HostMaintenanceState } from "@comma/native-bridge";

const mock = vi.hoisted(() => ({ read: vi.fn(), maintain: vi.fn(), resume: vi.fn() }));
vi.mock("@comma/native-bridge", async (original) => ({
  ...(await original<object>()),
  getNativeBridge: () => bridge,
}));
const bridge = {
  platform: "electron",
  computeNode: {
    hostMaintenanceState: mock.read,
    maintainHost: mock.maintain,
    resumeHostMaintenance: mock.resume,
  },
};
import { useHostMaintenanceCategory } from "../useHostMaintenanceCategory";
const installed: HostMaintenanceState = {
  installation: "installed",
  installedReleaseId: "old",
  selectedReleaseId: "new",
  updateAvailable: true,
};
const operation: NonNullable<HostMaintenanceState["operation"]> = {
  requestId: "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa",
  action: "uninstall",
  dataPolicy: "reset",
  phase: "removing",
  outcome: "pending",
};
beforeEach(() => {
  mock.read.mockResolvedValue(installed);
});
afterEach(() => {
  vi.restoreAllMocks();
  mock.read.mockReset();
  mock.maintain.mockReset();
  mock.resume.mockReset();
});

it("reads only on shared visible ticks and never mutates on observation", async () => {
  let hidden = false;
  vi.spyOn(document, "hidden", "get").mockImplementation(() => hidden);
  const { rerender } = renderHook(
    ({ visible, tick }) => useHostMaintenanceCategory(visible, tick),
    { initialProps: { visible: true, tick: 0 } }
  );
  await act(async () => {});
  await act(async () => rerender({ visible: true, tick: 1 }));
  hidden = true;
  await act(async () => rerender({ visible: true, tick: 2 }));
  await act(async () => rerender({ visible: false, tick: 3 }));
  expect(mock.read).toHaveBeenCalledTimes(2);
  expect(mock.maintain).not.toHaveBeenCalled();
  expect(mock.resume).not.toHaveBeenCalled();
});
it("preserves files for repair/uninstall and only explicit clearing requests reset", async () => {
  mock.maintain.mockResolvedValue(installed);
  const { result } = renderHook(() => useHostMaintenanceCategory(true, 0));
  await act(async () => {});
  await act(() => result.current.submit("reinstall"));
  expect(mock.maintain).toHaveBeenLastCalledWith({
    action: "reinstall",
    dataPolicy: "preserve",
  });
  await act(() => result.current.submit("uninstall"));
  expect(mock.maintain).toHaveBeenLastCalledWith({
    action: "uninstall",
    dataPolicy: "preserve",
  });
  await act(() => result.current.submit("clear"));
  expect(mock.maintain).toHaveBeenLastCalledWith({
    action: "reinstall",
    dataPolicy: "reset",
  });
  mock.read.mockResolvedValue({ ...installed, installation: "not_installed" });
  await act(() => result.current.refresh());
  await act(() => result.current.submit("clear"));
  expect(mock.maintain).toHaveBeenLastCalledWith({
    action: "uninstall",
    dataPolicy: "reset",
  });
});
it("prevents duplicate requests and fences late reads after mutation completion", async () => {
  let finish!: (state: HostMaintenanceState) => void;
  mock.maintain.mockImplementation(
    () =>
      new Promise((resolve) => {
        finish = resolve;
      })
  );
  const { result } = renderHook(() => useHostMaintenanceCategory(true, 0, true));
  await act(async () => {});
  let request!: Promise<HostMaintenanceState | undefined>;
  act(() => {
    request = result.current.submit("update");
    void result.current.submit("update");
  });
  expect(mock.maintain).toHaveBeenCalledTimes(1);
  mock.read.mockResolvedValue({ ...installed, operation });
  await act(() => result.current.refresh());
  expect(result.current.state?.operation?.phase).toBe("removing");
  let late!: (state: HostMaintenanceState) => void;
  mock.read.mockImplementation(
    () =>
      new Promise((resolve) => {
        late = resolve;
      })
  );
  let read!: Promise<void>;
  act(() => {
    read = result.current.refresh();
  });
  await act(async () => {
    finish({
      ...installed,
      operation: { ...operation, outcome: "succeeded", phase: "completed" },
    });
    await request;
  });
  await act(async () => {
    late({ ...installed, operation });
    await read;
  });
  expect(result.current.state?.operation?.outcome).toBe("succeeded");
});
it("resumes the original failed receipt and blocks replacement while outcome is unreadable", async () => {
  const failed = {
    ...operation,
    action: "reinstall" as const,
    dataPolicy: "preserve" as const,
    outcome: "failed" as const,
  };
  mock.read.mockResolvedValue({ ...installed, operation: failed });
  mock.resume.mockResolvedValue({
    ...installed,
    operation: { ...failed, outcome: "pending" },
  });
  const { result } = renderHook(() => useHostMaintenanceCategory(true, 0));
  await act(async () => {});
  await act(() => result.current.submit("reinstall"));
  expect(mock.maintain).not.toHaveBeenCalled();
  await act(async () => result.current.resume());
  expect(mock.resume).toHaveBeenCalledExactlyOnceWith({
    requestId: operation.requestId,
  });
  await act(() => result.current.submit("uninstall"));
  expect(mock.maintain).not.toHaveBeenCalled();
  mock.read.mockRejectedValue(new Error("receipt unavailable"));
  await act(() => result.current.refresh());
  await act(() => result.current.submit("clear"));
  expect(mock.maintain).not.toHaveBeenCalled();
});
it("requires a read after an ambiguous response instead of replacing the operation", async () => {
  mock.maintain.mockRejectedValue(new Error("IPC disconnected"));
  const { result } = renderHook(() => useHostMaintenanceCategory(true, 0));
  await act(async () => {});
  await act(() => result.current.submit("uninstall"));
  await act(() => result.current.submit("uninstall"));
  expect(mock.maintain).toHaveBeenCalledTimes(1);
  expect(result.current.readingError).toBe(true);
  mock.read.mockResolvedValue({ ...installed, operation });
  await act(() => result.current.refresh());
  expect(result.current.unfinished).toBe(true);
  expect(mock.resume).not.toHaveBeenCalled();
});
