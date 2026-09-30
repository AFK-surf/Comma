import { expect, test } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { startChatSmokeStub } from "../../../e2e/p0/chat-stub";

const suggestions = [
  { id: "sug_1", label: "发到项目群", prompt: "把纪要发到项目群。" },
  { id: "sug_2", label: "拆成待办", prompt: "把后续事项拆成待办。" },
];

test("settled reply suggests a draft that Tab accepts before sending", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({ streamAssistantReply: true });
  let suggestionRequests = 0;

  try {
    await page.route("**/suggestions*", async (route) => {
      suggestionRequests += 1;
      await route.fulfill({
        contentType: "application/json",
        body: JSON.stringify({ data: suggestions }),
      });
    });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "comma-chat-suggestions@comma.local",
      token: "comma_sess_chat_suggestions",
    });
    await page.goto("/");

    const content = page.getByRole("region", { name: "Content" });
    const prompt = content.getByRole("textbox", { name: "AI prompt" });
    await prompt.fill("刚才3点那个会议的会议纪要发一下");
    await content.getByRole("button", { name: "Send" }).click();
    await stub.waitForDraft();

    await expect(prompt).not.toHaveAttribute(
      "data-placeholder",
      suggestions[0]!.prompt
    );
    expect(suggestionRequests).toBe(0);
    stub.completeStreamingReply();
    await expect(prompt).toHaveAttribute("data-placeholder", suggestions[0]!.prompt);
    await expect(prompt).toHaveText("");
    await expect(page.getByTestId("chat-suggestions")).toBeVisible();
    await expect(page.getByTestId("chat-suggestion-sug_1")).toHaveText(
      suggestions[0]!.label
    );
    await expect(page.getByTestId("chat-suggestion-sug_2")).toHaveText(
      suggestions[1]!.label
    );
    const sentBeforeAccept = stub.messageBodies.length;
    await prompt.press("Enter");
    await expect(prompt).toHaveText("");
    expect(stub.messageBodies).toHaveLength(sentBeforeAccept);
    await prompt.focus();
    await prompt.press("Shift+Tab");
    await expect(prompt).not.toBeFocused();
    await expect(prompt).toHaveText("");
    await prompt.focus();
    await prompt.press("Tab");
    await expect(prompt).toHaveText(suggestions[0]!.prompt);
    await expect(prompt).toBeFocused();
    expect(stub.messageBodies).toHaveLength(sentBeforeAccept);
    // Editing interrupts the visual copy without waiting for the wave to finish.
    // The caret stays at the end and the accepted prompt remains editable.
    await prompt.pressSequentially(" 请先给我预览。");
    await expect(page.locator(".comma-suggestion-acceptance")).toHaveCount(0);
    await prompt.press("Enter");
    await expect.poll(() => stub.messageBodies.length).toBe(sentBeforeAccept + 1);
    expect(stub.messageBodies.at(-1)).toMatchObject({
      message: { text: suggestions[0]!.prompt + " 请先给我预览。" },
    });
    expect(suggestionRequests).toBe(1);
  } finally {
    await stub.close();
  }
});

for (const text of ["界".repeat(12), "n".repeat(12), "👩🏽‍💻".repeat(12)]) {
  test(`12-grapheme suggestion stays single-line in the minimum compact input: ${text}`, async ({
    page,
  }) => {
    const stub = await startChatSmokeStub({ streamAssistantReply: true });
    try {
      await page.route("**/suggestions*", (route) =>
        route.fulfill({
          contentType: "application/json",
          body: JSON.stringify({
            data: [{ id: "sug_1", label: "Next", prompt: text }],
          }),
        })
      );
      await installBrowserTestSession(page, {
        apiBaseUrl: stub.baseUrl,
        email: "comma-compact@comma.local",
        token: "comma_sess_compact",
      });
      await page.goto("/");
      // Home declares a 393px chat minimum; use that real layout floor.
      await page.addStyleTag({
        content:
          ".comma-home-chat { width: 393px !important; min-width: 393px !important; max-width: 393px !important; }",
      });
      const composer = page.locator(".comma-chat-composer");
      const prompt = composer.getByRole("textbox", { name: "AI prompt" });
      await prompt.fill("Summarize");
      await composer.getByRole("button", { name: "Send" }).click();
      await stub.waitForDraft();
      stub.completeStreamingReply();
      await expect(prompt).toHaveAttribute("data-placeholder", text);
      expect(
        await prompt.evaluate(
          (editor) => getComputedStyle(editor, "::before").whiteSpace
        )
      ).toBe("nowrap");
      await prompt.press("Tab");
      await expect(prompt).toHaveText(text);
    } finally {
      await stub.close();
    }
  });
}

