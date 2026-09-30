import { expect, test } from "@playwright/test";

for (const fontScale of [90, 100, 110]) {
  test(`compact composer centers its text and controls at ${fontScale}% font size`, async ({
    page,
  }) => {
    await page.goto("/iframe.html?id=app-components-ai-input--small&viewMode=story");
    await page.addStyleTag({ content: `html { font-size: ${fontScale}%; }` });
    const editor = page.getByRole("textbox", { name: "AI prompt" });
    await expect(editor).toBeVisible();

    const expectCentered = async () => {
      await expect
        .poll(() =>
          editor.evaluate((element) => {
            const style = getComputedStyle(element);
            const textCenter =
              element.getBoundingClientRect().top +
              parseFloat(style.paddingTop) +
              parseFloat(style.lineHeight) / 2;
            const shell = element.closest('[data-testid="ai-input-shell"]')!;
            const controls = shell.querySelectorAll("button");
            return Math.max(
              ...Array.from(controls, (control) => {
                const bounds = control.getBoundingClientRect();
                return Math.abs(textCenter - (bounds.top + bounds.height / 2));
              })
            );
          })
        )
        .toBeLessThanOrEqual(0.5);
    };

    await expectCentered();
    await editor.fill("Hello");
    await expectCentered();
    await editor.press("Shift+Enter");
    await editor.pressSequentially("Second line");
    await expect
      .poll(async () => (await editor.boundingBox())!.height)
      .toBeGreaterThan(36);
    await editor.fill("");
    await expectCentered();
  });
}

test("compact composer keeps its corners bounded while expanding", async ({ page }) => {
  await page.goto("/iframe.html?id=app-components-ai-input--small&viewMode=story");
  const shell = page.getByTestId("ai-input-shell");
  await shell.evaluate((element) => {
    element.addEventListener("transitionrun", (event) => {
      if (
        event.target !== element ||
        (event as TransitionEvent).propertyName !== "border-top-left-radius"
      ) {
        return;
      }
      // Inspect the rendered shape halfway through the actual resize, without
      // depending on the test runner catching a particular animation frame.
      const animations = element.getAnimations({ subtree: true });
      for (const animation of animations) {
        animation.pause();
        animation.currentTime = Number(animation.effect!.getTiming().duration) / 2;
      }
      const bounds = element.getBoundingClientRect();
      const radius = parseFloat(getComputedStyle(element).borderTopLeftRadius);
      element.setAttribute(
        "data-midpoint-radius",
        String(Math.min(radius, bounds.width / 2, bounds.height / 2))
      );
      for (const animation of animations) animation.play();
    });
  });

  await page
    .getByRole("textbox", { name: "AI prompt" })
    .fill("First line\nSecond line");
  await expect(shell).toHaveAttribute("data-midpoint-radius");
  expect(Number(await shell.getAttribute("data-midpoint-radius"))).toBeLessThanOrEqual(
    20.5
  );
  await expect(shell).toHaveCSS("border-top-left-radius", "20px");
});

test("composer collapse finishes within 100ms across height, corners, and text", async ({
  page,
}) => {
  await page.goto("/iframe.html?id=app-components-ai-input--small&viewMode=story");
  const editor = page.getByRole("textbox", { name: "AI prompt" });
  const shell = page.getByTestId("ai-input-shell");
  await editor.fill("First line\nSecond line");
  // Observe expansion before accepting an idle animation list.
  await expect(shell).toHaveAttribute("data-compact", "false");
  await expect(shell).toHaveCSS("border-top-left-radius", "20px");
  await expect(editor).toHaveCSS("height", "40px");
  await expect
    .poll(() =>
      shell.evaluate((element) => element.getAnimations({ subtree: true }).length)
    )
    .toBe(0);
  await shell.evaluate((element) => {
    element.addEventListener("transitionend", (event) => {
      const transition = event as TransitionEvent;
      const property = transition.propertyName;
      if (!["height", "border-top-left-radius", "transform"].includes(property)) return;
      // Finished transitions can disappear before queued events are delivered.
      // Read their elapsed animation time instead of requiring a live Animation.
      const delays = getComputedStyle(event.target as Element)
        .transitionDelay.split(",")
        .map((delay) => parseFloat(delay) * (delay.trim().endsWith("ms") ? 1 : 1000));
      element.setAttribute(
        `data-duration-${property}`,
        String(transition.elapsedTime * 1000 + Math.max(...delays))
      );
    });
  });
  await editor.fill("First line");
  for (const property of ["height", "border-top-left-radius", "transform"]) {
    const attribute = `data-duration-${property}`;
    await expect(shell).toHaveAttribute(attribute);
    expect(Number(await shell.getAttribute(attribute))).toBeLessThanOrEqual(100);
  }
  await expect(editor).toHaveCSS("height", "36px");
  await expect(shell).toHaveCSS("border-top-left-radius", "19px");
});

