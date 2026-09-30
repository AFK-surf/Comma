import { expect, test, type Locator, type Page } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { startChatSmokeStub } from "../../../e2e/p0/chat-stub";

// These regressions use the same public HTTP/SSE fixture as chat-reply-streaming:
// a real send, source-bound draft updates and the canonical conversation snapshot.
for (const container of ["blockquote", "list"] as const) {
  test(`a late reference definition preserves code inside the same ${container}`, async ({
    page,
  }) => {
    const lines = [
      "[Guide][guide]",
      "",
      "```js",
      "const ready = true;",
      "finish(ready);",
      "```",
      "",
      "The code in this container has finished.",
    ];
    const initial =
      container === "blockquote"
        ? lines.map((line) => `> ${line}`).join("\n")
        : lines.map((line, index) => `${index === 0 ? "- " : "  "}${line}`).join("\n");
    const appended = `${initial}\n\n[guide]: http://127.0.0.1/streaming-guide\n\n`;
    const stub = await startChatSmokeStub({
      assistantDraft: initial,
      assistantReply: appended,
      holdStreamingReplyStart: true,
      streamAssistantReply: true,
    });
    try {
      const content = await openDraft(page, stub, `nested-${container}`);
      const draft = content.getByTestId("chat-assistant-draft");
      const code = draft.locator("figure.markdown-stream-code-block");
      await expect(
        code.locator(
          ".code-block-render:not(.hidden):not(.code-block-render-pending) pre"
        )
      ).toContainText("finish(ready);");
      const continuity = await observeCompletedBlocks(draft, [
        "figure.markdown-stream-code-block",
      ]);
      stub.updateStreamingDraft(appended);
      await expect(
        draft.getByRole("link", { name: "Guide", exact: true })
      ).toHaveAttribute("href", "http://127.0.0.1/streaming-guide");
      await expectCompletedBlocks(continuity);
      stub.completeStreamingReply();
      await expect(
        content.locator('[data-message-id="msg-assistant-smoke"]')
      ).toBeVisible();
      await expectCompletedBlocks(continuity);
      await continuity.evaluate(({ stop }) => stop());
      await continuity.dispose();
    } finally {
      await stub.close();
    }
  });
}

test("canonical whitespace normalization preserves completed mixed blocks", async ({
  page,
}) => {
  const initial = [
    "A completed paragraph.",
    "",
    "- First item",
    "- Second item",
    "",
    "> A completed quote.",
    "",
    "| Item | Status |",
    "| --- | --- |",
    "| Work | Ready |",
    "",
    "Below is code:",
    "",
    "```js",
    "const ready = true;",
    "```",
    "",
    "The mixed reply is complete.",
    "",
    "",
  ].join("\n");
  const stub = await startChatSmokeStub({
    assistantDraft: initial,
    assistantReply: initial,
    holdStreamingReplyStart: true,
    streamAssistantReply: true,
  });
  try {
    const content = await openDraft(page, stub, "canonical-whitespace");
    const draft = content.getByTestId("chat-assistant-draft");
    await expect(
      draft.locator(
        ".code-block-render:not(.hidden):not(.code-block-render-pending) pre"
      )
    ).toContainText("const ready = true;");
    const continuity = await observeCompletedBlocks(draft, [
      "p",
      "ul",
      "blockquote",
      "table",
      "figure.markdown-stream-code-block",
    ]);
    stub.completeStreamingReply();
    await expect(
      content.locator('[data-message-id="msg-assistant-smoke"]')
    ).toContainText("The mixed reply is complete.");
    await expect(draft).toHaveCount(0);
    await expect(content.locator('[data-slot="chat-assistant-output"]')).toHaveCount(1);
    const status = content.getByTestId("participant-status-slot");
    await expect(status).toBeHidden();
    expect((await status.boundingBox())?.height).toBe(40);
    await expectCompletedBlocks(continuity);
    await continuity.evaluate(({ stop }) => stop());
    await continuity.dispose();
  } finally {
    await stub.close();
  }
});

