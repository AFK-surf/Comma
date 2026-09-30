import { expect, test as baseTest } from "@playwright/test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createServer } from "vite";
import { fileURLToPath } from "node:url";
import { waitForSettledMotion } from "../../../e2e/helpers/motion";
// A source server exercises the shared menu components with production CSS.
type MenuTransition = { exiting: boolean; property: string; duration: string };
declare global {
  interface Window {
    menuTransitions: MenuTransition[];
  }
}
const test = baseTest.extend<{}, { menuBaseURL: string }>({
  menuBaseURL: [
    // Playwright requires fixture dependencies to use object destructuring.
    // eslint-disable-next-line no-empty-pattern
    async ({}, use) => {
      const root = fileURLToPath(new URL("../../../apps/web/", import.meta.url));
      const cacheDir = await mkdtemp(join(tmpdir(), "comma-menu-vite-"));
      const previousCwd = process.cwd();
      let server: Awaited<ReturnType<typeof createServer>> | undefined;
      try {
        // The web app config resolves workspace source aliases from its own cwd.
        process.chdir(root);
        server = await createServer({
          root,
          configFile: join(root, "vite.config.ts"),
          cacheDir,
          server: {
            host: "127.0.0.1",
            port: 0,
            strictPort: false,
            hmr: false,
            watch: null,
          },
          optimizeDeps: { include: ["eventsource-parser", "shiki", "mermaid"] },
          logLevel: "error",
        });
        await server.listen();
      } finally {
        process.chdir(previousCwd);
      }
      try {
        await use(server.resolvedUrls!.local[0]!);
      } finally {
        await server.close();
        await rm(cacheDir, { recursive: true, force: true });
      }
    },
    { scope: "worker" },
  ],
});

for (const trigger of ["Left menu", "Right menu"] as const) {
  test(`${trigger} uses shared enter and exit motion`, async ({
    page,
    menuBaseURL,
  }) => {
    await page.emulateMedia({ reducedMotion: "no-preference" });
    await page.route("**/menu-motion-fixture", (route) =>
      route.fulfill({
        contentType: "text/html",
        body: `<!doctype html><html><body><div id="root"></div><script type="module">import RefreshRuntime from '/@react-refresh';RefreshRuntime.injectIntoGlobalHook(window);window.$RefreshReg$=()=>{};window.$RefreshSig$=()=>t=>t;window.__vite_plugin_react_preamble_installed__=true;</script><script type="module" src="/@fs${encodeURI(fileURLToPath(new URL("./fixtures/menu-motion.tsx", import.meta.url)))}"></script></body></html>`,
      })
    );
    await page.goto(new URL("/menu-motion-fixture", menuBaseURL).href);
    // Capture real transitions even when the short animation ends before an assertion.
    await page.evaluate(() => {
      window.menuTransitions = [];
      // A short exit may finish and unmount before the browser dispatches its
      // queued transition event. Listen on the surface itself so detached-node
      // events remain observable instead of relying on document bubbling.
      const observed = new WeakSet<Element>();
      const observeSurfaces = () => {
        for (const surface of document.querySelectorAll('[data-animation="anchor"]')) {
          if (observed.has(surface)) continue;
          observed.add(surface);
          surface.addEventListener("transitionend", (event) => {
            if (event.target !== surface) return;
            window.menuTransitions.push({
              exiting: surface.hasAttribute("data-exiting"),
              property: (event as TransitionEvent).propertyName,
              duration: `${(event as TransitionEvent).elapsedTime}s`,
            });
          });
        }
      };
      new MutationObserver(observeSurfaces).observe(document.body, {
        childList: true,
        subtree: true,
      });
      observeSurfaces();
    });
    await page
      .getByRole("button", { name: trigger, exact: true })
      .click({ button: trigger === "Right menu" ? "right" : "left" });
    const popup = page.locator('[data-animation="anchor"]');
    await expect(popup).toBeVisible();
    await expect(popup).toHaveCSS("filter", "none");
    await expect
      .poll(() => page.evaluate(() => window.menuTransitions))
      .toContainEqual({ exiting: false, property: "opacity", duration: "0.12s" });
    await waitForSettledMotion(popup);
    await page.keyboard.press("Escape");
    await expect
      .poll(() => page.evaluate(() => window.menuTransitions))
      .toContainEqual({ exiting: true, property: "opacity", duration: "0.08s" });
    await expect(popup).toHaveCount(0);
  });
}

