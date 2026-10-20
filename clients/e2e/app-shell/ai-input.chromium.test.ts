import { expect, test, type Page, useFixture } from "./support/page";
import { fixtureMount } from "./support/fixture";

useFixture(fixtureMount(new URL("./fixtures/ai-input/src/main.tsx", import.meta.url)));
const fixtureUrl = "http://fixture.test/";

test("AI Input auto-resizes in the browser and removes attachments", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiInputFixture));

  const textarea = page.getByLabel("AI prompt", { exact: true });
  const imageTile = page.getByTestId("image-attachment").filter({
    has: page.getByRole("button", { name: "Remove Generated asset" }),
  });
  // A ready image without a thumbnail stays removable, but cannot be previewed.
  await expect(imageTile.locator('[data-state="ready"]')).toBeVisible();
  await expect(imageTile.locator("img")).toHaveCount(0);
  await expect(
    imageTile.getByRole("button", { name: "Preview Generated asset" })
  ).toHaveCount(0);
  await expect(page.getByText("Openai")).toBeVisible();

  const initial = await getAiInputSnapshot(page);
  expect(initial.textareaClientHeight).toBe(40);
  expect(initial.textareaOverflowY).toBe("auto");

  await textarea.fill(
    Array.from({ length: 50 }, (_, index) => `Line ${index + 1}`).join("\n")
  );

  await expect
    .poll(() =>
      getAiInputSnapshot(page).then((snapshot) => snapshot.textareaClientHeight)
    )
    .toBeGreaterThanOrEqual(320);

  const grown = await getAiInputSnapshot(page);
  expect(grown.textareaClientHeight).toBeLessThan(330);
  expect(grown.textareaMaxHeight).toBe("320px");
  expect(grown.textareaScrollHeight).toBeGreaterThan(grown.textareaClientHeight);

  await page.getByRole("button", { name: "Remove Generated asset" }).click();

  await expect(imageTile).toBeHidden();
  await expect(page.getByText("Openai")).toBeVisible();
  await expect(page.getByTestId("attachment-count")).toHaveText("Attachments: 4");
});

test("AI Input reveals a quote attachment's full passage on hover", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiInputFixture));

  const chip = page
    .getByTestId("primary-ai-input")
    .locator('[data-slot="quote-attachment"]');
  await expect(chip).toBeVisible();
  // The chip shows only the glyph; the passage itself lives in the hover card.
  await expect(chip).toHaveText("");
  expect(await chip.boundingBox()).toMatchObject({ height: 48, width: 48 });

  // React Aria opens a hover card only once the global interaction modality is
  // pointer, which a bare synthetic mousemove never establishes.
  await page.getByRole("heading", { name: "AI Input E2E Fixture" }).click();
  await chip.hover();

  const card = page.locator('[data-slot="hover-card"]');
  await expect(card).toBeVisible();
  await expect(card).toContainText("Quoted text");
  await expect(card).toContainText("点 形状 → 铅笔 会得到一支完整的铅笔。");

  await page.getByTestId("attachment-count").hover();
  await expect(card).toBeHidden();

  await page
    .getByRole("button", { name: "Remove 圆橡皮，中间留出金属箍空隙。" })
    .click();
  await expect(chip).toBeHidden();
  await expect(page.getByTestId("attachment-count")).toHaveText("Attachments: 4");
});

