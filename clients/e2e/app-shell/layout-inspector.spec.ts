import { expect, test, type Locator, type Page } from "@playwright/test";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import localGroupSelectors from "../../vite/comma-tailwind";
import { resolve } from "node:path";
import type { AddressInfo } from "node:net";
import { fileURLToPath } from "node:url";
import {
  createBuiltFixtureServer,
  type BuiltFixtureServer,
} from "../helpers/built-fixture";
import { layoutInspectorSourcePlugin } from "../../packages/layout-inspector/src/vite";

const currentDir = fileURLToPath(new URL(".", import.meta.url));
const clientsRoot = resolve(currentDir, "../..");
const repositoryRoot = resolve(clientsRoot, "..");
const fixtureRoot = resolve(currentDir, "fixtures/layout-inspector");

let fixtureServer: BuiltFixtureServer | undefined;
let fixtureUrl = "";

test.beforeAll(async () => {
  // Source annotations remain enabled in the build; these cases assert their
  // actual file/line output as well as CSS provenance and interactive geometry.
  fixtureServer = await createBuiltFixtureServer({
    cacheDir: resolve(clientsRoot, "node_modules/.vite/layout-inspector-e2e"),
    configFile: false,
    define: {
      "process.env.NODE_ENV": JSON.stringify("test"),
    },
    plugins: [
      layoutInspectorSourcePlugin({
        enabled: true,
        root: repositoryRoot,
      }),
      react(),
      tailwindcss({ optimize: false }),
      localGroupSelectors(),
    ],
    resolve: {
      alias: {
        "@comma/layout-inspector": resolve(
          clientsRoot,
          "packages/layout-inspector/src/index.ts"
        ),
        "@comma/ui/styles.css": resolve(clientsRoot, "packages/ui/src/styles.css"),
        "@comma/ui": resolve(clientsRoot, "packages/ui/src/index.ts"),
      },
    },
    root: fixtureRoot,
    server: {
      host: "127.0.0.1",
      port: 0,
    },
  });

  const address = fixtureServer.httpServer?.address();
  if (!address || typeof address === "string") {
    throw new Error("Layout Inspector fixture server did not expose a TCP port.");
  }

  fixtureUrl = `http://127.0.0.1:${(address as AddressInfo).port}/`;
});

test.afterAll(async () => {
  await fixtureServer?.close();
});

test("layout inspector stays interactive above a portalled menu", async ({ page }) => {
  await page.goto(`${fixtureUrl}?open-menu`);

  const settingsItem = page.locator(".fixture-menu-settings-label");
  await settingsItem.hover();
  await settingsItem.click();

  const panel = page.getByTestId("layout-inspector-panel");
  await expect(panel).toBeVisible();
  await expect(panel.locator("h2")).toContainText("fixture-menu-settings-label");

  await panel.getByRole("button", { name: "Inspector settings" }).click();

  await expect(panel.getByRole("dialog", { name: "Inspector settings" })).toBeVisible();
  await expect(panel.locator("h2")).toContainText("fixture-menu-settings-label");
  await expect(page.locator('[data-slot="menu"]')).toBeVisible();
  await expect(settingsItem).toBeAttached();
  await expect(page.locator(".comma-layout-inspector")).not.toHaveAttribute("inert");
});

test("layout inspector copies selected source without edits and refreshes for a new target", async ({
  page,
}) => {
  await installClipboardCapture(page);
  await page.goto(fixtureUrl);
  const target = page.getByTestId("layout-target");
  const panel = await pinTarget(page, target);
  await expect(panel.getByTestId("copy-layout-prompt")).toBeDisabled();
  const source = await target.getAttribute("data-comma-source");
  expect(source).toMatch(/clients\/.*\.tsx:\d+:\d+$/);
  const placement = await panel.getAttribute("data-placement");
  const copySource = panel.getByRole("button", { name: "Copy source", exact: true });
  await copySource.click();
  await expect(copySource).toHaveText("Copied");
  const report = await readCopiedPrompt(page);
  expect(report).toContain(`Source location: \`${source}\``);
  expect(report).toContain('`[data-testid="layout-target"]`');
  expect(report).toContain("Classes (source-search hint)");
  expect(report).toContain("DOM context:");
  expect(report).toContain("sibling position:");
  expect(report).not.toContain("Requested source change");
  await expect(panel).toHaveAttribute("data-placement", placement!);
  await expect(panel.getByTestId("copy-layout-prompt")).toBeDisabled();

  // Source copying stays independent of pending style edits.
  await panel.getByLabel("Padding top variable").selectOption("--spacing-xl");
  const preview = await target.getAttribute("style");
  await copySource.click();
  expect(await readCopiedPrompt(page)).toBe(report);
  await expect(target).toHaveAttribute("style", preview!);
  await expect(panel.getByTestId("copy-layout-prompt")).toBeEnabled();

  await page.keyboard.press("Escape");
  const nextTarget = page.getByTestId("transition-target");
  await nextTarget.evaluate((element) => element.removeAttribute("data-comma-source"));
  const nextPanel = await pinTarget(page, nextTarget);
  const nextCopy = nextPanel.getByRole("button", { name: "Copy source", exact: true });
  await expect(nextCopy).toHaveText("Copy source");
  await nextCopy.focus();
  await page.keyboard.press("Enter");
  await expect(nextCopy).toHaveText("Copied");
  const fallback = await readCopiedPrompt(page);
  expect(fallback).toContain("Source location unavailable");
  expect(fallback).toContain('[data-testid="transition-target"]');
  expect(fallback).not.toContain('[data-testid="layout-target"]');
});

