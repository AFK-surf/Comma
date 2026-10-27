import { expect, test, type Page } from "@playwright/test";
import {
  context,
  csrf,
  injectCsrfToken,
  ok,
  routeApi,
  type RecordedRequest,
} from "./support";

const base = "/orgs/acme/projects/p-1/devices";
const api = "/orgs/acme/projects/p-1/devices";
const project = { id: "p-1", name: "Support Desk", role: "admin" };

const device = (id: string, name: string, extra: Record<string, unknown> = {}) => ({
  id,
  name,
  status: "connected",
  disconnectable: true,
  runtimes: [],
  host: null,
  os: null,
  cpu_model: null,
  cpu_count: null,
  memory_bytes: null,
  last_seen_at: new Date(Date.now() - 120_000).toISOString(),
  info_updated_at: null,
  android: null,
  ...extra,
});

const cloudVm = (overrides: Record<string, unknown> = {}) => ({
  enabled: true,
  manageable: true,
  vm: { status: "ready", location: { kind: "runner", name: "Lab Mac mini" } },
  runner: { name: "Lab Mac mini", status: "ready" },
  next_location: { kind: "runner", name: "Lab Mac mini" },
  runner_choosable: false,
  runner_removable: false,
  ...overrides,
});

type Data = ReturnType<typeof page1>;

const page1 = (overrides: Record<string, unknown> = {}) => ({
  project,
  cloud_vm: cloudVm(),
  devices: [
    device("dev-mac", "Mac Studio", {
      runtimes: [{ id: "rt-codex", provider: "codex", version: "codex-cli 1.4.2" }],
      host: "studio.local",
      os: "macOS 15.4",
      cpu_model: "Apple M2",
      cpu_count: 8,
      memory_bytes: 17_179_869_184,
    }),
    device("dev-box", "Build box", { status: "disconnected", disconnectable: false }),
  ],
  provisioning: false,
  android: {
    status: "ok",
    entitled: false,
    profiles: [],
    setup: "not_connected",
    registered: false,
  },
  compute: {
    status: "ok",
    environments: [
      { id: "env-1", desired_state: "ready", observed_state: "ready", revision: 3 },
    ],
    workloads: [{ id: "wl-shell", kind: "shell", observed_state: "pending" }],
  },
  ...overrides,
});

const failure = (status: number, code: string, message: string) => ({
  status,
  body: { ok: false, error: { code, message, details: {} } },
});

type Handler = (
  request: RecordedRequest
) => { status: number; body: unknown } | undefined;

/** The page's data; `extra` answers anything else first. */
async function open(
  page: Page,
  handle: Handler = () => undefined,
  data: () => Data = () => page1(),
  path = base
) {
  await injectCsrfToken(page);
  const requests = await routeApi(page, (request) => {
    if (request.path === "/orgs/acme/context") return ok(context);
    const answer = handle(request);
    if (answer) return answer;
    if (request.method === "GET" && request.path === api) return ok(data());
    return undefined;
  });
  await page.goto(path);
  await expect(page.getByRole("heading", { level: 1, name: "Devices" })).toBeVisible();
  return requests;
}

const main = (page: Page) => page.getByRole("main");
const cloudVmSection = (page: Page) =>
  main(page).getByRole("region", { name: "Cloud VM" });
const writes = (requests: RecordedRequest[]) =>
  requests.filter((request) => request.method !== "GET");
const pageReads = (requests: RecordedRequest[]) =>
  requests.filter((request) => request.method === "GET" && request.path === api);
const polls = (requests: RecordedRequest[]) =>
  requests.filter((request) => request.path === `${api}/provisioning`);