for (const { name, triggerName, popupSelector, triggerSelector } of [
  {
    name: "selection",
    triggerName: "Selection",
    popupSelector: '[data-slot="dropdown-popover"]',
    triggerSelector: '[data-slot="dropdown-trigger"][aria-label="Selection"]',
  },
  {
    name: "inline text editor",
    triggerName: "Inline name",
    popupSelector: ".comma-inline-editor-popover",
    triggerSelector: ".comma-inline-editor-trigger",
  },
]) {
  test(`${name} opens opaque over its hidden trigger and fades only on exit`, async ({
    page,
    menuBaseURL,
  }) => {
    await page.emulateMedia({ reducedMotion: "no-preference" });
    await page.route("**/menu-motion-fixture", (route) =>
      route.fulfill({
        contentType: "text/html",
        body: `<!doctype html><html><body><div id="root"></div><script type="module">import RefreshRuntime from '/@react-refresh';RefreshRuntime.injectIntoGlobalHook(window);window.$RefreshReg$=()=>{};window.$RefreshSig$=()=>t=>t;window.__vite_plugin_react_preamble_installed__=true;</script><script type="module" src="/@fs${encodeURI(fileURLToPath(new URL("./fixtures/menu-motion.tsx", import.meta.url)))}"></script></body></html>`,
      })
    );
    await page.goto(new URL("/menu-motion-fixture", menuBaseURL).href);
    // The popup replaces the hidden trigger label. Hold any entry fade
    // open so a dimmed label cannot slip between two samples.
    await page.addStyleTag({ content: ":root { --motion-duration-menu-enter: 1s; }" });
    await page.evaluate(
      ({ popupSelector: surfaceSelector, triggerSelector: controlSelector }) => {
        const samples: { popup: string; trigger: string }[] = [];
        const exits: { property: string; duration: string }[] = [];
        Object.assign(window, { selectionOpacity: samples, selectionExits: exits });
        const observed = new WeakSet<Element>();
        new MutationObserver(() => {
          const surface = document.querySelector(surfaceSelector);
          const trigger = document.querySelector(controlSelector);
          if (!surface || !trigger || surface.hasAttribute("data-exiting")) return;
          samples.push({
            popup: getComputedStyle(surface).opacity,
            trigger: getComputedStyle(trigger).opacity,
          });
          if (observed.has(surface)) return;
          observed.add(surface);
          surface.addEventListener("transitionend", (event) => {
            if (event.target !== surface || !surface.hasAttribute("data-exiting"))
              return;
            exits.push({
              property: (event as TransitionEvent).propertyName,
              duration: `${(event as TransitionEvent).elapsedTime}s`,
            });
          });
        }).observe(document.body, {
          childList: true,
          subtree: true,
          attributes: true,
          attributeFilter: ["class", "data-entering", "style"],
        });
      },
      { popupSelector, triggerSelector }
    );
    await page.getByRole("button", { name: triggerName, exact: true }).click();
    const popup = page.locator(popupSelector);
    if (name === "selection") {
      await expect(
        page.getByRole("option", { name: "One", exact: true })
      ).toBeVisible();
    } else {
      await expect(
        page.getByRole("textbox", { name: "Fixture inline name" })
      ).toHaveValue("Inline name");
    }
    const samples = await page.evaluate(
      () =>
        (
          window as unknown as {
            selectionOpacity: { popup: string; trigger: string }[];
          }
        ).selectionOpacity
    );
    expect(samples.length).toBeGreaterThan(0);
    // At least one surface stays opaque at each observed DOM mutation.
    // This catches the entry fade, not every painted frame or text alignment.
    for (const sample of samples) {
      expect(sample.popup === "1" || sample.trigger === "1").toBe(true);
    }
    await expect(popup).toHaveCSS("opacity", "1");
    await page.keyboard.press("Escape");
    await expect
      .poll(() =>
        page.evaluate(
          () => (window as unknown as { selectionExits: object[] }).selectionExits
        )
      )
      .toContainEqual({ property: "opacity", duration: "0.08s" });
    await expect(popup).toHaveCount(0);
  });
}

