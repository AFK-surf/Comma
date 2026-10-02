import { expect, test } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";

const apiBaseUrl = "http://127.0.0.1:65534";
const workspaceId = "wsp_device_settings_e2e";

test("device cards keep connection and readiness separate and target management correctly", async ({
  page,
}) => {
  await installBrowserTestSession(page, {
    apiBaseUrl,
    email: "devices-e2e@example.com",
    token: "comma_sess_devices_e2e",
    userId: "usr_devices_e2e",
  });
  await page.addInitScript((id) => {
    localStorage.setItem("comma.activeWorkspaceId", id);
  }, workspaceId);
  let allowsOperations = false;
  let deviceName = "office-mini";
  let removed = false;
  let failRemove = false;
  let failNext = false;
  let failRefresh = false;
  let validUntil = Math.floor(Date.now() / 1000) + 600;
  const accessChanges: boolean[] = [];
  const device = () => ({
    device_id: "dev_office_mac",
    name: deviceName,
    os: "darwin",
    arch: "arm64",
    system_info: {
      hostname: "studio.local",
      cpu_model: "Apple M4",
      memory_total: 17179869184,
    },
    disconnected_at: 1789627075,
    status: "connected",
    allows_operations: allowsOperations,
    device_runtimes: Array.from({ length: 3 }, (_, index) => ({
      device_runtime_id: `runtime_${index}`,
      provider: index === 2 ? "pi" : index === 1 ? "claude" : "codex",
      status: index === 0 ? "unavailable" : "ready",
      issue: index === 0 ? "authentication_required" : undefined,
      version: `1.0.${index}`,
      readiness_checked_at: Math.floor(Date.now() / 1000),
      readiness_valid_until: validUntil,
    })),
  });
  await page.route(`${apiBaseUrl}/v1/comma/workspaces**`, async (route) => {
    const request = route.request();
    const path = new URL(request.url()).pathname;
    const headers = {
      "access-control-allow-credentials": "true",
      "access-control-allow-headers":
        "authorization,content-type,x-comma-session-transport",
      "access-control-allow-methods": "GET,POST,PUT,DELETE,OPTIONS",
      "access-control-allow-origin":
        request.headers().origin ?? "http://127.0.0.1:4173",
      "content-type": "application/json",
    };
    if (request.method() === "OPTIONS") {
      await route.fulfill({ status: 204, headers, body: "" });
      return;
    }
    let body: unknown = {};
    if (path === "/v1/comma/workspaces") {
      body = { data: [{ id: workspaceId, group_id: "grp_devices_e2e", name: "Main" }] };
    } else if (path.endsWith("/probe") && request.method() === "POST") {
      body = device();
    } else if (path.endsWith("/access") && request.method() === "PUT") {
      allowsOperations = request.postDataJSON().allow_operations;
      accessChanges.push(allowsOperations);
      body = { allows_operations: allowsOperations };
    } else if (
      path.endsWith("/devices") &&
      new URL(request.url()).searchParams.has("cursor")
    ) {
      if (failNext) {
        await route.fulfill({
          status: 503,
          headers,
          body: JSON.stringify({ error: "unavailable" }),
        });
        return;
      }
      body = {
        devices: [
          {
            ...device(),
            device_id: "dev_next",
            name: "Next page computer",
            device_runtimes: [],
          },
        ],
        next_cursor: null,
      };
    } else if (path.endsWith("/devices")) {
      if (failRefresh) {
        await route.fulfill({
          status: 503,
          headers,
          body: JSON.stringify({ error: "unavailable" }),
        });
        return;
      }
      body = {
        devices: [
          ...(removed ? [] : [device()]),
          ...Array.from({ length: 18 }, (_, i) => ({
            ...device(),
            device_id: `dev_extra_${i}`,
            name: `Computer ${i + 1}`,
            allows_operations: false,
            status: i === 0 ? "disconnected" : "connected",
            device_runtimes: [],
          })),
        ],
        next_cursor: "page_2",
      };
    } else if (path.endsWith("/devices/dev_office_mac")) {
      if (request.method() === "PUT") deviceName = request.postDataJSON().name;
      if (request.method() === "DELETE") {
        if (failRemove) {
          await route.fulfill({
            status: 503,
            headers,
            body: JSON.stringify({ error: "unavailable" }),
          });
          return;
        }
        removed = true;
      }
      if (request.method() === "GET" && removed) {
        await route.fulfill({
          status: 404,
          headers,
          body: JSON.stringify({ error: "not_found" }),
        });
        return;
      }
      body = request.method() === "DELETE" ? { removed: true } : device();
    }
    await route.fulfill({ status: 200, headers, body: JSON.stringify(body) });
  });

  await page.goto("/#/settings");
  const devicesCategory = page.getByRole("button", { name: "Devices", exact: true });
  await devicesCategory.click();
  const panel = page.locator('[data-slot="device-settings"]');
  const card = panel.getByRole("article").first();
  await expect(card.getByRole("heading", { name: "office-mini" })).toBeVisible();
  await expect(card.getByText("Connected", { exact: true })).toBeVisible();
  await expect(
    card
      .locator("summary")
      .getByText("Operations are disabled", { exact: true })
      .first()
  ).toBeVisible();
  await card.locator("summary").filter({ hasText: "Codex" }).click();
  await expect(card).toContainText("Version: 1.0.0");
  await expect(card).toContainText("Authentication: Not reported");
  await card.locator("summary").filter({ hasText: "Codex" }).click();
  const offline = panel.getByRole("article", { name: "Computer 1", exact: true });
  const firstCard = (await card.boundingBox())!;
  const secondCard = (await offline.boundingBox())!;
  expect(Math.round(secondCard.x)).toBe(Math.round(firstCard.x));
  expect(secondCard.y).toBeGreaterThanOrEqual(firstCard.y + firstCard.height);

  await expect(
    offline.locator(".comma-device__connection").getByText("Offline", { exact: true })
  ).toBeVisible();

  await expect(card).toContainText("16 GB");
  await expect(card).not.toContainText("Disconnected at:");
  await offline.getByRole("button", { name: "Permissions & details" }).click();
  const permissionDialog = page.getByRole("dialog", {
    name: "Computer 1",
    exact: true,
  });
  await expect(permissionDialog).toContainText("Disconnected at:");
  await expect(permissionDialog).toContainText("studio.local");
  await expect(permissionDialog.getByRole("switch")).toBeDisabled();
  await permissionDialog
    .getByRole("button", { name: "Close", exact: true })
    .last()
    .click();
  await card.getByRole("button", { name: "Permissions & details" }).click();
  const localPermissions = page.getByRole("dialog", {
    name: "office-mini",
    exact: true,
  });
  const access = localPermissions.getByRole("switch", { name: "Allow operations" });
  await expect(access).not.toBeChecked();
  await localPermissions.locator('[data-slot="toggle-base"]').click();
  await expect(access).toBeChecked();
  expect(accessChanges).toEqual([true]);
  await localPermissions
    .getByRole("button", { name: "Close", exact: true })
    .last()
    .click();
  const otherCard = panel.getByRole("article", { name: "Computer 2", exact: true });
  await expect(otherCard).toContainText("Read-only access");
  const title = panel.getByRole("heading", { name: "Devices", exact: true });
  const titlePosition = await title.boundingBox();
  const viewport = panel.locator(".comma-scroll-area__viewport");
  const scrollbar = panel.locator('[data-slot="scroll-area-scrollbar"]');
  const assertScrollbarPosition = async () => {
    const track = (await scrollbar.boundingBox())!;
    const bounds = (await panel.boundingBox())!;
    const deviceCard = (await card.boundingBox())!;
    expect(bounds.x + bounds.width - track.x - track.width).toBeLessThanOrEqual(12);
    expect(track.x).toBeGreaterThan(deviceCard.x + deviceCard.width);
  };
  await assertScrollbarPosition();
  await panel
    .getByRole("heading", { name: "Computer 18", exact: true })
    .scrollIntoViewIfNeeded();
  await expect(
    panel.getByRole("heading", { name: "Computer 18", exact: true })
  ).toBeInViewport();
  expect(await title.boundingBox()).toEqual(titlePosition);
  await expect
    .poll(() => viewport.evaluate((element) => element.scrollTop))
    .toBeGreaterThan(0);
  // The last computer of the page in view asks for the next page by itself.
  await expect(panel.getByRole("heading", { name: "Next page computer" })).toHaveCount(
    1
  );
  await card.scrollIntoViewIfNeeded();
  await page.setViewportSize({ width: 850, height: 700 });
  await assertScrollbarPosition();
  const cards = panel.getByRole("article");
  await expect
    .poll(
      async () =>
        Math.round((await cards.nth(0).boundingBox())!.x) -
        Math.round((await cards.nth(1).boundingBox())!.x)
    )
    .toBe(0);
  expect(
    await viewport.evaluate((element) => element.scrollWidth <= element.clientWidth + 1)
  ).toBe(true);
  await page.setViewportSize({ width: 1280, height: 800 });
  await card.scrollIntoViewIfNeeded();
  await viewport.evaluate((element) => {
    element.scrollTop = 0;
  });
  await expect(card.getByRole("heading", { name: "office-mini" })).toBeInViewport();
  await expect(
    card.locator("summary").getByText("Check passed", { exact: true })
  ).toHaveCount(2);
  failRefresh = true;
  await page.evaluate(() => window.dispatchEvent(new Event("focus")));
  await expect(panel.getByRole("alert")).toBeVisible();
  await expect(
    card.locator("summary").getByText("Check passed", { exact: true })
  ).toHaveCount(0);
  failRefresh = false;
  validUntil = Math.floor(Date.now() / 1000) - 1;
  await page.evaluate(() => window.dispatchEvent(new Event("focus")));
  await expect(
    card.locator("summary").getByText("Check expired", { exact: true })
  ).toHaveCount(2);
  // The refresh dropped the page read when "Computer 18" scrolled into view.
  // Scrolling to the end asks for it again; this time it fails, and the list
  // offers Retry instead of asking again on its own.
  await expect(panel.getByRole("heading", { name: "Next page computer" })).toHaveCount(
    0
  );
  failNext = true;
  await viewport.evaluate((element) => {
    element.scrollTop = element.scrollHeight;
  });
  await expect(panel.getByRole("alert")).toBeVisible();
  failNext = false;
  await panel.getByRole("button", { name: "Retry", exact: true }).click();
  await expect(
    panel.getByRole("heading", { name: "Next page computer" })
  ).toBeVisible();
  await expect(panel.getByRole("heading", { name: "office-mini" })).toBeVisible();
  // Away from the end, so the refresh below is the only read.
  await viewport.evaluate((element) => {
    element.scrollTop = 0;
  });
  await page.evaluate(() => window.dispatchEvent(new Event("focus")));
  await expect(panel.getByRole("heading", { name: "Next page computer" })).toHaveCount(
    0
  );
  await card.getByRole("button", { name: /More actions for/ }).click();
  await page.getByRole("menuitem", { name: "Rename device" }).click();
  const rename = page.getByRole("dialog", { name: "Rename device" });
  await rename.getByRole("textbox", { name: "Device name" }).fill("Studio Mac");
  await rename.getByRole("button", { name: "Save" }).click();
  await expect(panel.getByRole("heading", { name: "Studio Mac" })).toBeVisible();
  await page.reload();
  await page.getByRole("button", { name: "Devices", exact: true }).click();
  await expect(panel.getByRole("heading", { name: "Studio Mac" })).toBeVisible();
  await card.getByRole("button", { name: /More actions for/ }).click();
  await page.getByRole("menuitem", { name: "Delete device" }).click();
  const deletion = page.getByRole("dialog", { name: "Delete device" });
  await expect(deletion).toContainText("Studio Mac");
  await deletion.getByRole("button", { name: "Cancel" }).click();
  expect(removed).toBe(false);
  await card.getByRole("button", { name: /More actions for/ }).click();
  await page.getByRole("menuitem", { name: "Delete device" }).click();
  failRemove = true;
  await deletion.getByRole("button", { name: "Delete device", exact: true }).click();
  await expect(deletion.getByRole("alert")).toBeVisible();
  expect(removed).toBe(false);
  failRemove = false;
  await deletion.getByRole("button", { name: "Delete device", exact: true }).click();
  await expect(deletion).not.toBeVisible();
  await expect(panel.getByRole("heading", { name: "Studio Mac" })).not.toBeVisible();
  expect(removed).toBe(true);
  removed = false;
  await page.evaluate(() => window.dispatchEvent(new Event("focus")));
  await expect(panel.getByRole("heading", { name: "Studio Mac" })).toBeVisible();
  removed = true;
  await page.evaluate(() => window.dispatchEvent(new Event("focus")));
  await expect(panel.getByRole("heading", { name: "Studio Mac" })).not.toBeVisible();
  await panel.getByRole("button", { name: "Add device" }).click();
  // A browser cannot copy the connect command: it offers the Mac app instead.
  await page.getByRole("button", { name: "Connect manually" }).click();
  const prompt = page.getByRole("dialog", { name: "Get Comma for Mac" });
  await expect(prompt).toContainText("Connecting a device manually needs");
  await expect(page.getByRole("dialog", { name: "Connect manually" })).toHaveCount(0);
  await page
    .context()
    .route("https://comma.surf/**", (route) =>
      route.fulfill({ status: 200, contentType: "text/html", body: "" })
    );
  const [download] = await Promise.all([
    page.waitForEvent("popup"),
    prompt.getByRole("button", { name: "Download" }).click(),
  ]);
  expect(download.url()).toBe("https://comma.surf/download?start=mac");
  await expect(prompt).not.toBeVisible();
});