test("lists the Cloud VM, the devices, Compute and Android setup", async ({ page }) => {
  await open(page);

  const m = main(page);
  await expect(
    m.getByText("Computers and runtimes the agents of Support Desk can use.")
  ).toBeVisible();
  const vm = cloudVmSection(page);
  await expect(vm.getByText("Ready")).toHaveCount(2);
  await expect(vm.getByText("Runner Lab Mac mini")).toBeVisible();
  await expect(
    vm.getByRole("switch", { name: "Use the Cloud VM in this Agent Swarm" })
  ).toBeChecked();
  // This existing VM uses the runner, so removal is unavailable.
  await expect(vm.getByRole("button")).toHaveCount(0);

  const mac = m.getByRole("row", { name: /Mac Studio/ });
  await expect(mac.getByText("Connected")).toBeVisible();
  await expect(mac.getByText("codex-cli 1.4.2")).toBeVisible();
  await expect(mac.getByText("studio.local")).toBeVisible();
  await expect(mac.getByText("macOS 15.4")).toBeVisible();
  await expect(mac.getByText("8 cores · 16.0 GiB")).toBeVisible();
  await expect(mac.getByText("2 minutes ago")).toBeVisible();
  await expect(
    m.getByRole("row", { name: /Build box/ }).getByText("Disconnected")
  ).toBeVisible();

  await expect(m.getByRole("row", { name: /env-1/ }).getByText("Ready")).toHaveCount(2);
  await expect(
    m.getByRole("row", { name: /wl-shell/ }).getByText("Pending")
  ).toBeVisible();
  await expect(
    m.getByText(
      "Android setup is unavailable because this organization has no Android connector entitlement. Contact your platform administrator."
    )
  ).toBeVisible();
  await expect(
    page
      .getByRole("navigation", { name: "Organization navigation" })
      .getByRole("link", { name: "Devices", exact: true })
  ).toHaveAttribute("aria-current", "page");
});

test("a device that cannot take tasks says how to upgrade it", async ({ page }) => {
  const needsStation =
    "This device runs the old connector, which cannot take tasks. Install the Comma desktop app on it (it includes the station), or install the station with the command from Add station in Comma.";
  const outdated =
    "This device's station is too old to take tasks. Update the Comma desktop app, or on a standalone station run `stillfail update` or use its Updates page.";
  await open(page, undefined, () =>
    page1({
      devices: [
        device("dev-mac", "Mac Studio"),
        device("dev-old", "Old connector box", {
          station_notice: {
            reason: "device_needs_station",
            tasks: null,
            required_tasks: 2,
            message: needsStation,
          },
        }),
        device("dev-outdated", "Outdated station", {
          station_notice: {
            reason: "station_outdated",
            tasks: 1,
            required_tasks: 2,
            message: outdated,
          },
        }),
      ],
    })
  );

  const notes = main(page).getByRole("note");
  await expect(notes).toHaveCount(2);
  await expect(notes.nth(0)).toContainText("Cannot take tasks: install the station");
  await expect(notes.nth(0)).toContainText(needsStation);
  await expect(notes.nth(1)).toContainText("Cannot take tasks: update the station");
  await expect(notes.nth(1)).toContainText(outdated);
});

test("an entitled swarm shows its Android connector, profiles and slots", async ({
  page,
}) => {
  await open(page, undefined, () =>
    page1({
      devices: [
        device("dev-android", "Android N2", {
          android: {
            profiles: ["api30-phone", "api35-phone-google-apis"],
            default_profile: "api35-phone-google-apis",
            active_profile: "api30-phone",
            target_profile: "api35-phone-google-apis",
            phase: "waiting_ready",
            state: "preparing",
            available_slots: 0,
            capacity: 1,
          },
        }),
      ],
      android: {
        status: "ok",
        entitled: true,
        profiles: ["api30-phone"],
        setup: "connected",
        registered: true,
      },
      compute: { status: "unavailable", environments: [], workloads: [] },
    })
  );

  const m = main(page);
  await expect(
    m.getByText("Allowed profiles: api30-phone · One concurrent lease")
  ).toBeVisible();
  await expect(
    m.getByText("The Android connector is registered to this Agent Swarm.")
  ).toBeVisible();
  for (const line of [
    "Configured profiles: api30-phone, api35-phone-google-apis",
    "Default: api35-phone-google-apis",
    "Current: api30-phone",
    "Target: api35-phone-google-apis",
    "Phase: Waiting for Android",
    "Android: Preparing",
    "0 of 1 slots available",
  ]) {
    await expect(m.getByText(line, { exact: true })).toBeVisible();
  }
  await expect(
    m.getByText("Could not load Compute readiness. Retry shortly.")
  ).toBeVisible();
});