test("capsule sends its own suggestion without consuming an existing draft", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({ streamAssistantReply: true });
  try {
    await page.route("**/suggestions*", (route) =>
      route.fulfill({
        contentType: "application/json",
        body: JSON.stringify({ data: suggestions }),
      })
    );
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "comma-capsules@comma.local",
      token: "comma_sess_capsules",
    });
    await page.goto("/");
    const composer = page.locator(".comma-chat-composer");
    const prompt = composer.getByRole("textbox", { name: "AI prompt" });
    await prompt.fill("Summarize this meeting");
    await composer.getByRole("button", { name: "Send" }).click();
    await stub.waitForDraft();
    stub.completeStreamingReply();
    await expect(page.getByTestId("chat-suggestion-sug_2")).toBeVisible();
    await prompt.fill("Keep my draft");
    const before = stub.messageBodies.length;
    await page.getByTestId("chat-suggestion-sug_2").click();
    await expect.poll(() => stub.messageBodies.length).toBe(before + 1);
    expect(stub.messageBodies.at(-1)).toMatchObject({
      message: { text: suggestions[1]!.prompt },
    });
    await expect(prompt).toHaveText("Keep my draft");
    await expect(page.getByTestId("chat-suggestions")).toHaveCount(0);
  } finally {
    await stub.close();
  }
});

test("suggestion arrival and Tab preserve a half-typed draft and staged attachment", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({ streamAssistantReply: true });

  try {
    await page.route("**/suggestions*", async (route) => {
      await route.fulfill({
        contentType: "application/json",
        body: JSON.stringify({ data: suggestions }),
      });
    });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "comma-chat-suggestions-draft@comma.local",
      token: "comma_sess_chat_suggestions_draft",
    });
    await page.goto("/");

    const content = page.getByRole("region", { name: "Content" });
    const composer = page
      .getByTestId("comma-route-outlet")
      .locator(".comma-chat-composer");
    const prompt = composer.getByRole("textbox", { name: "AI prompt" });
    await prompt.fill("刚才3点那个会议的会议纪要发一下");
    await content.getByRole("button", { name: "Send" }).click();
    await stub.waitForDraft();
    await prompt.fill("另外顺便帮我");
    stub.completeStreamingReply();
    await expect(prompt).toHaveText("另外顺便帮我");

    const chooserPromise = page.waitForEvent("filechooser");
    await composer.getByRole("button", { name: "Add attachment" }).click();
    const chooser = await chooserPromise;
    await chooser.setFiles({
      buffer: Buffer.from("private context that must remain staged"),
      mimeType: "text/plain",
      name: "follow-up-context.txt",
    });
    await expect.poll(() => stub.uploads.length).toBe(1);
    await expect(
      composer.getByText("follow-up-context.txt", { exact: true })
    ).toBeVisible();

    const sentBeforeTab = stub.messageBodies.length;
    await prompt.focus();
    await prompt.press("Tab");
    await expect(prompt).toHaveText("另外顺便帮我");
    await expect(
      composer.getByText("follow-up-context.txt", { exact: true })
    ).toBeVisible();
    expect(stub.messageBodies).toHaveLength(sentBeforeTab);
    await prompt.fill("");
    await expect(prompt).toHaveAttribute("data-placeholder", suggestions[0]!.prompt);
    await prompt.press("Tab");
    await expect(prompt).toHaveText(suggestions[0]!.prompt);
    await expect(
      composer.getByText("follow-up-context.txt", { exact: true })
    ).toBeVisible();
  } finally {
    await stub.close();
  }
});

/**
 * COMMA-274: the suggestions are model-written, so the language the interface is in
 * has to reach the generator as a request parameter. Nothing else proves the
 * locale survives the whole path — the hook reads it from the i18n context and
 * the API client puts it on the query string, and a browser locale is the only
 * way to drive that from the outside.
 */