test("layout inspector previews tokens and copies pending source changes", async ({
  page,
}) => {
  await installClipboardCapture(page);
  await page.goto(fixtureUrl);
  const target = page.getByTestId("layout-target");
  const targetBox = await target.boundingBox();
  if (!targetBox) throw new Error("Layout target did not have a bounding box.");

  const inspectPoint = {
    x: targetBox.x + 8,
    y: targetBox.y + 8,
  };
  await page.mouse.move(inspectPoint.x, inspectPoint.y);

  await expect(page.getByRole("status")).toContainText("hover to inspect");
  await expect(page.getByTestId("layout-inspector-border-box")).toBeVisible();
  await expect(page.getByTestId("layout-inspector-dimension")).toContainText(
    "344px × 220px"
  );
  await expect(page.locator('[data-inspector-segment="padding-top"]')).toHaveAttribute(
    "data-inspector-value",
    "16"
  );
  await expect(page.locator('[data-inspector-segment="padding-left"]')).toHaveAttribute(
    "data-inspector-value",
    "4"
  );
  await expect(
    page.locator(
      '.comma-layout-inspector__segment-label[data-inspector-property="padding-left"]'
    )
  ).toHaveText("p 4px");
  const paddingLabelLayer = await page
    .locator(
      '.comma-layout-inspector__segment-label[data-inspector-property="padding-left"]'
    )
    .evaluate((element) => Number.parseInt(getComputedStyle(element).zIndex, 10));
  const borderBoxLayer = await page
    .getByTestId("layout-inspector-border-box")
    .evaluate((element) => Number.parseInt(getComputedStyle(element).zIndex, 10));
  expect(paddingLabelLayer).toBeGreaterThan(borderBoxLayer);
  await expect(page.locator('[data-inspector-segment="margin-left"]')).toHaveAttribute(
    "data-inspector-value",
    "16"
  );
  await expect(
    page.locator('.comma-layout-inspector__segment[data-inspector-kind="gap"]')
  ).toHaveCount(2);
  await expect(
    page
      .locator(
        '.comma-layout-inspector__segment-label[data-inspector-property="row-gap"]'
      )
      .first()
  ).toHaveText("gap 12px");
  await expect(
    page.locator('.comma-layout-inspector__segment[data-inspector-kind="border"]')
  ).toHaveCount(0);

  await page.mouse.click(inspectPoint.x, inspectPoint.y);

  const panel = page.getByTestId("layout-inspector-panel");
  await expect(panel).toBeVisible();
  await expect(panel).toContainText("grid");
  const panelBackdropFilter = await panel.evaluate(
    (element) => getComputedStyle(element).backdropFilter
  );
  expect(panelBackdropFilter).toContain("blur(12px)");
  expect(panelBackdropFilter).toMatch(/saturate\((?:180%|1\.8)\)/);
  await expect
    .poll(() =>
      panel
        .locator(".comma-layout-inspector__panel-header")
        .evaluate((element) =>
          getComputedStyle(element).getPropertyValue("-webkit-app-region")
        )
    )
    .toBe("no-drag");
  await expect(
    panel.locator(":scope > .comma-layout-inspector__panel-section")
  ).toHaveCount(2);
  const boxModel = panel.getByTestId("layout-inspector-box-model");
  const properties = panel.locator(":scope > .comma-layout-inspector__properties");
  const changesCard = panel.getByTestId("layout-inspector-pending");
  await expect(boxModel).toBeVisible();
  await expect(
    boxModel.locator(":scope > .comma-layout-inspector__box-layer")
  ).toHaveAttribute("data-inspector-kind", "margin");
  await expect(boxModel.locator(".comma-layout-inspector__box-diagram")).toHaveCount(0);
  await expect(properties).toBeVisible();
  await expect(changesCard).toBeVisible();
  const boxModelBox = await boxModel.boundingBox();
  const propertiesBox = await properties.boundingBox();
  const changesCardBox = await changesCard.boundingBox();
  if (!boxModelBox || !propertiesBox || !changesCardBox) {
    throw new Error("Inspector priority sections did not have browser bounds.");
  }
  expect(boxModelBox.y).toBeLessThan(propertiesBox.y);
  expect(propertiesBox.height).toBeGreaterThanOrEqual(220);
  expect(propertiesBox.y).toBeLessThan(changesCardBox.y);
  await expect(panel).not.toContainText("No pending changes");
  await expect(panel).not.toContainText("Value format");
  await expect(panel).not.toContainText("Variable previews");
  await expect(changesCard).toContainText("Changes");
  await expect(changesCard).toContainText("0");
  await expect(changesCard.getByRole("button", { name: "Clear all" })).toBeDisabled();
  await expect(page.getByTestId("copy-layout-prompt")).toBeDisabled();

  const settingsButton = panel.getByRole("button", {
    name: "Inspector settings",
  });
  await expect(settingsButton.locator("svg")).toBeVisible();
  await settingsButton.click();
  const settingsMenu = panel.getByRole("dialog", {
    name: "Inspector settings",
  });
  await expect(settingsMenu).toBeVisible();
  const panelBox = await panel.boundingBox();
  const settingsMenuBox = await settingsMenu.boundingBox();
  if (!panelBox || !settingsMenuBox) {
    throw new Error("Inspector panel and settings menu did not have browser bounds.");
  }
  expect(settingsMenuBox.width).toBeGreaterThanOrEqual(270);
  expect(settingsMenuBox.x).toBeGreaterThanOrEqual(panelBox.x);
  expect(settingsMenuBox.x + settingsMenuBox.width).toBeLessThanOrEqual(
    panelBox.x + panelBox.width + 1
  );
  await expect
    .poll(() =>
      settingsMenu.evaluate((element) =>
        getComputedStyle(element).getPropertyValue("-webkit-app-region")
      )
    )
    .toBe("no-drag");
  await expect(settingsMenu.getByRole("radio", { name: "Pixels" })).toBeChecked();
  await expect(settingsMenu.getByRole("radio", { name: "Both" })).toHaveCount(0);
  await expect(
    settingsMenu.getByRole("switch", { name: "Show padding overlay" })
  ).toBeChecked();
  await expect(
    settingsMenu.getByRole("switch", { name: "Show gap overlay" })
  ).toBeChecked();
  const borderOverlaySwitch = settingsMenu.getByRole("switch", {
    name: "Show border overlay",
  });
  await expect(borderOverlaySwitch).not.toBeChecked();
  await expect(settingsMenu.getByText("Layers", { exact: true })).toHaveCount(0);

  const unitsLabelBox = await settingsMenu
    .getByText("Units", { exact: true })
    .boundingBox();
  const unitsControlBox = await settingsMenu
    .locator(".comma-layout-inspector__segmented-control")
    .boundingBox();
  if (!unitsLabelBox || !unitsControlBox) {
    throw new Error("Compact settings rows did not have browser bounds.");
  }
  expect(unitsLabelBox.x + unitsLabelBox.width).toBeLessThan(unitsControlBox.x);
  expect(unitsControlBox.height).toBeLessThanOrEqual(32);

  for (const kind of ["padding", "border", "gap"] as const) {
    const row = settingsMenu.locator(
      `.comma-layout-inspector__overlay-settings > label[data-inspector-kind="${kind}"]`
    );
    const labelBox = await row
      .locator(".comma-layout-inspector__setting-label")
      .boundingBox();
    const controlBox = await row
      .locator(".comma-layout-inspector__setting-control")
      .boundingBox();
    if (!labelBox || !controlBox) {
      throw new Error(`${kind} settings row did not have browser bounds.`);
    }
    expect(labelBox.x + labelBox.width).toBeLessThan(controlBox.x);
    expect(controlBox.height).toBeLessThanOrEqual(32);
  }

  await borderOverlaySwitch.click();
  await expect(
    page.locator('.comma-layout-inspector__segment[data-inspector-kind="border"]')
  ).toHaveCount(4);
  await settingsButton.click();
  await expect(settingsMenu).toBeHidden();

  const paddingTopSelect = panel.getByLabel("Padding top variable");
  await expect
    .poll(() =>
      panel
        .getByLabel("Width variable", { exact: true })
        .evaluate((select) => (select as HTMLSelectElement).selectedOptions[0]?.text)
    )
    // The fixture also contains unresolved nested width/height selectors.
    // The bounded provenance contract keeps those properties computed rather
    // than reimplementing CSS nesting.
    .toBe("Original · 344px");
  await expect
    .poll(() =>
      panel
        .getByLabel("Height variable", { exact: true })
        .evaluate((select) => (select as HTMLSelectElement).selectedOptions[0]?.text)
    )
    .toBe("Original · 220px");
  await expect
    .poll(() =>
      paddingTopSelect.evaluate(
        (select) => (select as HTMLSelectElement).selectedOptions[0]?.text
      )
    )
    .toBe("Original · 16px");
  const paddingTopRow = paddingTopSelect.locator("..").locator("..");
  const propertyLabelBox = await paddingTopRow.locator("dt").boundingBox();
  const propertySelectBox = await paddingTopSelect.boundingBox();
  if (!propertyLabelBox || !propertySelectBox) {
    throw new Error("Padding property row did not have browser bounds.");
  }
  expect(propertyLabelBox.x + propertyLabelBox.width).toBeLessThanOrEqual(
    propertySelectBox.x
  );
  await expect(
    paddingTopRow.locator(".comma-layout-inspector__property-icon")
  ).toHaveAttribute("data-direction", "top");

  await settingsButton.click();
  await settingsMenu.getByText("Variables", { exact: true }).click();
  await expect(page.getByTestId("layout-inspector-dimension")).toContainText(
    "344px × 220px"
  );
  await expect(
    page
      .locator(
        '.comma-layout-inspector__segment-label[data-inspector-property="row-gap"]'
      )
      .first()
  ).toHaveText("gap 12px");

  await settingsMenu.getByText("Pixels", { exact: true }).click();
  await expect(page.getByTestId("layout-inspector-dimension")).toContainText(
    "344px × 220px"
  );
  await expect(
    page
      .locator(
        '.comma-layout-inspector__segment-label[data-inspector-property="row-gap"]'
      )
      .first()
  ).toHaveText("gap 12px");
  await settingsButton.click();

  const spacingToken = panel.getByText("var(--spacing-xl)").first();
  await expect(spacingToken).toBeVisible();
  expect(
    await spacingToken.evaluate((element) => element.scrollWidth <= element.clientWidth)
  ).toBe(true);
  await expect(page.getByTestId("activation-count")).toHaveText("Activation count: 0");

  await panel.getByLabel("Margin top variable").selectOption("--spacing-2xl");
  await expect
    .poll(() => target.evaluate((element) => getComputedStyle(element).marginTop))
    .toBe("20px");
  await expect
    .poll(() =>
      panel.getByLabel("Margin top variable").locator("option").first().textContent()
    )
    .toBe("Restore · --spacing-xl · 16px");

  const pending = page.getByTestId("layout-inspector-pending");
  await expect(pending).toBeVisible();
  await expect(pending.getByRole("button", { name: /Changes\s*1/ })).toBeEnabled();
  await expect(pending).not.toContainText("margin-top");

  await pending.getByRole("button", { name: /Changes\s*1/ }).click();
  const changeList = pending.getByRole("dialog", {
    name: "Layout change list",
  });
  await expect(changeList).toBeVisible();
  const changeListBox = await changeList.boundingBox();
  if (!changeListBox) {
    throw new Error("Layout change menu did not have browser bounds.");
  }
  expect(changeListBox.x).toBeGreaterThanOrEqual(panelBox.x);
  expect(changeListBox.x + changeListBox.width).toBeLessThanOrEqual(
    panelBox.x + panelBox.width + 1
  );
  await expect(changeList).toContainText("margin-top");
  await expect(changeList).toContainText("var(--spacing-2xl)");

  await panel.getByLabel("Margin top variable").selectOption("");
  await expect(changeList).toBeHidden();
  await expect(pending).toContainText("Changes");
  await expect(pending).toContainText("0");
  await expect
    .poll(() => target.evaluate((element) => getComputedStyle(element).marginTop))
    .toBe("16px");

  await panel.getByLabel("Margin top variable").selectOption("--spacing-2xl");
  await expect(pending.getByRole("button", { name: /Changes\s*1/ })).toBeEnabled();

  await page.getByTestId("copy-layout-prompt").click();
  await expect(page.getByTestId("copy-layout-prompt")).toHaveText("Copied");
  const copiedPrompt = await page.evaluate(
    () =>
      (
        window as Window & {
          copiedLayoutPrompt?: string;
        }
      ).copiedLayoutPrompt
  );
  expect(copiedPrompt).toContain('`[data-testid="layout-target"]`');
  expect(copiedPrompt).toMatch(
    /`clients\/e2e\/app-shell\/fixtures\/layout-inspector\/src\/main\.tsx:\d+:\d+`/
  );
  expect(copiedPrompt).toContain(
    "margin-top: var(--spacing-xl) [16px] → var(--spacing-2xl) [20px]"
  );

  await pending.getByRole("button", { name: "Clear all" }).click();
  await expect(pending.getByRole("button", { name: /Changes\s*0/ })).toBeDisabled();
  await expect(page.getByTestId("copy-layout-prompt")).toBeDisabled();
  await expect
    .poll(() => target.evaluate((element) => getComputedStyle(element).marginTop))
    .toBe("16px");
  await expect(page.getByTestId("activation-count")).toHaveText("Activation count: 0");

  await page.keyboard.press("Escape");
  await expect(panel).toBeHidden();
  await page.keyboard.press("Escape");
  await expect(page.getByRole("status")).toBeHidden();
});

test("layout inspector preserves previews while hidden until they are cleared", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  const target = page.getByTestId("transition-target");
  const baseline = await readInlineAndComputed(target, "margin-top");

  let panel = await pinTarget(page, target);
  await panel.getByLabel("Margin top variable").selectOption("--spacing-transition");
  await expect
    .poll(() => target.evaluate((element) => getComputedStyle(element).marginTop))
    .toBe("96px");
  const applied = await readInlineAndComputed(target, "margin-top");

  await page.keyboard.press("Escape");
  await expect(panel).toBeHidden();
  await page.keyboard.press("Escape");
  await expect(page.getByRole("status")).toBeHidden();
  expect(await readInlineAndComputed(target, "margin-top")).toEqual(applied);

  await page.keyboard.press("Control+Shift+L");
  await expect(page.getByRole("status")).toBeVisible();
  panel = await pinTarget(page, target);
  await expect(panel.getByRole("button", { name: /Changes\s*1/ })).toBeEnabled();
  await expect(panel.getByLabel("Margin top variable")).toHaveValue(
    "--spacing-transition"
  );
  await panel.getByRole("button", { name: "Clear all" }).click();
  expect(await readInlineAndComputed(target, "margin-top")).toEqual(baseline);

  await panel.getByLabel("Margin top variable").selectOption("--spacing-transition");
  await expect
    .poll(() => target.evaluate((element) => getComputedStyle(element).marginTop))
    .toBe("96px");

  await page.keyboard.press("Control+Shift+L");
  await expect(page.getByRole("status")).toBeHidden();
  expect(await readInlineAndComputed(target, "margin-top")).toEqual(applied);

  await page.keyboard.press("Control+Shift+L");
  await expect(panel).toBeVisible();
  await expect(panel.getByRole("button", { name: /Changes\s*1/ })).toBeEnabled();
  await panel.getByRole("button", { name: "Clear all" }).click();
  expect(await readInlineAndComputed(target, "margin-top")).toEqual(baseline);
});

