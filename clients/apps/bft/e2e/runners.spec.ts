import { expect, test, type Page } from "@playwright/test";
import {
  context,
  csrf,
  injectCsrfToken,
  ok,
  routeApi,
  type RecordedRequest,
} from "./support";

const minutesAgo = (minutes: number) =>
  new Date(Date.now() - minutes * 60_000).toISOString();

const runner = (id: string, name: string, extra = {}) => ({
  id,
  stable_id: id,
  name,
  status: "online",
  effective_status: "online",
  host_identity: `${id}.local`,
  os_summary: "macOS arm64",
  version: "0.9.4",
  component_versions: { "salix-connect": "2026.09.20" },
  update_available: false,
  capacity: 4,
  current_connector_count: 1,
  last_seen_at: minutesAgo(1),
  last_seen_age_seconds: 60,
  connectors: { total: 2, by_status: [{ status: "connected", count: 2 }] },
  credential: { active: true, key_id: `key-${id}`, created_at: minutesAgo(600) },
  ...extra,
});

const fleet = [
  runner("office-1", "office-1"),
  runner("office-2", "office-2", {
    status: "offline",
    effective_status: "offline",
    version: "0.8.1",
    update_available: true,
    last_seen_at: minutesAgo(190),
  }),
];

const runnersPage = (
  runners: unknown[],
  extra: Partial<{ can_manage: boolean; next_cursor: string | null; poll: number }> = {}
) => ({
  viewer: { can_manage: extra.can_manage ?? true },
  runners,
  total_count: runners.length,
  cursor: null,
  next_cursor: extra.next_cursor ?? null,
  poll_interval_ms: extra.poll ?? 60_000,
});

const onboarding = {
  org_id: "org-1",
  api_base_url: "https://api.example",
  install_code_ttl_seconds: 900,
  local_steps: [
    {
      id: "doctor",
      group: "primary",
      title: "Check local posture",
      description: "Run a no-secret preflight.",
      command: "bft-runner doctor",
    },
    {
      id: "status-logs",
      group: "advanced",
      title: "Inspect status and logs",
      description: "Read the local worker state.",
      command: "bft-runner logs",
    },
  ],
  paths: {
    config: "~/.bridge-for-teams/runner.json",
    install_status: "~/.bridge-for-teams/runner-install-status.json",
    worker_status: "~/.bridge-for-teams/state/runner-status.json",
    logs: "~/.bridge-for-teams/state/logs",
  },
  agent_handoff: "Help me connect a BFT runner.",
  agent_skill: "name: bft-operator",
};

const command = (code: string) => ({
  command: `curl -fsSL https://api.example/install.sh | BFT_INSTALL_CODE=${code} sh`,
  expires_at: new Date(Date.now() + 15 * 60_000).toISOString(),
  runner_stable_id: null,
});

const connectorEntry = (index: number) => ({
  id: `c-${index}`,
  name: `connector-${index}`,
  provisioning_status: index === 1 ? "failed" : "connected",
  project_id: "p-1",
  project_name: index === 2 ? null : "Support Desk",
});
async function openRunners(
  page: Page,
  handle: (
    request: RecordedRequest
  ) => { status: number; body: unknown } | undefined = () => undefined,
  first = runnersPage(fleet)
) {
  await injectCsrfToken(page);
  const requests = await routeApi(page, (request) => {
    if (request.path === "/orgs/acme/context") return ok(context);
    return (
      handle(request) ??
      (request.path === "/orgs/acme/runners" && request.method === "GET"
        ? ok(first)
        : undefined)
    );
  });
  await page.goto("/orgs/acme/fin");
  await expect(page.getByRole("heading", { level: 1, name: "Runners" })).toBeVisible();
  return requests;
}

const writes = (requests: RecordedRequest[]) =>
  requests.filter((request) => request.method !== "GET");