test("a closing selection cannot capture input while the next selection opens", async ({
  page,
  menuBaseURL,
}) => {
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await page.route("**/menu-motion-fixture", (route) =>
    route.fulfill({
      contentType: "text/html",
      body: `<!doctype html><html><body><div id="root"></div><script type="module">import RefreshRuntime from '/@react-refresh';RefreshRuntime.injectIntoGlobalHook(window);window.$RefreshReg$=()=>{};window.$RefreshSig$=()=>t=>t;window.__vite_plugin_react_preamble_installed__=true;</script><script type="module" src="/@fs${encodeURI(fileURLToPath(new URL("./fixtures/menu-motion.tsx", import.meta.url)))}"></script></body></html>`,
    })
  );
  await page.goto(new URL("/menu-motion-fixture", menuBaseURL).href);
  // Hold a real exit transition open so the assertion cannot miss the short
  // overlap on a fast machine. The normal 80ms duration is covered above.
  await page.addStyleTag({ content: ":root { --motion-duration-menu-exit: 1s; }" });
  const trigger = page.getByRole("button", { name: "Selection", exact: true });
  await trigger.click();
  const popup = page.getByRole("dialog", { name: "Selection", exact: true });
  const oldPopup = await popup.elementHandle();
  expect(oldPopup).not.toBeNull();
  await expect(page.getByRole("option", { name: "One", exact: true })).toBeVisible();
  await page.keyboard.press("Escape");
  await oldPopup!.evaluate((element) => {
    for (const animation of element.getAnimations()) animation.pause();
  });
  expect(
    await oldPopup!.evaluate((element) => element.hasAttribute("data-exiting"))
  ).toBe(true);
  // FocusScope restores focus after unmount. Start outside the paused exit
  // surface to test whether a stale option can steal focus back.
  await trigger.focus();
  await expect(trigger).toBeFocused();
  // Closed content must leave both hit testing and the accessibility tree, even
  // while its pixels finish animating. Do not merely ignore it in the locator.
  const canReceiveInput = await oldPopup!.evaluate((element) => {
    const option = element.querySelector<HTMLElement>('[role="option"]')!;
    option.focus();
    const box = option.getBoundingClientRect();
    return {
      focus: element.contains(document.activeElement),
      pointer: element.contains(
        document.elementFromPoint(box.x + box.width / 2, box.y + box.height / 2)
      ),
    };
  });
  expect(canReceiveInput).toEqual({ focus: false, pointer: false });
  // Playwright's role locator does not account for native inert. Query the
  // browser accessibility tree rather than a DOM approximation of that tree.
  const cdp = await page.context().newCDPSession(page);
  const accessibleDialogs = async () => {
    const { nodes } = await cdp.send("Accessibility.getFullAXTree");
    return nodes
      .filter((node) => !node.ignored && node.role?.value === "dialog")
      .map((node) => node.name?.value);
  };
  try {
    expect(await accessibleDialogs()).toEqual([]);
    await page.getByRole("button", { name: "Next selection", exact: true }).click();
    expect(await accessibleDialogs()).toEqual(["Next selection"]);
  } finally {
    await cdp.detach();
  }
  await page.getByRole("option", { name: "Beta", exact: true }).click();
  await expect(page.getByRole("button", { name: /Beta Next selection/ })).toBeVisible();
  await oldPopup!.evaluate((element) => {
    for (const animation of element.getAnimations()) animation.finish();
  });
  await expect(page.locator('[data-slot="dropdown-popover"]')).toHaveCount(0);
  await trigger.click();
  await page.getByRole("option", { name: "Two", exact: true }).click();
  await expect(page.getByRole("button", { name: /Two Selection/ })).toBeVisible();
});

test("select restores its trigger focus inside a modal after choosing an option", async ({
  page,
  menuBaseURL,
}) => {
  await page.route("**/menu-motion-fixture", (route) =>
    route.fulfill({
      contentType: "text/html",
      body: `<!doctype html><html><body><div id="root"></div><script type="module">import RefreshRuntime from '/@react-refresh';RefreshRuntime.injectIntoGlobalHook(window);window.$RefreshReg$=()=>{};window.$RefreshSig$=()=>t=>t;window.__vite_plugin_react_preamble_installed__=true;</script><script type="module" src="/@fs${encodeURI(fileURLToPath(new URL("./fixtures/menu-motion.tsx", import.meta.url)))}"></script></body></html>`,
    })
  );
  await page.goto(new URL("/menu-motion-fixture", menuBaseURL).href);

  await page.getByRole("button", { name: "Open settings fixture" }).click();
  const trigger = page.getByRole("button", { name: /Fixture theme/ });
  await trigger.click();
  await page.getByRole("option", { name: "Dark", exact: true }).click();
  await expect(page.getByRole("listbox")).toBeHidden();
  await expect(trigger).toBeFocused();

  await trigger.click();
  await expect(page.getByRole("option", { name: "Light", exact: true })).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(trigger).toBeFocused();

  // Reopen while the previous surface may still be completing its exit.
  await trigger.click();
  await page.getByRole("option", { name: "Light", exact: true }).click();
  await expect(trigger).toBeFocused();
  const otherControl = page.getByRole("button", { name: "First settings control" });
  await otherControl.focus();
  await expect(page.locator('[data-slot="dropdown-popover"]')).toHaveCount(0);
  await expect(otherControl).toBeFocused();
});