test("late references preserve an expanded nested code block", async ({ page }) => {
  const initial = [
    "> [Guide][guide]",
    ">",
    "> ```js",
    ...Array.from({ length: 40 }, (_, index) => `> const item${index} = ${index};`),
    "> ```",
    ">",
    "> The code has finished.",
  ].join("\n");
  const appended = `${initial}\n\n[guide]: http://127.0.0.1/expanded-guide`;
  const stub = await startChatSmokeStub({
    assistantDraft: initial,
    assistantReply: appended,
    holdStreamingReplyStart: true,
    streamAssistantReply: true,
  });
  try {
    const content = await openDraft(page, stub, "expanded-nested");
    const draft = content.getByTestId("chat-assistant-draft");
    const code = draft.locator("blockquote figure.markdown-stream-code-block");
    await expect(
      code.locator(
        ".code-block-render:not(.hidden):not(.code-block-render-pending) pre"
      )
    ).toContainText("const item31 = 31;");
    // The disclosure becomes interactive when the pointer enters its code block.
    await code.hover();
    const disclosure = code.locator("button[aria-expanded]");
    await disclosure.click();
    await expect(disclosure).toHaveAttribute("aria-expanded", "true");
    await expect(
      code.locator(
        ".code-block-render:not(.hidden):not(.code-block-render-pending) pre"
      )
    ).toContainText("const item39 = 39;");
    const continuity = await observeCompletedBlocks(draft, [
      "blockquote figure.markdown-stream-code-block",
    ]);
    stub.updateStreamingDraft(appended);
    await expect(
      draft.getByRole("link", { name: "Guide", exact: true })
    ).toHaveAttribute("href", "http://127.0.0.1/expanded-guide");
    expect(await disclosure.getAttribute("aria-expanded")).toBe("true");
    await expectCompletedBlocks(continuity);
    stub.completeStreamingReply();
    await expect(
      content.locator('[data-message-id="msg-assistant-smoke"]')
    ).toBeVisible();
    await expectCompletedBlocks(continuity);
    await continuity.evaluate(({ stop }) => stop());
    await continuity.dispose();
  } finally {
    await stub.close();
  }
});

test("streaming longer table cells keeps existing column widths stable", async ({
  page,
}) => {
  const initial = "| Project | State |\n| --- | --- |\n| A | Ready |\n";
  const rowParts = [
    "| A substantially longer project name",
    " | A description that keeps extending while the existing header remains visible",
    " and concludes with the final detail. |\n\n",
  ];
  const finalText = `${initial}${rowParts.join("")}The table is complete.`;
  const stub = await startChatSmokeStub({
    assistantDraft: initial,
    assistantReply: finalText,
    holdStreamingReplyStart: true,
    streamAssistantReply: true,
  });
  try {
    const content = await openDraft(page, stub, "stable-table-columns");
    const draft = content.getByTestId("chat-assistant-draft");
    const table = draft.getByRole("table");
    await expect(table).toContainText("Ready");
    const firstHeader = table.getByRole("columnheader").first();
    const initialWidth = (await firstHeader.boundingBox())!.width;
    let text = initial;
    for (const [index, part] of rowParts.entries()) {
      text += part;
      stub.updateStreamingDraft(text);
      await expect(table).toContainText(
        index === 0
          ? "longer project name"
          : index === 1
            ? "remains visible"
            : "final detail."
      );
      expect(
        Math.abs((await firstHeader.boundingBox())!.width - initialWidth)
      ).toBeLessThanOrEqual(0.5);
    }
    stub.completeStreamingReply();
    await expect(
      content.locator('[data-message-id="msg-assistant-smoke"]')
    ).toContainText("The table is complete.");
    expect(
      Math.abs(
        (await content
          .getByRole("table")
          .getByRole("columnheader")
          .first()
          .boundingBox())!.width - initialWidth
      )
    ).toBeLessThanOrEqual(0.5);
  } finally {
    await stub.close();
  }
});

