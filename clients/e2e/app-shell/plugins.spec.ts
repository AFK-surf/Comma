import { expect, test } from "@playwright/test";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import localGroupSelectors from "../../vite/comma-tailwind";
import type { AddressInfo } from "node:net";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  createBuiltFixtureServer,
  type BuiltFixtureServer,
} from "../helpers/built-fixture";

const currentDir = fileURLToPath(new URL(".", import.meta.url));
const clientsRoot = resolve(currentDir, "../..");
const fixtureRoot = resolve(currentDir, "fixtures/plugins");

let fixtureServer: BuiltFixtureServer | undefined;
let fixtureUrl = "";

test.beforeAll(async ({ browser }) => {
  test.setTimeout(120_000);
  fixtureServer = await createBuiltFixtureServer({
    cacheDir: resolve(clientsRoot, "node_modules/.vite/plugins-e2e"),
    configFile: false,
    define: {
      "process.env.NODE_ENV": JSON.stringify("test"),
    },
    plugins: [react(), tailwindcss({ optimize: false }), localGroupSelectors()],
    resolve: {
      alias: {
        "@comma/ui/styles.css": resolve(clientsRoot, "packages/ui/src/styles.css"),
        "@comma/ui": resolve(clientsRoot, "packages/ui/src/index.ts"),
      },
    },
    root: fixtureRoot,
    server: {
      hmr: false,
      host: "127.0.0.1",
      port: 0,
    },
  });

  const address = fixtureServer.httpServer?.address();
  if (!address || typeof address === "string") {
    throw new Error("Plugins fixture server did not expose a TCP port.");
  }

  fixtureUrl = `http://127.0.0.1:${(address as AddressInfo).port}/`;

  const warmupPage = await browser.newPage();
  try {
    await warmupPage.goto(fixtureUrl);
    await expect(warmupPage.getByRole("heading", { name: "Plugins" })).toBeVisible({
      timeout: 120_000,
    });
  } finally {
    await warmupPage.close();
  }
});

test.afterAll(async () => {
  await fixtureServer?.close();
});

test.beforeEach(async ({ page }) => {
  await page.goto(fixtureUrl);
  await expect(page.getByRole("heading", { name: "Plugins" })).toBeVisible();
});

test("plugin catalog preserves keyboard focus through expansion", async ({ page }) => {
  const showAll = page.getByRole("button", { name: /Show all/ }).first();

  await showAll.focus();
  await expect(showAll).toBeFocused();
  await showAll.press("Enter");

  const revealedPlugin = page.getByRole("button", {
    name: "View GitHub plugin details",
  });
  await expect(revealedPlugin).toBeFocused();

  await page.keyboard.press("Tab");
  await expect(page.getByRole("button", { name: "Add GitHub" })).toBeFocused();
});

test("plugin preview icons remain visible through pointer expansion", async ({
  page,
}) => {
  const showAll = page.getByRole("button", { name: /Show all/ }).first();
  const flights = page.locator('[data-slot="plugin-artwork-flight"]');
  const revealedGitHubArtwork = page
    .locator('[data-slot="plugin-list-item"][data-plugin-id="github"]')
    .locator('[data-slot="plugin-artwork"]');

  expect(
    await showAll.evaluate(
      (button) =>
        new Promise((resolveSnapshot) => {
          button.dispatchEvent(
            new MouseEvent("click", { bubbles: true, detail: 1, view: window })
          );
          requestAnimationFrame(() => {
            resolveSnapshot({
              flightCount: document.querySelectorAll(
                '[data-slot="plugin-artwork-flight"]'
              ).length,
              flightIconCount: document.querySelectorAll(
                '[data-slot="plugin-artwork-flight"] svg'
              ).length,
              targetVisibility: getComputedStyle(
                document.querySelector<HTMLElement>(
                  '[data-slot="plugin-list-item"][data-plugin-id="github"] [data-slot="plugin-artwork"]'
                )!
              ).visibility,
            });
          });
        })
    )
  ).toEqual({
    flightCount: 2,
    flightIconCount: 4,
    targetVisibility: "hidden",
  });

  await expect(flights).toHaveCount(0);
  await expect(revealedGitHubArtwork).toHaveCSS("visibility", "visible");
});

