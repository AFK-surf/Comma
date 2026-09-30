import { expect, test, type Locator, type Page } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { startChatSmokeStub } from "../../../e2e/p0/chat-stub";

// Real App -> public HTTP/SSE -> channel -> Markdown. Reveal changes browser
// paint; CSS Animation presence alone cannot prove its visible behavior.
const settled = "Already readable: AVATAR office affinity. 已完成的正文保持原位。";
const cases = [
  {
    name: "English words and wrapping",
    parts: [
      "AVATAR To Wa office ",
      "affinity ffi continuousword ",
      "keeps growing across a wrapped line. ",
      "Received words become solid without moving earlier text.",
    ],
  },
  {
    name: "Chinese and whole emoji graphemes",
    parts: [
      "中文内容逐步出现，",
      "完整 emoji 👩🏽‍💻 👨‍👩‍👧‍👦 👍🏽 🇨🇳 é。  \n",
      "换行后的文字仍然清晰。\n\n",
      "新段落继续，已经出现的文字保持原位。",
    ],
  },
];
for (const item of cases)
  test(`reveal paints ${item.name} without a caret or layout motion`, async ({
    page,
  }, info) => {
    const finalText = `${settled}\n\n${item.parts.join("")}`;
    const stub = await startChatSmokeStub({
      assistantDraft: settled,
      assistantReply: finalText,
      streamAssistantReply: true,
    });
    try {
      const { content, draft } = await openDraft(page, stub, item.name);
      const probe = await observeReveal(draft);
      let text = `${settled}\n\n`;
      for (const part of item.parts) {
        text += part;
        stub.updateStreamingDraft(text);
        await expect(draft).toContainText(part.trim().split("\n").at(-1)!);
        await page.waitForTimeout(100);
      }
      await page.waitForTimeout(350);
      const painting = await probe.evaluate((p) => p.read());
      await info.attach("streaming-paint", {
        body: JSON.stringify(painting, null, 2),
        contentType: "application/json",
      });
      await draft.screenshot({ path: info.outputPath("settled-stream.png") });
      expect(painting.activeFrames).toBeGreaterThan(2);
      expect(painting.colors.length).toBeGreaterThan(2);
      expect(painting.maxRanges).toBeLessThanOrEqual(220);
      expect(painting).toMatchObject({
        caretFrames: 0,
        missingBodyFrames: 0,
        replacedParagraphFrames: 0,
        detachedTextFrames: 0,
        highlightedSettledFrames: 0,
        invalidGraphemeFrames: 0,
        characterWrapperFrames: 0,
        maxSettledShiftPx: 0,
        currentRanges: 0,
      });
      stub.completeStreamingReply();
      await expect(
        content.locator('[data-message-id="msg-assistant-smoke"]')
      ).toContainText(item.parts.at(-1)!);
      await expect(content.getByTestId("chat-assistant-draft")).toHaveCount(0);
      const final = await probe.evaluate((p) => p.stop());
      expect(final.currentRanges).toBe(0);
      expect(final.sameArticle).toBe(true);
      await expect(content.getByTestId("participant-status-slot")).toBeHidden();
      expect(
        (await content.getByTestId("participant-status-slot").boundingBox())?.height
      ).toBe(40);
      await info.attach("reveal-observations", {
        body: JSON.stringify({ painting, final }, null, 2),
        contentType: "application/json",
      });
      await probe.dispose();
    } finally {
      await stub.close();
    }
  });