test("a delayed image preserves the following text and opens its full original", async ({
  page,
}) => {
  let releaseImage: (() => void) | undefined;
  const imageReady = new Promise<void>((resolve) => {
    releaseImage = resolve;
  });
  const imageUrl = "http://127.0.0.1:4040/streaming-preview.svg";
  const text = `Before the image.\n\n![Local preview](${imageUrl})\n\nThe paragraph after the image is already readable.\n\n`;
  const stub = await startChatSmokeStub({
    assistantDraft: text,
    assistantReply: text,
    holdStreamingReplyStart: true,
    streamAssistantReply: true,
  });
  await page.context().route(imageUrl, async (route) => {
    await imageReady;
    await route.fulfill({
      contentType: "image/svg+xml",
      body: '<svg xmlns="http://www.w3.org/2000/svg" width="320" height="96"><rect width="320" height="96" fill="#518484"/></svg>',
    });
  });
  try {
    const content = await openDraft(page, stub, "delayed-image");
    const draft = content.getByTestId("chat-assistant-draft");
    const image = draft.getByRole("img", { name: "Local preview" });
    const paragraph = draft.locator("p").filter({
      hasText: "The paragraph after the image is already readable.",
    });
    await expect(paragraph).toBeVisible();
    expect(
      await image.evaluate((node) => (node as HTMLImageElement).naturalWidth)
    ).toBe(0);
    const imageNode = await image.elementHandle();
    const paragraphNode = await paragraph.elementHandle();
    const position = () =>
      paragraph.evaluate((node) => {
        const body = node.closest(".markdown-stream")!;
        return node.getBoundingClientRect().y - body.getBoundingClientRect().y;
      });
    const originalY = await position();
    releaseImage?.();
    await expect
      .poll(() => image.evaluate((node) => (node as HTMLImageElement).naturalWidth))
      .toBe(320);
    expect(Math.abs((await position()) - originalY)).toBeLessThanOrEqual(0.5);
    expect(await image.evaluate((node, original) => node === original, imageNode)).toBe(
      true
    );
    expect(
      await paragraph.evaluate((node, original) => node === original, paragraphNode)
    ).toBe(true);
    const preview = image.locator("..");
    const frame = (await preview.boundingBox())!;
    expect(Math.abs(frame.width / frame.height - 16 / 9)).toBeLessThan(0.01);
    expect(await image.evaluate((node) => getComputedStyle(node).objectFit)).toBe(
      "contain"
    );
    await expect(preview).toHaveAttribute("href", imageUrl);
    await expect(preview).toHaveAttribute("target", "_blank");
    await expect(preview).toHaveAttribute("rel", "noopener noreferrer");
    stub.completeStreamingReply();
    const canonical = content.locator('[data-message-id="msg-assistant-smoke"]');
    await expect(canonical).toContainText(
      "The paragraph after the image is already readable."
    );
    expect(
      await canonical
        .getByRole("img", { name: "Local preview" })
        .evaluate((node, original) => node === original, imageNode)
    ).toBe(true);
    const completedParagraph = canonical.locator("p").filter({
      hasText: "The paragraph after the image is already readable.",
    });
    expect(
      await completedParagraph.evaluate(
        (node, original) => node === original,
        paragraphNode
      )
    ).toBe(true);
    expect(
      Math.abs(
        (await completedParagraph.evaluate((node) => {
          const body = node.closest(".markdown-stream")!;
          return node.getBoundingClientRect().y - body.getBoundingClientRect().y;
        })) - originalY
      )
    ).toBeLessThanOrEqual(0.5);
    // App routes keyboard-activated links to its browser sidebar; this browser
    // fixture exposes the original URL and its external-browser fallback there.
    await canonical.getByRole("link", { name: "Local preview" }).focus();
    await page.keyboard.press("Enter");
    const browser = page.getByRole("tabpanel", { name: "Browser", exact: true });
    await expect(browser.getByRole("textbox", { name: "Address" })).toHaveValue(
      imageUrl
    );
    await expect(
      browser.getByRole("link", { name: "Open in browser" })
    ).toHaveAttribute("href", imageUrl);
  } finally {
    releaseImage?.();
    await stub.close();
  }
});