test("turns the Cloud VM off and reads the page again", async ({ page }) => {
  let enabled = true;
  const requests = await open(
    page,
    (request) => {
      if (request.method === "PUT" && request.path === `${api}/cloud`) {
        enabled = false;
        return ok({
          enabled: false,
          notice: "Cloud computer disabled for this Agent Swarm.",
        });
      }
      return undefined;
    },
    () =>
      page1({
        cloud_vm: cloudVm({ enabled, ...(enabled ? {} : { vm: null, runner: null }) }),
      })
  );

  const cloud = cloudVmSection(page);
  // The switch input is visually hidden inside its label; click the label like a user.
  await cloud
    .locator("label")
    .filter({ has: page.getByRole("switch") })
    .click();
  await expect(
    page.getByText("Cloud computer disabled for this Agent Swarm.")
  ).toBeVisible();
  await expect(cloud.getByText("Turned off")).toBeVisible();
  await expect(cloud.getByRole("switch")).not.toBeChecked();
  expect(writes(requests)).toEqual([
    expect.objectContaining({ method: "PUT", csrf, body: { enabled: false } }),
  ]);
});

test("adds a device on a runner, then polls only until it is provisioned", async ({
  page,
}) => {
  await page.clock.install();
  let provisioning = false;
  let answers = [true, false];
  const requests = await open(
    page,
    (request) => {
      if (request.path === `${api}/runners`)
        return ok({
          runners: [
            { id: "run-1", label: "Lab Mac mini" },
            { id: "run-2", label: "Spare Mac mini" },
          ],
          runners_href: "/orgs/acme/fin",
        });
      if (request.method === "POST" && request.path === api) {
        provisioning = true;
        return {
          status: 201,
          body: { ok: true, data: { notice: "Device connection request created." } },
        };
      }
      if (request.path === `${api}/provisioning`) {
        const active = answers.shift() ?? false;
        provisioning = active;
        return ok({ active });
      }
      return undefined;
    },
    () => page1({ provisioning })
  );

  await page.getByRole("button", { name: "Add device" }).click();
  const dialog = page.getByRole("dialog", { name: "Add device" });
  await dialog.getByLabel("Name").fill("staging-box");
  await dialog.getByLabel("Alias").fill("prod-mac");
  await dialog.getByRole("button", { name: /Runner/ }).click();
  await page.getByRole("option", { name: "Spare Mac mini" }).click();
  await dialog.getByRole("button", { name: "Create on runner" }).click();

  await expect(page.getByText("Device connection request created.")).toBeVisible();
  await expect(dialog).toHaveCount(0);
  expect(writes(requests)).toEqual([
    expect.objectContaining({
      method: "POST",
      path: api,
      csrf,
      body: { name: "staging-box", alias: "prod-mac", runner_id: "run-2" },
    }),
  ]);
  const status = main(page).getByText(
    "A device is being connected. The list updates when it is ready."
  );
  await expect(status).toBeVisible();
  const readsBefore = pageReads(requests).length;

  // Still provisioning: the page is not read again.
  await page.clock.runFor(2_100);
  await expect.poll(() => polls(requests).length).toBe(1);
  expect(pageReads(requests)).toHaveLength(readsBefore);
  // Done: the page is read once more and the poll stops.
  await page.clock.runFor(2_100);
  await expect.poll(() => polls(requests).length).toBe(2);
  await expect(status).toHaveCount(0);
  expect(pageReads(requests)).toHaveLength(readsBefore + 1);
  await page.clock.runFor(10_000);
  expect(polls(requests)).toHaveLength(2);
});

