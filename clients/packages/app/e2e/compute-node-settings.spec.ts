import { expect, test, type Page, type Route } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";

test("keeps the current creation across late responses and tracks recovered resources outside the page", async ({
  page,
  context,
}) => {
  const base = "http://127.0.0.1:65534";
  const requests: string[] = [];
  const results = new Map<
    string,
    {
      id: string;
      environment_id: string;
      kind: string;
      desired_state: string;
      observed_state: string;
      phase?: string;
    }
  >();
  let releaseFirst!: () => void;
  const firstResponse = new Promise<void>((resolve) => {
    releaseFirst = resolve;
  });
  await context.route(`${base}/v1/comma/workspaces**`, async (route) => {
    const request = route.request();
    const path = new URL(request.url()).pathname;
    const headers = {
      "access-control-allow-origin":
        request.headers().origin ?? "http://127.0.0.1:4173",
      "access-control-allow-credentials": "true",
      "access-control-allow-headers": "content-type,x-comma-session-transport",
      "access-control-allow-methods": "GET,POST,OPTIONS",
      "content-type": "application/json",
    };
    const respond = (value: unknown, status = 200) =>
      route.fulfill({ headers, status, body: JSON.stringify(value) });
    if (request.method() === "OPTIONS") return route.fulfill({ headers, status: 204 });
    if (path.endsWith("/compute/workloads") && request.method() === "POST") {
      const input = request.postDataJSON() as {
        request_id: string;
        environment_id: string;
      };
      requests.push(input.request_id);
      if (requests.length === 2) return route.abort("failed");
      const workload = {
        id: `workload_focus_${requests.length}`,
        environment_id: input.environment_id,
        kind: "shell",
        desired_state: "ready",
        observed_state: "pending",
        phase: "waiting_connection",
      };
      results.set(input.request_id, workload);
      if (requests.length === 1) await firstResponse;
      return respond({ workload });
    }
    if (path.includes("/compute/requests/")) {
      const workload = results.get(path.split("/").at(-1)!);
      return workload ? respond({ workload }) : respond({ error: "not_found" }, 404);
    }
    if (path.includes("/compute/workloads/")) {
      const workload = [...results.values()].find(
        (value) => value.id === path.split("/").at(-1)
      );
      return workload ? respond({ workload }) : respond({ error: "not_found" }, 404);
    }
    if (path === "/v1/comma/workspaces")
      return respond({
        data: [
          { id: "wsp_compute", group_id: "grp_compute", name: "Compute workspace" },
          { id: "wsp_other", group_id: "grp_other", name: "Other workspace" },
        ],
      });
    if (path.endsWith("/compute"))
      return respond({
        workspace_name: "Compute workspace",
        environments: [
          {
            id: "env_compute",
            desired_state: "ready",
            observed_state: "ready",
            can_create: true,
          },
        ],
        // The focused resource is outside this page.
        workloads: [],
        next_workload_cursor: null,
      });
    return respond({ data: [] });
  });
  const open = async (target: Page) => {
    await installBrowserTestSession(target, {
      apiBaseUrl: base,
      email: "compute@example.com",
      token: "comma_sess_compute",
      userId: "usr_compute",
    });
    await target.addInitScript(() =>
      localStorage.setItem("comma.activeWorkspaceId", "wsp_compute")
    );
    await target.goto("/#/settings");
    await target.getByRole("button", { name: "Devices", exact: true }).click();
  };
  await open(page);
  await createShell(page);
  await expect.poll(() => requests.length).toBe(1);
  const other = await context.newPage();
  await open(other);
  await other.bringToFront();
  await expect(
    other.getByRole("status").filter({ hasText: /Waiting for node connection/ })
  ).toBeVisible();
  results.get(requests[0]!)!.observed_state = "ready";
  results.get(requests[0]!)!.phase = "ready";
  await expect(
    other.getByRole("status").filter({ hasText: /Ready to use/ })
  ).toBeVisible();
  await createShell(other, true);
  await expect(
    other.getByText("Creation result is not yet confirmed", { exact: true })
  ).toBeVisible();
  // Another window selects a workspace: the tabs share one core, so every page follows.
  const switchWorkspace = async (id: string) => {
    const chooser = await context.newPage();
    await installBrowserTestSession(chooser, {
      apiBaseUrl: base,
      email: "compute@example.com",
      token: "comma_sess_compute",
      userId: "usr_compute",
    });
    await chooser.addInitScript(
      (workspaceId) => localStorage.setItem("comma.activeWorkspaceId", workspaceId),
      id
    );
    // It stays open: its window hands the selection to the core as it loads.
    await chooser.goto("/#/settings");
  };
  await switchWorkspace("wsp_other");
  await expect(page.getByText("No workloads yet", { exact: true })).toBeVisible();
  const response = page.waitForResponse((value) =>
    value.url().endsWith("/compute/workloads")
  );
  releaseFirst();
  await response;
  // The pending request is core-owned. Its retry below must keep this id,
  // even after the old response arrives and this page changes workspace.
  await expect(
    page.getByRole("status").filter({ hasText: /Ready to use/ })
  ).toHaveCount(0);
  await switchWorkspace("wsp_compute");
  await page.getByRole("button", { name: "Refresh workloads", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "Retry this creation", exact: true })
  ).toBeEnabled();
  await page.getByRole("button", { name: "Retry this creation", exact: true }).click();
  await expect.poll(() => requests.length).toBe(3);
  expect(requests[2]).toBe(requests[1]);
  expect(results.size).toBe(2);
});

