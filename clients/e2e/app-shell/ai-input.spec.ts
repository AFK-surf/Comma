import { expect, test, type Page } from "@playwright/test";
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

const currentDir = fileURLToPath(new URL(".", import.meta.url));
const clientsRoot = resolve(currentDir, "../..");
const fixtureRoot = resolve(currentDir, "fixtures/ai-input");

let fixtureServer: BuiltFixtureServer | undefined;
let fixtureUrl = "";

test.beforeAll(async () => {
  fixtureServer = await createBuiltFixtureServer({
    cacheDir: resolve(clientsRoot, "node_modules/.vite/ai-input-e2e"),
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
      host: "127.0.0.1",
      port: 0,
    },
  });

  const address = fixtureServer.httpServer?.address();
  if (!address || typeof address === "string") {
    throw new Error("AI Input fixture server did not expose a TCP port.");
  }

  fixtureUrl = `http://127.0.0.1:${(address as AddressInfo).port}/`;
});

test.afterAll(async () => {
  await fixtureServer?.close();
});

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

test("AI Input shows image upload progress and retries a failed tile", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiInputFixture));

  const shell = page.getByTestId("primary-ai-input");
  const loading = shell.locator(
    '[data-slot="image-attachment"] [data-state="loading"]'
  );
  const errored = shell.locator('[data-slot="image-attachment"] [data-state="error"]');

  // Every state keeps the same 48px footprint, so the row never reflows as an
  // upload settles.
  await expect(loading).toBeVisible();
  expect(await loading.boundingBox()).toMatchObject({ height: 48, width: 48 });
  await expect(loading).toContainText("Uploading shot.png");

  await expect(errored).toBeVisible();
  expect(await errored.boundingBox()).toMatchObject({ height: 48, width: 48 });
  await expect(errored).toHaveText("Retry");
  await expect(errored).toHaveAccessibleName("Retry uploading Broken shot.png");

  // The failed tile is the retry target, and pressing it re-enters loading.
  await errored.click();
  await expect(errored).toBeHidden();
  await expect(
    shell.locator('[data-slot="image-attachment"] [data-state="loading"]')
  ).toHaveCount(2);
});

test("AI Input shows the drop overlay while files are dragged over", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiInputFixture));

  const shell = page.getByTestId("ai-input-shell").first();
  const overlay = shell.getByTestId("ai-input-drop-overlay");
  const textarea = shell.getByLabel("AI prompt", { exact: true });
  await expect(shell).not.toHaveAttribute("data-drop-active", "true");
  await expect(overlay).not.toHaveAttribute("data-drop-active", "true");
  await expect(textarea).toHaveAttribute("placeholder", "Do anything");

  await shell.evaluate((element) => {
    const dataTransfer = new DataTransfer();
    dataTransfer.items.add(new File(["fixture"], "fixture.txt"));
    element.dispatchEvent(
      new DragEvent("dragenter", {
        bubbles: true,
        cancelable: true,
        dataTransfer,
      })
    );
  });

  await expect(shell).toHaveAttribute("data-drop-active", "true");
  await expect(overlay).toHaveAttribute("data-drop-active", "true");
  await expect(overlay).toContainText("Drop anything here");
  await expect(overlay).toContainText("Docs, images, videos and more");
  await expect(textarea).toHaveAttribute("placeholder", "Do anything");
  await expect(shell.getByRole("button", { name: "Add attachment" })).toBeDisabled();
  await expect(shell.getByRole("button", { name: "Voice input" })).toBeDisabled();

  await shell.evaluate((element) => {
    const dataTransfer = new DataTransfer();
    dataTransfer.items.add(new File(["fixture"], "fixture.txt"));
    element.dispatchEvent(
      new DragEvent("dragleave", {
        bubbles: true,
        cancelable: true,
        dataTransfer,
      })
    );
  });
  await expect(shell).not.toHaveAttribute("data-drop-active", "true");
  await expect(overlay).not.toHaveAttribute("data-drop-active", "true");
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