test("a pause clears paint and canonical completion flushes an active tail", async ({
  page,
}, info) => {
  const firstTail = "The stream pauses after this sentence. ";
  const resumed = "Then a final burst arrives and completes immediately.";
  const finalText = `${settled}\n\n${firstTail}${resumed}`;
  const stub = await startChatSmokeStub({
    assistantDraft: settled,
    assistantReply: finalText,
    streamAssistantReply: true,
  });
  try {
    const { content, draft } = await openDraft(page, stub, "pause-final");
    const probe = await observeReveal(draft);
    stub.updateStreamingDraft(`${settled}\n\n${firstTail}`);
    await expect(draft).toContainText(firstTail.trim());
    await page.waitForTimeout(500);
    const paused = await probe.evaluate((p) => p.read());
    expect(paused.activeFrames).toBeGreaterThan(0);
    expect(paused.currentRanges).toBe(0);
    stub.updateStreamingDraft(finalText);
    await expect(draft).toContainText(resumed);
    const beforeFinal = await probe.evaluate((p) => p.read());
    expect(beforeFinal.currentRanges).toBeGreaterThan(0);
    stub.completeStreamingReply();
    await expect(
      content.locator('[data-message-id="msg-assistant-smoke"]')
    ).toContainText(resumed);
    await expect(content.getByTestId("chat-assistant-draft")).toHaveCount(0);
    const completed = await probe.evaluate((p) => p.stop());
    expect(completed).toMatchObject({
      currentRanges: 0,
      sameArticle: true,
      caretFrames: 0,
      highlightedSettledFrames: 0,
      maxSettledShiftPx: 0,
    });
    await info.attach("pause-and-final", {
      body: JSON.stringify({ paused, beforeFinal, completed }, null, 2),
      contentType: "application/json",
    });
    await probe.dispose();
  } finally {
    await stub.close();
  }
});

test("reduced motion shows every received word immediately without reveal paint", async ({
  page,
}) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  const tail = "Reduced motion: 中文 👩🏽‍💻 remains immediately readable.";
  const finalText = `${settled}\n\n${tail}`;
  const stub = await startChatSmokeStub({
    assistantDraft: settled,
    assistantReply: finalText,
    streamAssistantReply: true,
  });
  try {
    const { content, draft } = await openDraft(page, stub, "reduced-motion");
    const probe = await observeReveal(draft);
    stub.updateStreamingDraft(finalText);
    await expect(draft).toContainText(tail);
    await page.waitForTimeout(300);
    stub.completeStreamingReply();
    await expect(
      content.locator('[data-message-id="msg-assistant-smoke"]')
    ).toContainText(tail);
    const observed = await probe.evaluate((p) => p.stop());
    expect(observed).toMatchObject({
      activeFrames: 0,
      maxRanges: 0,
      caretFrames: 0,
      maxSettledShiftPx: 0,
      sameArticle: true,
    });
    await probe.dispose();
  } finally {
    await stub.close();
  }
});

async function openDraft(
  page: Page,
  stub: Awaited<ReturnType<typeof startChatSmokeStub>>,
  name: string
) {
  await installBrowserTestSession(page, {
    apiBaseUrl: stub.baseUrl,
    email: "text-reveal@comma.local",
    token: "text_reveal_browser",
  });
  await page.goto("/");
  const content = page.getByRole("region", { name: "Content" });
  await expect(content.getByRole("textbox", { name: "AI prompt" })).toBeVisible();
  await content
    .getByRole("textbox", { name: "AI prompt" })
    .fill(`Local text reveal: ${name}`);
  await content.getByRole("button", { name: /^Send(?: message)?$/ }).click();
  await stub.waitForDraft();
  const draft = content.getByTestId("chat-assistant-draft");
  await expect(draft).toContainText(settled);
  await expect(content.locator('[data-outgoing-presentation="flying"]')).toHaveCount(0);
  // The baseline paragraph must finish its own initial reveal before we
  // measure whether later chunks accidentally highlight settled text again.
  await expect
    .poll(() =>
      draft.evaluate((article) => {
        let ranges = 0;
        CSS.highlights.forEach((highlight) => {
          for (const range of highlight) {
            if (article.contains(range.startContainer)) ranges++;
          }
        });
        return ranges;
      })
    )
    .toBe(0);
  return { content, draft };
}

