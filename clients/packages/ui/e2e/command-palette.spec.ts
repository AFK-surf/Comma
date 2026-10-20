import { expect, test } from "@playwright/test";
import { motionDuration } from "../src/tokens/motion";

const LONG_TASK_HISTORY_STORY =
  "/iframe.html?id=app-components-search-command-palette--long-task-history&viewMode=story";

test("keeps row hover immediate while preview waits for pointer intent", async ({
  page,
}) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  // The preview waits for a short pointer dwell. Playwright sends each mouse
  // step as its own round trip, so on a busy runner real time between two
  // steps can exceed the dwell and commit a row the pointer only crossed.
  // The page clock stops during each gesture and the test advances it.
  await page.clock.install();
  await page.goto(LONG_TASK_HISTORY_STORY);

  const options = page.getByRole("option");
  const first = options.nth(0);
  const fourth = options.nth(3);
  const preview = page.getByRole("region", { name: "Task preview" });
  const previewTitle = preview.getByRole("heading", { level: 2 }).first();

  await expect(options).toHaveCount(48);
  await expect(first).toHaveAttribute("aria-selected", "true");
  await expect(previewTitle).toHaveText("Task result 1");

  await page.evaluate(() => {
    const optionElements = Array.from(
      document.querySelectorAll<HTMLElement>('[role="option"]')
    );
    const list = document.querySelector<HTMLElement>("[cmdk-list]");
    const previewHeading = document.querySelector<HTMLElement>(
      '[data-slot="command-palette-preview"] h2'
    );
    if (!list || !previewHeading) {
      throw new Error("Command palette trace targets are not mounted");
    }

    let hoveredIndex: number | null = null;
    const trace: Array<{
      hoveredIndex: number | null;
      previewTitle: string;
      selectedIndex: number;
    }> = [];
    const writeTrace = () => {
      document.body.dataset.commandPaletteSelectionTrace = JSON.stringify(trace);
    };

    list.addEventListener("pointermove", (event) => {
      const option = (event.target as Element).closest<HTMLElement>('[role="option"]');
      hoveredIndex = option ? optionElements.indexOf(option) + 1 : null;
    });

    const observer = new MutationObserver((records) => {
      for (const record of records) {
        const option = record.target as HTMLElement;
        if (option.getAttribute("aria-selected") !== "true") continue;
        trace.push({
          hoveredIndex,
          previewTitle: previewHeading.textContent ?? "",
          selectedIndex: optionElements.indexOf(option) + 1,
        });
      }
      writeTrace();
    });
    observer.observe(list, {
      attributeFilter: ["aria-selected"],
      attributes: true,
      subtree: true,
    });
    (
      document.body as HTMLElement & {
        commandPaletteSelectionObserver?: MutationObserver;
      }
    ).commandPaletteSelectionObserver = observer;
    writeTrace();
  });

  const firstBox = await first.boundingBox();
  const fourthBox = await fourth.boundingBox();
  const previewBox = await preview.boundingBox();
  if (!firstBox || !fourthBox || !previewBox) {
    throw new Error("Command palette rows and preview are not laid out");
  }

  const firstCenterY = firstBox.y + firstBox.height / 2;
  const fourthCenterY = fourthBox.y + fourthBox.height / 2;
  await page.clock.pauseAt((await page.evaluate(() => Date.now())) + 1_000);
  await page.mouse.move(firstBox.x + 8, firstCenterY);
  // One continuous gesture: the intermediate points hit rows two and three,
  // while the final point lands in the preview at row four's height. Each
  // point waits for its row's hover to commit: two moves sent back to back can
  // land in one React render (the hover commits at continuous priority, after
  // the next input), which would skip a row the pointer did cross.
  // The paused clock keeps the dwell from running meanwhile.
  const from = { x: firstBox.x + 8, y: firstCenterY };
  const to = { x: previewBox.x + 8, y: fourthCenterY };
  for (const step of [1, 2, 3]) {
    await page.mouse.move(
      from.x + ((to.x - from.x) * step) / 3,
      from.y + ((to.y - from.y) * step) / 3
    );
    if (step < 3) {
      await expect(options.nth(step)).toHaveAttribute("aria-selected", "true");
      await expect(previewTitle).toHaveText("Task result 1");
    }
  }

  // Run past the dwell threshold to prove that no abandoned row left a
  // timer capable of replacing the preview after the pointer arrived there.
  await page.clock.runFor(motionDuration.pointerIntent + 50);
  await expect(first).toHaveAttribute("aria-selected", "true");
  await expect(previewTitle).toHaveText("Task result 1");

  const crossingTrace = await page.evaluate(
    () =>
      JSON.parse(document.body.dataset.commandPaletteSelectionTrace ?? "[]") as Array<{
        hoveredIndex: number | null;
        previewTitle: string;
        selectedIndex: number;
      }>
  );
  expect(crossingTrace).toEqual(
    expect.arrayContaining([
      {
        hoveredIndex: 2,
        previewTitle: "Task result 1",
        selectedIndex: 2,
      },
      {
        hoveredIndex: 3,
        previewTitle: "Task result 1",
        selectedIndex: 3,
      },
    ])
  );

  await page.mouse.move(
    fourthBox.x + fourthBox.width / 2,
    fourthBox.y + fourthBox.height / 2
  );
  await page.clock.runFor(motionDuration.pointerIntent + 50);
  await page.clock.resume();

  const dwellTrace = await page.evaluate(
    () =>
      JSON.parse(document.body.dataset.commandPaletteSelectionTrace ?? "[]") as Array<{
        hoveredIndex: number | null;
        previewTitle: string;
        selectedIndex: number;
      }>
  );
  expect(dwellTrace).toContainEqual({
    hoveredIndex: 4,
    previewTitle: "Task result 1",
    selectedIndex: 4,
  });
  await expect(fourth).toHaveAttribute("aria-selected", "true");
  await expect(first).toHaveAttribute("aria-selected", "false");
  await expect(previewTitle).toHaveText("Task result 4");
});