test("Inbox actions dismiss on blank content and remain usable after reopening", async ({
  page,
  menuBaseURL,
}) => {
  await page.route("**/menu-motion-fixture", (route) =>
    route.fulfill({
      contentType: "text/html",
      body: `<!doctype html><html><body><div id="root"></div><script type="module">import RefreshRuntime from '/@react-refresh';RefreshRuntime.injectIntoGlobalHook(window);window.$RefreshReg$=()=>{};window.$RefreshSig$=()=>t=>t;window.__vite_plugin_react_preamble_installed__=true;</script><script type="module" src="/@fs${encodeURI(fileURLToPath(new URL("./fixtures/menu-motion.tsx", import.meta.url)))}"></script></body></html>`,
    })
  );
  await page.goto(new URL("/menu-motion-fixture", menuBaseURL).href);
  const trigger = page.getByTestId("inbox-actions-trigger");
  await trigger.click();
  await expect(
    page.getByRole("menuitem", { name: "Delete all", exact: true })
  ).toBeVisible();
  const blank = await page.getByTestId("blank-content").boundingBox();
  await page.mouse.click(blank!.x + 20, blank!.y + 20);
  await expect(
    page.getByRole("menuitem", { name: "Delete all", exact: true })
  ).toHaveCount(0);
  await trigger.click();
  await expect(
    page.getByRole("menuitem", { name: "Delete all", exact: true })
  ).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(trigger).toBeFocused();
});

test("submenu motion preserves targets and keyboard return focus", async ({
  page,
  menuBaseURL,
}) => {
  await page.route("**/menu-motion-fixture", (route) =>
    route.fulfill({
      contentType: "text/html",
      body: `<!doctype html><html><body><div id="root"></div><script type="module">import RefreshRuntime from '/@react-refresh';RefreshRuntime.injectIntoGlobalHook(window);window.$RefreshReg$=()=>{};window.$RefreshSig$=()=>t=>t;window.__vite_plugin_react_preamble_installed__=true;</script><script type="module" src="/@fs${encodeURI(fileURLToPath(new URL("./fixtures/menu-motion.tsx", import.meta.url)))}"></script></body></html>`,
    })
  );
  await page.goto(new URL("/menu-motion-fixture", menuBaseURL).href);
  await page.getByRole("button", { name: "Left menu", exact: true }).click();
  const parent = page.getByRole("menuitem", { name: "Arrange", exact: true });
  await parent.focus();
  await page.keyboard.press("ArrowRight");
  const child = page.getByRole("menu", { name: "Arrange", exact: true });
  await expect(child).toBeVisible();
  const parentBox = await parent.boundingBox();
  const childBox = await child.boundingBox();
  expect(childBox!.x).toBeGreaterThanOrEqual(parentBox!.x + parentBox!.width);
  const surface = child.locator("..");
  const motion = await surface.evaluate((element) => {
    const style = getComputedStyle(element);
    return {
      scale: style.scale,
      filter: style.filter,
      property: style.transitionProperty,
    };
  });
  expect(motion).toEqual({ scale: "none", filter: "none", property: "opacity" });
  await page.keyboard.press("Escape");
  await expect(child).toHaveCount(0);
  await expect(parent).toBeFocused();
  await page.keyboard.press("ArrowRight");
  await expect(child).toBeVisible();
  await page.keyboard.press("ArrowLeft");
  await expect(parent).toBeFocused();
  await expect(child).toHaveCount(0);
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.keyboard.press("ArrowRight");
  await expect(child).toBeVisible();
  await expect(surface).toHaveCSS("transition-property", "none");
});