test("layout inspector uses winning declarations in copied source changes", async ({
  page,
}) => {
  await installClipboardCapture(page);
  await page.goto(fixtureUrl);
  const target = page.getByTestId("cascade-target");
  let panel = await pinTarget(page, target);
  const marginTop = panel.getByLabel("Margin top variable");

  await expect
    .poll(() =>
      marginTop.evaluate(
        (select) => (select as HTMLSelectElement).selectedOptions[0]?.text
      )
    )
    .toBe("Original · 13px");

  await marginTop.selectOption("--spacing-2xl");
  await page.getByTestId("copy-layout-prompt").click();
  const copiedPrompt = await readCopiedPrompt(page);

  expect(copiedPrompt).toContain("margin-top: 13px [13px] → var(--spacing-2xl) [20px]");
  expect(copiedPrompt).not.toContain("margin-top: var(--spacing-xl) [13px]");
  expect(copiedPrompt).not.toContain("var(--spacing-transition) [13px]");

  await panel.getByRole("button", { name: "Clear all" }).click();
  await page.keyboard.press("Escape");

  const sameValueTarget = page.getByTestId("cascade-same-target");
  panel = await pinTarget(page, sameValueTarget);
  const marginLeft = panel.getByLabel("Margin left variable");
  await expect
    .poll(() =>
      marginLeft.evaluate(
        (select) => (select as HTMLSelectElement).selectedOptions[0]?.text
      )
    )
    .toBe("Original · 40px");

  await marginLeft.selectOption("--spacing-2xl");
  await page.getByTestId("copy-layout-prompt").click();
  const sameValuePrompt = await readCopiedPrompt(page);

  expect(sameValuePrompt).toContain(
    "margin-left: 40px [40px] → var(--spacing-2xl) [20px]"
  );
  expect(sameValuePrompt).not.toContain("var(--spacing-loser)");
});

test("layout inspector keeps animated spacing winners ambiguous", async ({ page }) => {
  await installClipboardCapture(page);
  await page.goto(fixtureUrl);
  const target = page.getByTestId("animation-cascade-target");
  await expect
    .poll(() => target.evaluate((element) => getComputedStyle(element).marginTop))
    .toBe("16px");
  const marginAfterChangingLoser = await target.evaluate((element) => {
    const style = (element as HTMLElement).style;
    style.setProperty("--fixture-animation-spacing-loser", "80px");
    const margin = getComputedStyle(element).marginTop;
    style.removeProperty("--fixture-animation-spacing-loser");
    return margin;
  });
  expect(marginAfterChangingLoser).toBe("16px");

  const panel = await pinTarget(page, target);
  const marginTop = panel.getByLabel("Margin top variable");
  await expect
    .poll(() =>
      marginTop.evaluate(
        (select) => (select as HTMLSelectElement).selectedOptions[0]?.text
      )
    )
    .toBe("Original · 16px");

  await marginTop.selectOption("--spacing-2xl");
  await page.getByTestId("copy-layout-prompt").click();
  const prompt = await readCopiedPrompt(page);
  expect(prompt).not.toContain("--fixture-animation-spacing-loser");
});

test("layout inspector does not promote a losing variable behind width auto", async ({
  page,
}) => {
  await installClipboardCapture(page);
  await page.goto(fixtureUrl);
  const target = page.getByTestId("width-auto-target");
  const panel = await pinTarget(page, target);
  const width = panel.getByLabel("Width variable", { exact: true });

  await expect
    .poll(() =>
      width.evaluate((select) => (select as HTMLSelectElement).selectedOptions[0]?.text)
    )
    .toBe("Original · 100px");

  await width.selectOption("--spacing-3xl");
  await page.getByTestId("copy-layout-prompt").click();
  const prompt = await readCopiedPrompt(page);

  expect(prompt).toContain("width: 100px [100px] → var(--spacing-3xl) [24px]");
  expect(prompt).not.toContain("--fixture-width-loser");
});

test("layout inspector keeps unknown container and scope winners ambiguous", async ({
  page,
}) => {
  await installClipboardCapture(page);
  await page.goto(fixtureUrl);

  for (const { loser, testId } of [
    {
      loser: "--fixture-import-loser",
      testId: "import-target",
    },
    {
      loser: "--fixture-inherit-loser",
      testId: "inherit-target",
    },
    {
      loser: "--fixture-container-loser",
      testId: "container-query-target",
    },
    {
      loser: "--fixture-nested-container-loser",
      testId: "nested-container-target",
    },
    {
      loser: "--fixture-nested-sibling-loser",
      testId: "nested-sibling-target",
    },
    {
      loser: "--fixture-scope-loser",
      testId: "scope-target",
    },
    {
      loser: "--fixture-scope-loser",
      testId: "scope-nesting-target",
    },
    {
      loser: "--fixture-nested-scope-loser",
      testId: "nested-scope-target",
    },
    {
      loser: "--fixture-overlap-scope-loser",
      testId: "overlap-scope-target",
    },
  ]) {
    const target = page.getByTestId(testId);
    const widthAfterChangingLoser = await target.evaluate((element, variable) => {
      (element as HTMLElement).style.setProperty(variable, "80px");
      const width = getComputedStyle(element).width;
      (element as HTMLElement).style.removeProperty(variable);
      return width;
    }, loser);
    expect(widthAfterChangingLoser).toBe("100px");

    const panel = await pinTarget(page, target);
    const width = panel.getByLabel("Width variable", { exact: true });

    await expect
      .poll(() =>
        width.evaluate(
          (select) => (select as HTMLSelectElement).selectedOptions[0]?.text
        )
      )
      .toBe("Original · 100px");

    await width.selectOption("--spacing-3xl");
    await page.getByTestId("copy-layout-prompt").click();
    const prompt = await readCopiedPrompt(page);

    expect(prompt).toContain("width: 100px [100px] → var(--spacing-3xl) [24px]");
    expect(prompt).not.toContain(loser);

    await panel.getByRole("button", { name: "Clear all" }).click();
    await page.keyboard.press("Escape");
  }
});

test("layout inspector keeps unrelated-subtree nesting winners ambiguous", async ({
  page,
}) => {
  await installClipboardCapture(page);
  await page.goto(fixtureUrl);
  await page.evaluate(() => {
    const triggerRegion = document.createElement("div");
    triggerRegion.className = "fixture-unrelated-nesting-trigger-region";
    triggerRegion.innerHTML =
      '<span class="fixture-unrelated-nesting-trigger">Nesting trigger</span>';
    document.body.append(triggerRegion);
  });
  const target = page.getByTestId("unrelated-subtree-nesting-target");
  const widthAfterChangingLoser = await target.evaluate((element) => {
    const style = (element as HTMLElement).style;
    style.setProperty("--fixture-unrelated-nesting-loser", "80px");
    const width = getComputedStyle(element).width;
    style.removeProperty("--fixture-unrelated-nesting-loser");
    return width;
  });
  expect(widthAfterChangingLoser).toBe("100px");

  const panel = await pinTarget(page, target);
  const width = panel.getByLabel("Width variable", { exact: true });
  await expect
    .poll(() =>
      width.evaluate((select) => (select as HTMLSelectElement).selectedOptions[0]?.text)
    )
    .toBe("Original · 100px");

  await width.selectOption("--spacing-3xl");
  await page.getByTestId("copy-layout-prompt").click();
  const prompt = await readCopiedPrompt(page);
  expect(prompt).toContain("width: 100px [100px] → var(--spacing-3xl) [24px]");
  expect(prompt).not.toContain("--fixture-unrelated-nesting-loser");
});

test("layout inspector keeps absent-parent nesting winners ambiguous", async ({
  page,
}) => {
  await installClipboardCapture(page);
  await page.goto(fixtureUrl);
  await expect(page.locator(".fixture-review-absent-trigger")).toHaveCount(0);

  const target = page.getByTestId("absent-trigger-nesting-target");
  const heightAfterChangingLoser = await target.evaluate((element) => {
    const style = (element as HTMLElement).style;
    style.setProperty("--fixture-absent-trigger-nesting-loser", "80px");
    const height = getComputedStyle(element).height;
    style.removeProperty("--fixture-absent-trigger-nesting-loser");
    return height;
  });
  expect(heightAfterChangingLoser).toBe("100px");

  const panel = await pinTarget(page, target);
  const height = panel.getByLabel("Height variable", { exact: true });
  await expect
    .poll(() =>
      height.evaluate(
        (select) => (select as HTMLSelectElement).selectedOptions[0]?.text
      )
    )
    .toBe("Original · 100px");

  await height.selectOption("--spacing-3xl");
  await page.getByTestId("copy-layout-prompt").click();
  const prompt = await readCopiedPrompt(page);
  expect(prompt).toContain("height: 100px [100px] → var(--spacing-3xl) [24px]");
  expect(prompt).not.toContain("--fixture-absent-trigger-nesting-loser");
});