test("the prompt slides its full course while typing wraps the compact composer", async ({
  page,
}) => {
  await page.goto("/iframe.html?id=app-components-ai-input--small&viewMode=story");
  const editor = page.getByRole("textbox", { name: "AI prompt" });
  const shell = page.getByTestId("ai-input-shell");
  await expect(editor).toBeVisible();
  await editor.evaluate((element) => {
    element.addEventListener("transitionend", (event) => {
      if (
        event.target !== element ||
        (event as TransitionEvent).propertyName !== "transform"
      ) {
        return;
      }
      element.setAttribute("data-slide-finished", "true");
    });
  });

  // Keystrokes keep landing while the prompt slides; measuring them must not
  // cut the slide short.
  await editor.pressSequentially(
    "A long line that keeps going until it wraps past the compact width of this composer",
    { delay: 10 }
  );
  await expect(shell).toHaveAttribute("data-compact", "false");
  await expect(editor).toHaveAttribute("data-slide-finished", "true");
});

test("skill tooltip stays above its token inside a transformed preview", async ({
  page,
}) => {
  await page.goto("/iframe.html?id=app-components-ai-input--default&viewMode=story");

  const editor = page.getByRole("textbox", { name: "AI prompt" });
  await editor.click();
  await page.keyboard.type("/");
  await expect(page.getByRole("listbox", { name: "Skills" })).toBeVisible();
  await editor.press("Enter");

  const token = editor.locator("[data-ai-input-token]");
  await expect(token).toHaveText("image-gen");
  await expect
    .poll(() =>
      token.evaluate((element) => {
        for (
          let ancestor = element.parentElement;
          ancestor;
          ancestor = ancestor.parentElement
        ) {
          if (getComputedStyle(ancestor).transform !== "none") return true;
        }
        return false;
      })
    )
    .toBe(true);

  await token.hover();
  const tooltip = page.getByRole("tooltip");
  await expect(tooltip).toBeVisible();
  await expect(tooltip).toContainText("Generate or edit images");
  await expect(tooltip).toHaveAttribute("data-placement", "above");

  await expect
    .poll(async () => {
      const [tokenBounds, tooltipBounds] = await Promise.all([
        token.boundingBox(),
        tooltip.boundingBox(),
      ]);
      if (!tokenBounds || !tooltipBounds) return Number.NaN;
      return tokenBounds.y - (tooltipBounds.y + tooltipBounds.height);
    })
    .toBeGreaterThanOrEqual(7);
  await expect
    .poll(async () => {
      const [tokenBounds, tooltipBounds] = await Promise.all([
        token.boundingBox(),
        tooltip.boundingBox(),
      ]);
      if (!tokenBounds || !tooltipBounds) return Number.NaN;
      return tokenBounds.y - (tooltipBounds.y + tooltipBounds.height);
    })
    .toBeLessThanOrEqual(9);
  await expect
    .poll(() =>
      tooltip.evaluate(
        (element) => element.parentElement?.parentElement === document.body
      )
    )
    .toBe(true);
});

test("a temporarily unavailable staged image does not reopen its preview", async ({
  page,
}) => {
  await page.goto(
    "/iframe.html?id=app-components-ai-input--preview-attachment-lifecycle&viewMode=story"
  );

  const previewTrigger = page.getByRole("button", {
    name: "Preview Lifecycle image",
  });
  await previewTrigger.click();

  const dialog = page.getByRole("dialog", { name: "Preview image" });
  await expect(dialog).toBeVisible();

  await page
    .getByTestId("make-preview-unavailable")
    .evaluate((button: HTMLButtonElement) => button.click());
  await expect(dialog).toBeHidden();

  await page
    .getByTestId("restore-preview")
    .evaluate((button: HTMLButtonElement) => button.click());
  await expect(dialog).toBeHidden();

  await previewTrigger.click();
  await expect(dialog).toBeVisible();
});

test("composer typography is 13px on native and rich editors", async ({ page }) => {
  const expectComposerTypography = async (storyId: string) => {
    await page.goto(`/iframe.html?id=${storyId}&viewMode=story`);
    const editor = page.getByRole("textbox", { name: "AI prompt" });
    await expect(editor).toHaveCSS("font-size", "13px");
    await expect(editor).toHaveCSS("line-height", "20px");
  };

  // Both editing implementations are independently styled. Keep their type
  // scale on the control-sized 13px/20px grid rather than chat prose's 15px.
  await expectComposerTypography("app-components-ai-input--default");
  await expectComposerTypography("app-components-ai-input--rich-text");
});
