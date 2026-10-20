import type { ComputeValue, ComputeWorkload, DevicesValue } from "@comma/core/contract";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { act, render, screen, waitFor, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { beforeEach, expect, it, vi } from "vitest";
import { SettingsCategory } from "../../test/settingsHarness";
import { useDeviceSettingsCategory } from "../devices/useDeviceSettingsCategory";
import {
  createMemoryHistory,
  createRootRoute,
  createRouter,
  RouterProvider,
} from "@tanstack/react-router";

// Settings › Devices' Shells over a scripted core. What the core keeps
// on the device for a creation whose answer was lost, and the request id it
// asks again with, is tested in packages/core/test/compute.test.ts; here the
// page shows that creation, retries it, and acts on the Shell it names.

const workspace = "wsp_compute";

type State = Pick<ComputeValue, "creation" | "accepted"> & {
  workloads: ComputeWorkload[];
};

/** Devices over a core that keeps `state`, answering calls by `answers`. */
async function openCompute(
  state: State,
  answers: Record<string, (params: Record<string, unknown>) => unknown> = {}
) {
  const calls: [string, Record<string, unknown>][] = [];
  const core = createScriptedCore({
    values: (topic): ComputeValue | DevicesValue | undefined =>
      topic.topic === "compute"
        ? {
            workspace,
            projection: {
              environments: [
                {
                  id: "env_compute",
                  desired_state: "ready",
                  observed_state: "ready",
                  can_create: true,
                },
              ],
              workloads: state.workloads,
              next_workload_cursor: null,
            } as ComputeValue["projection"],
            error: false,
            creation: state.creation,
            accepted: state.accepted,
          }
        : topic.topic === "devices"
          ? {
              workspace,
              devices: [],
              cloud: null,
              hasMore: false,
              loading: false,
              failed: false,
              checks: {},
            }
          : undefined,
    calls: (name, raw) => {
      const params = raw as Record<string, unknown>;
      calls.push([name, params]);
      return answers[name]?.(params) ?? null;
    },
  });
  const user = userEvent.setup();
  const router = createRouter({
    routeTree: createRootRoute({ component: ComputePage }),
    history: createMemoryHistory(),
  });
  await router.load();
  render(core.wrap(<RouterProvider router={router} />));
  await screen.findByLabelText("Settings content");
  return {
    user,
    called: (name: string) => calls.filter(([n]) => n === name).map(([, p]) => p),
    /** The core sends what it keeps now. */
    changed: () => core.changed("compute"),
  };
}

function ComputePage() {
  return <SettingsCategory category={useDeviceSettingsCategory(true)} />;
}

const content = () => within(screen.getByLabelText("Settings content"));
const actions = async () =>
  (await content().findAllByRole("button", { name: /Node actions$/ }))[0]!;
const status = (text: RegExp) =>
  content()
    .getAllByRole("status")
    .find((element) => text.test(element.textContent ?? ""));

const shell = (id: string, fields: Partial<ComputeWorkload> = {}): ComputeWorkload =>
  ({
    id,
    environment_id: "env_compute",
    kind: "shell",
    desired_state: "ready",
    observed_state: "pending",
    ...fields,
  }) as ComputeWorkload;

beforeEach(() => {
  installNativeBridgeMock({ platform: "web" });
  localStorage.setItem("comma.activeWorkspaceId", workspace);
});

it("asks for a Shell once, however often Confirm is pressed", async () => {
  const state: State = { workloads: [], creation: null, accepted: null };
  const t = await openCompute(state);
  await t.user.click(await content().findByRole("button", { name: "New Shell" }));
  await t.user.clear(content().getByRole("textbox", { name: "Name" }));
  await t.user.paste("First Shell");
  await t.user.dblClick(screen.getByRole("button", { name: "Confirm creation" }));
  expect(t.called("compute.create")).toEqual([
    { workspace, environment: "env_compute", name: "First Shell" },
  ]);
});

it("shows a creation whose answer was lost, retries it, and then permits another Shell", async () => {
  // The core kept the creation on the device: its answer never came.
  const state: State = {
    workloads: [],
    creation: { requestId: "req-1", environmentId: "env_compute", name: "First Shell" },
    accepted: null,
  };
  const t = await openCompute(state, {
    "compute.create": () => {
      state.creation = null;
      state.workloads = [shell("workload_shell_1")];
      t.changed();
    },
  });
  expect(
    await content().findByText("Creation result is not yet confirmed")
  ).toBeInTheDocument();
  await t.user.click(content().getByRole("button", { name: "Retry this creation" }));
  // The retry asks for the same Shell; the core reuses its request.
  expect(t.called("compute.create")).toEqual([
    { workspace, environment: "env_compute", name: "First Shell" },
  ]);
  expect(
    await content().findByRole("button", { name: "Shell _shell_1" })
  ).toBeVisible();

  // Each state the Shell goes through reads as such.
  for (const [phase, observed, desired, text] of [
    ["waiting_connection", "pending", "ready", /Waiting for node connection/],
    ["starting", "pending", "ready", /Preparing/],
    ["ready", "ready", "ready", /Ready to use/],
    ["ready", "ready", "draining", /Being disabled; execution may still be active/],
    ["ready", "ready", "ready", /Ready to use/],
  ] as const) {
    state.workloads = [
      shell("workload_shell_1", {
        phase,
        observed_state: observed,
        desired_state: desired,
      }),
    ];
    t.changed();
    await waitFor(() => expect(status(text)).toBeDefined());
  }
  expect(content().queryByText(/Being disabled/)).toBeNull();

  // Settled, another Shell may be created.
  await t.user.click(content().getByRole("button", { name: "New Shell" }));
  await t.user.clear(content().getByRole("textbox", { name: "Name" }));
  await t.user.paste("Second Shell");
  await t.user.click(screen.getByRole("button", { name: "Confirm creation" }));
  expect(t.called("compute.create").at(-1)).toEqual({
    workspace,
    environment: "env_compute",
    name: "Second Shell",
  });
});

/** Shell A and Shell B, ready, each with its revision and generation. */
const namedShells = () =>
  ["A", "B"].map((name) =>
    shell(`shell_${name}`, {
      name: `Shell ${name}`,
      observed_state: "ready",
      phase: "ready",
      revision: 1,
      generation: 1,
      location: { provider: "agent_vmm", registration_id: "remote-registration" },
      actions: { rename: true, delete: true },
      deletion: null,
    } as Partial<ComputeWorkload>)
  ) as [ComputeWorkload, ComputeWorkload];

it("returns the focus to a Shell's actions when a rename opened from the keyboard is escaped", async () => {
  const t = await openCompute({
    workloads: [namedShells()[0]],
    creation: null,
    accepted: null,
  });
  // Escape from the keyboard-opened rename returns focus to its trigger.
  (await actions()).focus();
  await t.user.keyboard("{Enter}");
  (await screen.findByRole("menuitem", { name: "Rename" })).focus();
  await t.user.keyboard("{Enter}");
  await waitFor(() =>
    expect(screen.getByRole("textbox", { name: "Name" })).toHaveFocus()
  );
  // Focus moving from the menu into the dialog has React Aria check, on the
  // next animation frame, that focus stayed inside the settings page's focus
  // scope. A person presses Escape after that frame. Pressing it earlier lets
  // the check run after the dialog has closed, and the check then focuses the
  // page's first control instead of the trigger.
  await act(() => vi.advanceTimersToNextFrame());
  await t.user.keyboard("{Escape}");
  await waitFor(() =>
    expect(screen.queryByRole("dialog", { name: "Rename" })).toBeNull()
  );
  await waitFor(async () => expect(await actions()).toHaveFocus());
});

it("freezes the deletion target across a late detail read and keeps the adjacent Shell", async () => {
  const [a, b] = namedShells();
  const state: State = { workloads: [a, b], creation: null, accepted: null };
  let releaseDetail!: () => void;
  const detail = new Promise<void>((resolve) => (releaseDetail = resolve));
  const t = await openCompute(state, {
    // Shell B's detail read answers late.
    "compute.workload": async (params) => {
      await detail;
      return state.workloads.find((w) => w.id === params.id);
    },
    "compute.rename": (params) => {
      state.workloads = state.workloads.map((w) =>
        w.id === params.id ? { ...w, name: params.name as string, revision: 2 } : w
      );
      t.changed();
      return state.workloads[0];
    },
    "compute.delete": (params) => {
      const deleting = {
        ...state.workloads.find((w) => w.id === params.id)!,
        deletion: { phase: "cleaning", request_id: "del-1" },
        desired_state: "draining",
        phase: "deleting",
        revision: 3,
      } as ComputeWorkload;
      state.workloads = state.workloads.map((w) => (w.id === params.id ? deleting : w));
      t.changed();
      return deleting;
    },
  });

  await t.user.click(await actions());
  await t.user.click(await screen.findByRole("menuitem", { name: "Rename" }));
  const nameField = screen.getByRole("textbox", { name: "Name" });
  await t.user.clear(nameField);
  await t.user.paste("Named Shell A");
  await t.user.click(screen.getByRole("button", { name: "Save name" }));
  expect(
    await content().findByRole("button", { name: "Named Shell A" })
  ).toBeInTheDocument();
  expect(t.called("compute.rename")).toEqual([
    { workspace, id: "shell_A", revision: 1, name: "Named Shell A" },
  ]);

  // Shell B's detail read is still out when the reader returns and deletes A.
  await t.user.click(content().getByRole("button", { name: "Shell B" }));
  await t.user.click(content().getByRole("button", { name: "Back" }));
  await t.user.click(await actions());
  await t.user.click(await screen.findByRole("menuitem", { name: "Delete Shell" }));
  releaseDetail();
  const dialog = await screen.findByRole("dialog", { name: "Delete Shell" });
  await waitFor(() => expect(dialog).toHaveTextContent("Named Shell A"));
  await t.user.click(within(dialog).getByRole("button", { name: "Delete workload" }));
  expect(t.called("compute.delete")).toEqual([
    { workspace, id: "shell_A", revision: 2, generation: 1 },
  ]);
  expect(state.workloads[1]!.deletion).toBeNull();
  await waitFor(() => expect(status(/Deleting/)).toBeDefined());
});

it("names the deletion of a retired External Worker Workload without calling it a Shell", async () => {
  const [retired] = namedShells();
  const state: State = {
    workloads: [
      { ...retired, id: "worker_A", name: "Worker A", kind: "external_worker" },
    ],
    creation: null,
    accepted: null,
  };
  const t = await openCompute(state);

  await t.user.click(await actions());
  expect(screen.queryByRole("menuitem", { name: "Delete Shell" })).toBeNull();
  await t.user.click(await screen.findByRole("menuitem", { name: "Delete workload" }));
  const dialog = await screen.findByRole("dialog", { name: "Delete workload" });
  expect(dialog).not.toHaveTextContent("Shell");
  await t.user.click(within(dialog).getByRole("button", { name: "Delete workload" }));
  expect(t.called("compute.delete")).toEqual([
    { workspace, id: "worker_A", revision: 1, generation: 1 },
  ]);
});

it("says the node name is unavailable only for a Shell whose location is unknown", async () => {
  const [onMac, elsewhere] = namedShells();
  const state: State = {
    workloads: [onMac, { ...elsewhere, location: null } as unknown as ComputeWorkload],
    creation: null,
    accepted: null,
  };
  const t = await openCompute(state);
  const remove = async (index: number) => {
    await t.user.click(
      (await content().findAllByRole("button", { name: /Node actions$/ }))[index]!
    );
    await t.user.click(await screen.findByRole("menuitem", { name: "Delete Shell" }));
    return screen.findByRole("dialog", { name: "Delete Shell" });
  };
  const known = await remove(0);
  expect(known).toHaveTextContent("Mac · device not identified");
  expect(known).not.toHaveTextContent("The execution node name is unavailable.");
  await t.user.click(within(known).getByRole("button", { name: "Cancel" }));
  const unknown = await remove(1);
  expect(unknown).toHaveTextContent("Location unknown");
  expect(unknown).toHaveTextContent("The execution node name is unavailable.");
});

it("says the Mac is not connected when the workspace has no connected node for a new Shell", async () => {
  const t = await openCompute(
    { workloads: [], creation: null, accepted: null },
    {
      "compute.create": () => {
        throw Object.assign(new Error("node offline"), {
          code: "node_offline",
          status: 409,
        });
      },
    }
  );
  await t.user.click(await content().findByRole("button", { name: "New Shell" }));
  await t.user.click(screen.getByRole("button", { name: "Confirm creation" }));
  expect(
    await content().findByText(
      "This Mac is not connected. Connect it, then create the Shell."
    )
  ).toBeVisible();
});