test("layout inspector never disproves an unknown winner with a detached probe", async ({
  page,
}) => {
  await installClipboardCapture(page);
  await page.goto(fixtureUrl);
  const target = page.getByTestId("font-context-target");
  const computedWidth = await target.evaluate((element) => {
    const width = getComputedStyle(element).width;
    (element as HTMLElement).style.setProperty("--fixture-font-width-loser", width);
    return width;
  });
  const widthAfterChangingLoser = await target.evaluate((element) => {
    const style = (element as HTMLElement).style;
    const previous = style.getPropertyValue("--fixture-font-width-loser");
    (element as HTMLElement).style.setProperty("--fixture-font-width-loser", "80px");
    const width = getComputedStyle(element).width;
    style.setProperty("--fixture-font-width-loser", previous);
    return width;
  });
  expect(widthAfterChangingLoser).toBe(computedWidth);

  const panel = await pinTarget(page, target);
  const width = panel.getByLabel("Width variable", { exact: true });
  await expect
    .poll(() =>
      width.evaluate((select) => (select as HTMLSelectElement).selectedOptions[0]?.text)
    )
    .toBe(`Original · ${computedWidth}`);

  await width.selectOption("--spacing-3xl");
  await page.getByTestId("copy-layout-prompt").click();
  const prompt = await readCopiedPrompt(page);
  expect(prompt).not.toContain("--fixture-font-width-loser");
});

test("layout inspector evaluates declaration expressions on their source property", async ({
  page,
}) => {
  await installClipboardCapture(page);
  await page.goto(fixtureUrl);

  for (const testId of ["border-keyword-target", "border-shorthand-target"]) {
    const target = page.getByTestId(testId);
    const widthAfterChangingLoser = await target.evaluate((element) => {
      (element as HTMLElement).style.setProperty("--fixture-border-loser", "3px");
      const width = getComputedStyle(element).borderTopWidth;
      (element as HTMLElement).style.removeProperty("--fixture-border-loser");
      return width;
    });
    expect(widthAfterChangingLoser).toBe("1px");

    const panel = await pinTarget(page, target);
    const borderTop = panel.getByLabel("Border top width variable", {
      exact: true,
    });
    await expect
      .poll(() =>
        borderTop.evaluate(
          (select) => (select as HTMLSelectElement).selectedOptions[0]?.text
        )
      )
      .toBe("Original · 1px");

    await borderTop.selectOption("--fixture-border-width-choice");
    await page.getByTestId("copy-layout-prompt").click();
    const prompt = await readCopiedPrompt(page);
    expect(prompt).toContain(
      "border-top-width: 1px [1px] → var(--fixture-border-width-choice) [4px]"
    );
    expect(prompt).not.toContain("--fixture-border-loser");

    await panel.getByRole("button", { name: "Clear all" }).click();
    await page.keyboard.press("Escape");
  }
});

test("layout inspector ignores inactive top-level stylesheets for provenance", async ({
  page,
}) => {
  await installClipboardCapture(page);
  await page.goto(fixtureUrl);
  await expect
    .poll(() =>
      page.evaluate(() => {
        const mediaSheet = (
          document.getElementById("fixture-inactive-media-sheet") as HTMLStyleElement
        ).sheet;
        const disabledSheet = (
          document.getElementById("fixture-disabled-sheet") as HTMLStyleElement
        ).sheet;
        return {
          disabled: disabledSheet?.disabled,
          media: mediaSheet?.media.mediaText,
          mediaMatches: mediaSheet
            ? window.matchMedia(mediaSheet.media.mediaText).matches
            : undefined,
        };
      })
    )
    .toEqual({
      disabled: true,
      media: "print",
      mediaMatches: false,
    });

  for (const testId of ["inactive-media-sheet-target", "disabled-sheet-target"]) {
    const target = page.getByTestId(testId);
    const paddingAfterChangingInactiveVariable = await target.evaluate((element) => {
      const style = (element as HTMLElement).style;
      style.setProperty("--fixture-inactive-sheet-loser", "80px");
      const padding = getComputedStyle(element).paddingTop;
      style.removeProperty("--fixture-inactive-sheet-loser");
      return padding;
    });
    expect(paddingAfterChangingInactiveVariable).toBe("0px");

    const panel = await pinTarget(page, target);
    const paddingTop = panel.getByLabel("Padding top variable");
    const originalOption = paddingTop.locator("option:checked");
    await expect(originalOption).toContainText("0px");
    await expect(originalOption).not.toContainText("--fixture-inactive-sheet-loser");

    await paddingTop.selectOption("--spacing-2xl");
    await page.getByTestId("copy-layout-prompt").click();
    const prompt = await readCopiedPrompt(page);
    expect(prompt).toContain("padding-top: 0px [0px] → var(--spacing-2xl) [20px]");
    expect(prompt).not.toContain("--fixture-inactive-sheet-loser");

    await panel.getByRole("button", { name: "Clear all" }).click();
    await page.keyboard.press("Escape");
  }
});

test("layout inspector preserves distinct same-selector declaration candidates", async ({
  page,
}) => {
  await installClipboardCapture(page);
  await page.goto(fixtureUrl);
  const target = page.getByTestId("declaration-identity-target");
  const widthAfterChangingNonSourceVariable = await target.evaluate((element) => {
    const style = (element as HTMLElement).style;
    style.setProperty("--fixture-border-rule-loser", "5px");
    const width = getComputedStyle(element).borderTopWidth;
    style.removeProperty("--fixture-border-rule-loser");
    return width;
  });
  expect(widthAfterChangingNonSourceVariable).toBe("0px");

  const panel = await pinTarget(page, target);
  const borderTop = panel.getByLabel("Border top width variable", {
    exact: true,
  });
  await expect
    .poll(() =>
      borderTop.evaluate(
        (select) => (select as HTMLSelectElement).selectedOptions[0]?.text
      )
    )
    .toBe("Original · 0px");

  await borderTop.selectOption("--fixture-border-width-choice");
  await page.getByTestId("copy-layout-prompt").click();
  const prompt = await readCopiedPrompt(page);
  expect(prompt).toContain(
    "border-top-width: 0px [0px] → var(--fixture-border-width-choice) [0px]"
  );
  expect(prompt).not.toContain("--fixture-border-rule-loser");
});

test("layout inspector keeps implicit shadow scope winners ambiguous", async ({
  page,
}) => {
  await page.goto(fixtureUrl);

  for (const { id, testId } of [
    {
      id: "fixture-shadow-scope-target",
      testId: "shadow-scope-target",
    },
    {
      id: "fixture-shadow-nested-scope-target",
      testId: "shadow-nested-scope-target",
    },
    {
      id: "fixture-shadow-link-target",
      testId: "shadow-link-target",
    },
    {
      id: "fixture-shadow-host-nesting-target",
      testId: "shadow-host-nesting-target",
    },
  ]) {
    const target = page.getByTestId(testId);
    await expect
      .poll(() => target.evaluate((element) => getComputedStyle(element).width))
      .toBe("100px");
    const widthAfterChangingLoser = await page
      .getByTestId(testId)
      .evaluate((element) => {
        (element as HTMLElement).style.setProperty(
          "--fixture-shadow-scope-loser",
          "80px"
        );
        const width = getComputedStyle(element).width;
        (element as HTMLElement).style.removeProperty("--fixture-shadow-scope-loser");
        return width;
      });
    expect(widthAfterChangingLoser).toBe("100px");

    await expect
      .poll(() =>
        page.evaluate((targetId) => window.resolveShadowWidth?.(targetId) ?? null, id)
      )
      .toEqual({
        computed: "100px",
        confidence: "computed",
        variables: [],
      });
  }
});

test("layout inspector selects an element inside an open shadow root", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  const target = page.getByTestId("shadow-scope-target");
  await target.scrollIntoViewIfNeeded();
  const targetBox = await target.boundingBox();
  if (!targetBox) throw new Error("Shadow layout target did not have a bounding box.");

  const expectedNodeLabel =
    "div#fixture-shadow-scope-target.fixture-shadow-scope-target";
  await page.mouse.move(targetBox.x + 4, targetBox.y + 4);
  await expect(
    page.getByTestId("layout-inspector-dimension").locator("strong")
  ).toHaveText(expectedNodeLabel);

  await page.mouse.click(targetBox.x + 4, targetBox.y + 4);
  const panel = page.getByTestId("layout-inspector-panel");
  await expect(panel).toBeVisible();
  await expect(panel.getByRole("heading", { level: 2 })).toHaveText(expectedNodeLabel);
});

test("layout inspector keeps slotted cross-tree winners ambiguous", async ({
  page,
}) => {
  await installClipboardCapture(page);
  await page.goto(fixtureUrl);
  const target = page.getByTestId("slotted-provenance-target");
  await expect
    .poll(() =>
      target.evaluate((element) => {
        const ownRoot = element.getRootNode();
        const slotRoot = element.assignedSlot?.getRootNode();
        return {
          assigned: element.assignedSlot instanceof HTMLSlotElement,
          ownRootOpen: ownRoot instanceof ShadowRoot && ownRoot.mode === "open",
          rootsDiffer: ownRoot !== slotRoot,
          slotRootOpen: slotRoot instanceof ShadowRoot && slotRoot.mode === "open",
        };
      })
    )
    .toEqual({
      assigned: true,
      ownRootOpen: true,
      rootsDiffer: true,
      slotRootOpen: true,
    });
  const borderAfterChangingLoser = await target.evaluate((element) => {
    const style = (element as HTMLElement).style;
    style.setProperty("--fixture-slotted-border-width-loser", "8px");
    const width = getComputedStyle(element).borderTopWidth;
    style.removeProperty("--fixture-slotted-border-width-loser");
    return width;
  });
  expect(borderAfterChangingLoser).toBe("4px");

  const panel = await pinTargetWithLabel(
    page,
    target,
    "div#fixture-slotted-provenance-target.fixture-slotted-provenance-target"
  );
  const borderTop = panel.getByLabel("Border top width variable", {
    exact: true,
  });
  await expect
    .poll(() =>
      borderTop.evaluate(
        (select) => (select as HTMLSelectElement).selectedOptions[0]?.text
      )
    )
    .toBe("Original · 4px");

  await borderTop.selectOption("--fixture-slotted-border-width-choice");
  await expect
    .poll(() => readInlineAndComputed(target, "border-top-width"))
    .toEqual({
      computed: "4px",
      priority: "important",
      value: "var(--fixture-slotted-border-width-choice)",
    });
  await page.getByTestId("copy-layout-prompt").click();
  const prompt = await readCopiedPrompt(page);
  expect(prompt).toContain(
    "border-top-width: 4px [4px] → var(--fixture-slotted-border-width-choice) [4px]"
  );
  expect(prompt).not.toContain("--fixture-slotted-border-width-loser");

  await panel.getByRole("button", { name: "Clear all" }).click();
  await expect
    .poll(() => readInlineAndComputed(target, "border-top-width"))
    .toEqual({
      computed: "4px",
      priority: "",
      value: "",
    });
});