test("a completed runtime check preserves an in-flight next page", async ({ page }) => {
  await installBrowserTestSession(page, {
    apiBaseUrl,
    email: "device-pagination@example.com",
    token: "comma_sess_pagination",
    userId: "usr_pagination",
  });
  await page.addInitScript(
    (id) => localStorage.setItem("comma.activeWorkspaceId", id),
    workspaceId
  );
  const device = {
    device_id: "dev_pagination",
    name: "Checking computer",
    status: "connected",
    allows_operations: true,
    device_runtimes: [
      {
        device_runtime_id: "runtime_pagination",
        provider: "codex",
        status: "ready",
        readiness_valid_until: Math.floor(Date.now() / 1000) - 1,
      },
    ],
  };
  let finishProbe!: () => void;
  const probe = new Promise<void>((resolve) => (finishProbe = resolve));
  let finishPage!: () => void;
  const nextPage = new Promise<void>((resolve) => (finishPage = resolve));
  let pageRequested = false;
  await page.route(`${apiBaseUrl}/v1/comma/workspaces**`, async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    const headers = {
      "access-control-allow-credentials": "true",
      "access-control-allow-headers":
        "authorization,content-type,x-comma-session-transport",
      "access-control-allow-methods": "GET,POST,OPTIONS",
      "access-control-allow-origin":
        request.headers().origin ?? "http://127.0.0.1:4173",
      "content-type": "application/json",
    };
    if (request.method() === "OPTIONS") {
      await route.fulfill({ status: 204, headers, body: "" });
      return;
    }
    let body: unknown = {};
    if (url.pathname === "/v1/comma/workspaces") {
      body = { data: [{ id: workspaceId, group_id: "grp_pagination", name: "Main" }] };
    } else if (url.pathname.endsWith("/probe")) {
      await probe;
      device.device_runtimes[0]!.readiness_valid_until =
        Math.floor(Date.now() / 1000) + 600;
      body = device;
    } else if (url.pathname.endsWith("/devices")) {
      if (url.searchParams.has("cursor")) {
        expect(url.searchParams.get("cursor")).toBe("page_2");
        pageRequested = true;
        await nextPage;
        body = {
          devices: [{ ...device, device_id: "dev_next", name: "Next page computer" }],
          next_cursor: null,
        };
      } else {
        body = {
          devices: [
            device,
            ...Array.from({ length: 18 }, (_, index) => ({
              ...device,
              device_id: `dev_filler_${index}`,
              name: `Computer ${index + 1}`,
              allows_operations: false,
              device_runtimes: [],
            })),
          ],
          next_cursor: "page_2",
        };
      }
    }
    await route.fulfill({ status: 200, headers, body: JSON.stringify(body) });
  });
  await page.goto("/#/settings");
  await page.getByRole("button", { name: "Devices", exact: true }).click();
  const panel = page.locator('[data-slot="device-settings"]');
  const card = panel.getByRole("article", { name: "Checking computer", exact: true });
  await expect(card.getByRole("button", { name: "Checking…" })).toBeDisabled();
  await panel
    .getByRole("heading", { name: "Computer 18", exact: true })
    .scrollIntoViewIfNeeded();
  await expect.poll(() => pageRequested).toBe(true);
  // Move away from the pagination sentinel before the check completes. The
  // requested page must finish without needing another scroll to restart it.
  await card.scrollIntoViewIfNeeded();
  finishProbe();
  await expect(card.locator("summary")).toContainText("Check passed");
  finishPage();
  await expect(panel.getByRole("heading", { name: "Next page computer" })).toHaveCount(
    1
  );
  await expect(card.locator("summary")).toContainText("Check passed");
});

