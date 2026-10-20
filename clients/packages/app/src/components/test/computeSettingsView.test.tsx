import { act, render, renderHook, screen, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { useCommaMessages } from "@comma/i18n/react";
import {
  computeNodeProblemSchema,
  type ComputeNodeState,
  type HostMaintenanceState,
} from "@comma/native-bridge";

// The local compute card over a scripted node owner and maintenance owner.

const mock = vi.hoisted(() => ({
  state: {} as ComputeNodeState,
  canManage: true,
  maintain: vi.fn(),
  abandon: vi.fn(),
  refresh: vi.fn(),
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
    refresh: vi.fn(),
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
const bridge = {
  platform: "electron",
  computeNode: {
    state: { subscribe: () => () => {} },
    hostMaintenanceState: async () => installed,
    maintainHost: mock.maintain,
    localOverview: async () => ({ availability: "available", environments: [] }),
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
  return within(screen.getByRole("region", { name: "Compute environment" }));
}

beforeEach(() => {
  mock.canManage = true;
  mock.state = {
    status: "action_required",
    confirmationId: "session-a",
    desiredEnabled: true,
    observationFresh: true,
    bindingWorkspaceId: "workspace",
    bindingInstallationId: "operation-1",
    bindingRevision: 3,
    revision: 3,
    eligibility: { eligible: true },
    facets: { connection: "disconnected" },
  } as ComputeNodeState;
  mock.refresh.mockImplementation(async () => mock.state);
  mock.maintain.mockResolvedValue(installed);
  mock.abandon.mockResolvedValue(undefined);
});
afterEach(() => {
  vi.clearAllMocks();
});

it("starts the component update from the card when the installed components lack a capability", async () => {
  mock.state = { ...mock.state, issue: "capability_missing" };
  const card = await show();
  await userEvent.click(card.getByRole("button", { name: "Update Agent VMM" }));
  expect(mock.maintain).toHaveBeenCalledWith({
    action: "update",
    dataPolicy: "preserve",
  });
});

it("closes an install request that was never handed over after confirmation", async () => {
  mock.state = {
    ...mock.state,
    issue: "enable_incomplete",
    recoveryActions: ["continue_enable", "check_status"],
    canAbandonRequest: true,
  };
  const card = await show();
  await userEvent.click(card.getByRole("button", { name: "Close unfinished request" }));
  const dialog = within(screen.getByRole("dialog"));
  await userEvent.click(
    dialog.getByRole("button", { name: "Close unfinished request" })
  );
  expect(mock.abandon).toHaveBeenCalledWith({
    workspaceId: "workspace",
    installationId: "operation-1",
    confirmationId: "session-a",
    bindingRevision: 3,
  });
});

it("offers no request closing when Main does not permit it", async () => {
  mock.state = { ...mock.state, issue: "enable_incomplete" };
  const card = await show();
  expect(card.queryByRole("button", { name: "Close unfinished request" })).toBeNull();
});

it("tells a reader without management permission why there is no node action", async () => {
  mock.canManage = false;
  mock.state = {
    ...mock.state,
    status: "not_set",
    desiredEnabled: false,
    bindingWorkspaceId: undefined,
  };
  const card = await show();
  expect(card.queryByRole("button", { name: "Enable this Mac" })).toBeNull();
  expect(
    card.getByText(
      "You can view the status. Changes need workspace management permission."
    )
  ).toBeVisible();
});

it("shows a problem in the user's language and keeps the raw error out of the card", async () => {
  mock.state = {
    ...mock.state,
    problem: "stop_failed",
    problemDetail: "helper exited with status 70",
  };
  const card = await show();
  expect(
    card.getByText("Disabling did not finish. Check the status, then try again.")
  ).toBeVisible();
  expect(card.queryByText(/helper exited/)).toBeNull();
});

it("has a message for every problem code Main publishes", async () => {
  const { computeProblemMessage } =
    await vi.importActual<typeof import("../useComputeNode")>("../useComputeNode");
  const { result } = renderHook(() => useCommaMessages());
  const texts = computeNodeProblemSchema.options.map((code) =>
    computeProblemMessage(code, result.current)
  );
  for (const [index, text] of texts.entries()) {
    expect(text).toBeTruthy();
    expect(text).not.toBe(computeNodeProblemSchema.options[index]);
  }
});