test("layout inspector keeps part cross-tree winners ambiguous", async ({ page }) => {
  await installClipboardCapture(page);
  await page.goto(fixtureUrl);
  const target = page.getByTestId("part-provenance-target");
  await expect
    .poll(() =>
      target.evaluate((element) => {
        const root = element.getRootNode();
        const outerRoot =
          root instanceof ShadowRoot ? root.host.getRootNode() : undefined;
        return {
          host: root instanceof ShadowRoot ? root.host.id : null,
          outerRootOpen: outerRoot instanceof ShadowRoot && outerRoot.mode === "open",
          part: element.getAttribute("part"),
          rootOpen: root instanceof ShadowRoot && root.mode === "open",
        };
      })
    )
    .toEqual({
      host: "fixture-cross-tree-inner-host",
      outerRootOpen: true,
      part: "fixture-provenance-target",
      rootOpen: true,
    });
  const marginAfterChangingLoser = await target.evaluate((element) => {
    const style = (element as HTMLElement).style;
    style.setProperty("--fixture-part-spacing-loser", "40px");
    const margin = getComputedStyle(element).marginTop;
    style.removeProperty("--fixture-part-spacing-loser");
    return margin;
  });
  expect(marginAfterChangingLoser).toBe("24px");

  const panel = await pinTargetWithLabel(
    page,
    target,
    "div#fixture-part-provenance-target.fixture-part-provenance-target"
  );
  const marginTop = panel.getByLabel("Margin top variable", {
    exact: true,
  });
  await expect
    .poll(() =>
      marginTop.evaluate(
        (select) => (select as HTMLSelectElement).selectedOptions[0]?.text
      )
    )
    .toBe("Original · 24px");

  await marginTop.selectOption("--fixture-part-spacing-choice");
  await expect
    .poll(() => readInlineAndComputed(target, "margin-top"))
    .toEqual({
      computed: "40px",
      priority: "important",
      value: "var(--fixture-part-spacing-choice)",
    });
  await page.getByTestId("copy-layout-prompt").click();
  const prompt = await readCopiedPrompt(page);
  expect(prompt).toContain(
    "margin-top: 24px [24px] → var(--fixture-part-spacing-choice) [40px]"
  );
  expect(prompt).not.toContain("--fixture-part-spacing-loser");

  await panel.getByRole("button", { name: "Clear all" }).click();
  await expect
    .poll(() => readInlineAndComputed(target, "margin-top"))
    .toEqual({
      computed: "24px",
      priority: "",
      value: "",
    });
});

test("layout inspector keeps host cross-tree winners ambiguous", async ({ page }) => {
  await installClipboardCapture(page);
  await page.goto(fixtureUrl);
  const target = page.getByTestId("host-provenance-target");
  await expect
    .poll(() =>
      target.evaluate((element) => ({
        rootOpen:
          element.getRootNode() instanceof ShadowRoot &&
          (element.getRootNode() as ShadowRoot).mode === "open",
        shadowOpen: element.shadowRoot?.mode === "open",
      }))
    )
    .toEqual({
      rootOpen: true,
      shadowOpen: true,
    });
  const heightAfterChangingLoser = await target.evaluate((element) => {
    const style = (element as HTMLElement).style;
    style.setProperty("--fixture-host-height-loser", "80px");
    const height = getComputedStyle(element).height;
    style.removeProperty("--fixture-host-height-loser");
    return height;
  });
  expect(heightAfterChangingLoser).toBe("40px");

  const panel = await pinTargetWithLabel(
    page,
    target,
    "div#fixture-cross-tree-inner-host.fixture-cross-tree-inner-host",
    { x: 200, y: 4 }
  );
  const height = panel.getByLabel("Height variable", {
    exact: true,
  });
  await expect
    .poll(() =>
      height.evaluate(
        (select) => (select as HTMLSelectElement).selectedOptions[0]?.text
      )
    )
    .toBe("Original · 40px");

  await height.selectOption("--fixture-host-height-choice");
  await expect
    .poll(() => readInlineAndComputed(target, "height"))
    .toEqual({
      computed: "40px",
      priority: "important",
      value: "var(--fixture-host-height-choice)",
    });
  await page.getByTestId("copy-layout-prompt").click();
  const prompt = await readCopiedPrompt(page);
  expect(prompt).toContain(
    "height: 40px [40px] → var(--fixture-host-height-choice) [40px]"
  );
  expect(prompt).not.toContain("--fixture-host-height-loser");

  await panel.getByRole("button", { name: "Clear all" }).click();
  await expect
    .poll(() => readInlineAndComputed(target, "height"))
    .toEqual({
      computed: "40px",
      priority: "",
      value: "",
    });
});

test("layout inspector measures percentage and calc gaps from used geometry", async ({
  page,
}) => {
  await page.goto(fixtureUrl);

  for (const { testId, expected } of [
    { expected: 40, testId: "percent-gap-target" },
    { expected: 45, testId: "calc-gap-target" },
  ]) {
    const target = page.getByTestId(testId);
    await target.scrollIntoViewIfNeeded();
    const targetBox = await target.boundingBox();
    if (!targetBox) throw new Error(`${testId} did not have a bounding box.`);
    const actualGutter = await target.locator(":scope > span").evaluateAll((items) => {
      const first = items[0]?.getBoundingClientRect();
      const second = items[1]?.getBoundingClientRect();
      if (!first || !second) throw new Error("Gap fixture children were unavailable.");
      return {
        center: first.right + (second.left - first.right) / 2,
        width: second.left - first.right,
      };
    });
    // Consecutive scrollIntoViewIfNeeded calls can place both targets at the
    // same viewport coordinates. Move away first so Chromium emits a new
    // pointermove for the second target.
    await page.mouse.move(0, 0);
    await page.mouse.move(actualGutter.center, targetBox.y + targetBox.height / 2);

    const segment = page.locator(
      '.comma-layout-inspector__segment[data-inspector-property="column-gap"]'
    );
    await expect(segment).toBeVisible();
    await expect
      .poll(() =>
        segment.evaluate((element) =>
          Number((element as HTMLElement).dataset.inspectorValue)
        )
      )
      .toBeCloseTo(actualGutter.width, 1);
    const measured = await segment.evaluate((element) => {
      const rect = element.getBoundingClientRect();
      return {
        overlay: rect.width,
        used: Number((element as HTMLElement).dataset.inspectorValue),
      };
    });

    expect(actualGutter.width).toBeCloseTo(expected, 1);
    expect(measured.used).toBeCloseTo(actualGutter.width, 1);
    expect(measured.overlay).toBeCloseTo(actualGutter.width, 1);
  }

  for (const { testId, expected } of [
    { expected: 0, testId: "auto-flex-percent-gap-target" },
    { expected: 5, testId: "auto-flex-calc-gap-target" },
  ]) {
    const target = page.getByTestId(testId);
    const actualGutter = await target.locator(":scope > span").evaluateAll((items) => {
      const first = items[0]?.getBoundingClientRect();
      const second = items[1]?.getBoundingClientRect();
      if (!first || !second) throw new Error("Flex gap children were unavailable.");
      return second.top - first.bottom;
    });
    const panel = await pinTarget(page, target);
    const displayedGap = panel
      .getByRole("button", { name: "Show Row gap property" })
      .locator("strong");

    expect(actualGutter).toBeCloseTo(expected, 1);
    await expect(displayedGap).toHaveText(String(expected));

    const segment = page.locator(
      '.comma-layout-inspector__segment[data-inspector-property="row-gap"]'
    );
    if (expected === 0) {
      await expect(segment).toHaveCount(0);
    } else {
      await expect(segment).toBeVisible();
      const measured = await segment.evaluate((element) => ({
        overlay: element.getBoundingClientRect().height,
        used: Number((element as HTMLElement).dataset.inspectorValue),
      }));
      expect(measured.used).toBeCloseTo(actualGutter, 1);
      expect(measured.overlay).toBeCloseTo(actualGutter, 1);
    }

    await page.keyboard.press("Escape");
  }
});

test("layout inspector excludes flex margins and distributed alignment from used gaps", async ({
  page,
}) => {
  await page.goto(fixtureUrl);

  for (const { expectedGap, expectedSeparation, testId } of [
    {
      expectedGap: 0,
      expectedSeparation: 10,
      testId: "margin-flex-percent-gap-target",
    },
    {
      expectedGap: 5,
      expectedSeparation: 15,
      testId: "margin-flex-calc-gap-target",
    },
  ]) {
    const target = page.getByTestId(testId);
    const actualSeparation = await target
      .locator(":scope > span")
      .evaluateAll((items) => {
        const first = items[0]?.getBoundingClientRect();
        const second = items[1]?.getBoundingClientRect();
        if (!first || !second) {
          throw new Error("Margin flex fixture children were unavailable.");
        }
        return second.top - first.bottom;
      });
    const panel = await pinTarget(page, target);
    const displayedGap = panel
      .getByRole("button", { name: "Show Row gap property" })
      .locator("strong");

    expect(actualSeparation).toBeCloseTo(expectedSeparation, 1);
    await expect(displayedGap).toHaveText(String(expectedGap));

    const segment = page.locator(
      '.comma-layout-inspector__segment[data-inspector-property="row-gap"]'
    );
    if (expectedGap === 0) {
      await expect(segment).toHaveCount(0);
    } else {
      await expect(segment).toHaveAttribute("data-inspector-value", "5");
      expect(
        await segment.evaluate((element) => element.getBoundingClientRect().height)
      ).toBeCloseTo(5, 1);
    }

    await page.keyboard.press("Escape");
  }

  const distributedTarget = page.getByTestId("distributed-flex-gap-target");
  const distributedSeparation = await distributedTarget
    .locator(":scope > span")
    .evaluateAll((items) => {
      const first = items[0]?.getBoundingClientRect();
      const second = items[1]?.getBoundingClientRect();
      if (!first || !second) {
        throw new Error("Distributed flex fixture children were unavailable.");
      }
      return second.top - first.bottom;
    });
  const distributedPanel = await pinTarget(page, distributedTarget);

  expect(distributedSeparation).toBeGreaterThan(10);
  await expect(
    distributedPanel
      .getByRole("button", { name: "Show Row gap property" })
      .locator("strong")
  ).toHaveText("10");
  await expect(
    page.locator('.comma-layout-inspector__segment[data-inspector-property="row-gap"]')
  ).toHaveAttribute("data-inspector-value", "10");
});

