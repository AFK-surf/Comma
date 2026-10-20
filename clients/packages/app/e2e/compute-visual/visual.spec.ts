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
const shot = async (page: Page, name: string) => {
  await page.locator('[data-slot="settings-content"]').screenshot({
    path: resolve(screenshotDir, `${name}.png`),
    animations: "disabled",
  });
};
test("page tree separates component maintenance, storage, and trusted removal scope", async ({
  page,
}) => {
  await page.goto("/preview.html?scene=ready");
  await screen(page, "home");
  await shot(page, "home");
  await page.getByRole("button", { name: "本机设置", exact: true }).click();
  await screen(page, "settings");
  await shot(page, "settings");

  await page.getByRole("button", { name: "管理存储", exact: true }).click();
  await screen(page, "local");
  await shot(page, "storage");
  await page.getByRole("button", { name: "查看清除范围…", exact: true }).click();
  await screen(page, "erase");
  await shot(page, "erase");
  await expect(
    page.getByRole("button", { name: "在本机确认清除…", exact: true })
  ).toHaveCount(1);
  await page.getByRole("button", { name: "返回", exact: true }).first().click();
  await screen(page, "local");
  await page.getByRole("button", { name: "返回", exact: true }).click();
  await screen(page, "settings");
  await page.getByRole("button", { name: "修复…", exact: true }).click();
  await screen(page, "maintenance");
  await shot(page, "maintenance");
  await expect(
    page.getByRole("button", { name: "在本机确认清除…", exact: true })
  ).toHaveCount(0);
  await page.getByRole("button", { name: "返回", exact: true }).click();
  await screen(page, "settings");
});
test("create and workload screens show policy, ownership, and destructive actions in their own sections", async ({
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
  await page
    .getByRole("button", { name: "Weekly report service", exact: true })
    .click();
  await screen(page, "owner");
  await shot(page, "owner");
});
for (const scene of [
  "new",
  "offline",
  "authorization",
  "shell-failed",
  "no-node",
  "retained",
  "maintenance-failed",
  "readonly",
  "browser",
  "setup",
])
  test(`${scene} displays a usable next step and produces a visual review image`, async ({
    page,
  }) => {
    await page.goto(`/preview.html?scene=${scene}`);
    await screen(page, "home");
    await shot(page, `scene-${scene}`);
    if (scene === "readonly") {
      await expect(
        page.getByRole("button", { name: "新建 Shell", exact: true })
      ).toHaveCount(0);
      return;
    }
    if (scene === "new" || scene === "no-node") {
      await page.getByRole("button", { name: "新建 Shell", exact: true }).click();
      await screen(page, "create");
      await expect(
        page.getByRole("button", { name: "启用这台 Mac", exact: true })
      ).toBeEnabled();
      await shot(page, `scene-${scene}-create`);
    }
    if (scene === "authorization") {
      await page.getByRole("button", { name: "重新授权这台 Mac", exact: true }).click();
      const dialog = page.getByRole("dialog");
      await expect(dialog).toBeVisible();
      for (const field of ["当前账号", "设备", "所属工作区", "服务地址"]) {
        await expect(dialog.getByText(field, { exact: true })).toBeVisible();
      }
      await expect(
        dialog.getByText("Default workspace", { exact: true })
      ).toBeVisible();
      await shot(page, "authorization-dialog");
    }
    if (scene === "setup") {
      await page.getByRole("button", { name: "查看进度", exact: true }).click();
      await screen(page, "setup");
      await shot(page, "setup");
    }
    if (scene === "maintenance-failed") {
      await page.getByRole("button", { name: "查看进度", exact: true }).click();
      await screen(page, "maintenance");
      await shot(page, "maintenance-failed");
    }
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

test("offline connection checks owner state without starting repair or setup", async ({
  page,
}) => {
  await page.goto("/preview.html?scene=offline&locale=en");
  const counts = () =>
    page.evaluate(() => ({
      refresh: Number(document.documentElement.dataset.refreshCount || 0),
      repair: Number(document.documentElement.dataset.repairCount || 0),
      configure: Number(document.documentElement.dataset.configureCount || 0),
    }));
  const before = await counts();
  await page.getByRole("button", { name: "Check status", exact: true }).click();
  await expect
    .poll(async () => (await counts()).refresh)
    .toBeGreaterThan(before.refresh);
  expect(await counts()).toMatchObject({ repair: 0, configure: 0 });
  await expect(page.getByRole("dialog")).toHaveCount(0);
});

for (const result of ["none", "failed"]) {
  test(`authorization ${result} keeps a visible explanation and retry`, async ({
    page,
  }) => {
    await page.goto(`/preview.html?scene=authorization&recovery=${result}`);
    await page.getByRole("button", { name: "重新授权这台 Mac", exact: true }).click();
    await screen(page, "authorization");
    await expect(page.getByRole("dialog")).toHaveCount(0);
    await expect(
      page.getByText(
        result === "none"
          ? "在此工作区中没有找到这台 Mac 可恢复的连接。你仍可在本机设置中管理本机资源。"
          : "无法确认此前的连接。请检查本机组件和网络后重试。",
        { exact: true }
      )
    ).toBeVisible();
    await expect(
      page.getByRole("button", { name: "重新授权这台 Mac", exact: true })
    ).toBeEnabled();
    if (result === "none") {
      const explanation = await page
        .getByText(
          "在此工作区中没有找到这台 Mac 可恢复的连接。你仍可在本机设置中管理本机资源。",
          { exact: true }
        )
        .boundingBox();
      const action = await page
        .getByRole("button", { name: "重新授权这台 Mac", exact: true })
        .boundingBox();
      expect(action!.y).toBeGreaterThanOrEqual(
        explanation!.y + explanation!.height + 12
      );
    }
    await shot(page, `authorization-${result}`);
  });
}

test("cloud retirement explains local files without claiming deletion", async ({
  page,
}) => {
  await page.goto("/preview.html?scene=cloud-retired");
  await expect(
    page.getByRole("button", { name: "Default Shell", exact: true })
  ).toBeHidden();
  await page.getByText("历史记录（本页）", { exact: true }).click();
  await expect(page.getByText("云端连接已结束", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Default Shell", exact: true }).click();
  await screen(page, "workload");
  await expect(page.getByText(/原设备上的数据尚未确认删除/)).toBeVisible();
  await expect(
    page.getByRole("button", { name: "删除 Shell", exact: true })
  ).toHaveCount(0);
  await shot(page, "cloud-retired-local-data");
});

test("offline Shell deletion explains the original device cleanup without reporting deleted", async ({
  page,
}) => {
  await page.goto("/preview.html?scene=deletion-offline");
  await screen(page, "home");
  await expect(page.getByText("等待原 Mac", { exact: true })).toBeVisible();
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

test("Shell retry remains visible and targets the selected workload revision", async ({
  page,
}) => {
  await page.goto("/preview.html?scene=shell-failed&locale=en");
  await page.getByRole("button", { name: "Default Shell", exact: true }).click();
  await page.getByRole("button", { name: "Retry preparation", exact: true }).click();
  await expect
    .poll(() =>
      page.evaluate(() =>
        JSON.parse(document.documentElement.dataset.retryRequest || "null")
      )
    )
    .toMatchObject({ id: "workload-default", revision: 1, generation: 1 });
  await expect(
    page.getByRole("button", { name: "Retry preparation", exact: true })
  ).toHaveCount(0);
  await page.getByText("Runtime policy", { exact: true }).first().click();
  await expect(
    page.getByText("No external network access", { exact: true })
  ).toBeVisible();
  await expect(page.getByText("deny_all", { exact: true })).toBeHidden();
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

test("failed workspace removal shows its error after confirmation", async ({
  page,
}) => {
  await page.goto("/preview.html?scene=removal-incomplete");
  await screen(page, "home");
  await page.getByRole("button", { name: "本机设置", exact: true }).click();
  await screen(page, "settings");
  await page.getByRole("button", { name: "完成移除", exact: true }).click();
  await expect(page.getByRole("dialog")).toBeVisible();
  await page
    .getByRole("dialog")
    .getByRole("button", { name: "移除计算节点", exact: true })
    .click();
  await expect(page.getByRole("dialog")).not.toBeVisible();
  await expect(page.getByRole("alert")).toContainText(
    "operation failure requires operator action"
  );
});

test("device permission explanation wraps inside its dialog", async ({ page }) => {
  await page.setViewportSize({ width: 680, height: 900 });
  await page.goto("/preview.html?scene=ready");
  await page.getByRole("button", { name: "权限与详情", exact: true }).click();
  const dialog = page.getByRole("dialog");
  await expect(dialog).toBeVisible();
  // Access is one of Off, Read and Full, each row with what it allows.
  const access = dialog.getByRole("radiogroup");
  await expect(access.getByRole("radio")).toHaveCount(3);
  expect(
    await access.evaluate((group) => {
      const container = group.closest('[role="dialog"]')!.getBoundingClientRect();
      return [...group.querySelectorAll("label")].every((label) => {
        const hint = label.querySelector(".comma-choice-list-description")!;
        const range = document.createRange();
        range.selectNodeContents(hint);
        return (
          range.getBoundingClientRect().right <= container.right &&
          label.scrollWidth <= label.clientWidth
        );
      });
    })
  ).toBe(true);
});