for (const ending of ["closed", "unfinished"] as const) {
  test(`a${ending === "unfinished" ? "n" : ""} ${ending} image URL never requests an intermediate address`, async ({
    page,
  }) => {
    const imageUrl = "http://127.0.0.1:4040/streaming-preview.svg";
    const initial = "A streaming image URL follows.\n\n![Local preview](http://1";
    const complete = `A streaming image URL follows.\n\n![Local preview](${imageUrl})`;
    const finalText = ending === "closed" ? complete : initial;
    const stub = await startChatSmokeStub({
      assistantDraft: initial,
      assistantReply: finalText,
      holdStreamingReplyStart: true,
      streamAssistantReply: true,
    });
    const imageRequests: string[] = [];
    await page.context().route("**/*", async (route) => {
      const request = route.request();
      const url = new URL(request.url());
      const local = ["127.0.0.1", "localhost", "[::1]"].includes(url.hostname);
      if (request.resourceType() === "image" && (url.port === "4040" || !local)) {
        imageRequests.push(request.url());
        await route.fulfill({
          contentType: "image/svg+xml",
          body: '<svg xmlns="http://www.w3.org/2000/svg" width="32" height="18"><rect width="32" height="18" fill="#518484"/></svg>',
        });
        return;
      }
      if (!local && ["http:", "https:"].includes(url.protocol)) {
        await route.abort();
        return;
      }
      await route.continue();
    });
    try {
      const content = await openDraft(page, stub, `image-url-${ending}`);
      const draft = content.getByTestId("chat-assistant-draft");
      await draft.evaluate(
        () =>
          new Promise<void>((resolve) =>
            requestAnimationFrame(() => requestAnimationFrame(() => resolve()))
          )
      );
      expect(imageRequests).toEqual([]);
      await expect(draft.getByRole("img")).toHaveCount(0);
      const pendingPreview = draft.locator(".markdown-stream-image-preview");
      await expect(pendingPreview).toHaveAttribute("aria-busy", "true");
      expect(await pendingPreview.getAttribute("href")).toBeNull();
      if (ending === "closed") {
        stub.updateStreamingDraft(complete);
        await expect(draft.getByRole("img", { name: "Local preview" })).toBeVisible();
        await expect.poll(() => imageRequests).toEqual([imageUrl]);
      }
      stub.completeStreamingReply();
      const canonical = content.locator('[data-message-id="msg-assistant-smoke"]');
      await expect(canonical).toBeVisible();
      expect(imageRequests).toEqual(ending === "closed" ? [imageUrl] : []);
      if (ending === "unfinished") {
        await expect(canonical.getByRole("img")).toHaveCount(0);
        expect(
          await canonical.locator(".markdown-stream-image-preview").getAttribute("href")
        ).toBeNull();
      }
    } finally {
      await stub.close();
    }
  });
}

test("a footnote definition prefix never becomes a formula", async ({ page }) => {
  const initial = [
    "Read the supporting detail[^detail].",
    "",
    "```js",
    "const ready = true;",
    "```",
    "",
    "[^detail]",
  ].join("\n");
  const complete = `${initial}: This is the supporting footnote.\n\n`;
  const stub = await startChatSmokeStub({
    assistantDraft: initial,
    assistantReply: complete,
    holdStreamingReplyStart: true,
    streamAssistantReply: true,
  });
  try {
    const content = await openDraft(page, stub, "footnote-prefix");
    const draft = content.getByTestId("chat-assistant-draft");
    await expect(
      draft.locator(".code-block-render:not(.code-block-render-pending) pre")
    ).toContainText("const ready = true;");
    // A real SSE boundary can land after the closing bracket and before ':';
    // this is a footnote-definition prefix, not a block formula.
    await expect(draft.locator(".math-block")).toHaveCount(0);
    const continuity = await observeCompletedBlocks(draft, [
      "figure.markdown-stream-code-block",
    ]);
    stub.updateStreamingDraft(complete);
    await expect(draft.locator('a[href="#footnote-detail"]')).toHaveCount(1);
    await expect(draft.locator(".math-block")).toHaveCount(0);
    stub.completeStreamingReply();
    const canonical = content.locator('[data-message-id="msg-assistant-smoke"]');
    await expect(canonical.locator("#footnote-detail")).toContainText(
      "This is the supporting footnote."
    );
    await expect(canonical.locator(".math-block")).toHaveCount(0);
    await expectCompletedBlocks(continuity);
    await continuity.evaluate(({ stop }) => stop());
    await continuity.dispose();
  } finally {
    await stub.close();
  }
});

