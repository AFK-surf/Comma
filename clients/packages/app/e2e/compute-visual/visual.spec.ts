import { expect, test as base, type Page } from "@playwright/test";
import { resolve } from "node:path";
const screenshotDir =
  process.env.COMMA_COMPUTE_VISUAL_DIR ||
  resolve(import.meta.dirname, "../../../../test-results/compute-visual");
// Each test loads the preview once. A dev server that finds a dependency its
// scan missed re-bundles and reloads the page under the test, which then
// waits on a second cold load.
const test = base.extend({
  page: async ({ page }, use) => {
    let documentLoads = 0;
    page.on("request", (request) => {
      if (request.isNavigationRequest() && request.frame() === page.mainFrame())
        documentLoads += 1;
    });
    await use(page);
    expect(documentLoads, "the dev server reloaded the preview").toBe(1);
  },
});
const screen = (page: Page, name: string) =>
  expect(page.locator(`[data-compute-screen="${name}"]`)).toBeVisible();
/** Local settings: in this computer's menu on its card. */
const openLocalSettings = async (page: Page, label = "本机设置") => {
  await page
    .locator('article[data-slot="device-card"]')
    .first()
    .getByRole("button", { name: /的更多操作$|^More actions for/ })
    .click();
  await page.getByRole("menuitem", { name: label, exact: true }).click();
};
const shot = async (page: Page, name: string) => {
  await page.locator('[data-slot="settings-content"]').screenshot({
    path: resolve(screenshotDir, `${name}.png`),
    animations: "disabled",
  });
};
test("local settings render software and storage together", async ({ page }) => {
  await page.goto("/preview.html?scene=ready");
  await screen(page, "home");
  await shot(page, "home");
  await openLocalSettings(page);
  await screen(page, "settings");
  await expect(
    page.getByRole("heading", { name: "计算组件", exact: true })
  ).toBeVisible();
  await page.getByText("清除所有计算数据", { exact: true }).click();
  await expect(page.getByText("本机数据", { exact: true }).first()).toBeVisible();
  await expect(
    page.getByRole("button", { name: "在本机确认清除…", exact: true })
  ).toBeEnabled();
  await shot(page, "settings");
  await page.getByRole("button", { name: "返回", exact: true }).click();
  await screen(page, "home");
});
test("workload dialogs return focus and service ownership stays visible", async ({
  page,
}) => {
  await page.goto("/preview.html?scene=ready");
  await screen(page, "home");
  await page.getByRole("button", { name: "新建 Shell", exact: true }).click();
  await screen(page, "create");
  await shot(page, "create");
  await expect(page.getByRole("textbox", { name: "名称", exact: true })).toHaveValue(
    "新 Shell"
  );
  await page.getByRole("button", { name: "取消", exact: true }).click();
  await page.getByRole("button", { name: "Default Shell", exact: true }).click();
  await screen(page, "workload");
  await shot(page, "workload");
  await page.getByRole("button", { name: "重命名", exact: true }).click();
  await shot(page, "rename-dialog");
  await page.keyboard.press("Escape");
  await expect(page.getByRole("button", { name: "重命名", exact: true })).toBeFocused();
  await page.getByRole("button", { name: "删除 Shell", exact: true }).click();
  await shot(page, "delete-dialog");
  await page.keyboard.press("Escape");
  await page.getByRole("button", { name: "返回", exact: true }).click();
  await page.getByRole("button", { name: "Weekly report", exact: true }).click();
  await screen(page, "workload");
  await expect(page.getByText("Weekly report service", { exact: true })).toBeVisible();
  await shot(page, "service-owner");
});
test("lost local intent shows the registration candidates to choose", async ({
  page,
}) => {
  await page.goto("/preview.html?scene=lost-intent");
  await page.getByRole("button", { name: "恢复管理", exact: true }).click();
  await screen(page, "authorization");
  await expect(page.getByText("Studio Mac", { exact: true })).toBeVisible();
  await expect(page.getByText("Travel Mac", { exact: true })).toBeVisible();
  await shot(page, "recovery-candidates");
});

test("a preparing sandbox row renders its owner progress", async ({ page }) => {
  await page.goto("/preview.html?scene=setup");
  await screen(page, "home");
  const sandbox = page.getByRole("region", { name: "沙箱" });
  await expect(sandbox.getByRole("status").first()).toBeVisible();
  await shot(page, "sandbox-preparing");
});

test("read-only workloads render without creation controls", async ({ page }) => {
  await page.goto("/preview.html?scene=readonly");
  await screen(page, "home");
  await expect(
    page.getByRole("button", { name: "Default Shell", exact: true })
  ).toBeVisible();
  await expect(
    page.getByRole("button", { name: "新建 Shell", exact: true })
  ).toHaveCount(0);
});

