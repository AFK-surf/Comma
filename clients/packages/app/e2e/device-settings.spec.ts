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
  let access = "read";
  let deviceName = "office-mini";
  let removed = false;
  let failRemove = false;
  let failNext = false;
  let failRefresh = false;
  let validUntil = Math.floor(Date.now() / 1000) + 600;
  const accessChanges: string[] = [];
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
    allows_operations: access === "full",
    access,
    tasks_readiness: "ready",
    task_models: { claude: ["claude-opus-5-5"] },
    device_runtimes: Array.from({ length: 2 }, (_, index) => ({
      device_runtime_id: `runtime_${index}`,
      provider: index === 1 ? "claude" : "codex",
      status: index === 0 ? "unavailable" : "ready",
      issue: index === 0 ? "authentication_required" : undefined,
      auth: { status: index === 0 ? "unauthenticated" : "authenticated" },
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
    } else if (path.endsWith("/stations/enrollments") && request.method() === "POST") {
      body = {
        token: "tok_e2e",
        command:
          "curl -fsSL https://api.comma.test/stations/install.sh | sh -s -- tok_e2e",
        expires_at: 4_102_444_800,
      };
    } else if (path.endsWith("/probe") && request.method() === "POST") {
      body = device();
    } else if (path.endsWith("/access") && request.method() === "PUT") {
      access = request.postDataJSON().access;
      accessChanges.push(access);
      body = { access, allows_operations: access === "full" };
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
            access: "read",
            status: i === 0 ? "disconnected" : "connected",
            device_runtimes: [],
          })),
        ],
        cloud_vm: {
          ...device(),
          device_id: "dev_cloud_vm",
          name: "Cloud Workspace",
          os: "linux",
          system_info: {},
          allows_operations: true,
          access: "full",
          device_runtimes: [],
        },
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
  // The Cloud VM has its own section and is not one of the person's computers.
  await expect(panel.locator(".comma-devices__summary").first()).toHaveText(
    "19 of your computers on this page · 18 online"
  );
  const cloud = panel
    .getByRole("region", { name: "Cloud VM" })
    .getByRole("article", { name: "Cloud Workspace", exact: true });
  await expect(cloud).toBeVisible();
  await cloud.getByRole("button", { name: /More actions for/ }).click();
  await expect(page.getByRole("menuitem", { name: "Rename device" })).toBeVisible();
  await expect(page.getByRole("menuitem", { name: "Delete device" })).toHaveCount(0);
  await page.keyboard.press("Escape");
  // Add device is the 28px button of Drive's Transfer: 8px before its icon,
  // 12px after its label.
  const addDevice = panel.getByRole("button", { name: "Add device", exact: true });
  await expect(addDevice).toBeVisible();
  expect(
    await addDevice.evaluate((element) => {
      const style = getComputedStyle(element);
      return [
        element.getBoundingClientRect().height,
        style.paddingLeft,
        style.paddingRight,
      ];
    })
  ).toEqual([28, "8px", "12px"]);
  await expect(
    card
      .locator("summary")
      .getByText("Operations are disabled", { exact: true })
      .first()
  ).toBeVisible();
  await card.locator("summary").filter({ hasText: "Codex" }).click();
  await expect(card).toContainText("Version: 1.0.0");
  await expect(card).toContainText("Authentication: Not signed in");
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
  await expect(card).toContainText("Ready for Tasks");
  await expect(card).not.toContainText("Disconnected at:");
  await offline.getByRole("button", { name: "Permissions & details" }).click();
  const permissionDialog = page.getByRole("dialog", {
    name: "Computer 1",
    exact: true,
  });
  await expect(permissionDialog).toContainText("Disconnected at:");
  await expect(permissionDialog).toContainText("studio.local");
  await expect(permissionDialog.getByRole("radio", { name: /^Full/ })).toBeDisabled();
  await permissionDialog
    .getByRole("button", { name: "Close", exact: true })
    .last()
    .click();
  await card.getByRole("button", { name: "Permissions & details" }).click();
  const localPermissions = page.getByRole("dialog", {
    name: "office-mini",
    exact: true,
  });
  const full = localPermissions.getByRole("radio", { name: /^Full/ });
  await expect(localPermissions.getByRole("radio", { name: /^Read/ })).toBeChecked();
  await full.click();
  await expect(full).toBeChecked();
  expect(accessChanges).toEqual(["full"]);
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
  // The title belongs to the page, so it scrolls away with the list.
  expect((await title.boundingBox())!.y).toBeLessThan(titlePosition!.y);
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
  ).toHaveCount(1);
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
  ).toHaveCount(1);
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
  // Adding a computer shows the one-time station install command, in a browser too.
  await panel.getByRole("button", { name: "Add device" }).click();
  const adding = page.getByRole("dialog", { name: "Add device" });
  await expect(adding.getByTestId("device-install-command")).toHaveText(
    "curl -fsSL https://api.comma.test/stations/install.sh | sh -s -- tok_e2e"
  );
  await expect(adding.getByRole("button", { name: "Ask Router" })).toBeVisible();
});