test("AI Input still pastes text with Cmd/Ctrl+V", async ({ page, context }) => {
  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiInputFixture));

  const textarea = page.getByLabel("AI prompt", { exact: true });
  await page.evaluate(() => navigator.clipboard.writeText("just text"));

  await textarea.focus();
  await page.keyboard.press("ControlOrMeta+V");

  await expect(textarea).toHaveValue("just text");
  await expect(page.getByTestId("attachment-count")).toHaveText("Attachments: 5");
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

test("AI Input keeps voice keyboard actions inside the active recorder", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiInputFixture));

  const primary = page.getByTestId("primary-ai-input");
  await primary.getByRole("button", { name: "Voice input" }).click();
  const recording = primary.locator('[data-slot="ai-input-voice-recording"]');
  await expect(recording).toBeFocused();

  const otherComposer = page.getByRole("textbox", { name: "Rich AI prompt" });
  await otherComposer.fill("submit from another composer");
  await otherComposer.press("Enter");

  await expect(recording).toBeVisible();
  await expect
    .poll(() => page.evaluate(() => window.aiInputFixture?.getVoiceSnapshot()))
    .toEqual({ cancels: 0, confirms: 0, presses: 1 });
  await expect
    .poll(() =>
      page.evaluate(() => window.aiInputFixture?.getRichSnapshot().lastSubmission)
    )
    .toEqual({
      plainText: "submit from another composer",
      tokenItemIds: [],
      tokenRevisions: [],
    });
});

test("AI Input restores voice focus after keyboard cancel and confirm", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiInputFixture));

  const primary = page.getByTestId("primary-ai-input");
  const voiceTrigger = primary.getByRole("button", { name: "Voice input" });
  await voiceTrigger.focus();
  await voiceTrigger.press("Enter");
  let recording = primary.locator('[data-slot="ai-input-voice-recording"]');
  await expect(recording).toBeFocused();
  await recording.press("Escape");
  await expect(voiceTrigger).toBeFocused();

  await voiceTrigger.press("Enter");
  recording = primary.locator('[data-slot="ai-input-voice-recording"]');
  await expect(recording).toBeFocused();
  await recording.press("Enter");
  await expect(voiceTrigger).toBeFocused();
  await expect
    .poll(() => page.evaluate(() => window.aiInputFixture?.getVoiceSnapshot()))
    .toEqual({ cancels: 1, confirms: 1, presses: 2 });
});

test("AI Input honors voice eligibility changes throughout recording", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiInputFixture));

  const primary = page.getByTestId("primary-ai-input");
  const voiceTrigger = primary.getByRole("button", { name: "Voice input" });

  await page.evaluate(() => window.aiInputFixture?.setPrimaryReadOnly(true));
  await expect(voiceTrigger).toBeDisabled();
  await page.evaluate(() => window.aiInputFixture?.setPrimaryReadOnly(false));

  const transitions = [
    {
      makeIneligible: () =>
        page.evaluate(() => window.aiInputFixture?.setPrimaryDisabled(true)),
      restore: () =>
        page.evaluate(() => window.aiInputFixture?.setPrimaryDisabled(false)),
    },
    {
      makeIneligible: () =>
        page.evaluate(() => window.aiInputFixture?.setPrimaryReadOnly(true)),
      restore: () =>
        page.evaluate(() => window.aiInputFixture?.setPrimaryReadOnly(false)),
    },
    {
      makeIneligible: () =>
        page.evaluate(() => window.aiInputFixture?.setPrimarySubmitPending(true)),
      restore: () =>
        page.evaluate(() => window.aiInputFixture?.setPrimarySubmitPending(false)),
    },
    {
      makeIneligible: () =>
        page.evaluate(() => window.aiInputFixture?.setPrimaryShowVoiceButton(false)),
      restore: () =>
        page.evaluate(() => window.aiInputFixture?.setPrimaryShowVoiceButton(true)),
    },
  ];

  for (const [index, transition] of transitions.entries()) {
    await voiceTrigger.click();
    await expect(
      primary.locator('[data-slot="ai-input-voice-recording"]')
    ).toBeVisible();
    await transition.makeIneligible();
    await expect(primary.locator('[data-slot="ai-input-voice-recording"]')).toHaveCount(
      0
    );
    await expect
      .poll(() =>
        page.evaluate(() => window.aiInputFixture?.getVoiceSnapshot().cancels)
      )
      .toBe(index + 1);
    await transition.restore();
    await expect(voiceTrigger).toBeEnabled();
  }
});