test("layout inspector releases a pinned target that leaves measurable DOM", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  const target = page.getByTestId("host-style-target");
  const panel = await pinTarget(page, target);

  await panel.getByLabel("Padding top variable").selectOption("--spacing-xl");
  await expect
    .poll(() => target.evaluate((element) => getComputedStyle(element).paddingTop))
    .toBe("16px");

  await target.evaluate((element) => {
    (
      window as Window & {
        detachedLayoutTarget?: HTMLElement;
      }
    ).detachedLayoutTarget = element as HTMLElement;
    element.remove();
  });

  await expect(panel).toHaveCount(0);
  await expect(page.getByRole("status")).toContainText("hover to inspect");
  await expect(page.getByTestId("layout-inspector-border-box")).toHaveCount(0);
  await expect
    .poll(() =>
      page.evaluate(() => {
        const element = (
          window as Window & {
            detachedLayoutTarget?: HTMLElement;
          }
        ).detachedLayoutTarget;
        return element
          ? {
              priority: element.style.getPropertyPriority("padding-top"),
              value: element.style.getPropertyValue("padding-top"),
            }
          : null;
      })
    )
    .toEqual({ priority: "", value: "4px" });

  await page.goto(fixtureUrl);
  const hiddenTarget = page.getByTestId("host-style-target");
  const hiddenPanel = await pinTarget(page, hiddenTarget);
  await hiddenPanel.getByLabel("Padding top variable").selectOption("--spacing-xl");

  await hiddenTarget.evaluate((element) => {
    (element as HTMLElement).style.display = "none";
  });

  await expect(hiddenPanel).toHaveCount(0);
  await expect(page.getByRole("status")).toContainText("hover to inspect");
  await expect(page.getByTestId("layout-inspector-border-box")).toHaveCount(0);
  await expect
    .poll(() =>
      hiddenTarget.evaluate((element) => ({
        display: (element as HTMLElement).style.display,
        priority: (element as HTMLElement).style.getPropertyPriority("padding-top"),
        value: (element as HTMLElement).style.getPropertyValue("padding-top"),
      }))
    )
    .toEqual({ display: "none", priority: "", value: "4px" });
});

test("layout inspector follows position-only reflow around a pinned target", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  const target = page.getByTestId("host-style-target");
  await pinTarget(page, target);
  const overlay = page.getByTestId("layout-inspector-border-box");
  const initialTarget = await target.boundingBox();
  if (!initialTarget) throw new Error("Reflow target did not have a bounding box.");

  await target.evaluate((element) => {
    const spacer = document.createElement("div");
    spacer.dataset.testid = "preceding-reflow-sibling";
    spacer.style.height = "120px";
    element.before(spacer);
  });

  await expect
    .poll(async () => {
      const [targetBox, overlayBox] = await Promise.all([
        target.boundingBox(),
        overlay.boundingBox(),
      ]);
      return targetBox && overlayBox
        ? {
            aligned: Math.abs(targetBox.y - overlayBox.y) < 1,
            height: targetBox.height,
            moved: targetBox.y - initialTarget.y,
          }
        : null;
    })
    .toEqual({
      aligned: true,
      height: initialTarget.height,
      moved: 120,
    });

  await page.getByTestId("preceding-reflow-sibling").evaluate(async (element) => {
    const animation = element.animate([{ height: "120px" }, { height: "180px" }], {
      duration: 160,
      easing: "linear",
      fill: "forwards",
    });
    await animation.finished;
  });

  await expect
    .poll(async () => {
      const [targetBox, overlayBox] = await Promise.all([
        target.boundingBox(),
        overlay.boundingBox(),
      ]);
      return targetBox && overlayBox
        ? {
            aligned: Math.abs(targetBox.y - overlayBox.y) < 1,
            height: targetBox.height,
            moved: targetBox.y - initialTarget.y,
          }
        : null;
    })
    .toEqual({
      aligned: true,
      height: initialTarget.height,
      moved: 180,
    });

  await page.getByTestId("preceding-reflow-sibling").evaluate((element) => {
    element.remove();
  });

  await expect
    .poll(async () => {
      const [targetBox, overlayBox] = await Promise.all([
        target.boundingBox(),
        overlay.boundingBox(),
      ]);
      return targetBox && overlayBox
        ? {
            aligned: Math.abs(targetBox.y - overlayBox.y) < 1,
            top: targetBox.y,
          }
        : null;
    })
    .toEqual({
      aligned: true,
      top: initialTarget.y,
    });

  await target.evaluate((element) => {
    const details = document.createElement("details");
    details.dataset.testid = "preceding-reflow-details";
    const summary = document.createElement("summary");
    summary.style.height = "20px";
    summary.textContent = "Details";
    const content = document.createElement("div");
    content.style.height = "80px";
    details.append(summary, content);
    element.before(details);
  });
  await expect
    .poll(async () => {
      const [targetBox, overlayBox] = await Promise.all([
        target.boundingBox(),
        overlay.boundingBox(),
      ]);
      return targetBox && overlayBox ? Math.abs(targetBox.y - overlayBox.y) < 1 : false;
    })
    .toBe(true);
  await waitForAnimationFrames(page, 2);
  const closedTarget = await target.boundingBox();
  if (!closedTarget) throw new Error("Closed details target geometry was unavailable.");

  await page.getByTestId("preceding-reflow-details").evaluate((element) => {
    (element as HTMLDetailsElement).open = true;
  });

  await expect
    .poll(async () => {
      const [targetBox, overlayBox] = await Promise.all([
        target.boundingBox(),
        overlay.boundingBox(),
      ]);
      return targetBox && overlayBox
        ? {
            aligned: Math.abs(targetBox.y - overlayBox.y) < 1,
            moved: targetBox.y - closedTarget.y,
          }
        : null;
    })
    .toEqual({
      aligned: true,
      moved: 80,
    });

  await page.getByTestId("preceding-reflow-details").evaluate((element) => {
    element.remove();
  });
});

test("layout inspector preserves ancestor resize coverage beside large sibling lists", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  const target = page.getByTestId("host-style-target");
  await target.evaluate((element) => {
    const outer = document.createElement("div");
    outer.dataset.testid = "crowded-reflow-ancestor";
    const crowdedParent = document.createElement("div");
    element.before(outer);
    outer.append(crowdedParent);
    for (let index = 0; index < 130; index += 1) {
      const sibling = document.createElement("span");
      sibling.style.display = "none";
      crowdedParent.append(sibling);
    }
    crowdedParent.append(element);
  });

  await pinTarget(page, target);
  const overlay = page.getByTestId("layout-inspector-border-box");
  const initialTarget = await target.boundingBox();
  if (!initialTarget) throw new Error("Crowded reflow target was unavailable.");

  await page.getByTestId("crowded-reflow-ancestor").evaluate(async (element) => {
    const animation = element.animate([{ paddingTop: "0px" }, { paddingTop: "60px" }], {
      duration: 160,
      easing: "linear",
      fill: "forwards",
    });
    await animation.finished;
  });

  await expect
    .poll(async () => {
      const [targetBox, overlayBox] = await Promise.all([
        target.boundingBox(),
        overlay.boundingBox(),
      ]);
      return targetBox && overlayBox
        ? {
            aligned: Math.abs(targetBox.y - overlayBox.y) < 1,
            moved: targetBox.y - initialTarget.y,
          }
        : null;
    })
    .toEqual({
      aligned: true,
      moved: 60,
    });
});

test("layout inspector bounds pinned reflow work and stops it after release", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  const target = page.getByTestId("host-style-target");
  await pinTarget(page, target);
  await target.evaluate((element) => {
    const originalGetBoundingClientRect = element.getBoundingClientRect.bind(element);
    (
      window as Window & {
        pinnedTargetMeasurementCount?: number;
      }
    ).pinnedTargetMeasurementCount = 0;
    element.getBoundingClientRect = () => {
      const testWindow = window as Window & {
        pinnedTargetMeasurementCount?: number;
      };
      testWindow.pinnedTargetMeasurementCount =
        (testWindow.pinnedTargetMeasurementCount ?? 0) + 1;
      return originalGetBoundingClientRect();
    };
  });
  await waitForAnimationFrames(page, 2);
  await resetPinnedTargetMeasurementCount(page);

  await target.evaluate((element) => {
    const spacer = document.createElement("div");
    spacer.dataset.testid = "bounded-reflow-spacer";
    spacer.style.height = "20px";
    element.before(spacer);
    spacer.style.height = "40px";
    spacer.dataset.state = "ready";
    spacer.textContent = "Changed";
  });
  await waitForAnimationFrames(page, 2);
  const burstMeasurementCount = await readPinnedTargetMeasurementCount(page);
  expect(burstMeasurementCount).toBeGreaterThan(0);
  expect(burstMeasurementCount).toBeLessThanOrEqual(2);
  await waitForAnimationFrames(page, 2);
  expect(await readPinnedTargetMeasurementCount(page)).toBe(burstMeasurementCount);

  await resetPinnedTargetMeasurementCount(page);
  const panel = page.getByTestId("layout-inspector-panel");
  const settingsButton = panel.getByRole("button", {
    name: "Inspector settings",
  });
  await settingsButton.click();
  await panel
    .getByRole("dialog", { name: "Inspector settings" })
    .getByRole("switch", { name: "Show gap overlay" })
    .click();
  await waitForAnimationFrames(page, 2);
  expect(await readPinnedTargetMeasurementCount(page)).toBe(0);
  await settingsButton.click();

  await resetPinnedTargetMeasurementCount(page);
  await page.evaluate(() => {
    const spacer = document.querySelector<HTMLElement>(
      '[data-testid="bounded-reflow-spacer"]'
    );
    if (!spacer) throw new Error("Bounded reflow spacer was unavailable.");
    spacer.style.height = "60px";
    document.dispatchEvent(
      new KeyboardEvent("keydown", {
        bubbles: true,
        cancelable: true,
        key: "Escape",
      })
    );
  });
  await expect(page.getByRole("status")).toContainText("hover to inspect");
  await waitForAnimationFrames(page, 2);
  const releaseMeasurementCount = await readPinnedTargetMeasurementCount(page);
  expect(releaseMeasurementCount).toBeLessThanOrEqual(1);
  await waitForAnimationFrames(page, 2);
  expect(await readPinnedTargetMeasurementCount(page)).toBe(releaseMeasurementCount);

  await resetPinnedTargetMeasurementCount(page);
  await page.getByTestId("bounded-reflow-spacer").evaluate((element) => {
    (element as HTMLElement).style.height = "80px";
  });
  await waitForAnimationFrames(page, 2);
  expect(await readPinnedTargetMeasurementCount(page)).toBe(0);
});