test("lists the fleet and pages a runner's connectors as the list scrolls", async ({
  page,
}) => {
  const big = runner("office-1", "office-1", {
    connectors: { total: 51, by_status: [{ status: "connected", count: 51 }] },
  });
  const requests = await openRunners(
    page,
    (request) =>
      request.path === "/orgs/acme/runners/office-1/connectors"
        ? ok(
            request.search.includes("cursor=page-2")
              ? { entries: [connectorEntry(51)], cursor: "page-2", next_cursor: null }
              : {
                  entries: Array.from({ length: 50 }, (_, index) =>
                    connectorEntry(index + 1)
                  ),
                  cursor: null,
                  next_cursor: "page-2",
                }
          )
        : undefined,
    runnersPage([big, fleet[1]])
  );

  const metrics = page.locator(".bft-metrics");
  await expect(metrics).toContainText("Runners2");
  await expect(metrics).toContainText("Online1");
  await expect(metrics).toContainText("Update available1");
  const fleetPanel = page.getByRole("region", { name: "Fleet" });
  await expect(fleetPanel.getByRole("row", { name: /office-2/ })).toContainText(
    "Offline"
  );
  await expect(fleetPanel.getByRole("row", { name: /office-2/ })).toContainText(
    "Update available"
  );

  await page.getByRole("button", { name: "Show details of office-1" }).click();
  const connectors = page.getByRole("region", { name: "Connectors" });
  await expect(connectors.getByRole("listitem")).toHaveCount(50);
  await expect(connectors.getByText("No Agent Swarm")).toBeVisible();
  expect(requests.filter((request) => request.search.includes("page-2"))).toEqual([]);

  await connectors.getByText("connector-1", { exact: true }).hover();
  for (let step = 0; step < 10; step += 1) {
    if (requests.some((request) => request.search.includes("page-2"))) break;
    await page.mouse.wheel(0, 400);
    await page.waitForTimeout(100);
  }
  await expect(connectors.getByRole("listitem")).toHaveCount(51);
});

test("rotating a key is confirmed first and shows the new command once", async ({
  page,
}) => {
  const requests = await openRunners(page, (request) =>
    request.method === "POST" &&
    request.path === "/orgs/acme/runners/keys/key-office-1/rotate"
      ? { status: 201, body: { ok: true, data: command("bfti_rotated") } }
      : undefined
  );

  await page.getByRole("button", { name: "Actions for office-1" }).click();
  await page.getByRole("menuitem", { name: "Rotate key" }).click();
  const confirm = page.getByRole("dialog", { name: "Rotate key" });
  await expect(confirm).toContainText("The current key of office-1 stops working now.");
  expect(writes(requests)).toEqual([]);

  await confirm.getByRole("button", { name: /Rotate key/ }).click();
  const issued = page.getByRole("dialog", { name: "New install command" });
  await expect(issued).toContainText("BFT_INSTALL_CODE=bfti_rotated");
  await expect(issued).toContainText("Shown only once.");
  expect(writes(requests)).toEqual([
    {
      method: "POST",
      path: "/orgs/acme/runners/keys/key-office-1/rotate",
      search: "",
      csrf,
      body: undefined,
    },
  ]);

  await issued.getByRole("button", { name: /Done/ }).click();
  await expect(issued).toBeHidden();
  await expect(page.getByText("bfti_rotated")).toHaveCount(0);
});

test("revoking a key and removing a runner are confirmed first", async ({ page }) => {
  let runners = fleet;
  const requests = await openRunners(page, (request) => {
    if (
      request.method === "DELETE" &&
      request.path === "/orgs/acme/runners/keys/key-office-2"
    ) {
      return ok({ id: "key-office-2", revoked_at: new Date().toISOString() });
    }
    if (request.method === "DELETE" && request.path === "/orgs/acme/runners/office-2") {
      runners = fleet.slice(0, 1);
      return ok({ id: "office-2" });
    }
    if (request.path === "/orgs/acme/runners") return ok(runnersPage(runners));
    return undefined;
  });

  await page.getByRole("button", { name: "Actions for office-2" }).click();
  await page.getByRole("menuitem", { name: "Revoke key" }).click();
  const revoke = page.getByRole("dialog", { name: "Revoke key" });
  await expect(revoke).toContainText("office-2 loses API access");
  await revoke.getByRole("button", { name: /Cancel/ }).click();
  expect(writes(requests)).toEqual([]);

  await page.getByRole("button", { name: "Actions for office-2" }).click();
  await page.getByRole("menuitem", { name: "Revoke key" }).click();
  await page
    .getByRole("dialog")
    .getByRole("button", { name: /Revoke key/ })
    .click();
  await expect(page.getByRole("dialog")).toBeHidden();

  await page.getByRole("button", { name: "Actions for office-2" }).click();
  await page.getByRole("menuitem", { name: "Remove runner" }).click();
  const remove = page.getByRole("dialog", { name: "Remove runner" });
  await expect(remove).toContainText("office-2 will be removed from this organization");
  await remove.getByRole("button", { name: /Remove runner/ }).click();
  await expect(remove).toBeHidden();
  await expect(page.getByRole("button", { name: "Actions for office-2" })).toHaveCount(
    0
  );

  expect(
    writes(requests).map((request) => [request.method, request.path, request.csrf])
  ).toEqual([
    ["DELETE", "/orgs/acme/runners/keys/key-office-2", csrf],
    ["DELETE", "/orgs/acme/runners/office-2", csrf],
  ]);
});