async function observeReveal(draft: Locator) {
  return draft.evaluateHandle((article) => {
    const paragraph = article.querySelector("p")!;
    const walker = document.createTreeWalker(paragraph, NodeFilter.SHOW_TEXT);
    const nodes: Text[] = [];
    let node: Node | null;
    while ((node = walker.nextNode())) nodes.push(node as Text);
    const segmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" });
    const anchors = nodes.flatMap((text) =>
      [...segmenter.segment(text.data)].map((part) => {
        const range = document.createRange();
        range.setStart(text, part.index);
        range.setEnd(text, part.index + part.segment.length);
        return range;
      })
    );
    const geometry = () => {
      const origin = article.getBoundingClientRect();
      return anchors.map((range) =>
        [...range.getClientRects()].map((rect) => ({
          x: rect.x - origin.x,
          y: rect.y - origin.y,
          width: rect.width,
          height: rect.height,
        }))
      );
    };
    const baseline = geometry();
    const colors = new Set<string>();
    const frames: { time: number; ranges: number; colors: string[] }[] = [];
    const start = performance.now();
    const data = {
      samples: 0,
      activeFrames: 0,
      caretFrames: 0,
      missingBodyFrames: 0,
      replacedParagraphFrames: 0,
      detachedTextFrames: 0,
      highlightedSettledFrames: 0,
      invalidGraphemeFrames: 0,
      characterWrapperFrames: 0,
      maxSettledShiftPx: 0,
      maxRanges: 0,
      currentRanges: 0,
    };
    let raf = 0;
    const sample = () => {
      data.samples++;
      if (!article.isConnected) data.missingBodyFrames++;
      if (article.querySelector("p") !== paragraph) data.replacedParagraphFrames++;
      if (nodes.some((text) => !text.isConnected)) data.detachedTextFrames++;
      if (article.querySelector(".typewriter-cursor")) data.caretFrames++;
      if (
        article.querySelector(".markdown-stream-char-slot,.markdown-stream-char-enter")
      )
        data.characterWrapperFrames++;
      const now = geometry();
      for (let i = 0; i < baseline.length; i++)
        for (let j = 0; j < baseline[i]!.length; j++) {
          const a = baseline[i]![j]!,
            b = now[i]?.[j];
          if (!b) {
            data.maxSettledShiftPx = Number.POSITIVE_INFINITY;
            continue;
          }
          data.maxSettledShiftPx = Math.max(
            data.maxSettledShiftPx,
            Math.abs(a.x - b.x),
            Math.abs(a.y - b.y),
            Math.abs(a.width - b.width),
            Math.abs(a.height - b.height)
          );
        }
      let ranges = 0;
      const frameColors = new Set<string>();
      CSS.highlights.forEach((highlight, name) => {
        for (const range of highlight) {
          if (!article.contains(range.startContainer)) continue;
          ranges++;
          if (paragraph.contains(range.startContainer)) data.highlightedSettledFrames++;
          const text = range.startContainer;
          if (text.nodeType !== Node.TEXT_NODE || text !== range.endContainer) {
            data.invalidGraphemeFrames++;
            continue;
          }
          const part = segmenter
            .segment(text.textContent ?? "")
            .containing(range.startOffset);
          if (
            !part ||
            part.index !== range.startOffset ||
            part.index + part.segment.length !== range.endOffset
          )
            data.invalidGraphemeFrames++;
          const color = getComputedStyle(
            text.parentElement!,
            `::highlight(${name})`
          ).color;
          colors.add(color);
          frameColors.add(color);
        }
      });
      data.currentRanges = ranges;
      data.maxRanges = Math.max(data.maxRanges, ranges);
      if (ranges) data.activeFrames++;
      if (frames.length < 600)
        frames.push({
          time: performance.now() - start,
          ranges,
          colors: [...frameColors],
        });
    };
    const frame = () => {
      sample();
      raf = requestAnimationFrame(frame);
    };
    frame();
    return {
      read() {
        sample();
        return {
          ...data,
          colors: [...colors],
          frames,
          sameArticle: article.isConnected,
        };
      },
      stop() {
        cancelAnimationFrame(raf);
        sample();
        return {
          ...data,
          colors: [...colors],
          frames,
          sameArticle: article.isConnected,
        };
      },
    };
  });
}