test("layout inspector explicitly omits unsupported structural geometry", async ({
  page,
}) => {
  await page.goto(fixtureUrl);

  for (const { reason, testId } of [
    {
      reason: "Anonymous text flex items",
      testId: "anonymous-text-flex-target",
    },
    {
      reason: "display: contents flex items",
      testId: "display-contents-target",
    },
    {
      reason: "Collapsed grid tracks",
      testId: "collapsed-grid-target",
    },
  ]) {
    const target = page.getByTestId(testId);
    if (testId === "anonymous-text-flex-target") {
      const anonymousItem = await target.evaluate((element) => {
        const text = Array.from(element.childNodes).find(
          (node) =>
            node.nodeType === Node.TEXT_NODE &&
            /[^\t\n\f\r ]/.test(node.textContent ?? "")
        );
        const child = element.querySelector(":scope > span");
        if (!text || !child) {
          throw new Error("Anonymous flex fixture was unavailable.");
        }
        const range = document.createRange();
        range.selectNode(text);
        const textRect = range.getBoundingClientRect();
        return {
          gap: child.getBoundingClientRect().left - textRect.right,
          width: textRect.width,
        };
      });
      expect(anonymousItem.width).toBeGreaterThan(0);
      expect(anonymousItem.gap).toBeCloseTo(20, 1);
    }
    const panel = await pinTarget(page, target);

    await expect(page.getByTestId("layout-inspector-geometry-limited")).toBeVisible();
    await expect(panel.getByTestId("layout-inspector-geometry-limit")).toContainText(
      reason
    );
    await expect(panel.getByLabel("Row gap variable")).toContainText("20px");
    await expect(
      page.locator('.comma-layout-inspector__segment[data-inspector-kind="gap"]')
    ).toHaveCount(0);
    await expect(
      panel
        .getByTestId("layout-inspector-box-model")
        .locator(":scope > .comma-layout-inspector__box-layer")
    ).toHaveCount(1);

    await page.keyboard.press("Escape");
  }

  for (const testId of [
    "transform-target",
    "individual-scale-target",
    "individual-rotate-target",
    "perspective-target",
  ]) {
    const transformedPanel = await pinTarget(page, page.getByTestId(testId));
    await expect(page.getByTestId("layout-inspector-border-box")).toBeVisible();
    await expect(page.getByTestId("layout-inspector-dimension")).toContainText(
      "Limited geometry"
    );
    await expect(
      transformedPanel.getByTestId("layout-inspector-geometry-limit")
    ).toContainText("Transformed coordinate space");
    await expect(
      transformedPanel
        .getByTestId("layout-inspector-box-model")
        .locator(".comma-layout-inspector__box-layer")
    ).toHaveCount(0);
    await expect(
      page.locator(
        '.comma-layout-inspector__segment[data-inspector-kind="margin"], .comma-layout-inspector__segment[data-inspector-kind="border"], .comma-layout-inspector__segment[data-inspector-kind="padding"], .comma-layout-inspector__segment[data-inspector-kind="gap"]'
      )
    ).toHaveCount(0);

    await page.keyboard.press("Escape");
  }

  const identityPanel = await pinTarget(
    page,
    page.getByTestId("individual-identity-target")
  );
  await expect(page.getByTestId("layout-inspector-geometry-limited")).toHaveCount(0);
  await expect(
    identityPanel
      .getByTestId("layout-inspector-box-model")
      .locator(".comma-layout-inspector__box-layer")
  ).toHaveCount(3);
});

test("layout inspector settles transition previews and preserves newer host styles", async ({
  page,
}) => {
  await installClipboardCapture(page);
  await page.goto(fixtureUrl);

  const transitionTarget = page.getByTestId("transition-target");
  let panel = await pinTarget(page, transitionTarget);
  await panel.getByLabel("Margin top variable").selectOption("--spacing-transition");
  await expect
    .poll(() =>
      transitionTarget.evaluate((element) => getComputedStyle(element).marginTop)
    )
    .toBe("96px");

  await page.waitForTimeout(1_200);
  const settledGeometry = await Promise.all([
    transitionTarget.evaluate((element) => element.getBoundingClientRect().top),
    page
      .getByTestId("layout-inspector-border-box")
      .evaluate((element) => element.getBoundingClientRect().top),
  ]);
  expect(settledGeometry[1]).toBeCloseTo(settledGeometry[0], 1);

  await page.getByTestId("copy-layout-prompt").click();
  expect(await readCopiedPrompt(page)).toContain(
    "margin-top: var(--spacing-xl) [16px] → var(--spacing-transition) [96px]"
  );
  await panel.getByRole("button", { name: "Clear all" }).click();
  await expect
    .poll(() =>
      transitionTarget.evaluate((element) => getComputedStyle(element).marginTop)
    )
    .toBe("16px");
  const restoredGeometry = await Promise.all([
    transitionTarget.evaluate((element) => element.getBoundingClientRect().top),
    page
      .getByTestId("layout-inspector-border-box")
      .evaluate((element) => element.getBoundingClientRect().top),
  ]);
  expect(restoredGeometry[1]).toBeCloseTo(restoredGeometry[0], 1);
  await page.waitForTimeout(1_200);
  const geometryAfterTransitionWindow = await Promise.all([
    transitionTarget.evaluate((element) => element.getBoundingClientRect().top),
    page
      .getByTestId("layout-inspector-border-box")
      .evaluate((element) => element.getBoundingClientRect().top),
  ]);
  expect(geometryAfterTransitionWindow[0]).toBeCloseTo(restoredGeometry[0], 1);
  expect(geometryAfterTransitionWindow[1]).toBeCloseTo(restoredGeometry[0], 1);

  await page.keyboard.press("Escape");
  const hostTarget = page.getByTestId("host-style-target");
  panel = await pinTarget(page, hostTarget);
  await panel.getByLabel("Padding top variable").selectOption("--spacing-xl");
  await expect
    .poll(() => hostTarget.evaluate((element) => getComputedStyle(element).paddingTop))
    .toBe("16px");

  await page.evaluate(() => window.setFixtureHostPadding?.(40));
  await expect
    .poll(() => readInlineAndComputed(hostTarget, "padding-top"))
    .toEqual({
      computed: "40px",
      priority: "",
      value: "40px",
    });

  await panel.getByRole("button", { name: "Clear all" }).click();
  await expect
    .poll(() => readInlineAndComputed(hostTarget, "padding-top"))
    .toEqual({
      computed: "40px",
      priority: "",
      value: "40px",
    });
});

test("layout inspector separates labels that share the same space", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  const target = page.getByTestId("collision-target");
  const targetBox = await target.boundingBox();
  if (!targetBox) throw new Error("Collision target did not have a bounding box.");

  await page.mouse.move(targetBox.x + 4, targetBox.y + targetBox.height / 2);

  const paddingLabel = page.locator(
    '.comma-layout-inspector__segment-label[data-inspector-property="padding-left"]'
  );
  const gapLabel = page.locator(
    '.comma-layout-inspector__segment-label[data-inspector-property="row-gap"]'
  );
  await expect(paddingLabel).toBeVisible();
  await expect(gapLabel).toBeVisible();

  const collisions = await page
    .locator(
      '.comma-layout-inspector__segment-label, [data-testid="layout-inspector-dimension"]'
    )
    .evaluateAll((labels) => {
      const boxes = labels.map((label) => ({
        property: (label as HTMLElement).dataset.inspectorProperty ?? "dimension badge",
        rect: label.getBoundingClientRect(),
      }));

      return boxes.flatMap((left, leftIndex) =>
        boxes.slice(leftIndex + 1).flatMap((right) => {
          const overlaps =
            left.rect.left < right.rect.right &&
            left.rect.right > right.rect.left &&
            left.rect.top < right.rect.bottom &&
            left.rect.bottom > right.rect.top;
          return overlaps ? [[left.property, right.property]] : [];
        })
      );
    });

  expect(collisions).toEqual([]);
  expect(
    await gapLabel.evaluate(
      (label) =>
        label.dataset.inspectorShiftX !== "0" || label.dataset.inspectorShiftY !== "0"
    )
  ).toBe(true);

  const gapLeader = page.locator(
    '[data-inspector-leader][data-inspector-property="row-gap"]'
  );
  await expect(gapLeader).toHaveAttribute("data-visible", "true");
  const leaderLength = await gapLeader.locator("line").evaluate((line) => {
    const x = Number(line.getAttribute("x2")) - Number(line.getAttribute("x1"));
    const y = Number(line.getAttribute("y2")) - Number(line.getAttribute("y1"));
    return Math.hypot(x, y);
  });
  expect(leaderLength).toBeGreaterThan(0);
  const leaderLayer = page.locator(".comma-layout-inspector__leader-layer");
  expect(
    await leaderLayer.evaluate((element) =>
      Number.parseInt(getComputedStyle(element).zIndex, 10)
    )
  ).toBe(
    await gapLabel.evaluate((element) =>
      Number.parseInt(getComputedStyle(element).zIndex, 10)
    )
  );
  await expect(gapLeader.locator("line")).toHaveCSS("stroke-dasharray", "none");
});