test("large plugin expansion reveals rows in order at an intermediate frame", async ({
  page,
}) => {
  await page.addInitScript(() => {
    const originalAnimate = Element.prototype.animate;
    const revealAnimations: Animation[] = [];

    (
      window as typeof window & {
        commaPluginRevealAnimations?: Animation[];
      }
    ).commaPluginRevealAnimations = revealAnimations;
    Element.prototype.animate = function (
      keyframes: Keyframe[] | PropertyIndexedKeyframes | null,
      options?: number | KeyframeAnimationOptions
    ) {
      const animation = originalAnimate.call(this, keyframes, options);

      if (this instanceof HTMLElement && this.dataset.slot === "plugin-list-item") {
        animation.pause();
        animation.currentTime = 0;
        revealAnimations.push(animation);
      }

      return animation;
    };
  });
  await page.goto(new URL("?hiddenPluginCount=10", fixtureUrl).toString());

  const showAll = page.getByRole("button", { name: /Show all/ }).first();
  await expect(showAll.locator("[data-plugin-id]")).toHaveCount(3);

  const snapshot = await showAll.evaluate(async (button) => {
    button.dispatchEvent(
      new MouseEvent("click", { bubbles: true, detail: 1, view: window })
    );
    await new Promise<void>((resolveCommit) => setTimeout(resolveCommit, 0));

    const revealAnimations =
      (
        window as typeof window & {
          commaPluginRevealAnimations?: Animation[];
        }
      ).commaPluginRevealAnimations ?? [];
    for (const animation of revealAnimations) {
      animation.currentTime = 60;
    }
    await new Promise<void>((resolveFrame) =>
      requestAnimationFrame(() => resolveFrame())
    );

    const rows = Array.from(
      document.querySelectorAll<HTMLElement>(
        '.comma-plugin-reveal [data-slot="plugin-list-item"]'
      )
    );
    const opacities = rows.map((row) => Number(getComputedStyle(row).opacity));
    const firstTransparentIndex = opacities.findIndex((opacity) => opacity <= 0.01);
    const firstOpaqueAfterTransparent = opacities.findIndex(
      (opacity, index) => index > firstTransparentIndex && opacity >= 0.99
    );
    const result = {
      animationCount: revealAnimations.length,
      firstOpaqueAfterTransparent,
      firstTransparentIndex,
      opacities,
      rowIds: rows.map((row) => row.dataset.pluginId),
    };

    for (const animation of revealAnimations) {
      animation.cancel();
    }
    return result;
  });

  expect(snapshot.rowIds).toHaveLength(10);
  expect(snapshot.animationCount).toBe(10);
  expect(snapshot.opacities[0]).toBeGreaterThan(snapshot.opacities[1]!);
  expect(snapshot.opacities[1]).toBeGreaterThan(0);
  expect(snapshot.firstTransparentIndex).toBe(2);
  expect(snapshot.firstOpaqueAfterTransparent).toBe(-1);
});

test("plugin search exposes a visible keyboard focus treatment", async ({ page }) => {
  const search = page.getByRole("textbox", { name: "Search plugins" });
  const wrapper = search.locator("..");
  const restingShadow = await wrapper.evaluate(
    (element) => getComputedStyle(element).boxShadow
  );

  await page.keyboard.press("Tab");
  await page.keyboard.press("Tab");
  await expect(search).toBeFocused();

  await expect
    .poll(() => wrapper.evaluate((element) => getComputedStyle(element).boxShadow))
    .not.toBe(restingShadow);
});

test("plugin search keeps its resting outline on pointer focus", async ({ page }) => {
  const search = page.getByRole("textbox", { name: "Search plugins" });
  const wrapper = search.locator("..");
  const restingShadow = await wrapper.evaluate(
    (element) => getComputedStyle(element).boxShadow
  );

  await search.click();
  await expect(search).toBeFocused();
  // Let the wrapper's shadow transition settle before reading it.
  await page.waitForTimeout(300);

  expect(await wrapper.evaluate((element) => getComputedStyle(element).boxShadow)).toBe(
    restingShadow
  );
});

test("installed plugins are not exposed as installable category rows", async ({
  page,
}) => {
  await expect(page.getByRole("button", { name: "Add Notion" })).toHaveCount(0);
  await expect(page.getByText("Notion", { exact: true })).toHaveCount(1);
});

test("installed plugin cards open the selected plugin", async ({ page }) => {
  await page.getByRole("button", { name: "View Notion plugin details" }).click();

  await expect(page.getByText("Opened plugin: notion", { exact: true })).toBeVisible();
});

test("plugin detail exposes the plugin name as its level-one heading", async ({
  page,
}) => {
  const detail = page.locator('[data-slot="plugin-detail"]');

  await expect(detail.getByRole("heading", { level: 1, name: "Linear" })).toBeVisible();
});

test("zh-CN fixture localizes catalog, detail, and dynamic accessibility copy", async ({
  page,
}) => {
  await page.goto(new URL("?locale=zh-CN", fixtureUrl).toString());
  await expect(page.locator("html")).toHaveAttribute("lang", "zh-CN");

  const catalog = page.locator('[data-slot="plugin-catalog"]');
  await expect(catalog.getByRole("heading", { level: 1, name: "插件" })).toBeVisible();

  const search = catalog.getByRole("textbox", { name: "搜索插件" });
  await expect(search).toHaveAttribute("placeholder", "搜索插件…");
  await expect(catalog.getByText("已安装", { exact: true })).toHaveCount(2);
  await expect(
    catalog.getByRole("button", { name: "查看 Notion 插件详情" })
  ).toBeVisible();
  await expect(catalog.getByRole("button", { name: "添加 Linear" })).toBeVisible();

  const showAll = catalog.getByRole("button", { name: "显示全部 效率 插件" });
  await expect(showAll).toHaveText("显示全部");

  await search.fill("missing-plugin");
  await expect(catalog.getByText("未找到插件", { exact: true })).toBeVisible();
  await search.fill("");

  const detail = page.locator('[data-slot="plugin-detail"]');
  await expect(detail.getByRole("button", { name: "返回插件列表" })).toBeVisible();
  await expect(detail.getByRole("heading", { name: "描述" })).toBeVisible();
  await expect(detail.getByRole("heading", { name: "MCP" })).toBeVisible();
  await expect(detail.getByRole("heading", { name: "技能" })).toBeVisible();

  const install = detail.getByRole("button", { name: "将 Linear 添加到 Comma" });
  await expect(install).toHaveText("添加到 Comma");
  await install.click();
  await expect(detail.getByRole("button", { name: "卸载 Linear" })).toBeVisible();
  await expect(
    detail.getByRole("button", { name: "在聊天中试用 Linear" })
  ).toBeVisible();
});
