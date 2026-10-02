import { expect, test, type Page } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";

test("recovers a lost Shell creation response after reload and permits explicit additional Shells", async ({
  page,
}, testInfo) => {
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
  const requests: Array<{ request_id: string; environment_id: string }> = [];
  const workloads: Array<{
    id: string;
    environment_id: string;
    kind: string;
    desired_state: string;
    observed_state: string;
    phase?: string;
  }> = [];
  const results = new Map<string, (typeof workloads)[number]>();
  let loseResponse = true;
  let queryNotFound = true;
  await page.route(`${base}/v1/comma/workspaces**`, async (route) => {
    const request = route.request();
    const url = new URL(request.url());
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
    if (url.pathname === "/v1/comma/workspaces")
      return respond({
        data: [
          { id: "wsp_compute", name: "Compute workspace", group_id: "grp_compute" },
        ],
      });
    if (url.pathname.endsWith("/compute/workloads") && request.method() === "POST") {
      const input = request.postDataJSON() as (typeof requests)[number];
      requests.push(input);
      const existing = results.get(input.request_id);
      const workload = existing ?? {
        id: `workload_shell_${workloads.length + 1}`,
        environment_id: input.environment_id,
        kind: "shell",
        desired_state: "ready",
        observed_state: "pending",
      };
      if (!existing) {
        results.set(input.request_id, workload);
        workloads.push(workload);
      }
      if (loseResponse) {
        loseResponse = false;
        return route.abort("failed");
      }
      return respond({ workload });
    }
    if (url.pathname.includes("/compute/requests/")) {
      if (queryNotFound) return respond({ error: "not_found" }, 404);
      const workload = results.get(url.pathname.split("/").at(-1)!);
      return workload ? respond({ workload }) : respond({ error: "not_found" }, 404);
    }
    if (url.pathname.endsWith("/compute"))
      return respond({
        environments: [
          {
            id: "env_compute",
            desired_state: "ready",
            observed_state: "ready",
            can_create: true,
          },
        ],
        workloads,
        next_workload_cursor: null,
      });
    return respond({ data: [] });
  });
  await page.goto("/#/settings");
  await page.getByRole("button", { name: "Compute node", exact: true }).click();
  await page
    .getByRole("button", { name: "View workspace compute", exact: true })
    .click();
  await page.getByRole("button", { name: "Manage environments", exact: true }).click();
  await page
    .getByRole("button", { name: "Create Shell workload", exact: true })
    .click();
  await page.getByRole("button", { name: "Confirm creation", exact: true }).dblclick();
  await expect(
    page.getByText("Creation result is not yet confirmed", { exact: true })
  ).toBeVisible();
  expect(requests).toHaveLength(1);
  await page.reload();
  await page.getByRole("button", { name: "Compute node", exact: true }).click();
  await page.getByRole("button", { name: "Retry this creation", exact: true }).click();
  await page
    .getByRole("button", { name: "View workspace compute", exact: true })
    .click();
  await expect(page.getByText("Check resource details", { exact: true })).toBeVisible();
  expect(requests).toHaveLength(2);
  expect(requests[0]!.request_id).toBe(requests[1]!.request_id);
  expect(workloads).toHaveLength(1);
  queryNotFound = false;
  workloads[0]!.phase = "waiting_connection";
  await page.getByRole("button", { name: "Refresh workloads", exact: true }).click();
  await expect(
    page.getByText("Waiting for node connection", { exact: true })
  ).toBeVisible();
  workloads[0]!.phase = "starting";
  await page.getByRole("button", { name: "Refresh workloads", exact: true }).click();
  await expect(
    page.getByText("Created, preparing the runtime", { exact: true })
  ).toBeVisible();
  workloads[0]!.phase = "ready";
  workloads[0]!.observed_state = "ready";
  await page.getByRole("button", { name: "Refresh workloads", exact: true }).click();
  await expect(page.getByText("Ready to use", { exact: true })).toBeVisible();
  workloads[0]!.desired_state = "draining";
  await page.getByRole("button", { name: "Refresh workloads", exact: true }).click();
  await expect(
    page.getByText("Being disabled; execution may still be active", { exact: true })
  ).toBeVisible();
  await expect(page.getByText("Ready to use", { exact: true })).toHaveCount(0);
  workloads[0]!.desired_state = "ready";
  await page.getByRole("button", { name: "Refresh workloads", exact: true }).click();
  await expect(page.getByText("Ready to use", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Manage environments", exact: true }).click();
  await page
    .getByRole("button", { name: "Create another Shell…", exact: true })
    .click();
  await page.getByRole("button", { name: "Confirm creation", exact: true }).click();
  await expect.poll(() => workloads.length).toBe(2);
  expect(requests[2]!.request_id).not.toBe(requests[0]!.request_id);
  await page.screenshot({
    path: testInfo.outputPath("compute-workspace.png"),
    animations: "disabled",
  });
});

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
    await target.getByRole("button", { name: "Compute node", exact: true }).click();
    await target
      .getByRole("button", { name: "View workspace compute", exact: true })
      .click();
  };
  await open(page);
  await createShell(page);
  await expect.poll(() => requests.length).toBe(1);
  const other = await context.newPage();
  await open(other);
  await expect(
    other.getByText("Waiting for node connection", { exact: true })
  ).toBeVisible();
  results.get(requests[0]!)!.observed_state = "ready";
  results.get(requests[0]!)!.phase = "ready";
  await expect(other.getByText("Ready to use", { exact: true })).toBeVisible();
  await createShell(other, true);
  await expect(
    other.getByText("Creation result is not yet confirmed", { exact: true })
  ).toBeVisible();
  const pendingKey = async () =>
    other.evaluate(() => {
      const key = Object.keys(localStorage).find((value) =>
        value.startsWith("comma.compute.creation:")
      );
      return key ? (JSON.parse(localStorage.getItem(key)!).requestId as string) : null;
    });
  expect(await pendingKey()).toBe(requests[1]);
  const switchWorkspace = async (id: string) =>
    page.evaluate((workspaceId) => {
      localStorage.setItem("comma.activeWorkspaceId", workspaceId);
      window.dispatchEvent(
        new CustomEvent("comma:active-workspace-changed", { detail: { workspaceId } })
      );
    }, id);
  await switchWorkspace("wsp_other");
  await expect(
    page.getByText(
      "No resources on this page. Enabling a node prepares its initial runtime automatically.",
      { exact: true }
    )
  ).toBeVisible();
  const response = page.waitForResponse((value) =>
    value.url().endsWith("/compute/workloads")
  );
  releaseFirst();
  await response;
  await expect.poll(pendingKey).toBe(requests[1]);
  await expect(page.getByText("Ready to use", { exact: true })).toHaveCount(0);
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
    .getByRole("button", { name: "Manage environments", exact: true })
    .click();
  await target
    .getByRole("button", {
      name: another ? "Create another Shell…" : "Create Shell workload",
      exact: true,
    })
    .click();
  await target.getByRole("button", { name: "Confirm creation", exact: true }).click();
};