for (const locale of ["en", "zh-CN"])
  test(`320px ${locale} keeps the actual page inside its viewport`, async ({
    page,
  }) => {
    await page.setViewportSize({ width: 320, height: 900 });
    await page.goto(`/preview.html?locale=${locale}`);
    await screen(page, "home");
    await shot(page, `narrow-${locale}`);
    expect(
      await page
        .locator(".comma-devices")
        .evaluate((el) => el.scrollWidth <= el.clientWidth)
    ).toBe(true);
  });

test("diagnostic status action calls the native owner", async ({ page }) => {
  await page.goto("/preview.html?scene=offline&locale=en");
  await openLocalSettings(page, "Local settings");
  await page.getByText("Diagnostic details", { exact: true }).click();
  const refreshCount = () =>
    page.evaluate(() => Number(document.documentElement.dataset.refreshCount || 0));
  const before = await refreshCount();
  await page.getByRole("button", { name: "Check status", exact: true }).click();
  await expect.poll(refreshCount).toBeGreaterThan(before);
});

test("cloud retirement explains local files without claiming deletion", async ({
  page,
}) => {
  await page.goto("/preview.html?scene=cloud-retired");
  await page.getByRole("button", { name: "Default Shell", exact: true }).click();
  await screen(page, "workload");
  await expect(page.getByText(/原设备上的数据尚未确认删除/)).toBeVisible();
  await expect(
    page.getByRole("button", { name: "删除 Shell", exact: true })
  ).toHaveCount(0);
  await shot(page, "cloud-retired-local-data");
  await page.getByRole("button", { name: "返回", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "Default Shell", exact: true })
  ).toHaveCount(0);
});

test("offline Shell deletion explains the original device cleanup without reporting deleted", async ({
  page,
}) => {
  await page.goto("/preview.html?scene=deletion-offline");
  await screen(page, "home");
  await expect(page.getByText("等待原 Mac 上线", { exact: true })).toBeVisible();
  await page.getByText("Default Shell", { exact: true }).click();
  await screen(page, "workload");
  await expect(
    page.getByText(
      "请重新连接保存此 Shell 的原 Mac，以完成本地文件清理。新工作区连接不能清理旧连接的文件。",
      { exact: true }
    )
  ).toBeVisible();
  await expect(page.getByText("已删除", { exact: true })).toHaveCount(0);
  await shot(page, "deletion-offline");
});

test("Shell preparation action and readable runtime policy stay visible", async ({
  page,
}) => {
  await page.goto("/preview.html?scene=shell-failed&locale=en");
  await page.getByRole("button", { name: "Default Shell", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "Retry preparation", exact: true })
  ).toBeEnabled();
  await page.getByText("Runtime policy", { exact: true }).first().click();
  await expect(
    page.getByText("No external network access", { exact: true })
  ).toBeVisible();
});

test("local component maintenance does not replace an unassociated Shell owner status", async ({
  page,
}) => {
  await page.goto("/preview.html?scene=maintenance-active&locale=en");
  await page.getByRole("button", { name: "Default Shell", exact: true }).click();
  await screen(page, "workload");
  await expect(
    page.getByText("Status needs confirmation", { exact: true })
  ).toHaveCount(0);
  await expect(page.getByText("Ready to use", { exact: true })).toBeVisible();
});

test("a refused reinstall names the data and offers only the reset", async ({
  page,
}) => {
  await page.goto("/preview.html?scene=maintenance-refused");
  await screen(page, "home");
  await expect(
    page
      .getByText("这台 Mac 上的数据与可用版本不兼容。可以删除数据并重新安装。")
      .first()
  ).toBeVisible();
  await shot(page, "maintenance-refused-card");
  await openLocalSettings(page);
  await screen(page, "settings");
  await expect(
    page.getByRole("button", { name: "删除数据并重新安装", exact: true })
  ).toBeEnabled();
  await expect(page.getByRole("button", { name: "继续维护", exact: true })).toHaveCount(
    0
  );
  await shot(page, "maintenance-refused-settings");
});

test("reinstall after clearing the data does not promise to keep it", async ({
  page,
}) => {
  await page.goto("/preview.html?scene=maintenance-data-cleared");
  await screen(page, "home");
  await openLocalSettings(page);
  await screen(page, "settings");
  await expect(
    page.getByRole("button", { name: "重新安装", exact: true })
  ).toBeEnabled();
  await expect(
    page.getByRole("button", { name: "保留数据并重新安装", exact: true })
  ).toHaveCount(0);
  await shot(page, "maintenance-data-cleared-settings");
});