test("AI Input starts voice recording with the advertised Control+D shortcut", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiInputFixture));

  const primary = page.getByTestId("primary-ai-input");
  const prompt = primary.getByRole("textbox", { name: "AI prompt" });
  await prompt.focus();
  await prompt.press("Control+d");

  await expect(primary.locator('[data-slot="ai-input-voice-recording"]')).toBeFocused();
  await expect
    .poll(() => page.evaluate(() => window.aiInputFixture?.getVoiceSnapshot()))
    .toEqual({ cancels: 0, confirms: 0, presses: 1 });
});

test("AI Input rich menu keeps the keyboard selection through keyup", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiInputFixture));

  const editor = page.getByRole("textbox", { name: "Rich AI prompt" });
  await editor.click();
  await page.keyboard.type("/");

  const menu = page.getByRole("listbox", { name: "Skills" });
  const alpha = menu.getByRole("option", { name: "Alpha" });
  const beta = menu.getByRole("option", { name: "Beta" });
  await expect(menu).toBeVisible();
  await expect(alpha).toHaveAttribute("aria-selected", "true");

  // Playwright's press dispatches both keydown and keyup, matching a real key press.
  await editor.press("ArrowDown");
  await expect(beta).toHaveAttribute("aria-selected", "true");
  await editor.press("Enter");

  await expect(menu).toBeHidden();
  await expect(editor.locator("[data-ai-input-token]")).toHaveText("Beta");

  await page.getByRole("button", { name: "Submit rich prompt" }).click();
  await expect
    .poll(() =>
      page.evaluate(() => window.aiInputFixture?.getRichSnapshot().lastSubmission)
    )
    .toEqual({
      plainText: "/beta ",
      tokenItemIds: ["beta"],
      tokenRevisions: [null],
    });
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
  ).toBe('"Ask Comma, @ for context"');
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

for (const vendor of ["Google Inc.", "Apple Computer, Inc."]) {
  test(`AI Input IME confirmation and immediate submit (${vendor})`, async ({
    page,
  }) => {
    // Exercise both event contracts in Chromium. This does not emulate a native IME.
    await page.addInitScript((value) => {
      Object.defineProperty(navigator, "vendor", { get: () => value });
    }, vendor);
    await page.goto(fixtureUrl);
    await page.waitForFunction(() => Boolean(window.aiInputFixture));
    const editor = page.getByRole("textbox", { name: "Rich AI prompt" });
    await editor.fill("你好");
    // Keep all presses inside the confirmation window, regardless of runner load.
    await page.clock.setFixedTime(new Date("2026-01-01T00:00:00Z"));
    await editor.dispatchEvent("compositionstart", { data: "" });
    await editor.dispatchEvent("keydown", {
      key: "Enter",
      keyCode: 229,
      isComposing: true,
    });
    const submission = () =>
      page.evaluate(() => window.aiInputFixture?.getRichSnapshot().lastSubmission);
    expect(await submission()).toBeNull();

    await editor.evaluate((element) => {
      element.dispatchEvent(
        new CompositionEvent("compositionend", { bubbles: true, data: "你好" })
      );
      element.dispatchEvent(
        new KeyboardEvent("keydown", {
          bubbles: true,
          cancelable: true,
          key: "Enter",
          keyCode: 13,
        })
      );
    });
    if (vendor === "Apple Computer, Inc.") {
      // A markerless WebKit confirmation must not send. The next press must send.
      expect(await submission()).toBeNull();
      await editor.press("Enter");
    }
    await expect.poll(submission).toEqual({
      plainText: "你好",
      tokenItemIds: [],
      tokenRevisions: [],
    });
  });
}