async function openDraft(
  page: Page,
  stub: Awaited<ReturnType<typeof startChatSmokeStub>>,
  id: string
) {
  await installBrowserTestSession(page, {
    apiBaseUrl: stub.baseUrl,
    email: `markdown-${id}@comma.local`,
    token: `comma_markdown_${id}`,
  });
  await page.goto("/");
  const content = page.getByRole("region", { name: "Content" });
  await expect(content.getByRole("textbox", { name: "AI prompt" })).toBeVisible();
  await stub.waitForInitialChatSnapshot();
  await content
    .getByRole("textbox", { name: "AI prompt" })
    .fill("Show the mixed Markdown reply");
  await content.getByRole("button", { name: /^Send(?: message)?$/ }).click();
  await stub.waitForStreamingReplyReady();
  stub.startStreamingReply();
  await stub.waitForDraft();
  await expect(content.getByTestId("chat-assistant-draft")).toBeVisible();
  return content;
}

async function observeCompletedBlocks(article: Locator, selectors: string[]) {
  return article.evaluateHandle((root, requestedSelectors) => {
    const blocks = requestedSelectors.map((selector) => {
      const node = root.querySelector(selector);
      if (!node) throw new Error(`Missing completed block: ${selector}`);
      return { selector, node };
    });
    const renderer = root.querySelector(
      ".code-block-render:not(.hidden):not(.code-block-render-pending)"
    );
    const pre = renderer?.querySelector("pre");
    if (!renderer || !pre) throw new Error("The code has not been highlighted");
    const colors = () =>
      Array.from(renderer.querySelectorAll(".line:first-child span"))
        .slice(0, 64)
        .map((node) => `${node.textContent}:${getComputedStyle(node).color}`)
        .join("|");
    const initialColors = colors();
    const probe = {
      samples: 0,
      detached: 0,
      replaced: 0,
      rendererReplaced: 0,
      fallback: 0,
      colorsChanged: 0,
    };
    const sample = () => {
      probe.samples += 1;
      if (!root.isConnected) probe.detached += 1;
      for (const block of blocks) {
        if (
          !block.node.isConnected ||
          root.querySelector(block.selector) !== block.node
        ) {
          probe.replaced += 1;
        }
      }
      if (
        !pre.isConnected ||
        root.querySelector(
          ".code-block-render:not(.hidden):not(.code-block-render-pending)"
        ) !== renderer ||
        renderer.querySelector("pre") !== pre
      ) {
        probe.rendererReplaced += 1;
      }
      if (root.querySelector(".code-fallback-plain,.shiki-fallback"))
        probe.fallback += 1;
      if (colors() !== initialColors) probe.colorsChanged += 1;
    };
    const observer = new MutationObserver(sample);
    observer.observe(root, { attributes: true, childList: true, subtree: true });
    let frame = 0;
    const sampleFrame = () => {
      sample();
      frame = requestAnimationFrame(sampleFrame);
    };
    sampleFrame();
    return {
      read: () => {
        sample();
        return { ...probe };
      },
      stop: () => {
        observer.disconnect();
        cancelAnimationFrame(frame);
      },
    };
  }, selectors);
}

async function expectCompletedBlocks(
  continuity: Awaited<ReturnType<typeof observeCompletedBlocks>>
) {
  const observed = await continuity.evaluate(({ read }) => read());
  expect(observed.samples).toBeGreaterThan(0);
  expect(observed).toMatchObject({
    detached: 0,
    replaced: 0,
    rendererReplaced: 0,
    fallback: 0,
    colorsChanged: 0,
  });
}