test("expired devices check once per visit, with bounded concurrency and manual retry", async ({
  page,
}) => {
  await installBrowserTestSession(page, {
    apiBaseUrl,
    email: "device-probe@example.com",
    token: "comma_sess_probe",
    userId: "usr_probe",
  });
  await page.addInitScript(
    (id) => localStorage.setItem("comma.activeWorkspaceId", id),
    workspaceId
  );
  const devices = [
    "Expired A",
    "Expired B",
    "Expired C",
    "Fresh",
    "Offline",
    "Read only",
  ].map((name, index) => ({
    device_id: `dev_probe_${index}`,
    name,
    status: index === 4 ? "disconnected" : "connected",
    allows_operations: index !== 5,
    device_runtimes: [
      {
        device_runtime_id: `runtime_probe_${index}`,
        provider: "codex",
        status: "ready",
        readiness_checked_at: Math.floor(Date.now() / 1000) - 700,
        readiness_valid_until: Math.floor(Date.now() / 1000) + (index === 3 ? 600 : -1),
      },
    ],
  }));
  const calls: string[] = [];
  const releases = new Map<string, (success: boolean) => void>();
  let reads = 0;
  await page.route(`${apiBaseUrl}/v1/comma/workspaces**`, async (route) => {
    const request = route.request();
    const path = new URL(request.url()).pathname;
    const headers = {
      "access-control-allow-credentials": "true",
      "access-control-allow-headers":
        "authorization,content-type,x-comma-session-transport",
      "access-control-allow-methods": "GET,POST,OPTIONS",
      "access-control-allow-origin":
        request.headers().origin ?? "http://127.0.0.1:4173",
      "content-type": "application/json",
    };
    if (request.method() === "OPTIONS") {
      await route.fulfill({ status: 204, headers, body: "" });
      return;
    }
    if (path.endsWith("/probe")) {
      const id = path.split("/").at(-2)!;
      calls.push(id);
      const success = await new Promise<boolean>((resolve) =>
        releases.set(id, resolve)
      );
      releases.delete(id);
      const device = devices.find((candidate) => candidate.device_id === id)!;
      if (success)
        device.device_runtimes[0]!.readiness_valid_until =
          Math.floor(Date.now() / 1000) + 600;
      await route.fulfill({
        status: success ? 200 : 503,
        headers,
        body: JSON.stringify(success ? device : { error: "unavailable" }),
      });
      return;
    }
    if (path.endsWith("/devices")) reads += 1;
    const body =
      path === "/v1/comma/workspaces"
        ? { data: [{ id: workspaceId, group_id: "grp_probe", name: "Main" }] }
        : path.endsWith("/devices")
          ? { devices, next_cursor: null }
          : {};
    await route.fulfill({ status: 200, headers, body: JSON.stringify(body) });
  });
  await page.goto("/#/settings");
  const enter = () =>
    page.getByRole("button", { name: "Devices", exact: true }).click();
  await enter();
  const card = page.getByRole("article", { name: "Expired A", exact: true });
  await expect(card.getByRole("button", { name: "Checking…" })).toBeDisabled();
  await expect.poll(() => calls.length).toBe(2);
  expect(calls).toEqual(["dev_probe_0", "dev_probe_1"]);
  await expect(
    page
      .getByRole("article", { name: "Offline", exact: true })
      .getByRole("button", { name: "Check again" })
  ).toBeDisabled();
  await expect(
    page
      .getByRole("article", { name: "Read only", exact: true })
      .getByRole("button", { name: "Check again" })
  ).toBeDisabled();
  releases.get("dev_probe_1")!(true);
  await expect.poll(() => calls.length).toBe(3);
  releases.get("dev_probe_0")!(false);
  releases.get("dev_probe_2")!(true);
  await expect(card.getByRole("alert")).toContainText("Could not check agents");
  await expect(card.locator("summary")).toContainText("Check expired");
  const previousReads = reads;
  await page.evaluate(() => window.dispatchEvent(new Event("focus")));
  await expect.poll(() => reads).toBeGreaterThan(previousReads);
  expect(calls).toHaveLength(3);
  await card.getByRole("button", { name: "Check again" }).click();
  await expect.poll(() => calls.length).toBe(4);
  await expect(card.getByRole("button", { name: "Checking…" })).toBeDisabled();
  releases.get("dev_probe_0")!(true);
  await expect(card.locator("summary")).toContainText("Check passed");
  await expect(card.getByRole("alert")).toHaveCount(0);
  devices[0]!.device_runtimes[0]!.readiness_valid_until =
    Math.floor(Date.now() / 1000) - 1;
  await page.evaluate(() => window.dispatchEvent(new Event("focus")));
  await expect(card.locator("summary")).toContainText("Check expired");
  expect(calls).toHaveLength(4);
  await page.getByRole("button", { name: "General", exact: true }).click();
  await enter();
  await expect.poll(() => calls.length).toBe(5);
  expect(calls.at(-1)).toBe("dev_probe_0");
  releases.get("dev_probe_0")!(true);
  await expect(card.locator("summary")).toContainText("Check passed");
});