for (const placement of ["bottom", "top", "right", "left"] as const) {
  test(`root menu enters from its resolved ${placement} anchor without blur`, async ({
    page,
    menuBaseURL,
  }) => {
    await page.route("**/menu-motion-fixture", (route) =>
      route.fulfill({
        contentType: "text/html",
        body: `<!doctype html><html><body><div id="root"></div><script type="module">import RefreshRuntime from '/@react-refresh';RefreshRuntime.injectIntoGlobalHook(window);window.$RefreshReg$=()=>{};window.$RefreshSig$=()=>t=>t;window.__vite_plugin_react_preamble_installed__=true;</script><script type="module" src="/@fs${encodeURI(fileURLToPath(new URL("./fixtures/menu-motion.tsx", import.meta.url)))}"></script></body></html>`,
      })
    );
    await page.goto(new URL("/menu-motion-fixture", menuBaseURL).href);
    const horizontal = placement === "left" || placement === "right";
    const trigger = page.getByRole("button", {
      name: horizontal ? "Right menu" : "Left menu",
      exact: true,
    });
    if (placement === "top" || placement === "left") {
      await trigger.evaluate((element, side) => {
        Object.assign(element.style, {
          position: "fixed",
          ...(side === "top" ? { bottom: "8px" } : { right: "8px" }),
          zIndex: "1",
        });
      }, placement);
    }
    await page.evaluate(() => {
      const samples: string[] = [];
      Object.assign(window, { menuTravel: samples });
      // Read actual entry positions when React Aria updates the surface.
      // A short transition can finish before transitionrun reaches the document.
      new MutationObserver(() => {
        const surface = document.querySelector('[data-animation="anchor"]');
        if (surface) samples.push(getComputedStyle(surface).translate);
      }).observe(document.body, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ["class", "data-entering", "data-placement"],
      });
    });
    await trigger.click({ button: horizontal ? "right" : "left" });
    const popup = page.locator('[data-animation="anchor"]');
    await expect(popup).toHaveAttribute("data-placement", placement);
    const from = {
      bottom: "0px -2px",
      top: "0px 2px",
      right: "-2px",
      left: "2px",
    }[placement];
    await expect
      .poll(() =>
        page.evaluate(() => (window as unknown as { menuTravel: string[] }).menuTravel)
      )
      .toContain(from);
    await expect(popup).toHaveCSS("translate", "0px");
    await expect(popup).toHaveCSS("scale", "1");
    await expect(popup).toHaveCSS("filter", "none");
    await page.keyboard.press("Escape");
    await expect(popup).toHaveCount(0);

    await page.emulateMedia({ reducedMotion: "reduce" });
    await trigger.click({ button: horizontal ? "right" : "left" });
    await expect(popup).toBeVisible();
    await expect(popup).toHaveCSS("translate", "0px");
    await expect(popup).toHaveCSS("transition-property", "none");
  });
}

test("composer menu enters from the caret with shared motion and remains keyboard usable", async ({
  page,
  menuBaseURL,
}) => {
  await page.route("**/menu-motion-fixture", (route) =>
    route.fulfill({
      contentType: "text/html",
      body: `<!doctype html><html><body><div id="root"></div><script type="module">import RefreshRuntime from '/@react-refresh';RefreshRuntime.injectIntoGlobalHook(window);window.$RefreshReg$=()=>{};window.$RefreshSig$=()=>t=>t;window.__vite_plugin_react_preamble_installed__=true;</script><script type="module" src="/@fs${encodeURI(fileURLToPath(new URL("./fixtures/menu-motion.tsx", import.meta.url)))}"></script></body></html>`,
    })
  );
  await page.goto(new URL("/menu-motion-fixture", menuBaseURL).href);
  await page.evaluate(() => {
    const samples: string[] = [];
    Object.assign(window, { composerTravel: samples });
    new MutationObserver(() => {
      const surface = document.querySelector(".comma-ai-input-menu");
      if (surface) samples.push(getComputedStyle(surface).translate);
    }).observe(document.body, { childList: true, subtree: true });
  });
  const editor = page.getByRole("textbox", { name: "AI prompt", exact: true });
  await editor.click();
  await page.keyboard.type("@");
  const menu = page.getByRole("listbox", { name: "Motion mentions" });
  await expect(menu).toBeVisible();
  await expect
    .poll(() =>
      page.evaluate(
        () => (window as unknown as { composerTravel: string[] }).composerTravel
      )
    )
    .toContain("0px 2px");
  await expect(menu).toHaveCSS("translate", "0px");
  await expect(menu).toHaveCSS("filter", "none");
  await expect(menu).toHaveCSS("transform", "matrix(1, 0, 0, 1, 0, 0)");
  const menuBox = await menu.boundingBox();
  const editorBox = await editor.boundingBox();
  expect(menuBox!.y + menuBox!.height).toBeLessThan(editorBox!.y);
  await page.keyboard.press("Escape");
  await expect(menu).toHaveCount(0);
  await expect(editor).toBeFocused();

  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.keyboard.press("Backspace");
  await page.keyboard.type("@");
  await expect(menu).toBeVisible();
  await expect(menu).toHaveCSS("translate", "none");
  await expect(menu).toHaveCSS("transition-property", "none");
  await page.keyboard.press("Enter");
  await expect(menu).toHaveCount(0);
  await expect(editor).toBeFocused();
  await expect(editor).toContainText("Notes");
});