test("AI Input attaches an image pasted with Cmd/Ctrl+V", async ({ page, context }) => {
  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiInputFixture));

  const textarea = page.getByLabel("AI prompt", { exact: true });
  await expect(page.getByTestId("attachment-count")).toHaveText("Attachments: 5");

  // Image data on the clipboard, the way a screenshot arrives: the OS hands
  // over a file rather than text, and Chromium names it for us.
  await page.evaluate(async () => {
    const canvas = document.createElement("canvas");
    canvas.width = 2;
    canvas.height = 2;
    const blob = await new Promise<Blob>((settle, fail) => {
      canvas.toBlob(
        (result) => (result ? settle(result) : fail(new Error("No PNG blob."))),
        "image/png"
      );
    });
    await navigator.clipboard.write([new ClipboardItem({ "image/png": blob })]);
  });

  await textarea.focus();
  await page.keyboard.press("ControlOrMeta+V");

  await expect(page.getByTestId("attachment-count")).toHaveText("Attachments: 6");
  await expect(
    page
      .getByTestId("primary-ai-input")
      .locator('[data-slot="file-attachment"]')
      .filter({ hasText: "image.png" })
  ).toBeVisible();
  await expect(textarea).toHaveValue("");
});

for (const { richText, appClipboard } of [
  { richText: false, appClipboard: false },
  { richText: true, appClipboard: false },
  { richText: true, appClipboard: true },
]) {
  test(`AI Input attaches an image through the context-menu Paste action (rich=${richText}, appClipboard=${appClipboard})`, async ({
    page,
    context,
  }) => {
    await context.grantPermissions(["clipboard-read", "clipboard-write"]);
    const query = new URLSearchParams();
    if (richText) query.set("rich", "1");
    if (appClipboard) query.set("appClipboard", "1");
    await page.goto(`${fixtureUrl}?${query}`);
    await page.waitForFunction(() => Boolean(window.aiInputFixture));

    const textarea = page.getByLabel("AI prompt", { exact: true });
    await expect(page.getByTestId("attachment-count")).toHaveText("Attachments: 5");

    // Image data on the clipboard, the way a screenshot arrives: the OS hands
    // over a file rather than text, and Chromium names it for us.
    await page.evaluate(async () => {
      const canvas = document.createElement("canvas");
      canvas.width = 2;
      canvas.height = 2;
      const blob = await new Promise<Blob>((settle, fail) => {
        canvas.toBlob(
          (result) => (result ? settle(result) : fail(new Error("No PNG blob."))),
          "image/png"
        );
      });
      await navigator.clipboard.write([new ClipboardItem({ "image/png": blob })]);
    });

    await textarea.focus();
    await textarea.click({ button: "right" });
    await page.getByRole("menuitem", { name: "Paste", exact: true }).click();

    await expect(page.getByTestId("attachment-count")).toHaveText("Attachments: 6");
    await expect(
      page
        .getByTestId("primary-ai-input")
        .locator('[data-slot="file-attachment"]')
        .filter({ hasText: "clipboard-image.png" })
    ).toBeVisible();
    if (richText) await expect(textarea).toHaveText("");
    else await expect(textarea).toHaveValue("");
  });
}

test("AI Input insets every attachment's close control inside its tile", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiInputFixture));

  const tiles = page
    .getByTestId("primary-ai-input")
    .locator(
      '[data-slot="file-attachment"], [data-slot="image-attachment"], [data-slot="quote-attachment"]'
    );
  await expect(tiles).toHaveCount(5);

  const placements = await tiles.evaluateAll((elements) =>
    elements.map((tile) => {
      const close = tile.querySelector<HTMLElement>(".comma-ai-input-attachment-close");
      if (!close) throw new Error("Attachment tile has no close control.");
      const inset = parseFloat(
        getComputedStyle(tile).getPropertyValue("--spacing-xxs")
      );
      const tileRect = tile.getBoundingClientRect();
      const closeRect = close.getBoundingClientRect();
      return {
        height: tileRect.height,
        inset,
        right: tileRect.right - closeRect.right,
        slot: tile.getAttribute("data-slot"),
        top: closeRect.top - tileRect.top,
      };
    })
  );
  for (const placement of placements) {
    expect(placement.inset).toBeGreaterThan(0);
    expect(placement, placement.slot ?? "").toMatchObject({
      right: placement.inset,
      top: placement.inset,
    });
  }
  // A mixed row keeps one baseline: the file chip matches the square tiles.
  expect(new Set(placements.map((placement) => placement.height)).size).toBe(1);

  // The file name shares its line with the control and must end before it.
  const fileTile = tiles.and(page.locator('[data-slot="file-attachment"]'));
  const clearance = await fileTile.evaluate((tile) => {
    const name = tile.querySelector<HTMLElement>(".truncate");
    const close = tile.querySelector<HTMLElement>(".comma-ai-input-attachment-close");
    if (!name || !close)
      throw new Error("File attachment is missing its name or close.");
    const nameTextRight =
      name.getBoundingClientRect().right -
      parseFloat(getComputedStyle(name).paddingRight);
    return close.getBoundingClientRect().left - nameTextRight;
  });
  expect(clearance).toBeGreaterThan(0);
});