test("the provisioning poll waits for each reply, pauses while hidden and stops on leaving", async ({
  page,
}) => {
  await page.clock.install();
  const requests = await open(
    page,
    (request) =>
      request.path === `${api}/provisioning` ? ok({ active: true }) : undefined,
    () => page1({ provisioning: true })
  );
  // Every poll is counted when it leaves; the first reply is held until released.
  const sent: number[] = [];
  let release: (() => void) | undefined;
  const held = new Promise<void>((resolve) => (release = resolve));
  await page.route(`**/dashboard/api/v1${api}/provisioning`, async (route) => {
    sent.push(sent.length + 1);
    if (sent.length === 1) await held;
    await route.fallback();
  });

  await page.clock.runFor(2_100);
  await expect.poll(() => sent.length).toBe(1);
  await page.clock.runFor(10_000);
  expect(sent).toHaveLength(1);
  release?.();
  await expect.poll(() => polls(requests).length).toBe(1);
  await page.clock.runFor(2_100);
  await expect.poll(() => sent.length).toBe(2);

  const setHidden = (hidden: boolean) =>
    page.evaluate((value) => {
      Object.defineProperty(document, "hidden", {
        configurable: true,
        get: () => value,
      });
      document.dispatchEvent(new Event("visibilitychange"));
    }, hidden);
  await setHidden(true);
  await page.clock.runFor(10_000);
  expect(sent).toHaveLength(2);
  // Visible again: it checks at once.
  await setHidden(false);
  await expect.poll(() => sent.length).toBe(3);

  await page.evaluate(() => {
    window.history.pushState(null, "", "/orgs/acme/members");
    window.dispatchEvent(new Event("bft:locationchange"));
  });
  await page.clock.runFor(10_000);
  expect(sent).toHaveLength(3);
});

test("without an online runner the dialog links Runners and checks again", async ({
  page,
}) => {
  const requests = await open(page, (request) =>
    request.path === `${api}/runners`
      ? ok({ runners: [], runners_href: "/orgs/acme/fin" })
      : undefined
  );

  await page.getByRole("button", { name: "Add device" }).click();
  const dialog = page.getByRole("dialog", { name: "No runners connected" });
  await expect(
    dialog.getByText("Connect a runner in Runners before creating a project device.")
  ).toBeVisible();
  await expect(dialog.getByRole("link", { name: "Open Runners" })).toHaveAttribute(
    "href",
    "/orgs/acme/fin"
  );
  const reads = () =>
    requests.filter((request) => request.path === `${api}/runners`).length;
  const before = reads();
  await dialog.getByRole("button", { name: "Check for runners" }).click();
  await expect.poll(reads).toBe(before + 1);
  expect(writes(requests)).toEqual([]);
});

test("disconnects and deletes a device after confirming", async ({ page }) => {
  const requests = await open(page, (request) => {
    if (request.method === "POST" && request.path === `${api}/dev-mac/disconnect`)
      return ok({ notice: "Device disconnected." });
    if (request.method === "DELETE" && request.path === `${api}/dev-box`)
      return ok({ notice: "Device deleted." });
    return undefined;
  });

  // A disconnected device can only be deleted.
  await page.getByRole("button", { name: "Actions for Build box" }).click();
  await expect(page.getByRole("menuitem", { name: "Disconnect" })).toHaveCount(0);
  await page.keyboard.press("Escape");

  await page.getByRole("button", { name: "Actions for Mac Studio" }).click();
  await page.getByRole("menuitem", { name: "Disconnect" }).click();
  const disconnect = page.getByRole("dialog", { name: "Disconnect device" });
  await expect(disconnect.getByText(/Disconnect Mac Studio\?/)).toBeVisible();
  await disconnect.getByRole("button", { name: "Disconnect" }).click();
  await expect(page.getByText("Device disconnected.")).toBeVisible();

  await page.getByRole("button", { name: "Actions for Build box" }).click();
  await page.getByRole("menuitem", { name: "Delete" }).click();
  const remove = page.getByRole("dialog", { name: "Delete device" });
  await expect(
    remove.getByText(
      "Delete Build box? It will be disconnected and removed from this Agent Swarm. Agents using it will become unavailable."
    )
  ).toBeVisible();
  await remove.getByRole("button", { name: "Delete" }).click();
  await expect(page.getByText("Device deleted.")).toBeVisible();

  expect(
    writes(requests).map(({ method, path, csrf: token }) => [method, path, token])
  ).toEqual([
    ["POST", `${api}/dev-mac/disconnect`, csrf],
    ["DELETE", `${api}/dev-box`, csrf],
  ]);
});

