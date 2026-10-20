import { expect, test, type Locator, type Page } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { startChatSmokeStub } from "../../../e2e/p0/chat-stub";
import { installVirtualTime } from "../../../e2e/helpers/virtual-time";

const cases = [
  {
    name: "an incomplete link",
    before: "Alpha [labelword",
    after: "Alpha [labelword](",
    visible: "labelword",
  },
  {
    name: "a late reference definition",
    before: "Alpha [labelword][ref]",
    after: "Alpha [labelword][ref]\n\n[ref]: http://127.0.0.1/guide",
    visible: "labelword",
  },
  {
    name: "a table header",
    before: "| Header | State |",
    after: "| Header | State |\n| --- | --- |",
    visible: "Header",
  },
  {
    name: "a Setext heading",
    before: "A completed heading",
    after: "A completed heading\n---",
    visible: "A completed heading",
  },
];

for (const item of cases)
  test(`existing text does not fade again when ${item.name} changes structure`, async ({
    page,
  }, info) => {
    const stub = await startChatSmokeStub({
      assistantDraft: item.before,
      assistantReply: item.after,
      streamAssistantReply: true,
    });
    try {
      const { content, draft } = await openDraft(page, stub);
      await expect(draft).toContainText(item.visible);
      await page.waitForTimeout(350);
      const probe = await observeHighlights(draft);
      stub.updateStreamingDraft(item.after);
      await expect(draft).toContainText(item.visible);
      await page.waitForTimeout(300);
      const observed = await probe.evaluate((p) => p.stop());
      await info.attach("structure-paint", {
        body: JSON.stringify(observed, null, 2),
        contentType: "application/json",
      });
      expect(observed.samples).toBeGreaterThan(8);
      expect(observed.highlighted).toEqual([]);
      expect(observed.missing).toBe(0);
      stub.completeStreamingReply();
      await expect(
        content.locator('[data-message-id="msg-assistant-smoke"]')
      ).toContainText(item.visible);
      await probe.dispose();
    } finally {
      await stub.close();
    }
  });

test("an identical new paragraph still reveals while the earlier occurrence remains clear", async ({
  page,
}, info) => {
  const first = "The same wording appears again.";
  const finalText = `${first}\n\n${first}`;
  const stub = await startChatSmokeStub({
    assistantDraft: first,
    assistantReply: finalText,
    streamAssistantReply: true,
  });
  try {
    const { draft } = await openDraft(page, stub);
    await expect(draft).toContainText(first);
    await page.waitForTimeout(350);
    const probe = await observeHighlights(draft);
    // Grow the next root so StrictMode's mount rehearsal cannot substitute for
    // verifying a distinct same-text occurrence in an already-mounted root.
    stub.updateStreamingDraft(`${first}\n\nThe `);
    await expect(draft.locator("p")).toHaveCount(2);
    await page.waitForTimeout(350);
    stub.updateStreamingDraft(finalText);
    await expect(draft.locator("p").last()).toHaveText(first);
    await page.waitForTimeout(300);
    const observed = await probe.evaluate((p) => p.stop());
    await info.attach("repeated-paragraph-paint", {
      body: JSON.stringify(observed, null, 2),
      contentType: "application/json",
    });
    expect(observed.highlighted.length).toBeGreaterThan(0);
    expect(observed.firstParagraphFrames).toBe(0);
    expect(observed.missing).toBe(0);
    await probe.dispose();
  } finally {
    await stub.close();
  }
});