test("appending words never moves the completed word at the previous line end", async ({
  page,
}, info) => {
  const first =
    "AVATAR To Wa office affinity ffi — these words retain their natural spacing. ";
  const addition = "Start with one clear idea, then give it enough room to develop. ";
  const initial = `${settled}\n\n${first}`;
  const finalText = initial + addition;
  const stub = await startChatSmokeStub({
    assistantDraft: initial,
    assistantReply: finalText,
    streamAssistantReply: true,
  });
  try {
    const { content, draft } = await openDraft(page, stub, "closed-word-wrap");
    const paragraph = draft.locator("p").filter({ hasText: "AVATAR To Wa" });
    const anchor = await observeClosedWord(paragraph, "spacing.");
    let text = initial;
    for (const chunk of [
      "St",
      "art",
      " wit",
      "h ",
      "on",
      "e c",
      "lear",
      " i",
      "de",
      "a, ",
      "then",
      " g",
      "ive it enough room to develop. ",
    ]) {
      text += chunk;
      stub.updateStreamingDraft(text);
      await page.waitForTimeout(65);
    }
    await expect(paragraph).toContainText(addition.trim());
    await page.waitForTimeout(300);
    const streaming = await anchor.evaluate((p) => p.read());
    await info.attach("closed-word-streaming", {
      body: JSON.stringify(streaming, null, 2),
      contentType: "application/json",
    });
    expect(streaming.samples).toBeGreaterThan(15);
    expect(streaming.maxWidthShift).toBeLessThanOrEqual(0.1);
    expect(streaming).toMatchObject({
      maxRelativeShift: 0,
      maxPageShift: 0,
      maxContainerWidthShift: 0,
      detached: 0,
    });
    stub.completeStreamingReply();
    await expect(
      content.locator('[data-message-id="msg-assistant-smoke"]')
    ).toContainText(addition.trim());
    const completed = await anchor.evaluate((p) => p.stop());
    expect(completed.maxRelativeShift).toBe(0);
    expect(completed.maxWidthShift).toBeLessThanOrEqual(0.1);
    expect(completed.maxContainerWidthShift).toBe(0);
    expect(completed.detached).toBe(0);
    await info.attach("closed-word-final", {
      body: JSON.stringify(completed, null, 2),
      contentType: "application/json",
    });
    await anchor.dispose();
  } finally {
    await stub.close();
  }
});

test("headings, list items and quotes keep completed words in place during mixed streaming", async ({
  page,
}, info) => {
  const blocks = [
    {
      initial: "## A practical heading about clear writing and steady interfaces ",
      addition: "with examples for every part of the conversation",
      selector: "h2",
      word: "writing",
    },
    {
      initial:
        "- The completed list wording provides enough detail for stable reading. ",
      addition: "Additional words arrive while its original wording stays in place.",
      selector: "li",
      word: "reading.",
    },
    {
      initial:
        "> A useful quote can contain a complete sentence about steady reading. ",
      addition:
        "The rest of this quotation arrives gradually without revisiting old line breaks.",
      selector: "blockquote p",
      word: "reading.",
    },
  ];
  const finalText = `${settled}\n\n${blocks.map((b) => b.initial + b.addition).join("\n\n")}`;
  const stub = await startChatSmokeStub({
    assistantDraft: settled,
    assistantReply: finalText,
    streamAssistantReply: true,
  });
  try {
    const { content, draft } = await openDraft(page, stub, "mixed-word-wrap");
    let text = `${settled}\n\n`;
    let last;
    for (const block of blocks) {
      text += block.initial;
      stub.updateStreamingDraft(text);
      const element = draft.locator(block.selector).last();
      await expect(element).toContainText(block.word);
      await page.waitForTimeout(300);
      const anchor = await observeClosedWord(element, block.word);
      for (let offset = 0; offset < block.addition.length; offset += 4) {
        text += block.addition.slice(offset, offset + 4);
        stub.updateStreamingDraft(text);
        await page.waitForTimeout(65);
      }
      await page.waitForTimeout(300);
      const observed = await anchor.evaluate((p) => p.read());
      await info.attach(`closed-word-${block.selector}`, {
        body: JSON.stringify(observed, null, 2),
        contentType: "application/json",
      });
      expect(observed.maxWidthShift).toBeLessThanOrEqual(0.1);
      expect(observed).toMatchObject({
        maxRelativeShift: 0,
        maxPageShift: 0,
        maxContainerWidthShift: 0,
        detached: 0,
      });
      if (block === blocks.at(-1)) last = anchor;
      else {
        await anchor.evaluate((p) => p.stop());
        await anchor.dispose();
      }
      text += "\n\n";
    }
    stub.completeStreamingReply();
    await expect(
      content.locator('[data-message-id="msg-assistant-smoke"]')
    ).toContainText(blocks.at(-1)!.addition);
    const completed = await last!.evaluate((p) => p.stop());
    expect(completed.maxRelativeShift).toBe(0);
    expect(completed.maxWidthShift).toBeLessThanOrEqual(0.1);
    expect(completed.maxContainerWidthShift).toBe(0);
    expect(completed.detached).toBe(0);
    await info.attach("mixed-word-final", {
      body: JSON.stringify(completed, null, 2),
      contentType: "application/json",
    });
    await last!.dispose();
  } finally {
    await stub.close();
  }
});