test("AI Input expands during IME composition without committing intermediate text", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiInputFixture));

  const editor = page.getByRole("textbox", { name: "Rich AI prompt" });
  const composingText = "大傻的大傻的两回事还得看脸色 d s d s d s d sa";
  await editor.evaluate((element, text) => {
    element.focus();
    element.dispatchEvent(
      new CompositionEvent("compositionstart", {
        bubbles: true,
        data: text,
      })
    );
    element.textContent = text;
    const textNode = element.firstChild;
    if (!textNode) throw new Error("IME composition did not create a text node.");
    const range = document.createRange();
    range.setStart(textNode, text.length);
    range.collapse(true);
    const selection = window.getSelection();
    selection?.removeAllRanges();
    selection?.addRange(range);
    element.dispatchEvent(
      new InputEvent("input", {
        bubbles: true,
        composed: true,
        data: text,
        inputType: "insertCompositionText",
        isComposing: true,
      })
    );
  }, composingText);

  await expect
    .poll(() =>
      editor.evaluate((element) => {
        const layout = element.parentElement?.parentElement;
        const shell = layout?.parentElement;
        const toolbar = layout?.querySelector<HTMLElement>(
          '[data-slot="ai-input-toolbar"]'
        );
        const editorRect = element.getBoundingClientRect();
        const toolbarRect = toolbar?.getBoundingClientRect();

        return {
          editorExpanded: editorRect.height > 36,
          layoutExpanded: (layout?.getBoundingClientRect().height ?? 0) > 36,
          shellExpanded: (shell?.getBoundingClientRect().height ?? 0) > 50,
          toolbarBelowPrompt:
            toolbarRect !== undefined && toolbarRect.top >= editorRect.bottom,
        };
      })
    )
    .toEqual({
      editorExpanded: true,
      layoutExpanded: true,
      shellExpanded: true,
      toolbarBelowPrompt: true,
    });
  await expect(editor).toHaveText(composingText);
  await expect
    .poll(() => page.evaluate(() => window.aiInputFixture?.getRichSnapshot().plainText))
    .toBe("");

  await editor.evaluate((element, text) => {
    element.dispatchEvent(
      new CompositionEvent("compositionend", {
        bubbles: true,
        data: text,
      })
    );
  }, composingText);

  await expect
    .poll(() => page.evaluate(() => window.aiInputFixture?.getRichSnapshot().plainText))
    .toBe(composingText);
});

test("AI Input rich menu stays dismissed until its trigger changes", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiInputFixture));

  const editor = page.getByRole("textbox", { name: "Rich AI prompt" });
  await editor.click();
  await page.keyboard.type("/");

  const menu = page.getByRole("listbox", { name: "Skills" });
  await expect(menu).toBeVisible();
  await editor.press("Escape");
  await expect(menu).toBeHidden();
  await editor.press("Shift");
  await expect(menu).toBeHidden();
  await page.keyboard.type("a");
  await expect(menu).toBeVisible();
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

test("AI Input @ panel lists sections, runs the Add action, and clears the trigger", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiInputFixture));

  await page.evaluate(() => window.aiInputFixture?.setMentionRoutinesLoading(true));
  const editor = page.getByRole("textbox", { name: "Rich AI prompt" });
  await editor.click();
  await page.keyboard.type("Use @");

  const menu = page.getByRole("listbox", { name: "Mentions" });
  await expect(menu).toBeVisible();
  await expect(menu.getByText("Add", { exact: true })).toBeVisible();
  await expect(menu.getByText("Tasks", { exact: true })).toBeVisible();
  // The routines section is still indexing, so the panel keeps one shimmer row.
  await expect(menu.getByTestId("ai-input-menu-searching")).toHaveText("Searching...");

  const addFiles = menu.getByRole("option", { name: "Add files or folders" });
  await expect(addFiles).toHaveAttribute("aria-selected", "true");
  await editor.press("Enter");

  await expect(menu).toBeHidden();
  await expect
    .poll(() => page.evaluate(() => window.aiInputFixture?.getMentionSnapshot()))
    .toEqual({ addFilesPresses: 1 });
  await expect
    .poll(() => page.evaluate(() => window.aiInputFixture?.getRichSnapshot().plainText))
    .toBe("Use ");
});

test("AI Input @ panel shows No results and lets Enter submit", async ({ page }) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiInputFixture));

  const editor = page.getByRole("textbox", { name: "Rich AI prompt" });
  await editor.click();
  await page.keyboard.type("@zzzz");

  const menu = page.getByRole("listbox", { name: "Mentions" });
  await expect(menu).toBeVisible();
  await expect(menu.getByTestId("ai-input-menu-no-results")).toHaveText("No results");

  await editor.press("Enter");
  await expect
    .poll(() =>
      page.evaluate(
        () => window.aiInputFixture?.getRichSnapshot().lastSubmission?.plainText
      )
    )
    .toBe("@zzzz");
});