test("a late link in a long paragraph preserves the active tail instead of snapping it clear", async ({
  page,
}, info) => {
  const settled = `Opening [label][ref]. ${"A long paragraph retains its reading position. ".repeat(150)}`;
  const arriving = `${settled} Newly arriving tail`;
  const finalText = `${arriving}\n\n[ref]: http://127.0.0.1/guide`;
  const stub = await startChatSmokeStub({
    assistantDraft: settled,
    assistantReply: finalText,
    streamAssistantReply: true,
  });
  // Range identity must not depend on whether the CI worker observes it
  // before the 150ms reveal expires. Step frames, not wall-clock latency.
  const time = await installVirtualTime(page);
  try {
    const { draft } = await openDraft(page, stub);
    await time.advanceUntil(() =>
      document
        .querySelector('[data-testid="chat-assistant-draft"]')
        ?.textContent?.includes("Opening [label][ref]")
    );
    stub.updateStreamingDraft(arriving);
    await time.advanceUntil(() =>
      document
        .querySelector('[data-testid="chat-assistant-draft"]')
        ?.textContent?.includes("Newly arriving tail")
    );
    await draft.evaluate((article) => {
      const ranges = () =>
        [...CSS.highlights.values()].flatMap((h) =>
          [...h].filter((r) => article.contains(r.startContainer))
        );
      const original = new Set(ranges());
      let after: { active: number; retained: number } | undefined;
      const sample = () => {
        if (article.querySelector('a[href="http://127.0.0.1/guide"]')) {
          const current = ranges();
          after = {
            active: current.length,
            retained: current.filter((range) => original.has(range)).length,
          };
        } else requestAnimationFrame(sample);
      };
      requestAnimationFrame(sample);
      Object.assign(window, {
        lateLinkProbe: { read: () => ({ before: original.size, after }) },
      });
    });
    const read = () =>
      page.evaluate(() =>
        (
          window as unknown as {
            lateLinkProbe: {
              read(): {
                before: number;
                after?: { active: number; retained: number };
              };
            };
          }
        ).lateLinkProbe.read()
      );
    expect((await read()).before).toBeGreaterThan(0);
    stub.updateStreamingDraft(finalText);
    await time.advanceUntil(
      () =>
        (
          window as unknown as { lateLinkProbe: { read(): { after?: unknown } } }
        ).lateLinkProbe.read().after !== undefined
    );
    const result = await read();
    await info.attach("long-root-active-tail", {
      body: JSON.stringify(result, null, 2),
      contentType: "application/json",
    });
    expect(result.after!.active).toBeGreaterThan(0);
    expect(result.after!.retained).toBe(result.before);
    await time.advance(300);
    expect(
      await draft.evaluate(
        (article) =>
          [...CSS.highlights.values()].flatMap((highlight) =>
            [...highlight].filter((range) => article.contains(range.startContainer))
          ).length
      )
    ).toBe(0);
  } finally {
    await stub.close();
  }
});

async function openDraft(
  page: Page,
  stub: Awaited<ReturnType<typeof startChatSmokeStub>>
) {
  await installBrowserTestSession(page, {
    apiBaseUrl: stub.baseUrl,
    email: "identity@comma.local",
    token: "identity_browser",
  });
  await page.goto("/");
  const content = page.getByRole("region", { name: "Content" });
  const prompt = content.getByRole("textbox", { name: "AI prompt" });
  await expect(prompt).toBeVisible();
  await prompt.fill("Show the next Markdown structure");
  await content.getByRole("button", { name: /^Send(?: message)?$/ }).click();
  await stub.waitForDraft();
  return { content, draft: content.getByTestId("chat-assistant-draft") };
}

async function observeHighlights(draft: Locator) {
  return draft.evaluateHandle((article) => {
    const first = article.querySelector("p");
    const highlighted = new Set<string>();
    let samples = 0,
      missing = 0,
      firstParagraphFrames = 0,
      frame = 0;
    const sample = () => {
      samples++;
      if (!article.isConnected) missing++;
      CSS.highlights.forEach((highlight) => {
        for (const range of highlight) {
          if (!article.contains(range.startContainer)) continue;
          highlighted.add(range.toString());
          if (first?.contains(range.startContainer)) firstParagraphFrames++;
        }
      });
    };
    const tick = () => {
      sample();
      frame = requestAnimationFrame(tick);
    };
    tick();
    return {
      stop() {
        cancelAnimationFrame(frame);
        sample();
        return {
          samples,
          missing,
          firstParagraphFrames,
          highlighted: [...highlighted],
        };
      },
    };
  });
}