test("Compute: a Shell workload after confirming; drain and revoke carry the revision", async ({
  page,
}) => {
  const requests = await open(page, (request) => {
    if (request.path === "/orgs/acme/projects/p-1/compute/env-1/shell")
      return {
        status: 201,
        body: {
          ok: true,
          data: {
            notice: "Shell workload accepted. Refresh to check its runtime status.",
          },
        },
      };
    if (request.path === "/orgs/acme/projects/p-1/compute/env-1/drain")
      return ok({ notice: "Compute environment updated." });
    if (request.path === "/orgs/acme/projects/p-1/compute/env-1/revoke")
      return failure(
        409,
        "environment_changed",
        "This Compute environment changed. Refresh and try again."
      );
    return undefined;
  });

  await page.getByRole("button", { name: "Actions for env-1" }).click();
  await page.getByRole("menuitem", { name: "Create Shell workload" }).click();
  const shell = page.getByRole("dialog", { name: "Create Shell workload" });
  await expect(
    shell.getByText(
      "Create a Shell workload in this environment? It has a 512 PID limit, a 2 GiB writable disk limit, and no network access."
    )
  ).toBeVisible();
  await shell.getByRole("button", { name: "Create Shell workload" }).click();
  await expect(
    page.getByText("Shell workload accepted. Refresh to check its runtime status.")
  ).toBeVisible();

  await page.getByRole("button", { name: "Actions for env-1" }).click();
  await page.getByRole("menuitem", { name: "Drain" }).click();
  await expect(page.getByText("Compute environment updated.")).toBeVisible();

  await page.getByRole("button", { name: "Actions for env-1" }).click();
  await page.getByRole("menuitem", { name: "Revoke" }).click();
  await expect(
    page.getByText("This Compute environment changed. Refresh and try again.")
  ).toBeVisible();

  expect(writes(requests).map(({ path, body }) => [path, body])).toEqual([
    ["/orgs/acme/projects/p-1/compute/env-1/shell", undefined],
    ["/orgs/acme/projects/p-1/compute/env-1/drain", { expected_revision: 3 }],
    ["/orgs/acme/projects/p-1/compute/env-1/revoke", { expected_revision: 3 }],
  ]);
});

test("a swarm member reads the page without admin controls", async ({ page }) => {
  await open(page, undefined, () =>
    page1({
      project: { ...project, role: "user" },
      cloud_vm: cloudVm({
        manageable: false,
        vm: { status: "archived", location: { kind: "cloudflare" } },
        runner: null,
      }),
    })
  );

  const m = main(page);
  await expect(m.getByRole("row", { name: /Mac Studio/ })).toBeVisible();
  await expect(cloudVmSection(page).getByText("Sleeping")).toBeVisible();
  await expect(
    cloudVmSection(page).getByText("Cloudflare", { exact: true })
  ).toBeVisible();
  await expect(page.getByRole("button", { name: "Add device" })).toHaveCount(0);
  await expect(m.getByRole("switch")).toHaveCount(0);
  await expect(m.getByRole("button", { name: "Choose runner" })).toHaveCount(0);
  await expect(m.getByRole("button", { name: /^Actions for/ })).toHaveCount(0);
});