test.describe("suggestion generation carries the interface language", () => {
  for (const { browserLocale, expected } of [
    { browserLocale: "zh-CN", expected: "zh-CN" },
    { browserLocale: "en-US", expected: "en" },
  ]) {
    test.describe(`under ${browserLocale}`, () => {
      test.use({ locale: browserLocale });

      test(`requests suggestions with locale=${expected}`, async ({ page }) => {
        const stub = await startChatSmokeStub({ streamAssistantReply: true });
        const requestedLocales: (string | null)[] = [];

        try {
          await page.route("**/suggestions*", async (route) => {
            requestedLocales.push(
              new URL(route.request().url()).searchParams.get("locale")
            );
            await route.fulfill({
              contentType: "application/json",
              body: JSON.stringify({ data: suggestions }),
            });
          });
          await installBrowserTestSession(page, {
            apiBaseUrl: stub.baseUrl,
            email: `comma-chat-suggestions-${expected}@comma.local`,
            token: `comma_sess_chat_suggestions_${expected.replace("-", "_")}`,
          });
          await page.goto("/");

          await expect(page.locator("html")).toHaveAttribute("lang", expected);

          // Every accessible name in the shell is itself localized, so this
          // test drives the composer through test ids instead.
          const content = page.getByTestId("comma-route-outlet");
          await content
            .locator(".comma-chat-composer [role=textbox]")
            .fill("刚才3点那个会议的会议纪要发一下");
          await content
            .locator(".comma-chat-composer")
            .getByRole("button", { name: /^(Send|发送)$/ })
            .click();
          await stub.waitForDraft();
          stub.completeStreamingReply();

          await expect(
            content.locator(".comma-chat-composer [role=textbox]")
          ).toHaveAttribute("data-placeholder", suggestions[0]!.prompt);
          expect(requestedLocales).toEqual([expected]);
        } finally {
          await stub.close();
        }
      });
    });
  }
});

