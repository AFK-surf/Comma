import { act, renderHook } from "@comma/test-utils/render";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import type { HostMaintenanceState } from "@comma/native-bridge";
import type { SettingsPanelItem } from "@comma/ui";

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
const press = (item: SettingsPanelItem | undefined) => {
  if (item?.control?.type !== "button") throw new Error("Expected button");
  return item.control.onPress?.();
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

it("uses only shared visible ticks, never starts or resumes maintenance on a read", async () => {
  let hidden = false;
  vi.spyOn(document, "hidden", "get").mockImplementation(() => hidden);
  const { rerender } = renderHook(
    ({ visible, tick }) => useHostMaintenanceCategory(visible, tick, vi.fn(), vi.fn()),
    {
      initialProps: { visible: true, tick: 1 },
    }
  );
  await act(async () => {});
  expect(mock.read).toHaveBeenCalledTimes(1);
  await act(async () => {
    rerender({ visible: true, tick: 2 });
  });
  expect(mock.read).toHaveBeenCalledTimes(2);
  hidden = true;
  await act(async () => {
    rerender({ visible: true, tick: 3 });
  });
  await act(async () => {
    rerender({ visible: false, tick: 4 });
  });
  expect(mock.read).toHaveBeenCalledTimes(2);
  expect(mock.maintain).not.toHaveBeenCalled();
  expect(mock.resume).not.toHaveBeenCalled();
});

it("routes required update to real maintenance and prevents duplicate submissions", async () => {
  mock.read.mockResolvedValue({ ...installed, updateAvailable: false });
  let finish!: (state: HostMaintenanceState) => void;
  mock.maintain.mockImplementation(
    () =>
      new Promise<HostMaintenanceState>((resolve) => {
        finish = resolve;
      })
  );
  const opened = vi.fn();
  const { result } = renderHook(() =>
    useHostMaintenanceCategory(true, 0, opened, vi.fn(), true)
  );
  await act(async () => {});
  act(() => press(result.current.section.items[0]));
  expect(opened).toHaveBeenCalledOnce();
  const submit = () =>
    result.current.detail
      .sections!.flatMap((s) => s.items)
      .find((i) => i.id === "compute-node.host-submit");
  act(() => {
    const button = submit();
    press(button);
    press(button);
  });
  expect(mock.maintain).toHaveBeenCalledTimes(1);
  expect(mock.maintain).toHaveBeenCalledWith({
    action: "update",
    dataPolicy: "preserve",
  });
  await act(async () => {
    finish({
      ...installed,
      operation: {
        ...operation,
        action: "update",
        dataPolicy: "preserve",
        phase: "completed",
        outcome: "succeeded",
      },
    });
  });
});

it("does not carry a destructive data choice into another maintenance action", async () => {
  mock.maintain.mockResolvedValue({
    ...installed,
    operation: { ...operation, phase: "completed", outcome: "succeeded" },
  });
  const { result } = renderHook(() =>
    useHostMaintenanceCategory(true, 0, vi.fn(), vi.fn())
  );
  await act(async () => {});
  act(() => result.current.choose("uninstall"));
  const row = (id: string) =>
    result.current.detail.sections!.flatMap((s) => s.items).find((i) => i.id === id);
  act(() => {
    const policy = row("compute-node.host-policy")!.control;
    if (policy?.type !== "dropdown") throw new Error("Expected data policy");
    policy.onChange?.("reset");
  });
  await act(async () => {
    press(row("compute-node.host-submit"));
  });
  expect(mock.maintain).toHaveBeenLastCalledWith({
    action: "uninstall",
    dataPolicy: "reset",
  });
  act(() => result.current.choose("reinstall"));
  const nextPolicy = row("compute-node.host-policy")!.control;
  expect(nextPolicy?.type === "dropdown" && nextPolicy.value).toBe("preserve");
});

it("resumes the exact existing local receipt without submitting a replacement", async () => {
  mock.read.mockResolvedValue({ ...installed, operation });
  mock.resume.mockResolvedValue({ ...installed, operation });
  const { result, rerender } = renderHook(
    ({ tick }) => useHostMaintenanceCategory(true, tick, vi.fn(), vi.fn()),
    { initialProps: { tick: 0 } }
  );
  await act(async () => {});
  await act(async () => {
    rerender({ tick: 1 });
  });
  expect(mock.resume).not.toHaveBeenCalled();
  await act(async () => {
    press(result.current.detail.sections![0]!.items[0]);
  });
  expect(mock.resume).toHaveBeenCalledWith({ requestId: operation.requestId });
  expect(mock.maintain).not.toHaveBeenCalled();
});

it("keeps an ambiguous mutation blocked until an observational read resolves it", async () => {
  mock.maintain.mockRejectedValue(new Error("IPC disconnected"));
  const { result } = renderHook(() =>
    useHostMaintenanceCategory(true, 0, vi.fn(), vi.fn())
  );
  await act(async () => {});
  act(() => result.current.choose("uninstall"));
  const row = (id: string) =>
    result.current.detail.sections!.flatMap((s) => s.items).find((i) => i.id === id);
  await act(async () => {
    press(row("compute-node.host-submit"));
  });
  const submit = row("compute-node.host-submit")?.control;
  expect(submit?.type === "button" && submit.disabled).toBe(true);
  mock.read.mockResolvedValue({ ...installed, operation });
  await act(async () => {
    await result.current.refresh();
  });
  expect(result.current.unfinished).toBe(true);
  expect(mock.maintain).toHaveBeenCalledTimes(1);
  expect(mock.resume).not.toHaveBeenCalled();
});

it("offers local reinstallation when the installed component cannot be read", async () => {
  mock.read.mockResolvedValue({
    ...installed,
    installation: "unreadable",
    updateAvailable: false,
  });
  mock.maintain.mockResolvedValue(installed);
  const { result } = renderHook(() =>
    useHostMaintenanceCategory(true, 0, vi.fn(), vi.fn())
  );
  await act(async () => {});
  act(() => press(result.current.section.items[0]));
  const submit = result.current.detail
    .sections!.flatMap((s) => s.items)
    .find((i) => i.id === "compute-node.host-submit");
  expect(submit?.control?.type === "button" && submit.control.disabled).toBe(false);
  await act(async () => press(submit));
  expect(mock.maintain).toHaveBeenCalledWith({
    action: "reinstall",
    dataPolicy: "preserve",
  });
});

it("keeps uninstall available after a data-preserving uninstall so retained data can be cleared", async () => {
  mock.read.mockResolvedValue({
    ...installed,
    installation: "not_installed",
    updateAvailable: false,
  });
  const { result } = renderHook(() =>
    useHostMaintenanceCategory(true, 0, vi.fn(), vi.fn())
  );
  await act(async () => {});
  const menu = result.current.detail
    .sections!.flatMap((s) => s.items)
    .find((i) => i.id === "compute-node.host-actions")?.control;
  expect(menu?.type === "menu" && menu.items.some((i) => i.id === "uninstall")).toBe(
    true
  );
});

it("reads progress during a long operation and fences late reads after completion", async () => {
  let finish!: (state: HostMaintenanceState) => void;
  mock.maintain.mockImplementation(
    () =>
      new Promise<HostMaintenanceState>((resolve) => {
        finish = resolve;
      })
  );
  const { result, rerender } = renderHook(
    ({ tick }) => useHostMaintenanceCategory(true, tick, vi.fn(), vi.fn()),
    { initialProps: { tick: 0 } }
  );
  await act(async () => {});
  act(() => result.current.choose("uninstall"));
  act(() =>
    press(
      result.current.detail
        .sections!.flatMap((s) => s.items)
        .find((i) => i.id === "compute-node.host-submit")
    )
  );
  expect(result.current.pending).toBe(true);
  mock.read.mockResolvedValue({ ...installed, operation });
  await act(async () => {
    rerender({ tick: 1 });
  });
  expect(result.current.state?.operation?.phase).toBe("removing");
  expect(mock.read).toHaveBeenCalledTimes(2);
  let lateRead!: (state: HostMaintenanceState) => void;
  mock.read.mockImplementation(
    () =>
      new Promise<HostMaintenanceState>((resolve) => {
        lateRead = resolve;
      })
  );
  await act(async () => {
    rerender({ tick: 2 });
  });
  await act(async () => {
    finish({
      ...installed,
      installation: "not_installed",
      operation: { ...operation, phase: "completed", outcome: "succeeded" },
    });
  });
  await act(async () => {
    lateRead({ ...installed, operation });
  });
  expect(result.current.state?.operation?.outcome).toBe("succeeded");
  expect(result.current.state?.installation).toBe("not_installed");
});

const failedRestore: NonNullable<HostMaintenanceState["operation"]> = {
  ...operation,
  action: "reinstall",
  dataPolicy: "preserve",
  phase: "checking",
  outcome: "failed",
  problem: "Guest data could not be restored",
};

it.each([
  ["reinstall", "reset"],
  ["uninstall", "preserve"],
  ["uninstall", "reset"],
] as const)(
  "offers an explicit %s/%s successor after failed maintenance",
  async (action, dataPolicy) => {
    mock.read.mockResolvedValue({ ...installed, operation: failedRestore });
    mock.maintain.mockResolvedValue({
      ...installed,
      operation: {
        ...operation,
        requestId: "bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb",
        action,
        dataPolicy,
      },
    });
    const { result } = renderHook(() =>
      useHostMaintenanceCategory(true, 0, vi.fn(), vi.fn())
    );
    await act(async () => {});
    const row = (id: string) =>
      result.current.detail.sections!.flatMap((s) => s.items).find((i) => i.id === id);
    expect(row("compute-node.host-result")?.title).toBe("Maintenance is incomplete");
    const resume = row("compute-node.host-result")?.control;
    expect(resume?.type === "button" && !resume.disabled).toBe(true);
    const menu = row("compute-node.host-actions")?.control;
    if (menu?.type !== "menu") throw new Error("Expected maintenance menu");
    expect(menu.disabled).toBe(false);
    expect(menu.items.some((i) => i.id === "update")).toBe(false);
    expect(menu.items.find((i) => i.id === "reinstall")?.label).toBe(
      "Delete data and reinstall"
    );
    act(() => menu.items.find((i) => i.id === action)!.onPress());
    const policy = row("compute-node.host-policy")?.control;
    if (policy?.type !== "dropdown") throw new Error("Expected data policy");
    expect(policy.value).toBe(action === "reinstall" ? "reset" : "preserve");
    if (action === "reinstall")
      expect(policy.items.map((i) => i.id)).toEqual(["reset"]);
    act(() => policy.onChange?.(dataPolicy));
    expect(mock.maintain).not.toHaveBeenCalled();
    await act(async () => press(row("compute-node.host-submit")));
    // Main owns the superseded request identity and final confirmation.
    expect(mock.maintain).toHaveBeenCalledExactlyOnceWith({ action, dataPolicy });
    expect(mock.resume).not.toHaveBeenCalled();
  }
);

it("continues the original failed operation without changing its data policy", async () => {
  mock.read.mockResolvedValue({ ...installed, operation: failedRestore });
  mock.resume.mockResolvedValue({
    ...installed,
    operation: { ...failedRestore, outcome: "pending" },
  });
  const { result } = renderHook(() =>
    useHostMaintenanceCategory(true, 0, vi.fn(), vi.fn())
  );
  await act(async () => {});
  await act(async () => press(result.current.detail.sections![0]!.items[0]));
  expect(mock.resume).toHaveBeenCalledExactlyOnceWith({
    requestId: failedRestore.requestId,
  });
  expect(mock.maintain).not.toHaveBeenCalled();
  expect(result.current.state?.operation?.dataPolicy).toBe("preserve");
});

it("withdraws a replacement selection when the old failure resumes and never replaces running maintenance", async () => {
  mock.read.mockResolvedValue({ ...installed, operation: failedRestore });
  const { result } = renderHook(() =>
    useHostMaintenanceCategory(true, 0, vi.fn(), vi.fn())
  );
  await act(async () => {});
  act(() => result.current.choose("uninstall"));
  const rows = () => result.current.detail.sections!.flatMap((s) => s.items);
  expect(rows().some((i) => i.id === "compute-node.host-submit")).toBe(true);
  mock.read.mockResolvedValue({
    ...installed,
    operation: { ...failedRestore, outcome: "pending" },
  });
  await act(async () => {
    await result.current.refresh();
  });
  expect(rows().some((i) => i.id === "compute-node.host-submit")).toBe(false);
  const menu = rows().find((i) => i.id === "compute-node.host-actions")?.control;
  expect(menu?.type === "menu" && menu.disabled).toBe(true);
  act(() => result.current.choose("uninstall"));
  expect(rows().some((i) => i.id === "compute-node.host-submit")).toBe(false);
  expect(mock.maintain).not.toHaveBeenCalled();
});

it("does not permit replacement when the failed receipt can no longer be confirmed", async () => {
  mock.read.mockResolvedValue({ ...installed, operation: failedRestore });
  const { result } = renderHook(() =>
    useHostMaintenanceCategory(true, 0, vi.fn(), vi.fn())
  );
  await act(async () => {});
  mock.read.mockRejectedValue(new Error("receipt unavailable"));
  await act(async () => {
    await result.current.refresh();
  });
  const menu = result.current.detail
    .sections!.flatMap((s) => s.items)
    .find((i) => i.id === "compute-node.host-actions")?.control;
  expect(menu?.type === "menu" && menu.disabled).toBe(true);
  act(() => result.current.choose("reinstall"));
  expect(
    result.current.detail
      .sections!.flatMap((s) => s.items)
      .some((i) => i.id === "compute-node.host-submit")
  ).toBe(false);
  expect(mock.maintain).not.toHaveBeenCalled();
});