test("Add runner generates a one-time install command and lists the local steps", async ({
  page,
}) => {
  let release = false;
  const requests = await openRunners(page, (request) => {
    if (request.path === "/orgs/acme/runners/onboarding") return ok(onboarding);
    if (request.path === "/orgs/acme/runners/install-commands") {
      return release
        ? { status: 201, body: { ok: true, data: command("bfti_first") } }
        : {
            status: 503,
            body: {
              ok: false,
              error: {
                code: "server_release_unavailable",
                message: "Server release is unavailable.",
                details: {},
              },
            },
          };
    }
    return undefined;
  });

  await page.getByRole("button", { name: "Add runner" }).click();
  const dialog = page.getByRole("dialog", { name: "Add runner" });
  await expect(dialog.getByText("bft-runner doctor")).toBeVisible();
  // Advanced steps start collapsed.
  await expect(dialog.getByText("bft-runner logs")).toBeHidden();
  await expect(dialog.getByRole("button", { name: "Copy Agent skill" })).toBeVisible();
  expect(writes(requests)).toEqual([]);

  await dialog.getByRole("button", { name: "Generate command" }).click();
  await expect(dialog.getByRole("alert")).toContainText(
    "This server has no runner release yet"
  );

  release = true;
  await dialog.getByRole("button", { name: "Generate command" }).click();
  await expect(dialog).toContainText("BFT_INSTALL_CODE=bfti_first");
  await expect(dialog).toContainText("Shown only once.");
  expect(writes(requests).map((request) => request.csrf)).toEqual([csrf, csrf]);

  await dialog.getByText("Advanced diagnostics").click();
  await expect(dialog.getByText("bft-runner logs")).toBeVisible();

  await dialog.getByRole("button", { name: /Done/ }).click();
  await page.getByRole("button", { name: "Add runner" }).click();
  await expect(page.getByRole("dialog", { name: "Add runner" })).toBeVisible();
  await expect(page.getByText("bfti_first")).toHaveCount(0);
});

test("polling refreshes the list without closing an open dialog", async ({ page }) => {
  let polls = 0;
  await openRunners(page, (request) => {
    if (request.path !== "/orgs/acme/runners") return undefined;
    polls += 1;
    const status = polls > 2 ? "offline" : "online";
    return ok(
      runnersPage(
        [runner("office-1", "office-1", { effective_status: status }), fleet[1]],
        { poll: 300 }
      )
    );
  });

  await page.getByRole("button", { name: "Actions for office-1" }).click();
  await page.getByRole("menuitem", { name: "Remove runner" }).click();
  const dialog = page.getByRole("dialog", { name: "Remove runner" });
  await expect(dialog).toBeVisible();

  await expect.poll(() => polls).toBeGreaterThan(3);
  await expect(dialog).toBeVisible();
  await dialog.getByRole("button", { name: /Cancel/ }).click();
  await expect(
    page.getByRole("region", { name: "Fleet" }).getByRole("row", { name: /office-1/ })
  ).toContainText("Offline");
});

test("a member sees the fleet without write actions", async ({ page }) => {
  await openRunners(
    page,
    undefined,
    runnersPage(
      fleet.map((entry) => ({ ...entry, credential: null })),
      { can_manage: false }
    )
  );

  await expect(
    page.getByRole("button", { name: "Show details of office-1" })
  ).toBeVisible();
  await expect(page.getByRole("button", { name: "Add runner" })).toHaveCount(0);
  await expect(page.getByRole("button", { name: /^Actions for / })).toHaveCount(0);
  await expect(page.getByRole("link", { name: /Runners/ })).toHaveAttribute(
    "aria-current",
    "page"
  );
});