const createShell = async (target: Page, another = false) => {
  await target
    .getByRole("button", {
      name: another ? "New Shell" : "New Shell",
      exact: true,
    })
    .click();
  await target
    .getByRole("textbox", { name: "Name", exact: true })
    .fill(another ? "Additional Shell" : "First Shell");
  await target.getByRole("button", { name: "Confirm creation", exact: true }).click();
};

test("opens a workload's business owner and keeps deletion with that owner", async ({
  page,
}) => {
  const base = "http://127.0.0.1:65534";
  await installBrowserTestSession(page, {
    apiBaseUrl: base,
    email: "compute@example.com",
    token: "comma_sess_compute",
    userId: "usr_compute",
  });
  await page.addInitScript(() =>
    localStorage.setItem("comma.activeWorkspaceId", "wsp_compute")
  );
  const workload = {
    id: "meeting_workload",
    name: "Weekly sync bot",
    environment_id: "env_compute",
    kind: "meeting_runtime",
    observed_state: "ready",
    phase: "ready",
    revision: 1,
    generation: 1,
    location: { provider: "agent_vmm", registration_id: "registration" },
    actions: { rename: true, delete: false },
    uses: [{ kind: "meeting", id: "mtg_weekly", label: "Weekly sync" }],
  };
  const handle = async (route: Route) => {
    const request = route.request(),
      path = new URL(request.url()).pathname;
    const respond = (value: unknown, status = 200) =>
      route.fulfill({
        status,
        headers: {
          "access-control-allow-origin":
            request.headers().origin ?? "http://127.0.0.1:4173",
          "access-control-allow-credentials": "true",
          "access-control-allow-headers": "content-type,x-comma-session-transport",
          "access-control-allow-methods": "GET,OPTIONS",
          "content-type": "application/json",
        },
        body: JSON.stringify(value),
      });
    if (request.method() === "OPTIONS") return respond({}, 204);
    if (path === "/v1/comma/workspaces")
      return respond({
        data: [
          { id: "wsp_compute", group_id: "grp_compute", name: "Compute workspace" },
          { id: "wsp_other", group_id: "grp_other", name: "Other workspace" },
        ],
      });
    if (path.endsWith("/compute"))
      return respond({
        environments: [],
        workloads: [workload],
        next_workload_cursor: null,
      });
    if (path.endsWith("/compute/workloads/meeting_workload"))
      return respond({ workload });
    return respond({ data: [] });
  };
  await page.route(`${base}/v1/comma/workspaces**`, handle);
  await page.goto("/#/settings");
  await page.getByRole("button", { name: "Devices", exact: true }).click();
  await page.getByRole("button", { name: /Node actions$/ }).click();
  await expect(
    page.getByRole("menuitem", { name: "Delete Shell", exact: true })
  ).toHaveCount(0);
  await page.keyboard.press("Escape");
  await page.getByRole("button", { name: "Weekly sync bot", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "Delete Shell", exact: true })
  ).toHaveCount(0);
  await page.getByRole("button", { name: "Weekly sync", exact: true }).click();
  await expect(
    page.getByRole("heading", { level: 1, name: "Weekly sync", exact: true })
  ).toBeVisible();
});