test("AI Input keeps attachment close motion scoped and respects both reduced-motion modes", async ({
  page,
}) => {
  const readPressedStyle = async (mode: "normal" | "manual" | "system") => {
    await page.emulateMedia({
      reducedMotion: mode === "system" ? "reduce" : "no-preference",
    });
    await page.goto(fixtureUrl);
    await page.waitForFunction(() => Boolean(window.aiInputFixture));
    if (mode === "manual") {
      await page.evaluate(() =>
        document.documentElement.setAttribute("data-comma-reduced-motion", "true")
      );
    }

    const removeButton = page
      .getByTestId("primary-ai-input")
      .getByRole("button", { name: "Remove Openai" });
    await removeButton.hover();
    await expect
      .poll(() => removeButton.evaluate((element) => getComputedStyle(element).opacity))
      .toBe("1");

    const box = await removeButton.boundingBox();
    if (!box) throw new Error("Attachment close button has no layout box.");
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await page.mouse.down();
    await page.waitForTimeout(180);
    const pressed = await removeButton.evaluate((element) => {
      const style = getComputedStyle(element);
      return { scale: style.scale, transitionProperty: style.transitionProperty };
    });
    await page.mouse.up();
    return pressed;
  };

  const normal = await readPressedStyle("normal");
  expect(normal.transitionProperty.split(", ")).toContain("opacity");
  expect(normal.transitionProperty.split(", ")).toContain("scale");
  expect(normal.scale).toBe("0.94");

  const manual = await readPressedStyle("manual");
  expect(manual.transitionProperty).toBe("none");
  expect(manual.scale).toBe("1");

  const system = await readPressedStyle("system");
  expect(system.transitionProperty).toBe("none");
  expect(system.scale).toBe("1");
});

test("AI Input shows the first rich line break and restores its placeholder", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiInputFixture));

  const editor = page.getByRole("textbox", { name: "Rich AI prompt" });
  await editor.fill("hello");

  await editor.press("Shift+Enter");

  await expect
    .poll(() => page.evaluate(() => window.aiInputFixture?.getRichSnapshot().plainText))
    .toBe("hello\n");
  await expect
    .poll(() =>
      editor.evaluate((element) => ({
        trailingBreaks: element.querySelectorAll("[data-ai-input-trailing-break]")
          .length,
        visibleTrailingLine: (() => {
          const trailingBreak = element.querySelector("[data-ai-input-trailing-break]");
          const firstText = Array.from(element.childNodes).find(
            (node) => node.nodeType === Node.TEXT_NODE && node.textContent
          );
          if (!trailingBreak || !firstText) return false;
          const firstCharacter = document.createRange();
          firstCharacter.setStart(firstText, 0);
          firstCharacter.setEnd(firstText, 1);
          const firstLineRect = firstCharacter.getClientRects()[0];
          return (
            firstLineRect !== undefined &&
            trailingBreak.getBoundingClientRect().top > firstLineRect.top
          );
        })(),
      }))
    )
    .toEqual({
      trailingBreaks: 1,
      visibleTrailingLine: true,
    });

  await page.keyboard.type("world");
  await expect
    .poll(() => page.evaluate(() => window.aiInputFixture?.getRichSnapshot().plainText))
    .toBe("hello\nworld");
  expect(
    await editor.evaluate((element) => ({
      emptyTextNodes: Array.from(element.childNodes).filter(
        (node) => node.nodeType === Node.TEXT_NODE && node.textContent === ""
      ).length,
      trailingBreaks: element.querySelectorAll("[data-ai-input-trailing-break]").length,
    }))
  ).toEqual({ emptyTextNodes: 0, trailingBreaks: 0 });

  await editor.press("ControlOrMeta+A");
  await editor.press("Backspace");

  await expect
    .poll(() => page.evaluate(() => window.aiInputFixture?.getRichSnapshot().plainText))
    .toBe("");
  await expect(editor).toHaveAttribute("data-empty", "true");
  await expect(editor).toHaveJSProperty("innerHTML", "");
  expect(
    await editor.evaluate((element) => getComputedStyle(element, "::before").content)
  ).toBe('"Type / for commands, @ for context"');
});