for (const level of ["list", "browse"] as const) {
  test(`composer ${level} keeps repeated keyboard navigation stable under a resting pointer`, async ({
    page,
    menuBaseURL,
  }) => {
    // Every held-key step waits for two painted frames. Allow slower runners
    // to complete the full wraparound without weakening the per-step assertions.
    test.setTimeout(120_000);
    await page.route("**/menu-motion-fixture?*", (route) =>
      route.fulfill({
        contentType: "text/html",
        body: `<!doctype html><html><body><div id="root"></div><script type="module">import RefreshRuntime from '/@react-refresh';RefreshRuntime.injectIntoGlobalHook(window);window.$RefreshReg$=()=>{};window.$RefreshSig$=()=>t=>t;window.__vite_plugin_react_preamble_installed__=true;</script><script type="module" src="/@fs${encodeURI(fileURLToPath(new URL("./fixtures/menu-motion.tsx", import.meta.url)))}"></script></body></html>`,
      })
    );
    await page.goto(
      new URL(`/menu-motion-fixture?navigation=${level}`, menuBaseURL).href
    );
    const editor = page.getByRole("textbox", { name: "AI prompt", exact: true });
    await editor.click();
    await page.keyboard.type("@");
    if (level === "browse") {
      await page.keyboard.press("ArrowDown");
      await page.keyboard.press("ArrowRight");
    }
    const menu = page.getByTestId("ai-input-menu");
    await waitForSettledMotion(menu);
    const initialBox = await menu.boundingBox();
    const input =
      level === "browse"
        ? page.getByRole("combobox", { name: "Browse files" })
        : editor;
    const row = page.getByRole("option", { name: "File 4", exact: true });
    await row.hover();
    await expect(row).toHaveAttribute("aria-selected", "true");
    await page.keyboard.press("ArrowDown");
    await expect(
      page.getByRole("option", { name: "File 5", exact: true })
    ).toHaveAttribute("aria-selected", "true");
    // Moving away and back to the same screen coordinates is still pointer intent.
    await page.mouse.move(0, 0);
    await row.hover();
    await expect(row).toHaveAttribute("aria-selected", "true");
    // Repeated down() sends real repeated keydowns without a keyup, as a held key does.
    // Paint each step so browser hit testing sees rows move under the stationary pointer.
    for (let step = 1; step <= 76; step++) {
      await page.keyboard.down("ArrowDown");
      await page.evaluate(
        () =>
          new Promise<void>((resolve) =>
            requestAnimationFrame(() => requestAnimationFrame(() => resolve()))
          )
      );
      const selected = page.getByRole("option", {
        name: `File ${(4 + step) % 72}`,
        exact: true,
      });
      await expect(selected).toHaveAttribute("aria-selected", "true");
      await expect(input).toHaveAttribute(
        "aria-activedescendant",
        (await selected.getAttribute("id"))!
      );
    }
    await page.keyboard.up("ArrowDown");
    await expect(input).toBeFocused();
    expect(await menu.boundingBox()).toEqual(initialBox);
    // A real mouse movement takes over immediately, without scrolling its target.
    const target = page.getByRole("option", { name: "File 6", exact: true });
    await target.hover();
    await expect(target).toHaveAttribute("aria-selected", "true");
    const viewport = menu.locator('[data-slot="scroll-area-viewport"]');
    const beforeWheel = await viewport.evaluate((element) => element.scrollTop);
    await page.mouse.wheel(0, 120);
    await expect
      .poll(() => viewport.evaluate((element) => element.scrollTop))
      .toBeGreaterThan(beforeWheel);
    await expect(target).toHaveAttribute("aria-selected", "true");
    await page.keyboard.press("ArrowUp");
    await expect(
      page.getByRole("option", { name: "File 5", exact: true })
    ).toHaveAttribute("aria-selected", "true");
    await page.keyboard.press("Enter");
    await expect(menu).toHaveCount(0);
    await expect(editor).toContainText("File 5");
    await expect(editor).toBeFocused();
  });
}