test("AI Input refreshes an open loading mention query when results resolve", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiInputFixture));
  await page.evaluate(() => window.aiInputFixture?.setMentionRoutinesLoading(true));

  const editor = page.getByRole("textbox", { name: "Rich AI prompt" });
  await editor.click();
  await page.keyboard.type("@daily");

  const menu = page.getByRole("listbox", { name: "Mentions" });
  await expect(menu.getByTestId("ai-input-menu-searching")).toHaveText("Searching...");

  await page.evaluate(() => window.aiInputFixture?.resolveMentionRoutines());

  await expect(menu.getByRole("option", { name: "Daily digest" })).toBeVisible();
  await expect(menu.getByTestId("ai-input-menu-searching")).toHaveCount(0);
});

test("AI Input keeps an empty loading mention query from submitting", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiInputFixture));
  await page.evaluate(() => window.aiInputFixture?.setMentionRoutinesLoading(true));

  const editor = page.getByRole("textbox", { name: "Rich AI prompt" });
  await editor.click();
  await page.keyboard.type("@daily");

  const menu = page.getByRole("listbox", { name: "Mentions" });
  await expect(menu.getByTestId("ai-input-menu-searching")).toBeVisible();
  await page.keyboard.press("Enter");

  await expect(menu).toBeVisible();
  await expect
    .poll(() =>
      page.evaluate(
        () => window.aiInputFixture?.getRichSnapshot().lastSubmission ?? null
      )
    )
    .toBeNull();
  await expect
    .poll(() => page.evaluate(() => window.aiInputFixture?.getRichSnapshot().plainText))
    .toBe("@daily");
});

test("AI Input arrow keys continue from the hovered mention item", async ({ page }) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiInputFixture));

  const editor = page.getByRole("textbox", { name: "Rich AI prompt" });
  await editor.click();
  await page.keyboard.type("@");

  const menu = page.getByRole("listbox", { name: "Mentions" });
  const first = menu.getByRole("option", { name: "Add files or folders" });
  const second = menu.getByRole("option", { name: "Fix login flow" });
  await second.hover();
  await expect(second).toHaveAttribute("aria-selected", "true");

  await page.keyboard.press("ArrowUp");
  await expect(first).toHaveAttribute("aria-selected", "true");
  await page.keyboard.press("ArrowDown");
  await expect(second).toHaveAttribute("aria-selected", "true");
});

test("AI Input @ Task mention inserts a token that submits the comma:task link", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiInputFixture));

  const editor = page.getByRole("textbox", { name: "Rich AI prompt" });
  await editor.click();
  await page.keyboard.type("Check @fix");

  const menu = page.getByRole("listbox", { name: "Mentions" });
  await expect(menu.getByRole("option", { name: "Fix login flow" })).toHaveAttribute(
    "aria-selected",
    "true"
  );
  await editor.press("Enter");
  await expect(menu).toBeHidden();
  await expect(editor.locator("[data-ai-input-token]")).toHaveText("Fix login flow");

  await page.getByRole("button", { name: "Submit rich prompt" }).click();
  await expect
    .poll(() =>
      page.evaluate(() => window.aiInputFixture?.getRichSnapshot().lastSubmission)
    )
    .toEqual({
      plainText: "Check [Fix login flow](comma:task/cnv1_e2e) ",
      tokenItemIds: ["task:cnv1_e2e"],
      tokenRevisions: [null],
    });
});

test("AI Input lets an over-limit rich value be shortened by replacement", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiInputFixture));

  const editor = page.getByRole("textbox", { name: "Over-limit rich prompt" });
  await editor.evaluate((element) => {
    element.focus();
    const text = element.firstChild;
    if (!text) throw new Error("Over-limit rich text was not mounted.");
    const range = document.createRange();
    range.setStart(text, 8);
    range.setEnd(text, 10);
    const selection = window.getSelection();
    selection?.removeAllRanges();
    selection?.addRange(range);
  });
  await page.keyboard.type("X");

  await expect(editor).toHaveText("12345678X");
});