for (const scenario of ["wave", "latin", "static-font", "arabic", "reduced"] as const) {
  // Generated suggestions now fit one compact line. Joining scripts still
  // use the shimmer, and reduced motion still skips the presentation.
  const copied =
    scenario === "wave" || scenario === "latin" || scenario === "static-font";
  test(`accepted suggestion motion: ${scenario}`, async ({ page }) => {
    const stub = await startChatSmokeStub({ streamAssistantReply: true });
    const text =
      scenario === "latin" || scenario === "static-font"
        ? "Send meeting notes"
        : scenario === "arabic"
          ? "أضف اختبارات"
          : "请检查修改并补充测试。";
    try {
      await page.emulateMedia({
        reducedMotion: scenario === "reduced" ? "reduce" : "no-preference",
      });
      await page.route("**/suggestions*", (route) =>
        route.fulfill({
          contentType: "application/json",
          body: JSON.stringify({
            data: [{ id: "sug_1", label: "检查", prompt: text }],
          }),
        })
      );
      await installBrowserTestSession(page, {
        apiBaseUrl: stub.baseUrl,
        email: "comma-chat-motion@comma.local",
        token: "comma_sess_chat_motion",
      });
      await page.goto("/");
      const composer = page
        .getByTestId("comma-route-outlet")
        .locator(".comma-chat-composer");
      const prompt = composer.getByRole("textbox", { name: "AI prompt" });
      await prompt.fill("检查这份修改");
      await composer.getByRole("button", { name: "Send" }).click();
      await stub.waitForDraft();
      stub.completeStreamingReply();
      await expect(prompt).toHaveAttribute("data-placeholder", text);
      if (scenario === "static-font") {
        // Static font faces change width abruptly at weight boundaries.
        await prompt.evaluate((editor) => {
          editor.style.fontFamily = "Arial, sans-serif";
        });
      }
      // The motion lasts only a moment, so record it instead of racing it:
      // hold the copy's wave and the editor shimmer on their first frames.
      const motion = await page.evaluateHandle(() => {
        const seen = { copy: false, shimmer: false };
        new MutationObserver((records) => {
          for (const record of records) {
            const target = record.target as HTMLElement;
            if (target.dataset?.suggestionShimmer) {
              seen.shimmer = true;
              target.getAnimations().forEach((animation) => animation.pause());
            }
            for (const node of record.addedNodes) {
              if (
                node instanceof HTMLElement &&
                node.classList.contains("comma-suggestion-acceptance")
              ) {
                seen.copy = true;
                node
                  .getAnimations({ subtree: true })
                  .forEach((animation) => animation.pause());
              }
            }
          }
        }).observe(document.body, {
          subtree: true,
          childList: true,
          attributes: true,
          attributeFilter: ["data-suggestion-shimmer"],
        });
        return seen;
      });
      await prompt.press("Tab");
      await expect(prompt).toHaveText(text);
      await expect(prompt).toBeFocused();
      if (copied) {
        const visual = page.locator(".comma-suggestion-acceptance");
        await expect(visual).toBeVisible();
        // The decorative copy never enters the editable or accessible message.
        await expect(visual).toHaveAttribute("aria-hidden", "true");
        const sample = await prompt.evaluate((editor) => {
          const overlay = document.querySelector<HTMLElement>(
            ".comma-suggestion-acceptance"
          )!;
          // The wave is one animation per glyph property plus the overlay's
          // shift. Seek them together on the page's timeline.
          const wave = overlay.getAnimations({ subtree: true });
          const seek = (time: number) => {
            for (const animation of wave) animation.currentTime = time;
          };
          const glyphs = Array.from(overlay.children) as HTMLElement[];
          const rest = parseFloat(getComputedStyle(editor).fontWeight);
          const paint = document.createElement("canvas").getContext("2d")!;
          const rgba = (color: string) => {
            paint.clearRect(0, 0, 1, 1);
            paint.fillStyle = color;
            paint.fillRect(0, 0, 1, 1);
            return Array.from(paint.getImageData(0, 0, 1, 1).data);
          };
          const ink = rgba(getComputedStyle(editor).color);
          const frame = () =>
            glyphs.map((glyph) => {
              const style = getComputedStyle(glyph);
              const box = glyph.getBoundingClientRect();
              const [r, g, b] = rgba(style.color);
              return {
                tint: Math.hypot(r! - ink[0]!, g! - ink[1]!, b! - ink[2]!),
                weight: parseFloat(style.fontWeight),
                size: style.scale === "none" ? 1 : parseFloat(style.scale),
                left: box.left,
                right: box.right,
              };
            });
          // On its first frame the copy covers the editable text exactly, at
          // the editor's weight and size.
          seek(0);
          const range = document.createRange();
          range.setStart(editor.firstChild!, 0);
          range.setEnd(editor.firstChild!, 1);
          const original = range.getBoundingClientRect();
          const copy = glyphs[0]!.getBoundingClientRect();
          const first = frame();
          const alignment = {
            x: Math.abs(copy.left - original.left),
            y: Math.abs(copy.top - original.top),
            fill: getComputedStyle(editor).webkitTextFillColor,
            atRest: first.every(
              (glyph) => glyph.weight === rest && glyph.size === 1 && glyph.tint <= 2
            ),
          };
          const em = parseFloat(getComputedStyle(editor).fontSize);
          const centers = first.map((glyph) => (glyph.left + glyph.right) / 2);
          const duration = Math.max(
            ...wave.map((animation) =>
              Number(animation.effect!.getComputedTiming().endTime)
            )
          );
          // One heavy, enlarged, blue crest travels across the text. The text
          // ahead of it and behind it is at rest, with no lighter band. The
          // line reflows around the crest: neighbors keep their spacing.
          const moments = [0.35, 0.5, 0.65].map((progress) => {
            seek(progress * duration);
            const glyphsNow = frame();
            const weights = glyphsNow.map((glyph) => glyph.weight);
            const sizes = glyphsNow.map((glyph) => glyph.size);
            const crest = sizes.indexOf(Math.max(...sizes));
            const distance = (index: number) =>
              (centers[index]! - centers[crest]!) / em;
            const ahead = glyphsNow.filter(
              (_, index) => distance(index) >= 5 && distance(index) <= 8
            );
            const spacing = glyphsNow
              .slice(1)
              .map((glyph, index) =>
                Math.abs(
                  glyph.left -
                    glyphsNow[index]!.right -
                    (first[index + 1]!.left - first[index]!.right)
                )
              );
            return {
              crest,
              // Weight moves in steps of 50, so it may trail the size by one.
              crestHeaviest: weights[crest]! >= Math.max(...weights) - 50,
              crestTint: glyphsNow[crest]!.tint,
              crestBluest:
                glyphsNow[crest]!.tint ===
                Math.max(...glyphsNow.map((glyph) => glyph.tint)),
              tintedFraction:
                glyphsNow.filter((glyph) => glyph.tint > 2).length / glyphs.length,
              crestGain: weights[crest]! - rest,
              crestSize: sizes[crest]!,
              heavyFraction:
                weights.filter((weight) => weight > rest).length / glyphs.length,
              aheadAtRest: ahead.every(
                (glyph) => glyph.weight === rest && glyph.size === 1 && glyph.tint <= 2
              ),
              behindAtRest: glyphsNow
                .filter((_, index) => distance(index) <= -5)
                .every(
                  (glyph) =>
                    glyph.weight === rest && glyph.size === 1 && glyph.tint <= 2
                ),
              spacingDrift: Math.max(...spacing),
            };
          });
          for (const animation of wave) animation.play();
          return { alignment, moments, glyphCount: glyphs.length };
        });
        expect(sample.alignment.x).toBeLessThan(1);
        expect(sample.alignment.y).toBeLessThanOrEqual(4);
        expect(sample.alignment.fill).toBe("rgba(0, 0, 0, 0)");
        expect(sample.alignment.atRest).toBe(true);
        const crests = sample.moments.map((moment) => moment.crest);
        expect(crests[0]).toBeGreaterThan(0);
        expect(crests[1]).toBeGreaterThan(crests[0]!);
        expect(crests[2]).toBeGreaterThan(crests[1]!);
        expect(crests[2]).toBeLessThan(sample.glyphCount - 1);
        for (const moment of sample.moments) {
          expect(moment.crestHeaviest).toBe(true);
          expect(moment.crestBluest).toBe(true);
          expect(moment.crestTint).toBeGreaterThan(150);
          // On a short recommendation the crest may cover most of the line.
          expect(moment.crestGain).toBeGreaterThan(200);
          expect(moment.crestSize).toBeGreaterThan(1.12);
          expect(moment.aheadAtRest).toBe(true);
          expect(moment.behindAtRest).toBe(true);
          expect(moment.spacingDrift).toBeLessThan(0.35);
        }
        await expect(visual).toHaveCount(0);
      } else {
        await expect(page.locator(".comma-suggestion-acceptance")).toHaveCount(0);
        if (scenario !== "reduced") {
          await expect.poll(() => motion.evaluate((seen) => seen.shimmer)).toBe(true);
          // The blue band crosses the text: plain on the first frame, and
          // blue halfway through.
          const region = await prompt.evaluate((editor) => {
            const range = document.createRange();
            range.selectNodeContents(editor);
            const lines = range.getBoundingClientRect();
            const box = editor.getBoundingClientRect();
            const x = Math.max(lines.left, box.left);
            const y = Math.max(lines.top, box.top);
            return {
              x,
              y,
              width: Math.min(lines.right, box.right) - x,
              height: Math.min(lines.bottom, box.bottom) - y,
            };
          });
          const paint = async (progress: number) => {
            await prompt.evaluate((editor, at) => {
              for (const animation of editor.getAnimations()) {
                const end = Number(animation.effect!.getComputedTiming().endTime);
                animation.currentTime = at * end;
              }
            }, progress);
            const shot = await page.screenshot({ clip: region, animations: "allow" });
            return page.evaluate(async (png) => {
              const bytes = Uint8Array.from(atob(png), (char) => char.charCodeAt(0));
              const bitmap = await createImageBitmap(
                new Blob([bytes], { type: "image/png" })
              );
              const canvas = new OffscreenCanvas(bitmap.width, bitmap.height);
              const context = canvas.getContext("2d")!;
              context.drawImage(bitmap, 0, 0);
              const { data } = context.getImageData(0, 0, bitmap.width, bitmap.height);
              let blue = 0;
              for (let index = 0; index < data.length; index += 4) {
                const [r, g, b] = [data[index]!, data[index + 1]!, data[index + 2]!];
                if (b - Math.max(r, g) > 100) blue += 1;
              }
              return blue;
            }, shot.toString("base64"));
          };
          const [start, middle] = [await paint(0), await paint(0.5)];
          expect(start).toBe(0);
          expect(middle).toBeGreaterThan(20);
          await prompt.evaluate((editor) =>
            editor.getAnimations().forEach((animation) => animation.play())
          );
          await expect(prompt).not.toHaveAttribute("data-suggestion-shimmer");
        }
      }
      await prompt.pressSequentially(" 再看一遍。");
      await expect(prompt).toHaveText(text + " 再看一遍。");
      await prompt.press("Enter");
      await expect
        .poll(() => stub.messageBodies.at(-1))
        .toMatchObject({
          message: { text: text + " 再看一遍。" },
        });
      // Each path uses exactly one presentation; reduced motion uses neither.
      expect(await motion.evaluate((seen) => seen)).toEqual({
        copy: copied,
        shimmer: !copied && scenario !== "reduced",
      });
    } finally {
      await stub.close();
    }
  });
}