for (const level of ["list", "browse"] as const) {
  test(`composer ${level} paints exactly one full highlight during repeated keys`, async ({
    page,
    menuBaseURL,
  }) => {
    await page.emulateMedia({ reducedMotion: "no-preference" });
    await page.route("**/menu-motion-fixture?*", (route) =>
      route.fulfill({
        contentType: "text/html",
        body: `<!doctype html><html><body><div id="root"></div><script type="module">import RefreshRuntime from '/@react-refresh';RefreshRuntime.injectIntoGlobalHook(window);window.$RefreshReg$=()=>{};window.$RefreshSig$=()=>t=>t;window.__vite_plugin_react_preamble_installed__=true;</script><script type="module" src="/@fs${encodeURI(fileURLToPath(new URL("./fixtures/menu-motion.tsx", import.meta.url)))}"></script></body></html>`,
      })
    );
    await page.goto(
      new URL(`/menu-motion-fixture?navigation=${level}`, menuBaseURL).href
    );
    const editor = page.getByRole("textbox", { name: "AI prompt", exact: true });
    await editor.click();
    await page.keyboard.type("@");
    if (level === "browse") {
      await page.keyboard.press("ArrowDown");
      await page.keyboard.press("ArrowRight");
    }
    const menu = page.getByTestId("ai-input-menu");
    await waitForSettledMotion(menu);
    await waitForSettledMotion(menu.getByRole("option").first());
    // Match menu.mp4: the pointer stays outside the menu throughout navigation.
    await page.mouse.move(0, 0);
    const recorder = await menu.evaluateHandle((root) => {
      const options = Array.from(root.querySelectorAll('[role="option"]'));
      const selectedColor = getComputedStyle(options[0]!).backgroundColor;
      const idleColor = getComputedStyle(options[1]!).backgroundColor;
      let running = true;
      let frames = 0;
      const violations: string[] = [];
      const sample = () => {
        if (!running) return;
        frames++;
        for (const option of options) {
          const selected = option.getAttribute("aria-selected") === "true";
          const actual = getComputedStyle(option).backgroundColor;
          const expected = selected ? selectedColor : idleColor;
          if (actual !== expected && violations.length < 12) {
            violations.push(
              `${option.textContent}: selected=${selected}, color=${actual}, expected=${expected}`
            );
          }
        }
        requestAnimationFrame(sample);
      };
      requestAnimationFrame(sample);
      return {
        violations,
        stop: () => {
          running = false;
          return frames;
        },
      };
    });
    for (const key of ["ArrowDown", "ArrowUp"]) {
      for (let step = 0; step < 16; step++) {
        await page.keyboard.down(key);
        // Sample every frame while the key repeats faster than a 150ms color fade.
        await page.evaluate(
          () =>
            new Promise<void>((resolve) => {
              let remaining = 4;
              const next = () =>
                --remaining === 0 ? resolve() : requestAnimationFrame(next);
              requestAnimationFrame(next);
            })
        );
      }
      await page.keyboard.up(key);
    }
    const result = await recorder.evaluate((recording) => ({
      frames: recording.stop(),
      violations: recording.violations,
    }));
    await recorder.dispose();
    expect(result.frames).toBeGreaterThanOrEqual(32);
    expect(result.violations).toEqual([]);
    await expect(
      menu.getByRole("option", { name: "File 0", exact: true })
    ).toHaveAttribute("aria-selected", "true");
    await page.keyboard.press("Enter");
    await expect(menu).toHaveCount(0);
    await expect(editor).toContainText("File 0");
    await expect(editor).toBeFocused();
  });
}
