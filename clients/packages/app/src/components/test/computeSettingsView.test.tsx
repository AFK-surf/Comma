import { act, render, screen, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import {
  type ComputeNodeState,
  type HostMaintenanceState,
  type LocalComputeOverview,
} from "@comma/native-bridge";

// The local compute card over a scripted node owner and maintenance owner.

const mock = vi.hoisted(() => ({
  state: {} as ComputeNodeState,
  host: {} as HostMaintenanceState,
  canManage: true,
  maintain: vi.fn(),
  resume: vi.fn(),
  abandon: vi.fn(),
  refresh: vi.fn(),
  workloadRefresh: vi.fn(),
  configure: vi.fn(),
  remove: vi.fn(),
  reset: vi.fn(),
  continue: vi.fn(),
  dispose: vi.fn(),
  environments: [] as LocalComputeOverview["environments"],
}));
vi.mock("@comma/native-bridge", async (original) => ({
  ...(await original<object>()),
  getNativeBridge: () => bridge,
}));
vi.mock("../activeWorkspace", () => ({
  useActiveWorkspaceId: () => "workspace",
}));
vi.mock("../useComputeNode", async (original) => ({
  ...(await original<object>()),
  useComputeNode: () => ({
    available: true,
    pending: false,
    state: mock.state,
    refresh: mock.refresh,
    abandon: mock.abandon,
    configure: mock.configure,
    remove: mock.remove,
    continue: mock.continue,
    drain: vi.fn(),
    reauthorize: vi.fn(),
    resetLocalRecord: mock.reset,
  }),
}));
vi.mock("../useComputeWorkloadsSection", () => ({
  useComputeWorkloadsSection: () => ({
    workspaceName: "Workspace A",
    close: vi.fn(),
    canManage: mock.canManage,
    projection: { environments: [], workloads: [], can_manage: mock.canManage },
    rows: [],
    pending: false,
    refresh: mock.workloadRefresh,
    openCreate: vi.fn(),
  }),
}));
vi.mock("../useComputeRecoverySection", () => ({
  useComputeRecoverySection: () => ({}),
}));
const installed: HostMaintenanceState = {
  installation: "installed",
  selectedReleaseId: "release",
  updateAvailable: false,
};
const failedRequest = "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa";
const bridge = {
  platform: "electron",
  computeNode: {
    state: { subscribe: () => () => {} },
    hostMaintenanceState: async () => mock.host,
    maintainHost: mock.maintain,
    resumeHostMaintenance: mock.resume,
    localOverview: async () => ({
      availability: "available",
      environments: mock.environments,
    }),
    disposeLocal: mock.dispose,
  },
};
import { useComputeSettingsController } from "../useComputeSettingsController";
import { ComputeSettingsView } from "../ComputeSettingsView";

function Harness() {
  const controller = useComputeSettingsController(true, true);
  return (
    <>
      <ComputeSettingsView controller={controller} />
      {controller.nodeOverlay}
    </>
  );
}

async function show() {
  render(<Harness />);
  await act(async () => {});
  return within(screen.getByRole("region", { name: "Sandbox" }));
}

beforeEach(() => {
  mock.environments = [
    {
      key: "local-env",
      label: "env-a",
      origin: "local",
      state: "vm_stopped",
      canDisposeLocal: true,
      canReadWorkloads: false,
      canOperate: false,
    },
  ];
  mock.canManage = true;
  mock.host = installed;
  mock.state = {
    status: "action_required",
    confirmationId: "session-a",
    desiredEnabled: true,
    observationFresh: true,
    bindingWorkspaceId: "workspace",
    bindingRegistrationId: "operation-1",
    bindingRevision: 3,
    revision: 3,
    eligibility: { eligible: true },
    observed: {
      host: "ready",
      connector: "degraded",
      readability: "readable",
      salix: "degraded",
    },
    facets: {
      connection: "disconnected",
      admission: "closed",
      installationHealth: "healthy",
      runtimeReadiness: "unavailable",
      workActivity: "idle",
    },
  };
  mock.refresh.mockImplementation(async () => mock.state);
  mock.configure.mockImplementation(async () => mock.state);
  mock.remove.mockImplementation(async () => mock.state);
  mock.reset.mockImplementation(async () => mock.state);
  mock.maintain.mockResolvedValue(installed);
  mock.abandon.mockResolvedValue(undefined);
});
afterEach(() => {
  vi.clearAllMocks();
});

it("reopens a failed remove with one reason and continues the original action", async () => {
  mock.state = {
    ...mock.state,
    problem: "removal_failed",
    primaryAction: "continue",
    currentRequest: { requestId: "remove-1", kind: "remove" },
  };
  const card = await show();
  expect(card.getAllByText(/Disconnect did not finish/i)).toHaveLength(1);
  await userEvent.click(card.getByRole("button", { name: "Continue removal" }));
  expect(mock.continue).toHaveBeenCalledTimes(1);
  expect(mock.configure).not.toHaveBeenCalled();
});

it("shows software progress and storage in the same local settings page", async () => {
  mock.host = {
    ...installed,
    operation: {
      requestId: failedRequest,
      action: "update",
      dataPolicy: "preserve",
      phase: "installing",
      outcome: "pending",
    },
  };
  await show();
  await userEvent.click(screen.getByRole("button", { name: "Local settings" }));
  expect(screen.getByRole("heading", { name: "Compute components" })).toBeTruthy();
  expect(
    screen.getByRole("heading", { name: "Compute component data disk" })
  ).toBeTruthy();
  expect(screen.getByText(/env-a/)).toBeTruthy();
  expect(screen.queryByText("View progress")).toBeNull();
});

it("passes local deletion directly to the trusted native confirmation", async () => {
  await show();
  await userEvent.click(screen.getByRole("button", { name: "Local settings" }));
  await userEvent.click(screen.getByRole("button", { name: /env-a.*Node actions/ }));
  await userEvent.click(
    screen.getByRole("menuitem", { name: "Delete local environment" })
  );
  expect(mock.dispose).toHaveBeenCalledWith({ key: "local-env" });
  expect(screen.queryByRole("dialog", { name: "Delete local environment" })).toBeNull();
});

it("shows one explicit registration-wide deletion for two remote environments and keeps their details", async () => {
  mock.environments = [
    {
      key: "remote-a",
      label: "env-a",
      origin: "remote",
      state: "unknown",
      canDisposeLocal: true,
      canReadWorkloads: false,
      canOperate: false,
      disposalScope: { key: "remote-a", label: "reg-scope" },
    },
    {
      key: "remote-b",
      label: "env-b",
      origin: "remote",
      state: "unknown",
      canDisposeLocal: false,
      canReadWorkloads: false,
      canOperate: false,
      disposalScope: { key: "remote-a", label: "reg-scope" },
    },
  ];
  await show();
  await userEvent.click(screen.getByRole("button", { name: "Local settings" }));
  expect(screen.getAllByText("Local data")).toHaveLength(3);
  expect(screen.getByText("…env-a")).toBeTruthy();
  expect(screen.getByText("…env-b")).toBeTruthy();
  await userEvent.click(screen.getByRole("button", { name: "reg-scope Node actions" }));
  const remove = screen.getAllByRole("menuitem", { name: "Delete local data" });
  expect(remove).toHaveLength(1);
  expect(
    screen.queryByRole("menuitem", { name: "Delete local environment" })
  ).toBeNull();
  await userEvent.click(remove[0]!);
  expect(mock.dispose).toHaveBeenCalledWith({ key: "remote-a" });
});

it("keeps explicit Update and Repair available when the source has no published version comparison", async () => {
  mock.host = {
    installation: "installed",
    installedReleaseId: "operator-release",
    updateAvailable: false,
  };
  await show();
  await userEvent.click(screen.getByRole("button", { name: "Local settings" }));
  await userEvent.click(screen.getByText("Diagnostic details"));
  expect(screen.getByText("operator-release")).toBeTruthy();
  expect(screen.getByText("Version unknown")).toBeTruthy();
  expect(screen.getByRole("button", { name: "Repair…" })).toBeTruthy();
  await userEvent.click(screen.getByRole("button", { name: "Update Agent VMM" }));
  expect(mock.maintain).toHaveBeenCalledWith({
    action: "update",
    dataPolicy: "preserve",
  });
});

it("keeps cloud details available when local activity and disk samples are unknown", async () => {
  mock.environments = [
    {
      key: "remote-a",
      label: "env-a",
      origin: "remote",
      state: "unknown",
      canDisposeLocal: true,
      canReadWorkloads: true,
      canOperate: false,
      disposalScope: { key: "remote-a", label: "reg-scope" },
    },
  ];
  await show();
  await userEvent.click(screen.getByRole("button", { name: "Local settings" }));
  expect(screen.getByText("…env-a")).toBeTruthy();
  await userEvent.click(screen.getByRole("button", { name: /env-a.*Node actions/ }));
  expect(screen.getByRole("menuitem", { name: "Workloads" })).toBeTruthy();
});

it("hides Update for the installed official target while retaining Repair", async () => {
  mock.host = { ...installed, installedReleaseId: "release" };
  await show();
  await userEvent.click(screen.getByRole("button", { name: "Local settings" }));
  expect(screen.queryByRole("button", { name: "Update Agent VMM" })).toBeNull();
  expect(screen.getByRole("button", { name: "Repair…" })).toBeTruthy();
});

it("refreshes a ready workload projection only when native binding or operation facts change", async () => {
  mock.state = { ...mock.state, status: "ready", desiredEnabled: true };
  const view = render(<Harness />);
  await act(async () => {});
  const reads = mock.workloadRefresh.mock.calls.length;
  mock.state = { ...mock.state, revision: 4, bindingRevision: 4 };
  view.rerender(<Harness />);
  await act(async () => {});
  expect(mock.workloadRefresh).toHaveBeenCalledTimes(reads);
  mock.state = {
    ...mock.state,
    bindingRegistrationId: undefined,
    bindingWorkspaceId: undefined,
    desiredEnabled: false,
  };
  view.rerender(<Harness />);
  await act(async () => {});
  expect(mock.workloadRefresh).toHaveBeenCalledTimes(reads + 1);
  mock.state = {
    ...mock.state,
    desiredEnabled: true,
    bindingWorkspaceId: "workspace",
    bindingRegistrationId: "new-registration",
    operation: { requestId: "enable-new", kind: "configure", outcome: "pending" },
  };
  view.rerender(<Harness />);
  await act(async () => {});
  expect(mock.workloadRefresh).toHaveBeenCalledTimes(reads + 2);
  mock.state = {
    ...mock.state,
    operation: { ...mock.state.operation!, outcome: "succeeded" },
  };
  view.rerender(<Harness />);
  await act(async () => {});
  expect(mock.workloadRefresh).toHaveBeenCalledTimes(reads + 3);
});