async function observeClosedWord(block: Locator, word: string) {
  return block.evaluateHandle((element, needle) => {
    const article = element.closest('[data-slot="chat-assistant-output"]')!;
    const original = element;
    const frames: {
      time: number;
      pageX: number;
      pageY: number;
      relativeX: number;
      relativeY: number;
      width: number;
      articleY: number;
      blockWidth: number;
      text: string;
      wrap: string;
      scroll: number[];
    }[] = [];
    let originalText: Node | undefined;
    let baseline: (typeof frames)[number] | undefined;
    let maxRelativeShift = 0,
      maxPageShift = 0,
      maxWidthShift = 0,
      maxContainerWidthShift = 0,
      detached = 0,
      raf = 0;
    const started = performance.now();
    const sample = () => {
      const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
      let node: Node | null;
      while ((node = walker.nextNode())) {
        const offset = (node.textContent ?? "").indexOf(needle);
        if (offset < 0) continue;
        originalText ??= node;
        if (node !== originalText || !originalText.isConnected || !original.isConnected)
          detached++;
        const range = document.createRange();
        range.setStart(node, offset);
        range.setEnd(node, offset + needle.length);
        const box = range.getBoundingClientRect(),
          origin = article.getBoundingClientRect();
        const current = {
          time: performance.now() - started,
          pageX: box.x,
          pageY: box.y,
          relativeX: box.x - origin.x,
          relativeY: box.y - origin.y,
          width: box.width,
          articleY: origin.y,
          blockWidth: element.getBoundingClientRect().width,
          text: element.textContent ?? "",
          wrap: getComputedStyle(element).textWrap,
          scroll: [
            ...document.querySelectorAll('[data-slot="scroll-area-viewport"]'),
          ].map((e) => e.scrollTop),
        };
        baseline ??= current;
        maxRelativeShift = Math.max(
          maxRelativeShift,
          Math.abs(current.relativeX - baseline.relativeX),
          Math.abs(current.relativeY - baseline.relativeY)
        );
        maxPageShift = Math.max(
          maxPageShift,
          Math.abs(current.pageX - baseline.pageX),
          Math.abs(current.pageY - baseline.pageY)
        );
        maxWidthShift = Math.max(
          maxWidthShift,
          Math.abs(current.width - baseline.width)
        );
        maxContainerWidthShift = Math.max(
          maxContainerWidthShift,
          Math.abs(current.blockWidth - baseline.blockWidth)
        );
        if (frames.length < 600) frames.push(current);
        return;
      }
      detached++;
    };
    const tick = () => {
      sample();
      raf = requestAnimationFrame(tick);
    };
    tick();
    const read = () => {
      sample();
      return {
        samples: frames.length,
        maxRelativeShift,
        maxPageShift,
        maxWidthShift,
        maxContainerWidthShift,
        detached,
        frames,
      };
    };
    return {
      read,
      stop() {
        cancelAnimationFrame(raf);
        return read();
      },
    };
  }, word);
}