test("before the Cloud VM exists, an admin chooses its runner once", async ({
  page,
}) => {
  let runner: { name: string; status: string } | null = null;
  const requests = await open(
    page,
    (request) => {
      if (request.path === `${api}/runners`)
        return ok({
          runners: [
            { id: "run-1", label: "Lab Mac mini" },
            { id: "run-2", label: "Spare Mac mini" },
          ],
          runners_href: "/orgs/acme/fin",
        });
      if (request.method === "PUT" && request.path === `${api}/cloud-vm/runner`) {
        // The first answer is lost; the retry repeats the same request.
        if (writes(requests).length === 1) return { status: 503, body: {} };
        runner = { name: "Spare Mac mini", status: "processing" };
        return ok({ notice: "The runner was asked to prepare the VMM Station." });
      }
      return undefined;
    },
    () =>
      page1({
        cloud_vm: cloudVm({
          vm: null,
          runner,
          next_location: { kind: "cloudflare" },
          runner_choosable: runner === null,
          runner_removable: runner !== null,
        }),
      })
  );

  const vm = cloudVmSection(page);
  await expect(vm.getByText("Not created yet")).toBeVisible();
  await expect(vm.getByText("A new Cloud VM runs on")).toBeVisible();
  await expect(vm.getByText("Cloudflare", { exact: true })).toBeVisible();
  await vm.getByRole("button", { name: "Choose runner" }).click();
  const dialog = page.getByRole("dialog", {
    name: "Choose a runner for the VMM Station",
  });
  await dialog.getByRole("button", { name: /Runner/ }).click();
  await page.getByRole("option", { name: "Spare Mac mini" }).click();
  await dialog.getByRole("button", { name: "Use this runner" }).click();
  await expect(dialog.getByRole("alert")).toBeVisible();
  await dialog.getByRole("button", { name: "Use this runner" }).click();

  await expect(
    page.getByText("The runner was asked to prepare the VMM Station.")
  ).toBeVisible();
  await expect(dialog).toHaveCount(0);
  await expect(vm.getByText("Installing")).toBeVisible();
  await expect(vm.getByRole("button", { name: "Choose runner" })).toHaveCount(0);
  const [first, second] = writes(requests);
  expect(first).toEqual(
    expect.objectContaining({
      method: "PUT",
      csrf,
      body: { runner_id: "run-2", request_id: expect.any(String) },
    })
  );
  expect(second?.body).toEqual(first?.body);
});

test("a second runner is refused with the server's reason", async ({ page }) => {
  await open(
    page,
    (request) => {
      if (request.path === `${api}/runners`)
        return ok({
          runners: [{ id: "run-1", label: "Lab Mac mini" }],
          runners_href: "/orgs/acme/fin",
        });
      if (request.method === "PUT" && request.path === `${api}/cloud-vm/runner`)
        return failure(
          409,
          "runner_already_chosen",
          "This Agent Swarm already has a runner. Remove it before you choose another runner."
        );
      return undefined;
    },
    () =>
      page1({
        cloud_vm: cloudVm({
          vm: null,
          runner: null,
          next_location: { kind: "cloudflare" },
          runner_choosable: true,
        }),
      })
  );

  await cloudVmSection(page).getByRole("button", { name: "Choose runner" }).click();
  const dialog = page.getByRole("dialog", {
    name: "Choose a runner for the VMM Station",
  });
  await dialog.getByRole("button", { name: "Use this runner" }).click();
  await expect(
    dialog.getByText(
      "This Agent Swarm already has a runner. Remove it before you choose another runner."
    )
  ).toBeVisible();
});

test("removes a runner that no Cloud VM runs on after confirming", async ({ page }) => {
  const requests = await open(
    page,
    (request) =>
      request.method === "DELETE" && request.path === `${api}/cloud-vm/runner`
        ? ok({ notice: "Runner removed from this Agent Swarm." })
        : undefined,
    () =>
      page1({
        cloud_vm: cloudVm({
          vm: null,
          runner: { name: "Lab Mac mini", status: "action_required" },
          next_location: { kind: "cloudflare" },
          runner_removable: true,
        }),
      })
  );

  const vm = cloudVmSection(page);
  await expect(vm.getByText("Needs attention")).toBeVisible();
  await vm.getByRole("button", { name: "Remove runner" }).click();
  const confirm = page.getByRole("dialog", { name: "Remove runner" });
  await expect(
    confirm.getByText(/Remove Lab Mac mini from this Agent Swarm\?/)
  ).toBeVisible();
  await confirm.getByRole("button", { name: "Remove runner" }).click();
  await expect(page.getByText("Runner removed from this Agent Swarm.")).toBeVisible();
  expect(writes(requests).map(({ method, path }) => [method, path])).toEqual([
    ["DELETE", `${api}/cloud-vm/runner`],
  ]);
});

test("the page fits a 900px window", async ({ page }) => {
  await page.setViewportSize({ width: 900, height: 700 });
  await open(page);
  await expect(main(page).getByRole("row", { name: /Mac Studio/ })).toBeVisible();
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth
    )
  ).toBe(0);
  // The narrower table leaves out CPU and memory.
  await expect(main(page).getByText("CPU / Memory")).toBeHidden();
});