test("AI Input keeps the caret visible through repeated rich line breaks", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiInputFixture));

  const editor = page.getByRole("textbox", { name: "Rich AI prompt" });
  await editor.fill("hello");
  for (let index = 0; index < 8; index += 1) {
    await editor.press("Shift+Enter");
  }

  const expectedValue = `hello${"\n".repeat(8)}`;
  await expect
    .poll(() => page.evaluate(() => window.aiInputFixture?.getRichSnapshot().plainText))
    .toBe(expectedValue);

  const caretState = await editor.evaluate((element, expectedLength) => {
    const marker = element.querySelector<HTMLElement>("[data-ai-input-trailing-break]");
    const selection = window.getSelection();
    const range = selection?.rangeCount ? selection.getRangeAt(0) : null;
    const editorRect = element.getBoundingClientRect();
    const markerRect = marker?.getBoundingClientRect();
    const visibleTop = editorRect.top + element.clientTop;
    const visibleBottom = visibleTop + element.clientHeight;

    return {
      active: document.activeElement === element,
      canonicalDom:
        element.childNodes.length === 2 &&
        element.firstChild?.nodeType === Node.TEXT_NODE &&
        element.lastChild === marker,
      caretAtEnd:
        selection?.isCollapsed === true &&
        range?.startContainer === element.firstChild &&
        range.startOffset === expectedLength,
      markerCount: element.querySelectorAll("[data-ai-input-trailing-break]").length,
      overflowing: element.scrollHeight > element.clientHeight,
      scrolled: element.scrollTop > 0,
      trailingLineVisible:
        markerRect !== undefined &&
        markerRect.top >= visibleTop - 0.5 &&
        markerRect.bottom <= visibleBottom + 0.5,
    };
  }, expectedValue.length);

  expect(caretState).toEqual({
    active: true,
    canonicalDom: true,
    caretAtEnd: true,
    markerCount: 1,
    overflowing: true,
    scrolled: true,
    trailingLineVisible: true,
  });
});

test("AI Input menu panel pops up at the trigger position, not the shell edge", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiInputFixture));
  await page.evaluate(() => window.aiInputFixture?.loadAsyncMenus());

  const editor = page.getByRole("textbox", { name: "Async skills prompt" });
  await editor.click();
  await editor.press("End");
  await page.keyboard.type(" /");

  const menu = page.getByRole("listbox", { name: "Skills" });
  await expect(menu).toBeVisible();

  const menuBox = await menu.boundingBox();
  const editorBox = await editor.boundingBox();
  if (!menuBox || !editorBox) throw new Error("expected menu and editor boxes");
  // Anchored to the caret after "review this ", not flush to the shell's left.
  expect(menuBox.x).toBeGreaterThan(editorBox.x + 40);
  // And it sits above the line being typed.
  expect(menuBox.y + menuBox.height).toBeLessThanOrEqual(editorBox.y + 1);
});