test("AI Input context-menu Paste keeps the textarea within maxLength", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiInputFixture));
  await page.evaluate(() => window.aiInputFixture?.setPlainClipboardText("6789"));

  const textarea = page.getByRole("textbox", {
    name: "Max-length plain prompt",
  });
  const contextMenuPrevented = await textarea.evaluate((element) => {
    if (!(element instanceof HTMLTextAreaElement)) {
      throw new Error("Max-length plain prompt is not a textarea.");
    }
    element.focus();
    element.setSelectionRange(3, 5);
    const bounds = element.getBoundingClientRect();
    const event = new MouseEvent("contextmenu", {
      bubbles: true,
      cancelable: true,
      clientX: bounds.left + 12,
      clientY: bounds.top + 12,
    });
    element.dispatchEvent(event);
    return event.defaultPrevented;
  });
  expect(contextMenuPrevented).toBe(true);
  await page.getByRole("menuitem", { name: "Paste", exact: true }).click();

  await expect(textarea).toHaveValue("12367");
  await expect
    .poll(() =>
      textarea.evaluate((element) => {
        if (!(element instanceof HTMLTextAreaElement)) {
          throw new Error("Max-length plain prompt is not a textarea.");
        }
        return {
          end: element.selectionEnd,
          start: element.selectionStart,
        };
      })
    )
    .toEqual({ end: 5, start: 5 });
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

test("AI Input preserves the focused editor and caret when menus load", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiInputFixture));

  const editor = page.getByRole("textbox", { name: "Async skills prompt" });
  const initialEditor = await editor.elementHandle();
  if (!initialEditor) throw new Error("Async AI Input was not mounted.");
  await editor.evaluate((element) => {
    element.focus();
    const text = element.firstChild;
    if (!text) throw new Error("Async AI Input text was not mounted.");
    const range = document.createRange();
    range.setStart(text, 6);
    range.collapse(true);
    const selection = window.getSelection();
    selection?.removeAllRanges();
    selection?.addRange(range);
  });

  await page.evaluate(() => window.aiInputFixture?.loadAsyncMenus());
  const loadedEditor = await editor.elementHandle();
  if (!loadedEditor) throw new Error("Async AI Input disappeared after menu load.");

  expect(
    await loadedEditor.evaluate((element, before) => element === before, initialEditor)
  ).toBe(true);
  await expect(editor).toBeFocused();
  await expect
    .poll(() => readContenteditableCaret(page, "Async skills prompt"))
    .toBe(6);
});

test("AI Input preserves restored token metadata through edits and submit", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiInputFixture));
  await page.evaluate(() => window.aiInputFixture?.restoreRichValue(1));

  const editor = page.getByRole("textbox", { name: "Rich AI prompt" });
  await expect(editor.locator("[data-ai-input-token]")).toHaveText("Alpha");
  await page.evaluate(() => window.aiInputFixture?.updateRestoredTokenRevision(2));
  await editor.click();
  await editor.press("End");
  await page.keyboard.type("!");

  await expect
    .poll(() => page.evaluate(() => window.aiInputFixture?.getRichSnapshot()))
    .toMatchObject({
      plainText: "/alpha draft!",
      tokenItemIds: ["alpha"],
      tokenRevisions: [2],
    });

  await page.getByRole("button", { name: "Submit rich prompt" }).click();
  await expect
    .poll(() =>
      page.evaluate(() => window.aiInputFixture?.getRichSnapshot().lastSubmission)
    )
    .toEqual({
      plainText: "/alpha draft!",
      tokenItemIds: ["alpha"],
      tokenRevisions: [2],
    });
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

async function readContenteditableCaret(page: Page, label: string) {
  return page.getByRole("textbox", { name: label }).evaluate((editor) => {
    const selection = window.getSelection();
    if (!selection || selection.rangeCount === 0) return null;
    const activeRange = selection.getRangeAt(0);
    const prefix = activeRange.cloneRange();
    prefix.selectNodeContents(editor);
    prefix.setEnd(activeRange.endContainer, activeRange.endOffset);
    return prefix.toString().length;
  });
}