test("keyboard rename returns focus to the workload actions", async ({ page }) => {
  await page.goto("/preview.html?scene=ready");
  await screen(page, "home");
  const actions = page.getByRole("button", { name: /Default Shell.*节点操作/ });
  await actions.focus();
  await page.keyboard.press("Enter");
  await page.getByRole("menuitem", { name: "重命名", exact: true }).focus();
  await page.keyboard.press("Enter");
  await expect(page.getByRole("textbox", { name: "名称", exact: true })).toBeFocused();
  await page.keyboard.press("Escape");
  await expect(actions).toBeFocused();
});

test("device access levels say what each allows inside the menu", async ({ page }) => {
  await page.setViewportSize({ width: 680, height: 900 });
  await page.goto("/preview.html?scene=ready");
  await page
    .locator('article[data-slot="device-card"]')
    .first()
    .getByRole("button", { name: /访问权限/ })
    .click();
  // Access is one of Off, Read and Full, each option with what it allows.
  const options = page.getByRole("option");
  await expect(options).toHaveCount(3);
  const width = page.viewportSize()!.width;
  for (const option of await options.all()) {
    const box = (await option.boundingBox())!;
    expect(box.x + box.width).toBeLessThanOrEqual(width);
  }
  await shot(page, "access-menu");
});

test("preparing details show Internet policy without missing usage noise", async ({
  page,
}) => {
  await page.goto("/preview.html?scene=preparing&locale=en");
  await page.getByRole("button", { name: "Default Shell", exact: true }).click();
  await screen(page, "workload");
  await page.getByText("Runtime policy", { exact: true }).first().click();
  await expect(page.getByText("Internet access", { exact: true })).toBeVisible();
  await expect(page.getByRole("alert")).toHaveCount(0);
  await shot(page, "preparing-details");
});

test("absent policy remains distinct from a failed network", async ({ page }) => {
  await page.goto("/preview.html?scene=missing-policy&locale=en");
  await page.getByRole("button", { name: "Default Shell", exact: true }).click();
  await page.getByText("Runtime policy", { exact: true }).first().click();
  const network = page
    .locator(".compute-fact")
    .filter({ has: page.getByText("Network access", { exact: true }) })
    .first();
  await expect(network.locator("dd")).toHaveText("—");
  await shot(page, "missing-policy");
});

test("local connection cleanup stays in its group menu", async ({ page }) => {
  await page.goto("/preview.html?scene=ready&locale=en");
  await openLocalSettings(page, "Local settings");
  await expect(page.getByText("Local data", { exact: true }).first()).toBeVisible();
  await page
    .getByRole("button", { name: "other123 Node actions", exact: true })
    .click();
  await expect(
    page.getByRole("menuitem", { name: "Delete local data", exact: true })
  ).toBeVisible();
  await shot(page, "connection-menu");
});

test("long workload names stay readable in a narrow list and detail", async ({
  page,
}) => {
  await page.setViewportSize({ width: 320, height: 900 });
  await page.goto("/preview.html?scene=long-names&locale=en");
  const workload = page.getByRole("button", {
    name: "A very long Shell name 工作负载名称需要完整可读 with useful identifying details",
    exact: true,
  });
  await expect(workload).toBeVisible();
  expect(
    await page
      .locator(".comma-devices")
      .evaluate((el) => el.scrollWidth <= el.clientWidth)
  ).toBe(true);
  await workload.scrollIntoViewIfNeeded();
  const bounds = await workload.boundingBox();
  expect(bounds!.x + bounds!.width).toBeLessThanOrEqual(320);
  await shot(page, "long-name-list");
  await workload.click();
  await screen(page, "workload");
  await shot(page, "long-name-detail");
});

test("delete refusal stays in its confirmation and clears when closed", async ({
  page,
}) => {
  await page.goto("/preview.html?scene=delete-refused&locale=en");
  await page
    .getByRole("button", { name: "Default Shell Node actions", exact: true })
    .click();
  await page.getByRole("menuitem", { name: "Delete Shell", exact: true }).click();
  const dialog = page.getByRole("dialog");
  await expect(
    dialog.getByRole("heading", { name: "Delete Default Shell", exact: true })
  ).toBeVisible();
  await dialog.getByRole("button", { name: "Delete", exact: true }).click();
  await expect(
    dialog.getByText(
      "This workload shares its runtime with other workloads and cannot be deleted separately.",
      { exact: true }
    )
  ).toBeVisible();
  await expect(page.getByRole("alert")).toHaveCount(1);
  await shot(page, "delete-refused");
  await page.keyboard.press("Escape");
  await expect(page.getByRole("alert")).toHaveCount(0);
  await shot(page, "delete-refused-closed");
});