test("AI Input clamps and ellipsizes long titles in menu rows and tokens", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiInputFixture));

  const editor = page.getByRole("textbox", { name: "Rich AI prompt" });
  await editor.click();
  await page.keyboard.type("@overflowing");

  const menu = page.getByRole("listbox", { name: "Mentions" });
  const row = menu.getByRole("option", { name: /Overflowing extremely long/ });
  await expect(row).toBeVisible();
  expect(
    await row.evaluate(
      (option, panel) => {
        const label = option.querySelector("span:not([data-slot])");
        return (
          label !== null &&
          label.scrollWidth > label.clientWidth &&
          option.getBoundingClientRect().right <=
            panel!.getBoundingClientRect().right + 1
        );
      },
      await menu.elementHandle()
    )
  ).toBe(true);

  await editor.press("Enter");
  const token = editor.locator("[data-ai-input-token]");
  await expect(token).toBeVisible();
  // The pill caps at 220px and never exceeds its editor (min(220px, 100%)),
  // ellipsizing the label — here the narrow editor is the binding constraint.
  expect(
    await token.evaluate((element) => {
      const label = element.querySelector("span:last-child");
      const editorElement = element.closest('[contenteditable="true"]');
      return {
        cappedAt220: element.getBoundingClientRect().width <= 220.5,
        insideEditor:
          editorElement !== null &&
          element.getBoundingClientRect().right <=
            editorElement.getBoundingClientRect().right + 1,
        ellipsized: label !== null && label.scrollWidth > label.clientWidth,
      };
    })
  ).toEqual({ cappedAt220: true, insideEditor: true, ellipsized: true });
});

test("AI Input fits inside a 320px container without horizontal overflow", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiInputFixture));

  const dimensions = await page
    .getByTestId("narrow-ai-input-container")
    .evaluate((container) => {
      const input = container.firstElementChild;
      if (!(input instanceof HTMLElement)) {
        throw new Error("Narrow AI Input was not mounted.");
      }

      return {
        containerWidth: container.getBoundingClientRect().width,
        inputWidth: input.getBoundingClientRect().width,
      };
    });

  expect(dimensions.containerWidth).toBe(320);
  expect(dimensions.inputWidth).toBeLessThanOrEqual(dimensions.containerWidth);
});

test("AI Input clears active rich UI and makes tokens inert when disabled", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiInputFixture));

  const editor = page.getByRole("textbox", { name: "Rich AI prompt" });
  await editor.click();
  await page.keyboard.type("/");
  const menu = page.getByRole("listbox", { name: "Skills" });
  await expect(menu).toBeVisible();
  await editor.press("Enter");
  const token = editor.locator("[data-ai-input-token]");
  await token.click();
  await expect(token).toHaveAttribute("aria-pressed", "true");

  await page.evaluate(() => window.aiInputFixture?.setRichDisabled(true));
  await expect(menu).toBeHidden();
  await expect(token).toBeDisabled();
  await expect(token).toHaveAttribute("aria-pressed", "false");
  await expect(editor).toHaveAttribute("contenteditable", "false");
  await expect(editor).toHaveAttribute("tabindex", "-1");
  await editor.dispatchEvent("keydown", { key: "Delete" });
  await expect(token).toHaveCount(1);

  await page.evaluate(() => window.aiInputFixture?.setRichDisabled(false));
  await expect(editor).toHaveAttribute("contenteditable", "true");
  await editor.evaluate((element) => {
    element.focus();
    const range = document.createRange();
    range.selectNodeContents(element);
    range.collapse(false);
    const selection = window.getSelection();
    selection?.removeAllRanges();
    selection?.addRange(range);
  });
  await page.keyboard.type("/");
  await expect(menu).toBeVisible();
  await page.evaluate(() => window.aiInputFixture?.setRichDisabled(true));
  await expect(menu).toBeHidden();
});

async function getAiInputSnapshot(page: Page) {
  return page.evaluate(() => {
    const snapshot = window.aiInputFixture?.getSnapshot();

    if (!snapshot) {
      throw new Error("AI Input fixture is not ready.");
    }

    return snapshot;
  });
}