test("box model navigation expands, scrolls to, and focuses property groups", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  const target = page.getByTestId("layout-target");
  const targetBox = await target.boundingBox();
  if (!targetBox) throw new Error("Layout target did not have a bounding box.");

  await page.mouse.move(targetBox.x + 8, targetBox.y + 8);
  await page.mouse.click(targetBox.x + 8, targetBox.y + 8);

  const panel = page.getByTestId("layout-inspector-panel");
  const properties = panel.getByTestId("layout-inspector-properties-scroll");
  await expect(properties).toHaveCSS("overflow-y", "auto");
  expect(
    await properties.evaluate((element) => element.scrollHeight > element.clientHeight)
  ).toBe(true);

  await panel.getByRole("button", { name: "Collapse Padding" }).click();
  await expect(panel.getByRole("button", { name: "Expand Padding" })).toHaveAttribute(
    "aria-expanded",
    "false"
  );
  await expect(panel.getByLabel("Padding left variable")).toBeHidden();

  await panel.getByRole("button", { name: "Show Padding left property" }).click();

  const paddingLeft = panel.getByLabel("Padding left variable");
  await expect(panel.getByRole("button", { name: "Collapse Padding" })).toHaveAttribute(
    "aria-expanded",
    "true"
  );
  await expect(paddingLeft).toBeFocused();
  const paddingLeftBox = await paddingLeft.boundingBox();
  const propertiesBox = await properties.boundingBox();
  if (!paddingLeftBox || !propertiesBox) {
    throw new Error("Focused padding property did not have visible browser bounds.");
  }
  expect(paddingLeftBox.y).toBeGreaterThanOrEqual(propertiesBox.y);
  expect(paddingLeftBox.y + paddingLeftBox.height).toBeLessThanOrEqual(
    propertiesBox.y + propertiesBox.height
  );

  await panel.getByRole("button", { name: "Collapse Gap" }).click();
  await panel.getByRole("button", { name: "Show Row gap property" }).click();
  await expect(panel.getByLabel("Row gap variable")).toBeFocused();
});

test("layout inspector avoids the active element and supports dragging and resizing", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  const target = page.getByTestId("layout-target");
  const targetBox = await target.boundingBox();
  if (!targetBox) throw new Error("Layout target did not have a bounding box.");

  await page.mouse.move(targetBox.x + 8, targetBox.y + 8);
  await page.mouse.click(targetBox.x + 8, targetBox.y + 8);

  const panel = page.getByTestId("layout-inspector-panel");
  const header = panel.locator(".comma-layout-inspector__panel-header");
  await expect(panel).toHaveAttribute("data-placement", "right");

  const initialPanelBox = await panel.boundingBox();
  if (!initialPanelBox) {
    throw new Error("Layout inspector panel did not have a bounding box.");
  }
  expect(rectanglesOverlap(initialPanelBox, targetBox)).toBe(false);

  const headerBox = await header.boundingBox();
  if (!headerBox) {
    throw new Error("Layout inspector header did not have a bounding box.");
  }
  await page.mouse.move(
    headerBox.x + headerBox.width / 2,
    headerBox.y + headerBox.height / 2
  );
  await page.mouse.down();
  await page.mouse.move(
    headerBox.x + headerBox.width / 2 + 160,
    headerBox.y + headerBox.height / 2
  );
  await page.mouse.up();

  await expect(panel).toHaveAttribute("data-placement", "manual");
  const draggedPanelBox = await panel.boundingBox();
  if (!draggedPanelBox) {
    throw new Error("Dragged layout inspector panel did not have a bounding box.");
  }
  expect(draggedPanelBox.x).toBeGreaterThan(initialPanelBox.x + 100);
  expect(draggedPanelBox.x + draggedPanelBox.width).toBeLessThanOrEqual(
    (await page.evaluate(() => window.innerWidth)) - 12
  );

  await header.dblclick();
  await expect(panel).toHaveAttribute("data-placement", "right");
  await expect
    .poll(async () => (await panel.boundingBox())?.x)
    .toBeCloseTo(initialPanelBox.x, 0);

  const resizeHandle = panel.getByRole("button", {
    name: "Resize inspector panel",
  });
  const resizeHandleBox = await resizeHandle.boundingBox();
  if (!resizeHandleBox) {
    throw new Error("Layout inspector resize handle did not have a bounding box.");
  }
  await page.mouse.move(
    resizeHandleBox.x + resizeHandleBox.width / 2,
    resizeHandleBox.y + resizeHandleBox.height / 2
  );
  await page.mouse.down();
  await page.mouse.move(
    resizeHandleBox.x + resizeHandleBox.width / 2 + 96,
    resizeHandleBox.y + resizeHandleBox.height / 2 - 48
  );
  await page.mouse.up();

  const resizedPanelBox = await panel.boundingBox();
  if (!resizedPanelBox) {
    throw new Error("Resized layout inspector panel did not have a bounding box.");
  }
  expect(resizedPanelBox.width).toBeGreaterThan(initialPanelBox.width + 80);
  expect(resizedPanelBox.height).toBeLessThan(initialPanelBox.height - 30);
  await expect(panel).toHaveAttribute("data-resizing", "false");

  const resizedHandleBox = await resizeHandle.boundingBox();
  if (!resizedHandleBox) {
    throw new Error("Resized layout inspector handle did not have a bounding box.");
  }
  await page.mouse.move(
    resizedHandleBox.x + resizedHandleBox.width / 2,
    resizedHandleBox.y + resizedHandleBox.height / 2
  );
  await page.mouse.down();
  await page.mouse.move(
    resizedHandleBox.x + resizedHandleBox.width / 2 - 1000,
    resizedHandleBox.y + resizedHandleBox.height / 2 - 1000
  );
  await page.mouse.up();

  const minimumPanelBox = await panel.boundingBox();
  const minimumPropertiesBox = await panel
    .locator(":scope > .comma-layout-inspector__properties")
    .boundingBox();
  if (!minimumPanelBox || !minimumPropertiesBox) {
    throw new Error("Minimum inspector geometry was unavailable.");
  }
  expect(minimumPanelBox.width).toBeGreaterThanOrEqual(320);
  expect(minimumPropertiesBox.height).toBeGreaterThanOrEqual(220);

  await resizeHandle.dblclick();
  await expect
    .poll(async () => (await panel.boundingBox())?.width)
    .toBeCloseTo(initialPanelBox.width, 0);
});

function rectanglesOverlap(
  left: { height: number; width: number; x: number; y: number },
  right: { height: number; width: number; x: number; y: number }
) {
  return (
    left.x < right.x + right.width &&
    left.x + left.width > right.x &&
    left.y < right.y + right.height &&
    left.y + left.height > right.y
  );
}

async function installClipboardCapture(page: Page) {
  await page.addInitScript(() => {
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: {
        writeText: async (text: string) => {
          (
            window as Window & {
              copiedLayoutPrompt?: string;
            }
          ).copiedLayoutPrompt = text;
        },
      },
    });
  });
}

async function pinTarget(page: Page, target: Locator) {
  await target.scrollIntoViewIfNeeded();
  const targetBox = await target.boundingBox();
  if (!targetBox) throw new Error("Layout target did not have a bounding box.");
  await page.mouse.move(targetBox.x + 4, targetBox.y + 4);
  await page.mouse.click(targetBox.x + 4, targetBox.y + 4);
  const panel = page.getByTestId("layout-inspector-panel");
  await expect(panel).toBeVisible();
  return panel;
}

async function pinTargetWithLabel(
  page: Page,
  target: Locator,
  expectedNodeLabel: string,
  offset = { x: 4, y: 4 }
) {
  await target.scrollIntoViewIfNeeded();
  const targetBox = await target.boundingBox();
  if (!targetBox) throw new Error("Layout target did not have a bounding box.");
  const x = targetBox.x + offset.x;
  const y = targetBox.y + offset.y;
  await page.mouse.move(x, y);
  await expect(
    page.getByTestId("layout-inspector-dimension").locator("strong")
  ).toHaveText(expectedNodeLabel);
  await page.mouse.click(x, y);
  const panel = page.getByTestId("layout-inspector-panel");
  await expect(panel).toBeVisible();
  await expect(panel.getByRole("heading", { level: 2 })).toHaveText(expectedNodeLabel);
  return panel;
}

async function readInlineAndComputed(target: Locator, property: string) {
  return target.evaluate((element, inspectedProperty) => {
    const htmlElement = element as HTMLElement;
    return {
      computed: getComputedStyle(element).getPropertyValue(inspectedProperty),
      priority: htmlElement.style.getPropertyPriority(inspectedProperty),
      value: htmlElement.style.getPropertyValue(inspectedProperty),
    };
  }, property);
}

async function readCopiedPrompt(page: Page) {
  return page.evaluate(
    () =>
      (
        window as Window & {
          copiedLayoutPrompt?: string;
        }
      ).copiedLayoutPrompt ?? ""
  );
}

async function waitForAnimationFrames(page: Page, count: number) {
  await page.evaluate(async (frameCount) => {
    for (let index = 0; index < frameCount; index += 1) {
      await new Promise<void>((resolveFrame) => {
        requestAnimationFrame(() => resolveFrame());
      });
    }
  }, count);
}

async function resetPinnedTargetMeasurementCount(page: Page) {
  await page.evaluate(() => {
    (
      window as Window & {
        pinnedTargetMeasurementCount?: number;
      }
    ).pinnedTargetMeasurementCount = 0;
  });
}

async function readPinnedTargetMeasurementCount(page: Page) {
  return page.evaluate(
    () =>
      (
        window as Window & {
          pinnedTargetMeasurementCount?: number;
        }
      ).pinnedTargetMeasurementCount ?? 0
  );
}