test("a known uncertain deletion continues the original operation without another confirmation", async ({
  page,
}) => {
  await page.goto("/preview.html?scene=delete-unknown&locale=en");
  await expect(
    page.getByRole("button", { name: "Default Shell", exact: true }).getByRole("status")
  ).toHaveText("Deletion result unconfirmed");
  await expect(
    page.getByRole("button", { name: "Weekly report", exact: true }).getByRole("status")
  ).toHaveText("Ready to use");
  await expect(
    page.getByRole("button", { name: "Continue deletion", exact: true })
  ).toBeVisible();
  await page
    .getByRole("button", { name: "Default Shell Node actions", exact: true })
    .click();
  await expect(
    page.getByRole("menuitem", { name: "Delete Shell", exact: true })
  ).toHaveCount(0);
  await page.keyboard.press("Escape");
  await page.getByRole("button", { name: "Default Shell", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "Delete Shell", exact: true })
  ).toHaveCount(0);
  await expect(
    page.getByRole("button", { name: "Continue deletion", exact: true })
  ).toBeVisible();
  await expect(page.getByRole("status")).toHaveText("Deletion result unconfirmed");
  await expect(page.getByRole("alert")).toHaveCount(0);
  await shot(page, "delete-unknown-details");
  await page.getByRole("button", { name: "Continue deletion", exact: true }).click();
  await expect(page.getByText("Deleting", { exact: true })).toBeVisible();
  await expect(page.getByRole("alert")).toHaveCount(0);
  await shot(page, "delete-continued");
});

test("delete confirmation omits a generic unnamed device", async ({ page }) => {
  await page.goto("/preview.html?scene=unknown-location&locale=en");
  await page
    .getByRole("button", { name: "Default Shell Node actions", exact: true })
    .click();
  await page.getByRole("menuitem", { name: "Delete Shell", exact: true }).click();
  const dialog = page.getByRole("dialog");
  await expect(
    dialog.getByRole("heading", { name: "Delete Default Shell", exact: true })
  ).toBeVisible();
  await expect(dialog.getByText(/Location:/)).toHaveCount(0);
  await shot(page, "delete-unnamed-device");
});

test("an unreadable owner keeps uncertain deletion query-only", async ({ page }) => {
  const scene = "delete-owner-unreadable";
  await page.goto(`/preview.html?scene=${scene}&locale=en`);
  await expect(
    page.getByRole("button", { name: "Check status", exact: true })
  ).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Continue deletion", exact: true })
  ).toHaveCount(0);
  await page.getByRole("button", { name: "Check status", exact: true }).click();
  await page.getByRole("button", { name: "Default Shell", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "Delete Shell", exact: true })
  ).toHaveCount(0);
  await shot(page, `${scene}-details`);
});

test("paused observation uses the existing refresh control to continue checking", async ({
  page,
}) => {
  await page.goto("/preview.html?scene=observation-paused&locale=en");
  const resume = page.getByRole("button", { name: "Continue checking", exact: true });
  await expect(resume).toBeVisible();
  await shot(page, "observation-paused");
  await resume.click();
});

test("unknown local deletion reports its receipt uncertainty", async ({ page }) => {
  await page.goto("/preview.html?scene=local-delete-unknown&locale=en");
  await openLocalSettings(page, "Local settings");
  await expect(
    page.getByText("Local deletion result unconfirmed.", { exact: true })
  ).toBeVisible();
  await shot(page, "local-delete-unknown");
});

test("a legacy deletion opens the existing confirmation for the displayed workload", async ({
  page,
}) => {
  await page.goto("/preview.html?scene=delete-query-only&locale=en");
  const reconfirm = page.getByRole("button", {
    name: "Confirm deletion again",
    exact: true,
  });
  await expect(reconfirm).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Continue deletion", exact: true })
  ).toHaveCount(0);
  await reconfirm.click();
  const dialog = page.getByRole("dialog");
  await expect(
    dialog.getByRole("heading", { name: "Delete Default Shell", exact: true })
  ).toBeVisible();
  await shot(page, "legacy-delete-confirmation");
  await dialog.getByRole("button", { name: "Cancel", exact: true }).click();
  await page.getByRole("button", { name: "Default Shell", exact: true }).click();
  await reconfirm.click();
  await dialog.getByRole("button", { name: "Delete", exact: true }).click();
  await expect(page.getByText("Deleting", { exact: true })).toBeVisible();
});
