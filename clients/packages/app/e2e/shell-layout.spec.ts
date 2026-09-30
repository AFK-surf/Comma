import { waitForSettledMotion } from "../../../e2e/helpers/motion";
import { expect, test as baseTest, type Locator, type Page } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { startSessionProjectionStub } from "../../../e2e/helpers/session-fixture";
import { parseCssColor, type CssRgbaColor } from "../../../e2e/helpers/css-color";
import { openTaskDetails, taskDoneButton } from "../../../e2e/helpers/task-panel";
import {
  chatSmokeAssistantReply,
  chatSmokeTaskConversation,
  chatSmokeWorkspace,
  chatSmokeWorkspaceChat,
  startChatSmokeStub,
} from "../../../e2e/p0/chat-stub";
import { webBaseURL } from "../../../e2e/p0/smoke-env";
import { grayDarkMode, grayLightMode } from "../../ui/src/tokens/colors/grays";
import {
  commaThemeLightnessMax,
  commaThemeLightnessMin,
  commaThemeLightnessNeutral,
  hexToOklch,
  oklchChromaGainFromSample,
} from "../../ui/src/tokens/colors/oklch";
import { AI_INPUT_SMALL_TEXTAREA_MIN_HEIGHT_PX } from "../../ui/src/components/ai-input/styles";
import { iconStrokeWidth } from "../../ui/src/tokens/icons";

const test = baseTest.extend<{ unavailableProductApi: string }>({
  // oxlint-disable-next-line no-empty-pattern -- Playwright requires a destructured fixture dependency list.
  unavailableProductApi: async ({}, use) => {
    const stub = await startSessionProjectionStub({ email: "e2e@example.com" });
    try {
      await use(stub.baseUrl);
    } finally {
      await stub.close();
    }
  },
});

const defaultCustomChroma = (() => {
  const light = hexToOklch(grayLightMode[500] ?? grayLightMode[900]);
  const dark = hexToOklch(grayDarkMode[500] ?? grayDarkMode[900]);
  return (
    Math.max(
      oklchChromaGainFromSample(light.c, light.l),
      oklchChromaGainFromSample(dark.c, dark.l)
    ) * 2.5
  );
})();

/** Published Ottosson OKLCH hue of Comma blue `#0C55FF`, not derived in this file. */
const commaBlueOklchHueDeg = 263.19;

const srgbChannelToLinear = (channel: number) => {
  const s = channel / 255;
  return s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
};

const relativeLuminance = ({ b, g, r }: CssRgbaColor) =>
  0.2126 * srgbChannelToLinear(r) +
  0.7152 * srgbChannelToLinear(g) +
  0.0722 * srgbChannelToLinear(b);

const contrastRatio = (a: CssRgbaColor, b: CssRgbaColor) => {
  const left = relativeLuminance(a);
  const right = relativeLuminance(b);
  const [hi, lo] = left > right ? [left, right] : [right, left];
  return (hi + 0.05) / (lo + 0.05);
};

const contrastAgainstPaintedBackground = async (locator: Locator) => {
  const pair = await locator.evaluate((element) => {
    const fg = getComputedStyle(element).color;
    const backgrounds: string[] = [];
    let node: Element | null = element;
    while (node) {
      backgrounds.push(getComputedStyle(node).backgroundColor);
      node = node.parentElement;
    }
    return { backgrounds, fg };
  });
  const fg = parseCssColor(pair.fg);
  const bg = pair.backgrounds.map(parseCssColor).find((color) => color.a > 0.95);
  if (!bg) throw new Error("No opaque background behind the sampled text.");
  return contrastRatio(fg, bg);
};

const contrastOfPrimaryTextOnPrimaryBg = async (page: Page) => {
  const pair = await page.evaluate(() => {
    const probe = document.createElement("span");
    probe.style.color = "var(--color-text-primary)";
    probe.style.backgroundColor = "var(--color-bg-primary)";
    document.documentElement.append(probe);
    const style = getComputedStyle(probe);
    const result = { background: style.backgroundColor, color: style.color };
    probe.remove();
    return result;
  });
  return contrastRatio(parseCssColor(pair.color), parseCssColor(pair.background));
};

// The widths an element paints over the next frames, to show a move plays out
// across frames rather than snapping to its rest.
function sampleFrameWidths(locator: Locator, durationMs = 900) {
  return locator.evaluate(
    (element, duration) =>
      new Promise<number[]>((resolve) => {
        const widths: number[] = [];
        const start = performance.now();
        const sample = (now: number) => {
          widths.push(element.getBoundingClientRect().width);
          if (now - start < duration) requestAnimationFrame(sample);
          else resolve(widths);
        };
        requestAnimationFrame(sample);
      }),
    durationMs
  );
}

let transitionObserverSequence = 0;

function armAndPauseTransition(
  locator: Locator,
  transitionProperty: string,
  currentTime: number
) {
  const marker = "data-e2e-transition-observer";
  const markerValue = String(++transitionObserverSequence);
  const captured = locator.evaluate(
    (element, options) => {
      element.setAttribute(options.marker, options.markerValue);

      return new Promise<void>((resolve, reject) => {
        let animationFrame: number | undefined;
        const existingAnimations = new Set(element.getAnimations());
        const cleanup = () => {
          if (animationFrame !== undefined) {
            cancelAnimationFrame(animationFrame);
          }
          window.clearTimeout(timeout);
          if (element.getAttribute(options.marker) === options.markerValue) {
            element.removeAttribute(options.marker);
          }
        };
        const findAndPauseTransition = () => {
          const transition = element
            .getAnimations()
            .find(
              (animation) =>
                !existingAnimations.has(animation) &&
                animation instanceof CSSTransition &&
                animation.transitionProperty === options.transitionProperty
            );
          if (!transition) {
            animationFrame = requestAnimationFrame(findAndPauseTransition);
            return;
          }

          transition.pause();
          transition.currentTime = options.currentTime;
          cleanup();
          resolve();
        };
        const timeout = window.setTimeout(() => {
          cleanup();
          reject(
            new Error(`Timed out waiting for ${options.transitionProperty} transition`)
          );
        }, 5_000);

        animationFrame = requestAnimationFrame(findAndPauseTransition);
      });
    },
    { currentTime, marker, markerValue, transitionProperty }
  );

  return {
    armed: expect(locator).toHaveAttribute(marker, markerValue),
    captured,
  };
}

async function assertCompactHomeControls(page: Page) {
  const prompt = page.getByRole("textbox", { name: "AI prompt" });

  // Home has no route header: its identity lives on the region.
  await expect(page.getByRole("region", { name: "Comma assistant" })).toBeVisible();
  await expect(page.getByRole("heading", { level: 1 })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Full-access" })).toHaveCount(0);
  await expect(prompt).toBeVisible();
  await expect
    .poll(async () => (await prompt.boundingBox())?.width ?? 0)
    .toBeGreaterThan(0);
}

// The active rail item is marked for assistive tech and paints only its icon
// slot with the sidebar item token; the label keeps its resting colour.
async function expectActiveRailItem(
  page: Page,
  name: string,
  role: "button" | "link" = "link"
) {
  const link = page.getByRole(role, { exact: true, name });
  await expect(link).toHaveAttribute("aria-current", "page");
  await expect
    .poll(() =>
      link.evaluate((element) => {
        const icon = element.querySelector<HTMLElement>(
          '[data-slot="left-rail-item-icon"]'
        )!;
        const probe = document.createElement("span");
        probe.style.backgroundColor = "var(--color-sidebar-bg-item)";
        document.body.append(probe);
        const expected = getComputedStyle(probe).backgroundColor;
        probe.remove();
        return {
          iconBackground: getComputedStyle(icon).backgroundColor === expected,
          selected: element.getAttribute("data-selected"),
        };
      })
    )
    .toEqual({ iconBackground: true, selected: "true" });
}

// The settings modal scales in from 95%, so every rect read while it is still
// entering comes back short. Wait for the card to reach its resting transform.
async function expectSettledSettingsModal(page: Page) {
  const dialog = page.getByRole("dialog", { name: "Settings sections" });
  await expect(dialog).toBeVisible();
  await expect
    .poll(() =>
      dialog.evaluate((element) => getComputedStyle(element.parentElement!).transform)
    )
    .toBe("none");
  return dialog;
}

test("titlebar navigation tracks history and invalidates forward branches", async ({
  page,
}) => {
  await installBrowserTestSession(page, {
    apiBaseUrl: "http://127.0.0.1:65535",
    email: "e2e@example.com",
    token: "comma_sess_e2e",
  });
  await page.goto("/#/inbox");

  const back = page.getByRole("button", { name: "Back" });
  const forward = page.getByRole("button", { name: "Forward" });
  const home = page.getByRole("link", { exact: true, name: "Home" });

  await expect(back).toBeDisabled();
  await expect(forward).toBeDisabled();

  await home.click();
  await expect(page).toHaveURL(/#\/$/);
  await expect(back).toBeEnabled();
  await expect(forward).toBeDisabled();

  await back.click();
  await expect(page).toHaveURL(/#\/inbox$/);
  await expect(back).toBeDisabled();
  await expect(forward).toBeEnabled();

  // The browser keeps its forward branch when the current entry reloads.
  await page.reload();
  await expect(page).toHaveURL(/#\/inbox$/);
  await expect(back).toBeDisabled();
  await expect(forward).toBeEnabled();

  await forward.click();
  await expect(page).toHaveURL(/#\/$/);
  await expect(back).toBeEnabled();
  await expect(forward).toBeDisabled();

  await back.click();
  await expect(page).toHaveURL(/#\/inbox$/);
  await expect(forward).toBeEnabled();

  // A fresh navigation from the back entry replaces the previous forward branch.
  await home.click();
  await expect(page).toHaveURL(/#\/$/);
  await expect(back).toBeEnabled();
  await expect(forward).toBeDisabled();

  await page.reload();
  await expect(page).toHaveURL(/#\/$/);
  await expect(back).toBeEnabled();
  await expect(forward).toBeDisabled();
});

test("skills catalog recovers from an API failure using Retry", async ({ page }) => {
  const apiBaseUrl = "https://salix.comma.surf";
  await installBrowserTestSession(page, {
    apiBaseUrl,
    email: "skills-retry@comma.local",
    token: "comma_sess_skills_retry",
  });
  await page.route(`${apiBaseUrl}/v1/comma/workspaces`, (route) =>
    route.fulfill({
      json: {
        data: [
          {
            group_id: "grp_plugins",
            id: "wsp_plugins",
            name: "Plugins",
            status: "ready",
          },
        ],
      },
    })
  );
  await page.route(`${apiBaseUrl}/v1/comma/workspaces/wsp_plugins/plugins`, (route) =>
    route.fulfill({ json: { data: [] } })
  );
  let requests = 0;
  await page.route(`${apiBaseUrl}/v1/comma/workspaces/wsp_plugins/skills`, (route) => {
    requests += 1;
    return requests === 1
      ? route.fulfill({ status: 503, json: { error: "skills_unavailable" } })
      : route.fulfill({
          json: {
            data: [
              {
                skill_id: "summary",
                name: "Recovered skill",
                source: "custom",
                location: "/.runtime/skills/summary/SKILL.md",
              },
            ],
          },
        });
  });
  await page.goto("/#/plugins");
  await page.getByRole("tab", { name: "Skills", exact: true }).click();
  await expect(page.getByRole("alert")).toHaveText("Couldn’t load skills.");
  await expect(page.getByText("No skills found")).toHaveCount(0);
  await page.getByRole("button", { name: "Retry", exact: true }).click();
  await expect(page.getByText("Recovered skill", { exact: true })).toBeVisible();
  await expect(page.getByRole("alert")).toHaveCount(0);
  expect(requests).toBe(2);
});

test("plugin detail keeps its top navigation controls outside the window drag region", async ({
  page,
}) => {
  const apiBaseUrl = "https://salix.comma.surf";
  await installBrowserTestSession(page, {
    apiBaseUrl,
    email: "plugin-drag-region@comma.local",
    token: "comma_sess_plugin_drag_region",
  });
  await page.route(`${apiBaseUrl}/v1/comma/workspaces`, (route) =>
    route.fulfill({
      contentType: "application/json",
      json: {
        data: [
          {
            group_id: "grp_plugins",
            id: "wsp_plugins",
            name: "Plugins",
            status: "ready",
          },
        ],
      },
    })
  );
  await page.route(`${apiBaseUrl}/v1/comma/workspaces/wsp_plugins/plugins`, (route) =>
    route.fulfill({
      contentType: "application/json",
      json: {
        data: [
          {
            brand: "notion",
            category: "Integrations",
            description: "Search and update your workspace",
            id: "notion",
            installed: true,
            locked: false,
            mcps: [{ id: "notion-mcp", name: "Notion" }],
            name: "Notion",
            skills: [],
            summary: "Search and update your workspace",
          },
        ],
      },
    })
  );
  await page.goto("/#/plugins");
  await expect(
    page.locator('[data-plugin-brand="notion"] svg[data-provider-logo="notion"]')
  ).toBeVisible();
  await page.getByRole("button", { name: "View Notion plugin details" }).click();

  const detail = page.locator('[data-slot="plugin-detail"]');
  const back = detail.getByRole("button", { name: "Back to plugins" });
  const sidebarToggle = page.locator(".comma-sidebar-edge-toggle");
  await expect(back).toBeVisible();
  // The header and the plugin's MCP row both carry the product logo.
  const detailLogos = detail.locator(
    '[data-plugin-brand="notion"] svg[data-provider-logo="notion"]'
  );
  await expect(detailLogos).toHaveCount(2);
  await expect(detailLogos.first()).toBeVisible();
  await expect(sidebarToggle).toBeVisible();
  await expect(sidebarToggle).toHaveAttribute("aria-expanded", "true");
  // The window bar is the only drag surface now, so the content panel stays
  // no-drag and the route paints no drag strip of its own over its controls.
  await expect(page.locator(".comma-content")).toHaveCSS(
    "-webkit-app-region",
    "no-drag"
  );
  await expect(detail.locator('[data-slot="plugin-titlebar-drag"]')).toHaveCount(0);
  await expect
    .poll(() =>
      detail.evaluate((element) =>
        Array.from(element.querySelectorAll<HTMLElement>("*")).every(
          (node) =>
            getComputedStyle(node).getPropertyValue("-webkit-app-region") !== "drag"
        )
      )
    )
    .toBe(true);

  for (const control of [back, sidebarToggle]) {
    await expect
      .poll(() =>
        control.evaluate((element) => {
          const rect = element.getBoundingClientRect();
          return (
            document
              .elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2)
              ?.closest("button") === element
          );
        })
      )
      .toBe(true);
  }

  await sidebarToggle.click();
  await expect(sidebarToggle).toHaveAttribute("aria-expanded", "false");
  await sidebarToggle.click();
  await expect(sidebarToggle).toHaveAttribute("aria-expanded", "true");
  await back.click();
  await expect(page.getByRole("heading", { level: 1, name: "Plugins" })).toBeVisible();
});

for (const freshAddBeforeExpiry of [false, true]) {
  test(`plugin verification deadline fences requests (${freshAddBeforeExpiry ? "new Add before expiry" : "retry after expiry"})`, async ({
    page,
  }) => {
    const apiBaseUrl = "http://127.0.0.1:43129";
    const plugin = {
      brand: "linear",
      category: "Integrations",
      id: "linear",
      installed: false,
      locked: false,
      mcps: [],
      name: "Linear",
      skills: [],
      summary: "Track work",
    };
    await installBrowserTestSession(page, {
      apiBaseUrl,
      email: "plugin-deadline@comma.local",
      token: "comma_sess_deadline",
    });
    await page.route(`${apiBaseUrl}/v1/comma/workspaces`, (route) =>
      route.fulfill({
        json: {
          data: [
            {
              group_id: "grp_plugins",
              id: "wsp_plugins",
              name: "Plugins",
              status: "ready",
            },
          ],
        },
      })
    );
    await page.route(`${apiBaseUrl}/v1/comma/workspaces/wsp_plugins/plugins`, (route) =>
      route.fulfill({ json: { data: [plugin] } })
    );
    let calls = 0;
    let releaseOld!: () => void;
    let releaseNew!: () => void;
    let oldResponded = false;
    const oldResponse = new Promise<void>((resolve) => {
      releaseOld = resolve;
    });
    const newResponse = new Promise<void>((resolve) => {
      releaseNew = resolve;
    });
    await page.route(
      `${apiBaseUrl}/v1/comma/workspaces/wsp_plugins/plugins/linear/install`,
      async (route) => {
        calls += 1;
        const call = calls;
        if (call === 2) await oldResponse;
        if (call === 3) await newResponse;
        await route.fulfill({
          json: {
            authorization: call === 1 ? { state: "deadline-state" } : null,
            plugin: {
              ...plugin,
              installed: call === 2 || (freshAddBeforeExpiry && call === 3),
            },
          },
        });
        if (call === 2) oldResponded = true;
      }
    );
    await page.goto("/#/plugins");
    const add = page.getByRole("button", { name: "Add Linear" });
    await expect(add).toBeEnabled();
    const now = new Date();
    await page.clock.install({ time: now });
    await page.clock.pauseAt(now);
    await add.click();
    await expect.poll(() => calls).toBe(1);
    await expect(add).toBeEnabled();
    if (freshAddBeforeExpiry) {
      await page.clock.runFor(1_000);
      await add.click();
      await expect.poll(() => calls).toBe(2);
      await expect(add).toBeDisabled();
      await page.clock.runFor(29_000);
      await expect(add).toBeDisabled();
      expect(calls).toBe(2);
      await page.clock.runFor(2_000);
      await expect(add).toBeEnabled();
      await expect(
        page.getByText("The connection request timed out. Try adding the plugin again.")
      ).toBeVisible();
      await add.click();
      await expect.poll(() => calls).toBe(3);
      releaseOld();
      await expect.poll(() => oldResponded).toBe(true);
      await page.clock.runFor(50);
      await expect(add).toBeDisabled();
      await expect(page).toHaveURL(/#\/plugins$/);
      releaseNew();
      await expect(page).toHaveURL(/#\/$/);
      return;
    }
    await page.clock.runFor(2_000);
    await expect.poll(() => calls).toBe(2);
    await expect(add).toBeDisabled();
    await page.clock.runFor(118_000);
    await expect(add).toBeEnabled();
    await add.click();
    await expect.poll(() => calls).toBe(3);
    releaseOld();
    await expect.poll(() => oldResponded).toBe(true);
    await page.clock.runFor(50);
    await expect(add).toBeDisabled();
    releaseNew();
    await expect(add).toBeEnabled();
  });
}

test("plugin install waits for pending authorization and continues through each source", async ({
  page,
  unavailableProductApi,
}) => {
  const apiBaseUrl = unavailableProductApi;
  const installRequests: Array<Record<string, unknown>> = [];
  const googlePlugin = {
    brand: "google",
    category: "Integrations",
    description: "Search Gmail and Google Calendar",
    id: "google",
    installed: false,
    locked: false,
    mcps: [{ id: "google-mcp", name: "Google Workspace" }],
    name: "Google Workspace",
    skills: [],
    summary: "Search Gmail and Google Calendar",
  };

  await installBrowserTestSession(page, {
    apiBaseUrl,
    email: "plugin-multi-source@comma.local",
    token: "comma_sess_plugin_multi_source",
  });
  await page.addInitScript(() => {
    const openedUrls: string[] = [];
    Object.assign(window, { commaOpenedExternalUrls: openedUrls });
    window.open = ((url?: string | URL) => {
      if (url) openedUrls.push(String(url));
      return null;
    }) as typeof window.open;
  });
  await page.route(`${apiBaseUrl}/v1/comma/workspaces`, (route) =>
    route.fulfill({
      contentType: "application/json",
      json: {
        data: [
          {
            group_id: "grp_plugins",
            id: "wsp_plugins",
            name: "Plugins",
            status: "ready",
          },
        ],
      },
    })
  );
  await page.route(`${apiBaseUrl}/v1/comma/workspaces/wsp_plugins/plugins`, (route) =>
    route.fulfill({
      contentType: "application/json",
      json: { data: [googlePlugin] },
    })
  );
  await page.route(
    `${apiBaseUrl}/v1/comma/workspaces/wsp_plugins/plugins/google/install`,
    async (route) => {
      const body = route.request().postDataJSON() as Record<string, unknown>;
      installRequests.push(body);
      const authorizationState = body.authorization_state;
      const pending =
        authorizationState === "gmail-state" && installRequests.length === 2;
      const authorization = pending
        ? { state: "gmail-state" }
        : authorizationState === "gmail-state"
          ? {
              authorizationUrl:
                "https://accounts.google.com/calendar?state=calendar-state",
              state: "calendar-state",
            }
          : authorizationState === "calendar-state"
            ? null
            : {
                authorizationUrl: "https://accounts.google.com/gmail?state=gmail-state",
                state: "gmail-state",
              };

      await route.fulfill({
        contentType: "application/json",
        json: {
          authorization,
          plugin: {
            ...googlePlugin,
            installed: authorizationState === "calendar-state",
          },
        },
      });
    }
  );

  await page.goto("/#/plugins");
  await page.getByRole("button", { name: "Add Google Workspace" }).click();
  await expect.poll(() => installRequests).toEqual([{ contract: "unified_v1" }]);
  await expect
    .poll(() =>
      page.evaluate(
        () =>
          (window as typeof window & { commaOpenedExternalUrls?: string[] })
            .commaOpenedExternalUrls
      )
    )
    .toEqual(["https://accounts.google.com/gmail?state=gmail-state"]);

  await expect
    .poll(() =>
      page.evaluate(
        () =>
          (window as typeof window & { commaOpenedExternalUrls?: string[] })
            .commaOpenedExternalUrls
      )
    )
    .toEqual([
      "https://accounts.google.com/gmail?state=gmail-state",
      "https://accounts.google.com/calendar?state=calendar-state",
    ]);

  await page.evaluate(() => window.dispatchEvent(new Event("focus")));
  await expect(page).toHaveURL(/#\/$/);
  expect(installRequests).toEqual([
    { contract: "unified_v1" },
    {
      authorization_state: "gmail-state",
      contract: "unified_v1",
      verify_only: true,
    },
    {
      authorization_state: "gmail-state",
      contract: "unified_v1",
      verify_only: true,
    },
    {
      authorization_state: "calendar-state",
      contract: "unified_v1",
      verify_only: true,
    },
  ]);
});

test("app shell supports routed content and sidebar interactions", async ({
  page,
  unavailableProductApi,
}) => {
  test.setTimeout(90_000);
  await page.emulateMedia({ colorScheme: "light" });
  // Wide enough for every Home rail (incl. Tasks) to stay inline.
  await page.setViewportSize({ width: 1440, height: 900 });
  await installBrowserTestSession(page, {
    // Both page and shared host authenticate; product reads return 503.
    apiBaseUrl: unavailableProductApi,
    email: "e2e@example.com",
    token: "comma_sess_e2e",
  });
  await page.addInitScript(() => {
    localStorage.setItem(
      "comma.app.shortcuts",
      JSON.stringify({
        overrides: {
          "toggle-left-sidebar": {
            kind: "sequence",
            codes: ["KeyX", "KeyL"],
          },
        },
        version: 2,
      })
    );
  });
  await page.goto("/");

  await expect(page.getByRole("complementary", { name: "App sidebar" })).toBeVisible();
  await expect
    .poll(() =>
      page
        .locator(".comma-content")
        .evaluate((element) =>
          getComputedStyle(element).getPropertyValue("-webkit-app-region")
        )
    )
    .toBe("no-drag");
  // The window bar sits flush with the frame's top edge, so it — not a shell
  // margin above it — is what a drag at the top of the window grabs.
  await expect
    .poll(() =>
      page.locator(".comma-window-bar").evaluate((element) => {
        const rect = element.getBoundingClientRect();
        const shell = document.querySelector<HTMLElement>(".comma-app-shell")!;
        return {
          appRegion: getComputedStyle(element).getPropertyValue("-webkit-app-region"),
          shellAppRegion:
            getComputedStyle(shell).getPropertyValue("-webkit-app-region"),
          startsAtFrameTop:
            Math.abs(rect.top - shell.getBoundingClientRect().top) < 0.5,
        };
      })
    )
    .toEqual({ appRegion: "drag", shellAppRegion: "drag", startsAtFrameTop: true });
  // The window bar is the only window drag surface: the panel below it is
  // no-drag and paints no drag strip of its own.
  await expect
    .poll(() =>
      page.locator(".comma-content").evaluate((element) => ({
        appRegion: getComputedStyle(element).getPropertyValue("-webkit-app-region"),
        dragStrip: getComputedStyle(element, "::before").content,
      }))
    )
    .toEqual({ appRegion: "no-drag", dragStrip: "none" });
  // The window bar is the frame's drag surface. An empty point in its leading
  // flank resolves to the bar: Electron hands a point to the nearest ancestor
  // that declares a region, and the flanks declare none.
  await expect
    .poll(() =>
      page.getByTestId("comma-window-bar").evaluate((bar) => {
        const forwardRect = bar
          .querySelector<HTMLElement>('[aria-label="Forward"]')!
          .getBoundingClientRect();
        const barRect = bar.getBoundingClientRect();
        const topmost = document.elementFromPoint(
          forwardRect.right + 24,
          barRect.top + barRect.height / 2
        );
        let regionOwner: Element | null = topmost;
        while (
          regionOwner &&
          getComputedStyle(regionOwner).getPropertyValue("-webkit-app-region") ===
            "none"
        ) {
          regionOwner = regionOwner.parentElement;
        }
        return {
          appRegion: getComputedStyle(bar).getPropertyValue("-webkit-app-region"),
          regionOwnerIsBar: regionOwner === bar,
          topmostInsideBar: topmost !== null && bar.contains(topmost),
        };
      })
    )
    .toEqual({
      appRegion: "drag",
      regionOwnerIsBar: true,
      topmostInsideBar: true,
    });
  await expect(page.getByRole("complementary", { name: "Chat" })).toHaveCount(0);
  await expectActiveRailItem(page, "Home");
  await expect(page.getByTestId("home-responsive-layout")).toBeVisible();
  await expect(page.getByTestId("home-greet-rail")).toHaveCount(1);
  await expect(page.getByTestId("chat-empty")).toBeVisible();
  await expect(page.getByTestId("home-tasks-section")).toBeVisible();
  await expect(
    page.getByRole("heading", { name: "What do you want to do" })
  ).toHaveCount(0);
  await expect(page.getByRole("group", { name: "AI input" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Send" })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Voice input" })).toBeEnabled();

  await page.getByRole("link", { name: "Inbox" }).click();

  await expect(page).toHaveURL(/#\/inbox$/);
  // Web InboxView loads via the Comma API (unreachable here), so it renders its
  // error-state structure: sync-source badge plus the rail's filter control
  // (the create-conversation affordance lives inside that menu).
  await expect(page.getByTestId("inbox-source")).toBeVisible();
  await expect(page.getByTestId("inbox-filter-trigger")).toBeVisible();

  // Both filter levels open to the right of the rail so neither covers the
  // conversation list behind them. (At the minimum window width the options
  // panel has to flip back inward — that case is covered by its own test.)
  await page.getByTestId("inbox-filter-trigger").click();
  await page.getByRole("menuitem", { name: /Task status/ }).click();
  await expect(page.getByTestId("inbox-status-filter")).toBeVisible();
  expect(
    await page.evaluate(() => {
      const rail = document
        .querySelector('[data-testid="inbox-conversation-rail"]')!
        .getBoundingClientRect();
      const popovers = Array.from(
        document.querySelectorAll('[data-slot="menu-popover"]')
      ).map((element) => element.getBoundingClientRect());
      const [firstLevel, optionsPanel] = popovers;
      return {
        levels: popovers.length,
        // Flush against the menu's inner edge (it overlaps the popover padding,
        // the same way the Tasks filter's panels connect on the other side).
        optionsOpensRightward: optionsPanel!.left > firstLevel!.left,
        optionsClearsRail: optionsPanel!.left >= rail.right - 1,
        statusMenuClearsRail: firstLevel!.right > rail.right,
      };
    })
  ).toEqual({
    levels: 2,
    optionsClearsRail: true,
    optionsOpensRightward: true,
    statusMenuClearsRail: true,
  });
  // An outside press dismisses the whole menu, submenu included.
  await page.mouse.click(20, 400);
  await expect(page.getByTestId("inbox-status-filter")).toHaveCount(0);
  await expect(page.getByRole("menuitem", { name: /Task status/ })).toHaveCount(0);
  await expect(page.getByTestId("inbox-filter-trigger")).toHaveAttribute(
    "aria-expanded",
    "false"
  );

  // The rail header keeps its own 16px inset; the Chat Sidebar toggle lives in
  // the window bar, so no content header reserves room for it any more.
  expect(
    await page.evaluate(() => {
      const rail = document.querySelector('[data-testid="inbox-conversation-rail"]')!;
      const header = rail.querySelector("header")!;
      const trigger = rail.querySelector('[data-testid="inbox-filter-trigger"]')!;
      return Math.round(
        header.getBoundingClientRect().right - trigger.getBoundingClientRect().right
      );
    })
  ).toBe(16);
  await expect
    .poll(() =>
      page
        .getByTestId("inbox-conversation-rail")
        .locator("header")
        .evaluate((element) => ({
          appRegion: getComputedStyle(element).getPropertyValue("-webkit-app-region"),
          buttonAppRegion: getComputedStyle(
            element.querySelector("button")!
          ).getPropertyValue("-webkit-app-region"),
          dragRegion: getComputedStyle(element, "::before").getPropertyValue(
            "-webkit-app-region"
          ),
        }))
    )
    .toEqual({
      appRegion: "no-drag",
      buttonAppRegion: "no-drag",
      dragRegion: "drag",
    });
  await expectActiveRailItem(page, "Inbox");
  await expect(
    page.getByRole("link", { exact: true, name: "Home" })
  ).not.toHaveAttribute("aria-current", "page");
  await expect(page.locator(".comma-sidebar-edge-toggle")).toHaveAttribute(
    "type",
    "button"
  );

  await page.getByRole("link", { name: "Tasks" }).click();

  await expect(page).toHaveURL(/#\/tasks$/);
  await expect(page.getByTestId("tasks-route")).toBeVisible();
  await expect(page.getByText("All tasks")).toBeVisible();
  await expect(page.locator('[data-slot="task-board-column"]')).toHaveCount(0);

  await page.getByRole("button", { name: "Filter tasks" }).click();
  const filterMenu = page.getByRole("menu", { name: "Filter tasks" });
  await expect(filterMenu).toBeVisible();
  const tasksRouteBox = await page.getByTestId("tasks-route").boundingBox();
  expect(tasksRouteBox).not.toBeNull();
  await page.mouse.click(tasksRouteBox!.x + 400, tasksRouteBox!.y + 400);
  await expect(filterMenu).toBeHidden();

  await page.getByRole("button", { name: "Filter tasks" }).click();
  const statusFilter = filterMenu.getByRole("menuitem", { name: "Status" });
  await expect(filterMenu.getByRole("menuitem", { name: "Worker" })).toHaveCount(0);
  await statusFilter.click();
  const statusDialog = page.getByRole("dialog", { name: "Status" });
  await expect(statusDialog).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(statusDialog).toBeHidden();
  await expect(statusFilter).toBeFocused();
  await page.keyboard.press("Escape");
  await expect(filterMenu).toBeHidden();

  await page.getByRole("button", { name: "List view" }).click();
  await expect(page.getByRole("dialog", { name: "View" })).toBeVisible();
  await page.getByRole("menuitemradio", { name: "List" }).click();
  await expect(page.getByRole("dialog", { name: "View" })).toBeHidden();
  await expect(page.getByRole("button", { name: "Board view" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Error" })).toBeVisible();
  await expect(
    page.getByText("Task could not be refreshed. Try again in a moment.")
  ).toBeVisible();
  await expect(page.locator('[data-slot="task-list-item"]')).toHaveCount(0);

  const slot = page.getByTestId("comma-sidebar-slot");
  const content = page.locator(".comma-content");
  const windowFrame = page.locator(".comma-window-frame");
  const windowBar = page.getByTestId("comma-window-bar");
  const toggle = page.locator(".comma-sidebar-edge-toggle");
  const expandedContentBox = await content.boundingBox();
  const contentSurface = await content.evaluate((element) => {
    const style = getComputedStyle(element);
    const shadowProbe = document.createElement("span");
    shadowProbe.style.cssText =
      "position:fixed;visibility:hidden;box-shadow:inset 0 0 0 var(--border-width-0-5) var(--color-border-primary)";
    element.append(shadowProbe);
    const expectedOutline = getComputedStyle(shadowProbe).boxShadow;
    shadowProbe.style.boxShadow = "0 1px 2px 0 #1018280f,0 1px 3px 0 #1018281a";
    const expectedOuterShadow = getComputedStyle(shadowProbe).boxShadow;
    shadowProbe.remove();
    const overlayStyle = getComputedStyle(element, "::after");

    return {
      borderWidths: [
        style.borderTopWidth,
        style.borderRightWidth,
        style.borderBottomWidth,
        style.borderLeftWidth,
      ],
      outerShadow: style.boxShadow,
      overlay: {
        bottom: overlayStyle.bottom,
        boxShadow: overlayStyle.boxShadow,
        left: overlayStyle.left,
        pointerEvents: overlayStyle.pointerEvents,
        position: overlayStyle.position,
        right: overlayStyle.right,
        top: overlayStyle.top,
      },
      expectedOutline,
      expectedOuterShadow,
    };
  });
  expect(contentSurface.expectedOutline).not.toBe("none");
  expect(contentSurface.borderWidths).toEqual(["0px", "0px", "0px", "0px"]);
  expect(contentSurface.outerShadow).toBe(contentSurface.expectedOuterShadow);
  expect(contentSurface.overlay).toEqual({
    bottom: "0px",
    boxShadow: contentSurface.expectedOutline,
    left: "0px",
    pointerEvents: "none",
    position: "absolute",
    right: "0px",
    top: "0px",
  });
  const windowEdgeGeometry = await windowFrame.evaluate((element) => {
    const frameStyle = getComputedStyle(element);
    const contentStyle = getComputedStyle(element.querySelector(".comma-content")!);
    const sidebarStyle = getComputedStyle(element.querySelector(".comma-sidebar")!);
    const outerRadius = Number.parseFloat(
      frameStyle.getPropertyValue("--comma-window-corner-radius")
    );
    const windowInset = Number.parseFloat(
      frameStyle.getPropertyValue("--comma-window-inset")
    );
    return {
      contentRadius: Number.parseFloat(contentStyle.borderTopRightRadius),
      expectedInnerRadius: outerRadius - windowInset,
      frameOverflow: frameStyle.overflow,
      frameRadius: Number.parseFloat(frameStyle.borderTopLeftRadius),
      sidebarRadii: [
        sidebarStyle.borderTopLeftRadius,
        sidebarStyle.borderTopRightRadius,
        sidebarStyle.borderBottomRightRadius,
        sidebarStyle.borderBottomLeftRadius,
      ].map(Number.parseFloat),
    };
  });
  expect(windowEdgeGeometry).toEqual({
    // The frame is flush with the window, so the panel's corners are the
    // window's own 12px corners.
    contentRadius: 12,
    expectedInnerRadius: 12,
    frameOverflow: "visible",
    frameRadius: 12,
    // The rail is flush inside the frame; the window's corner is the frame's.
    sidebarRadii: [0, 0, 0, 0],
  });
  // Figma 1384:23287: a 42px window bar spans the window's full width from its
  // top edge, with equal flanks around the 400px search hint; the 75px icon
  // rail and the content panel share the row below it.
  const shellGeometry = await windowBar.evaluate((bar) => {
    const frameRect = bar
      .closest<HTMLElement>(".comma-window-frame")!
      .getBoundingClientRect();
    const barRect = bar.getBoundingClientRect();
    const backRect = bar
      .querySelector<HTMLElement>('button[aria-label="Back"]')!
      .getBoundingClientRect();
    const leadingRect = bar
      .querySelector<HTMLElement>(".comma-window-bar-leading")!
      .getBoundingClientRect();
    const trailingRect = bar
      .querySelector<HTMLElement>(".comma-window-bar-trailing")!
      .getBoundingClientRect();
    const searchRect = bar
      .querySelector<HTMLElement>('[data-testid="comma-window-bar-search"]')!
      .getBoundingClientRect();
    const [trailingFirst, trailingLast] = [
      ...bar.querySelectorAll<HTMLElement>(".comma-window-bar-trailing button"),
    ].map((control) => control.getBoundingClientRect());
    const slotRect = document
      .querySelector<HTMLElement>('[data-testid="comma-sidebar-slot"]')!
      .getBoundingClientRect();
    const railRect = document
      .querySelector<HTMLElement>('[data-testid="comma-sidebar"]')!
      .getBoundingClientRect();
    const contentRect = document
      .querySelector<HTMLElement>(".comma-content")!
      .getBoundingClientRect();
    return {
      barHeight: barRect.height,
      barSpansFrame:
        barRect.left === frameRect.left && barRect.right === frameRect.right,
      barTop: barRect.top,
      contentStartsAtRail: contentRect.left === railRect.right,
      flanksEqual: leadingRect.width === trailingRect.width,
      // The web shell has no traffic lights: history leads the row at the
      // same inset the trailing controls keep from the right edge.
      historyInsets: {
        leading: backRect.left - barRect.left,
        trailing: barRect.right - trailingLast!.right,
      },
      railWidth: railRect.width,
      rowBelowBar:
        slotRect.top === barRect.bottom && contentRect.top === barRect.bottom,
      searchWidth: searchRect.width,
      slotWidth: slotRect.width,
      // History and the Chat Sidebar toggle sit as close as the icon pairs in
      // a panel header do, so the shell's icon spacing reads as one system.
      trailingGap: trailingLast!.left - trailingFirst!.right,
    };
  });
  expect(shellGeometry).toEqual({
    barHeight: 42,
    barSpansFrame: true,
    barTop: 0,
    contentStartsAtRail: true,
    flanksEqual: true,
    historyInsets: { leading: 12, trailing: 12 },
    railWidth: 75,
    rowBelowBar: true,
    searchWidth: 400,
    slotWidth: 75,
    trailingGap: 4,
  });
  await expectActiveRailItem(page, "Tasks");
  // The rail slides between its rests rather than jumping: frames during the
  // collapse paint widths between the open rail and the collapsed gutter.
  const collapseWidths = sampleFrameWidths(slot);
  await toggle.click();
  expect((await collapseWidths).some((width) => width > 9 && width < 74)).toBe(true);

  await expect(slot).toHaveAttribute("data-collapsed", "true");
  await expect(content).toHaveAttribute("data-sidebar-collapsed", "true");
  await expect(toggle).toHaveAttribute("aria-expanded", "false");
  await expect.poll(async () => (await slot.boundingBox())?.width ?? -1).toBe(8);
  // The rail keeps its width and slides under the panel. Collapsed, the slot
  // still holds the window's own gutter, so the panel starts one gutter in and
  // runs to the frame's right edge; the rail's border toggle rides the gutter.
  await expect
    .poll(() =>
      slot.evaluate((element) => {
        const frameRect = document
          .querySelector<HTMLElement>(".comma-window-frame")!
          .getBoundingClientRect();
        const contentElement = document.querySelector<HTMLElement>(".comma-content")!;
        const contentRect = contentElement.getBoundingClientRect();
        const railRect = element
          .querySelector<HTMLElement>(".comma-sidebar")!
          .getBoundingClientRect();
        const bodyStyle = getComputedStyle(
          element.querySelector<HTMLElement>(".comma-sidebar-body")!
        );
        return {
          contentKeepsGutter:
            contentRect.left - frameRect.left === 8 &&
            contentRect.right === frameRect.right,
          railBodyHidden:
            bodyStyle.visibility === "hidden" && bodyStyle.pointerEvents === "none",
          railWidth: railRect.width,
          slotKeepsHeight:
            element.getBoundingClientRect().height === contentRect.height,
        };
      })
    )
    .toEqual({
      contentKeepsGutter: true,
      railBodyHidden: true,
      railWidth: 75,
      slotKeepsHeight: true,
    });
  await expect
    .poll(() =>
      toggle.evaluate((element) => {
        const rect = element.getBoundingClientRect();
        return document
          .elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2)
          ?.closest("button")
          ?.getAttribute("aria-label");
      })
    )
    .toBe("Expand sidebar");

  // Expanding slides the slot open rather than snapping.
  const expandWidths = sampleFrameWidths(slot);
  await toggle.click();
  await expect(slot).toHaveAttribute("data-collapsed", "false");
  expect((await expandWidths).some((width) => width > 9 && width < 74)).toBe(true);
  await expect.poll(async () => (await slot.boundingBox())?.width ?? 0).toBe(75);
  await expect(toggle).toHaveAttribute("aria-expanded", "true");
  await expect(content).toHaveAttribute("data-sidebar-collapsed", "false");
  expect(await content.boundingBox()).toEqual(expandedContentBox);

  await toggle.click();
  await expect(slot).toHaveAttribute("data-collapsed", "true");
  await expect.poll(async () => (await slot.boundingBox())?.width ?? 0).toBe(8);
  const collapsedContentBox = await content.boundingBox();
  expect(collapsedContentBox?.x ?? 0).toBeLessThan(expandedContentBox?.x ?? 0);
  // Collapsing frees the rail's width less the window gutter the slot keeps.
  expect((collapsedContentBox?.width ?? 0) - (expandedContentBox?.width ?? 0)).toBe(67);

  await toggle.click();
  await expect(slot).toHaveAttribute("data-collapsed", "false");
  await expect.poll(async () => (await slot.boundingBox())?.width ?? 0).toBe(75);
});

test("the rail's border collapses it and its hint rides the pointer", async ({
  page,
}) => {
  await installBrowserTestSession(page, {
    apiBaseUrl: "http://127.0.0.1:65535",
    email: "rail-edge@comma.local",
    token: "comma_sess_rail_edge",
  });
  await page.goto("/#/inbox");
  await expect(page.getByRole("complementary", { name: "App sidebar" })).toBeVisible();

  const slot = page.getByTestId("comma-sidebar-slot");
  const edge = page.locator(".comma-sidebar-edge-toggle");
  await expect(edge).toHaveAttribute("aria-label", "Collapse sidebar");
  await expect(edge).toHaveCSS("cursor", "col-resize");
  const edgeBox = (await edge.boundingBox())!;
  const edgeX = edgeBox.x + edgeBox.width / 2;

  await page.mouse.move(edgeX, 200);
  // The border paints its hairline under the pointer and, after the hover
  // settles, raises the hint beside the cursor rather than at the strip's own
  // centre — the strip runs the whole height of the window.
  await expect
    .poll(() =>
      edge.evaluate((element) => getComputedStyle(element, "::after").opacity)
    )
    .toBe("1");
  const hint = page.getByTestId("comma-sidebar-edge-tooltip");
  await expect(hint).toBeVisible();
  await expect(hint.getByText("Collapse sidebar", { exact: true })).toBeVisible();
  const primaryShortcutLabel = await page.evaluate(() => {
    const platform = `${navigator.platform} ${navigator.userAgent}`.toLowerCase();
    return /mac|iphone|ipad/.test(platform) ? "⌘" : "Ctrl";
  });
  await expect(hint.locator('[data-slot="tooltip-shortcut"] kbd')).toHaveText([
    primaryShortcutLabel,
    "B",
  ]);
  const readHintCentre = async () => {
    const box = (await hint.boundingBox())!;
    // The bubble is shifted half its height up, so the box's own top is the
    // pointer line it tracks.
    return { x: Math.round(box.x), y: Math.round(box.y) };
  };
  expect(await readHintCentre()).toEqual({ x: Math.round(edgeX) + 14, y: 200 });

  await page.mouse.move(edgeX, 480);
  await expect.poll(readHintCentre).toEqual({ x: Math.round(edgeX) + 14, y: 480 });

  await page.mouse.click(edgeX, 480);
  await expect(slot).toHaveAttribute("data-collapsed", "true");
  await expect(hint).toHaveCount(0);
  await expect(edge).toHaveAttribute("aria-label", "Expand sidebar");
});

test("global chat sidebar animates, resizes, and keeps themed shell hover tokens", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    assistantAttachments: [
      {
        fileName: "report.pdf",
        mimeType: "application/pdf",
        size: 2_048,
        type: "file",
      },
      {
        fileName: "diagram.png",
        mimeType: "image/png",
        path: "/uploads/AAAAAAAAAAAAAAAAAAAAAA-diagram.png",
        size: 4_096,
        type: "image",
      },
    ],
    followupAssistantReply: "这是没有新用户消息时的后续回复。",
  });

  try {
    await page.setViewportSize({ width: 1280, height: 800 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "chat-sidebar-motion@comma.local",
      token: "comma_sess_chat_sidebar_motion",
    });
    await page.addInitScript(() => {
      localStorage.setItem(
        "comma.app.shortcuts",
        JSON.stringify({
          overrides: {
            "toggle-right-sidebar": {
              kind: "sequence",
              codes: ["KeyX", "KeyR"],
            },
          },
          version: 2,
        })
      );
    });
    await page.goto("/");

    const content = page.getByRole("region", { name: "Content" });
    const composer = page
      .getByTestId("comma-route-outlet")
      .locator(".comma-chat-composer");
    const prompt = composer.getByRole("textbox", { name: "AI prompt" });
    const attachButton = composer.getByRole("button", { name: "Add attachment" });
    const addFilesTooltip = page
      .locator(".comma-tooltip")
      .filter({ hasText: "Add files and more" });

    await page.mouse.move(1, 1);
    await attachButton.hover();
    await expect(addFilesTooltip).toBeVisible();
    const canceledChooserPromise = page.waitForEvent("filechooser");
    await attachButton.click();
    const canceledChooser = await canceledChooserPromise;
    const attachButtonBox = await attachButton.boundingBox();
    expect(attachButtonBox).not.toBeNull();
    await page.mouse.move(1, 1);
    await page.mouse.move(
      attachButtonBox!.x + attachButtonBox!.width / 2,
      attachButtonBox!.y + attachButtonBox!.height / 2
    );
    await canceledChooser.setFiles([]);
    await page.waitForTimeout(500);
    await expect(addFilesTooltip).toHaveCount(0);

    await page.mouse.move(1, 1);
    await attachButton.hover();
    await expect(addFilesTooltip).toBeVisible();
    const outsideCanceledChooserPromise = page.waitForEvent("filechooser");
    await attachButton.click();
    const outsideCanceledChooser = await outsideCanceledChooserPromise;
    await page.mouse.move(1, 1);
    await outsideCanceledChooser.setFiles([]);
    await page.waitForTimeout(500);
    await expect(addFilesTooltip).toHaveCount(0);
    await attachButton.hover();
    await expect(addFilesTooltip).toBeVisible();

    const selectedChooserPromise = page.waitForEvent("filechooser");
    await attachButton.click();
    const selectedChooser = await selectedChooserPromise;
    await page.mouse.move(1, 1);
    await attachButton.hover();
    await selectedChooser.setFiles({
      name: "tooltip-regression.txt",
      mimeType: "text/plain",
      buffer: Buffer.from("tooltip regression"),
    });
    const draftFileName = composer.getByText("tooltip-regression.txt", {
      exact: true,
    });
    await expect(draftFileName).toBeVisible();
    const draftFileAttachment = composer.locator('[data-slot="file-attachment"]');
    await expect
      .poll(() =>
        draftFileAttachment.evaluate((element) => {
          const icon = element.querySelector<HTMLElement>(
            '[data-slot="file-icon-surface"]'
          );
          const probe = document.createElement("span");
          element.append(probe);
          probe.style.background = "var(--color-bg-popup-primary)";
          const expectedOuter = getComputedStyle(probe).backgroundColor;
          probe.style.background = "var(--color-panel-bg-file)";
          const expectedIcon = getComputedStyle(probe).backgroundColor;
          const result = {
            icon: icon
              ? getComputedStyle(icon).backgroundColor === expectedIcon
              : false,
            outer: getComputedStyle(element).backgroundColor === expectedOuter,
          };
          probe.remove();
          return result;
        })
      )
      .toEqual({ icon: true, outer: true });
    await page.waitForTimeout(500);
    await expect(addFilesTooltip).toHaveCount(0);

    await prompt.fill("Comma Center sidebar motion");
    const sendButton = composer.getByRole("button", { name: "Send" });
    await expect(sendButton).toBeEnabled();
    await sendButton.click();

    const taskReference = content.getByTestId(
      `chat-ref-card-${chatSmokeTaskConversation.id}`
    );
    await expect(taskReference).toBeVisible();
    const chatColumn = content.locator(".comma-chat-column");
    const readMessageSpacing = () =>
      chatColumn.evaluate((column) => {
        const user = column.querySelector<HTMLElement>(
          '[data-message-id="msg-user-smoke"]'
        );
        const firstAgent = column.querySelector<HTMLElement>(
          '[data-message-id="msg-assistant-smoke"]'
        );
        const nextAgent = column.querySelector<HTMLElement>(
          '[data-message-id="msg-assistant-followup-smoke"]'
        );
        const turn = user?.closest<HTMLElement>(".comma-chat-turn");
        if (!user || !firstAgent || !nextAgent || !turn) {
          throw new Error("Missing consecutive chat messages");
        }
        const style = getComputedStyle(column);
        return {
          agentGap: Math.round(
            nextAgent.getBoundingClientRect().top -
              firstAgent.getBoundingClientRect().bottom
          ),
          agentGapToken: Number.parseFloat(
            style.getPropertyValue("--comma-chat-consecutive-message-gap")
          ),
          turnRowGapToken: Number.parseFloat(
            getComputedStyle(turn).getPropertyValue("--comma-chat-turn-row-gap")
          ),
          userToAgentGap: Math.round(
            firstAgent.getBoundingClientRect().top - user.getBoundingClientRect().bottom
          ),
        };
      });
    await expect.poll(readMessageSpacing).toEqual({
      agentGap: 6,
      agentGapToken: 6,
      turnRowGapToken: 8,
      userToAgentGap: 8,
    });
    await chatColumn.evaluate((column) => {
      (column as HTMLElement).style.setProperty(
        "--comma-chat-consecutive-message-gap",
        "13px"
      );
    });
    await expect.poll(async () => (await readMessageSpacing()).agentGap).toBe(13);
    await chatColumn.evaluate((column) => {
      (column as HTMLElement).style.removeProperty(
        "--comma-chat-consecutive-message-gap"
      );
    });
    await expect.poll(async () => (await readMessageSpacing()).agentGap).toBe(6);

    const chatViewport = content.locator(".comma-chat-scroll-viewport");
    await chatViewport.focus();
    await chatViewport.press("Home");
    const userMessage = content.locator('[data-message-id="msg-user-smoke"]');
    const userActions = content.getByTestId("chat-message-actions-msg-user-smoke");
    const userCopyButton = userActions.locator(".comma-chat-message-action-button");
    await expect(userMessage).toBeVisible();
    await userMessage.hover();
    await expect(userCopyButton).toBeVisible();
    await expect(userCopyButton).toHaveAccessibleName("Copy message");
    await expect(userCopyButton).not.toHaveAttribute("title");
    await expect(userActions).toHaveCSS("opacity", "1");
    await expect
      .poll(() =>
        userMessage.evaluate((article) => {
          const bubble = article.querySelector<HTMLElement>(".comma-chat-user-bubble");
          const button = article.querySelector<HTMLElement>(
            ".comma-chat-message-action-button"
          );
          if (!bubble || !button) return null;
          const bubbleRect = bubble.getBoundingClientRect();
          const buttonRect = button.getBoundingClientRect();
          return {
            besideBubble:
              buttonRect.right <= bubbleRect.left && buttonRect.top < bubbleRect.bottom,
            buttonHeight: Math.round(buttonRect.height),
            buttonWidth: Math.round(buttonRect.width),
            insideBubble: bubble.contains(button),
          };
        })
      )
      .toEqual({
        besideBubble: true,
        buttonHeight: 20,
        buttonWidth: 20,
        insideBubble: false,
      });
    await userCopyButton.hover();
    const userCopyTooltip = page
      .locator(".comma-tooltip")
      .filter({ hasText: /^Copy$/ });
    await expect(userCopyTooltip).toBeVisible();
    await expect(userCopyTooltip).toHaveAttribute("data-side", "bottom");
    await expect
      .poll(async () => {
        const [buttonBox, tooltipBox] = await Promise.all([
          userCopyButton.boundingBox(),
          userCopyTooltip.boundingBox(),
        ]);
        if (!buttonBox || !tooltipBox) return false;
        return tooltipBox.y >= buttonBox.y + buttonBox.height;
      })
      .toBe(true);

    await page.context().grantPermissions(["clipboard-write"], {
      origin: new URL(page.url()).origin,
    });
    const userCopyStateIcon = userCopyButton.locator(".t-icon-swap");
    await expect(userCopyStateIcon).toHaveAttribute("data-state", "a");
    await expect(userCopyStateIcon).toHaveAttribute("data-swap-blur", "none");
    await expect
      .poll(() =>
        userCopyStateIcon
          .locator(".t-icon")
          .first()
          .evaluate((icon) => {
            const styles = getComputedStyle(icon);
            return {
              filter: styles.filter,
              transitionProperty: styles.transitionProperty,
            };
          })
      )
      .toEqual({
        filter: "none",
        transitionProperty: "opacity, transform",
      });
    const userCopyButtonBox = await userCopyButton.boundingBox();
    expect(userCopyButtonBox).not.toBeNull();
    await page.mouse.click(
      userCopyButtonBox!.x - 3,
      userCopyButtonBox!.y + userCopyButtonBox!.height / 2
    );
    await expect(userCopyButton).toHaveAccessibleName("Copied");
    await expect(userCopyStateIcon).toHaveAttribute("data-state", "b");
    const userCopiedIconLayer = userCopyStateIcon.locator('[data-icon="b"]');
    const userCopiedIcon = userCopiedIconLayer.locator("svg");
    await expect(userCopiedIcon).toHaveClass(/text-fg-success-primary/);
    await expect
      .poll(() =>
        userCopiedIconLayer.evaluate((iconLayer) => {
          const styles = getComputedStyle(iconLayer);
          const baseSize = Number.parseFloat(styles.inlineSize);
          const scale = Number.parseFloat(styles.scale);
          return {
            baseSize,
            renderedSize: Math.round(baseSize * scale * 10) / 10,
            scale,
          };
        })
      )
      .toEqual({ baseSize: 16, renderedSize: 18.4, scale: 1.15 });
    await expect(userCopyStateIcon).toHaveAttribute("data-state", "a", {
      timeout: 3_000,
    });

    const assistantMessage = content.locator('[data-message-id="msg-assistant-smoke"]');
    const fileAttachment = assistantMessage
      .locator(".chat-panel-file")
      .filter({ hasText: "report.pdf" });
    // An agent's image keeps its own ratio instead of a cropped group card.
    const inlineImage = assistantMessage.locator(".comma-chat-inline-image");
    const imageAttachment = inlineImage.getByRole("img", {
      name: "diagram.png",
    });
    await expect(inlineImage).toHaveCount(1);
    await expect(inlineImage.locator(".chat-panel-image-group-card")).toHaveCount(0);
    await expect(imageAttachment).toBeVisible();
    await expect(inlineImage.locator('[data-slot="file-icon-surface"]')).toHaveCount(0);
    await expect(fileAttachment).toBeVisible();
    await expect(fileAttachment).toContainText("PDF · 2KB");
    await expect(
      fileAttachment.getByRole("button", { name: "Download", exact: true })
    ).toHaveCount(0);
    await expect(fileAttachment.locator('[data-slot="file-icon-surface"]')).toHaveCount(
      0
    );
    await expect
      .poll(() =>
        fileAttachment.evaluate((element) => {
          const probe = document.createElement("span");
          element.append(probe);
          probe.style.background = "var(--color-bg-popup-secondary)";
          const expectedOuter = getComputedStyle(probe).backgroundColor;
          const result = {
            outer: getComputedStyle(element).backgroundColor === expectedOuter,
          };
          probe.remove();
          return result;
        })
      )
      .toEqual({ outer: true });
    await taskReference.click();

    const sidebar = content.getByTestId("chat-sidebar");
    const toggle = page
      .getByTestId("comma-window-bar")
      .getByRole("button", { name: "Toggle chat sidebar" });
    const resizeHandle = sidebar.getByRole("separator", {
      name: "Resize chat sidebar",
    });
    await expect(sidebar).toHaveAttribute("data-open", "true");
    await expect(toggle).toHaveAttribute("aria-expanded", "true");
    await page.mouse.move(1, 1);
    await toggle.hover();
    const toggleTooltip = page.getByRole("tooltip", {
      name: /Toggle chat sidebar/,
    });
    await expect(toggleTooltip).toBeVisible();
    const shortcut = toggleTooltip.locator('[data-slot="tooltip-shortcut"]');
    await expect(shortcut).toHaveAttribute("aria-label", "Keyboard shortcut: X R");
    await expect(shortcut.locator("kbd")).toHaveText(["X", "R"]);
    await expect.poll(async () => (await sidebar.boundingBox())?.width ?? 0).toBe(440);
    await page.keyboard.press("KeyX");
    await page.keyboard.press("KeyR");
    await expect(sidebar).toHaveAttribute("data-open", "false");
    await expect.poll(async () => (await sidebar.boundingBox())?.width ?? -1).toBe(0);
    await page.keyboard.press("KeyX");
    await page.keyboard.press("KeyR");
    await expect(sidebar).toHaveAttribute("data-open", "true");
    await expect.poll(async () => (await sidebar.boundingBox())?.width ?? 0).toBe(440);
    // The toggle is the window bar's last control: 8px under the bar's top
    // edge, 12px in from the frame's right edge, above the content panel.
    const windowBarBox = await page.getByTestId("comma-window-bar").boundingBox();
    const contentBox = await content.boundingBox();
    const openToggleBox = await toggle.boundingBox();
    expect(windowBarBox).not.toBeNull();
    expect(contentBox).not.toBeNull();
    expect(openToggleBox).not.toBeNull();
    expect(openToggleBox!.y - windowBarBox!.y).toBe(8);
    expect(windowBarBox!.x + windowBarBox!.width - openToggleBox!.x - 28).toBe(12);
    expect(openToggleBox!.y + openToggleBox!.height).toBeLessThanOrEqual(contentBox!.y);

    const themedHoverColors: Array<{ background: string; foreground: string }> = [];
    for (const { preference, resolvedTheme } of [
      { preference: "light", resolvedTheme: "Light mode" },
      { preference: "dark", resolvedTheme: "Dark mode" },
      { preference: "signal-dark", resolvedTheme: "Dark mode" },
    ] as const) {
      await page.mouse.move(0, 0);
      await page.evaluate((theme) => {
        const key = "comma.client-settings";
        const oldValue = localStorage.getItem(key);
        const current = JSON.parse(oldValue ?? "{}");
        const newValue = JSON.stringify({
          ...current,
          appearance: { ...current.appearance, theme },
        });
        localStorage.setItem(key, newValue);
        window.dispatchEvent(
          new StorageEvent("storage", {
            key,
            newValue,
            oldValue,
            url: window.location.href,
          })
        );
      }, preference);
      await expect(page.locator("html")).toHaveAttribute("data-theme", resolvedTheme);
      if (preference === "signal-dark") {
        await expect(page.locator("html")).toHaveAttribute(
          "data-comma-theme",
          "signal-dark"
        );
        const signalAxes = await page.evaluate(() => {
          const style = getComputedStyle(document.documentElement);
          return {
            hue: Number.parseFloat(style.getPropertyValue("--comma-theme-h")),
            chroma: Number.parseFloat(style.getPropertyValue("--comma-theme-c")),
          };
        });
        expect(signalAxes.hue).toBeGreaterThan(commaBlueOklchHueDeg - 2);
        expect(signalAxes.hue).toBeLessThan(commaBlueOklchHueDeg + 2);
        expect(signalAxes.chroma).toBeGreaterThan(0.06);
      }
      await toggle.hover();

      await expect
        .poll(() =>
          toggle.evaluate((element) => {
            const style = getComputedStyle(element);
            const probe = document.createElement("span");
            probe.style.backgroundColor = "var(--color-sidebar-bg-item)";
            probe.style.color = "var(--color-sidebar-icon-primary)";
            element.append(probe);
            const expected = getComputedStyle(probe);
            const result = {
              backgroundMatches: style.backgroundColor === expected.backgroundColor,
              foregroundMatches: style.color === expected.color,
              hoverBackgroundTokenMatches:
                style.getPropertyValue("--comma-button-hover-bg").trim() ===
                style.getPropertyValue("--color-sidebar-bg-item").trim(),
              hoverForegroundTokenMatches:
                style.getPropertyValue("--comma-button-hover-fg").trim() ===
                style.getPropertyValue("--color-sidebar-icon-primary").trim(),
            };
            probe.remove();
            return result;
          })
        )
        .toEqual({
          backgroundMatches: true,
          foregroundMatches: true,
          hoverBackgroundTokenMatches: true,
          hoverForegroundTokenMatches: true,
        });
      themedHoverColors.push(
        await toggle.evaluate((element) => {
          const style = getComputedStyle(element);
          return { background: style.backgroundColor, foreground: style.color };
        })
      );
    }
    expect(themedHoverColors[0]).not.toEqual(themedHoverColors[1]);

    await resizeHandle.hover();
    const resizeTooltip = page.getByTestId("comma-chat-sidebar-resize-tooltip");
    await expect(resizeTooltip).toBeVisible();
    await expect(
      resizeTooltip.getByText("Drag to resize", { exact: true })
    ).toBeVisible();
    await expect
      .poll(() =>
        resizeHandle.evaluate((element) => getComputedStyle(element, "::after").opacity)
      )
      .toBe("1");
    const activeResizeEdge = await resizeHandle.evaluate((element) => {
      const style = getComputedStyle(element);
      const edgeStyle = getComputedStyle(element, "::after");
      const probe = document.createElement("span");
      probe.style.backgroundImage =
        "linear-gradient(to bottom, transparent 10%, var(--color-fg-quinary-hover) 50%, transparent 90%)";
      element.append(probe);
      const expectedBackgroundImage = getComputedStyle(probe).backgroundImage;
      const result = {
        opacity: edgeStyle.opacity,
        usesActiveToken:
          style.getPropertyValue("--color-fg-quinary-hover").trim() !== "" &&
          edgeStyle.backgroundImage === expectedBackgroundImage,
        width: edgeStyle.width,
      };
      probe.remove();
      return result;
    });
    expect.soft(activeResizeEdge.opacity).toBe("1");
    expect.soft(activeResizeEdge.usesActiveToken).toBe(true);
    expect.soft(activeResizeEdge.width).toBe("1px");

    await page.keyboard.press("KeyX");
    await page.keyboard.press("KeyR");
    await expect(sidebar).toHaveAttribute("data-open", "false");
    await expect(resizeTooltip).toHaveCount(0);
    await page.waitForTimeout(350);
    await expect(resizeTooltip).toHaveCount(0);
    await expect.poll(async () => (await sidebar.boundingBox())?.width ?? -1).toBe(0);
    await page.keyboard.press("KeyX");
    await page.keyboard.press("KeyR");
    await expect(sidebar).toHaveAttribute("data-open", "true");
    await expect.poll(async () => (await sidebar.boundingBox())?.width ?? 0).toBe(440);

    const handleBox = await resizeHandle.boundingBox();
    expect(handleBox).not.toBeNull();
    await page.mouse.move(
      handleBox!.x + handleBox!.width / 2,
      handleBox!.y + handleBox!.height / 2
    );
    await page.mouse.down();
    await page.mouse.move(
      handleBox!.x + handleBox!.width / 2 - 80,
      handleBox!.y + handleBox!.height / 2
    );
    await page.mouse.up();
    // Releasing keeps exactly what the pointer left — Home's rails are
    // responsive columns and every unfolded width is a legal resting shape,
    // so nothing snaps.
    await expect.poll(async () => (await sidebar.boundingBox())?.width ?? 0).toBe(520);
    await expect(page.locator(".comma-chat-sidebar-resize-cursor-overlay")).toHaveCount(
      0
    );

    const closeTransition = armAndPauseTransition(sidebar, "width", 75);
    await closeTransition.armed;
    await Promise.all([closeTransition.captured, toggle.click()]);
    const closingWidth = (await sidebar.boundingBox())?.width ?? 0;
    expect(closingWidth).toBeGreaterThan(0);
    expect(closingWidth).toBeLessThan(520);
    await sidebar.evaluate((element) =>
      element.getAnimations().forEach((animation) => animation.finish())
    );
    await expect.poll(async () => (await sidebar.boundingBox())?.width ?? -1).toBe(0);
    await expect(toggle).toHaveAttribute("aria-expanded", "false");
    expect((await toggle.boundingBox())?.x).toBe(openToggleBox!.x);

    const openTransition = armAndPauseTransition(sidebar, "width", 75);
    await openTransition.armed;
    await Promise.all([openTransition.captured, toggle.click()]);
    const openingWidth = (await sidebar.boundingBox())?.width ?? 0;
    expect(openingWidth).toBeGreaterThan(0);
    expect(openingWidth).toBeLessThan(520);
    await sidebar.evaluate((element) =>
      element.getAnimations().forEach((animation) => animation.finish())
    );
    await expect.poll(async () => (await sidebar.boundingBox())?.width ?? 0).toBe(520);
    await expect(toggle).toHaveAttribute("aria-expanded", "true");

    await resizeHandle.dblclick();
    await expect.poll(async () => (await sidebar.boundingBox())?.width ?? 0).toBe(440);
    // The minimum window keeps the icon rail; the Chat Sidebar yields to the
    // route's minimum instead.
    // With the Chat Sidebar open, 500px holds neither the rail nor Home's
    // minimum beside it: the rail yields its column, keeping the 8px gutter.
    await page.setViewportSize({ width: 500, height: 800 });
    await expect(page.getByTestId("comma-sidebar-slot")).toHaveAttribute(
      "data-collapsed",
      "true"
    );
    await expect
      .poll(
        async () => (await page.getByTestId("comma-sidebar-slot").boundingBox())?.width
      )
      .toBe(8);
    await expect(sidebar).toHaveAttribute("data-open", "true");
    await expect
      .poll(() =>
        content.evaluate((element) => {
          const contentRect = element.getBoundingClientRect();
          const routeRect = element
            .querySelector<HTMLElement>(".comma-route-outlet")!
            .getBoundingClientRect();
          const sidebarRect = element
            .querySelector<HTMLElement>(".comma-chat-sidebar")!
            .getBoundingClientRect();
          const promptElement = element.querySelector<HTMLElement>(
            '[role="textbox"][aria-label="AI prompt"]'
          )!;
          const promptRect = promptElement.getBoundingClientRect();
          const centerTarget = document.elementFromPoint(
            promptRect.left + promptRect.width / 2,
            promptRect.top + promptRect.height / 2
          );

          return {
            primaryMinimumPreserved: routeRect.width >= 240,
            promptCenterIsHittable:
              centerTarget === promptElement || promptElement.contains(centerTarget),
            promptHasWidth: promptRect.width > 0,
            railYieldsToPrimary: sidebarRect.width <= contentRect.width - 240 + 0.5,
          };
        })
      )
      .toEqual({
        primaryMinimumPreserved: true,
        promptCenterIsHittable: true,
        promptHasWidth: true,
        railYieldsToPrimary: true,
      });
    await prompt.click();
    await expect(prompt).toBeFocused();

    await page.setViewportSize({ width: 1280, height: 800 });
    await page.getByRole("link", { name: "Inbox", exact: true }).click();
    await expect(page).toHaveURL(/#\/inbox$/);
    const globalToggle = page
      .getByTestId("comma-window-bar")
      .getByRole("button", { name: "Toggle chat sidebar" });
    await expect(globalToggle).toBeVisible();
    await expect(globalToggle).toHaveAttribute("aria-expanded", "false");
    await globalToggle.click();
    await expect(sidebar).toHaveAttribute("data-open", "true");
    await expect(sidebar.getByRole("tab", { name: "New tab" })).toBeVisible();
    await expect(sidebar.getByRole("textbox", { name: "Address" })).toBeVisible();
  } finally {
    await stub.close();
  }
});

test("chat sidebar tabs share the strip, scroll past their minimum, and hold widths for repeated closes", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    assistantReply: "[Open docs](https://docs.alpha-long-hostname.example.com/)",
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "sidebar-tabs@comma.local",
      token: "comma_sess_sidebar_tabs",
    });
    await page.setViewportSize({ width: 1280, height: 800 });
    await page.goto("/");
    const main = page.locator('.comma-chat-route[data-variant="home"]');
    await main.getByRole("textbox", { name: "AI prompt" }).fill("Docs please");
    await main.getByRole("button", { name: "Send", exact: true }).click();
    await main.getByRole("link", { name: "Open docs" }).click();
    const sidebar = page.getByTestId("chat-sidebar");
    const tablist = sidebar.getByRole("tablist");
    const address = sidebar.getByRole("textbox", { name: "Address" });
    const newTab = sidebar.getByRole("button", { name: "New tab", exact: true });
    const tabWidths = () =>
      tablist
        .locator("[data-tab-item]")
        .evaluateAll((items) =>
          items.map((item) => Math.round(item.getBoundingClientRect().width))
        );
    for (const host of [
      "beta-release-notes.example.org",
      "gamma-long-hostname.example.net",
      "delta-dashboard.internal.example.com",
    ]) {
      await newTab.click();
      await address.fill(`https://${host}/`);
      await address.press("Enter");
      await expect(sidebar.getByRole("tab", { name: host })).toHaveAttribute(
        "aria-selected",
        "true"
      );
    }

    // Long titles narrow evenly to share the strip instead of scrolling.
    await expect
      .poll(async () => {
        const widths = await tabWidths();
        return {
          even: new Set(widths).size === 1,
          narrowed: widths[0]! < 180 && widths[0]! >= 80,
          overflow: await tablist.evaluate(
            (element) => element.scrollWidth > element.clientWidth + 1
          ),
        };
      })
      .toEqual({ even: true, narrowed: true, overflow: false });

    // Closing with the pointer holds every width until the pointer leaves, so
    // the next tab's close button lands where the pointer already is.
    const closeCenter = async (index: number) => {
      const item = tablist.locator("[data-tab-item]").nth(index);
      await item.hover();
      const box = await item.getByRole("button", { name: /^Close / }).boundingBox();
      return { x: box!.x + box!.width / 2, y: box!.y + box!.height / 2 };
    };
    const [narrowedWidth] = await tabWidths();
    const target = await closeCenter(1);
    await page.mouse.click(target.x, target.y);
    await expect(tablist.locator("[data-tab-item]")).toHaveCount(3);
    expect(await tabWidths()).toEqual([narrowedWidth, narrowedWidth, narrowedWidth]);
    const next = await closeCenter(1);
    expect(next.x).toBeCloseTo(target.x, 0);
    expect(next.y).toBeCloseTo(target.y, 0);
    await page.mouse.click(next.x, next.y);
    await expect(tablist.locator("[data-tab-item]")).toHaveCount(2);
    expect(await tabWidths()).toEqual([narrowedWidth, narrowedWidth]);
    await page.mouse.move(640, 600);
    await expect.poll(tabWidths).toEqual([180, 180]);

    // Middle-click closes a tab, as in a browser.
    await tablist.getByRole("tab").first().click({ button: "middle" });
    await expect(tablist.getByRole("tab")).toHaveCount(1);

    // Past the minimum width the strip scrolls, keeps the selected tab in
    // view, and a vertical wheel scrolls it sideways.
    for (let index = 0; index < 6; index += 1) await newTab.click();
    await expect
      .poll(() =>
        tablist.evaluate((element) => {
          const list = element.getBoundingClientRect();
          const selected = element
            .querySelector('[role="tab"][aria-selected="true"]')!
            .getBoundingClientRect();
          return {
            atMinimum: [...element.querySelectorAll("[data-tab-item]")].every(
              (item) => Math.round(item.getBoundingClientRect().width) === 80
            ),
            overflow: element.scrollWidth > element.clientWidth + 1,
            selectedVisible:
              selected.left >= list.left - 1 && selected.right <= list.right + 1,
          };
        })
      )
      .toEqual({ atMinimum: true, overflow: true, selectedVisible: true });
    const strip = await tablist.boundingBox();
    const scrolledLeft = await tablist.evaluate((element) => element.scrollLeft);
    await page.mouse.move(strip!.x + strip!.width / 2, strip!.y + strip!.height / 2);
    await page.mouse.wheel(0, -120);
    await expect
      .poll(() => tablist.evaluate((element) => element.scrollLeft))
      .toBeLessThan(scrolledLeft);
  } finally {
    await stub.close();
  }
});

test("Task activity reserves running avatars and hides them on errors", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({ taskStatus: "active", taskSchedule: null });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "task-typing@comma.local",
      token: "comma_sess_task_typing",
    });
    await page.goto(
      `/#/inbox/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`
    );
    const task = page.getByTestId("inbox-detail-pane");
    // Exercise activity after the requested conversation has loaded, not the
    // transient idle composer before the channel attaches.
    await expect(
      task.getByRole("heading", {
        name: chatSmokeTaskConversation.title,
        exact: true,
      })
    ).toBeVisible();
    const slot = task.getByTestId("participant-status-slot");
    await task
      .getByRole("textbox", { name: "AI prompt" })
      .fill("Please continue this task");
    await task.getByRole("button", { name: "Send message", exact: true }).click();
    await expect(task.locator('[data-message-id="msg-task-user-smoke"]')).toBeVisible();
    await expect(slot).toHaveAttribute("data-active", "false");
    await expect(slot).toHaveCSS("height", "40px");
    const activityElement = await slot
      .locator('[data-slot="ai-activity"]')
      .elementHandle();
    const router = {
      participant_id: "ptc_router",
      actor_id: "actor_router",
      actor_role: "router" as const,
      name: "Default workspace Router",
      state: "active" as const,
      status: "is thinking...",
      updated_at: 1,
    };
    const worker = {
      participant_id: "ptc_worker",
      actor_id: "actor_worker",
      actor_role: "worker" as const,
      name: "Default workspace Worker",
      state: "active" as const,
      status: "is composing a message...",
      updated_at: 1,
    };
    stub.setTaskParticipants([router, worker]);
    await expect(slot.getByRole("status")).toHaveText("Router and Worker are thinking");
    await expect(slot).not.toContainText("Default workspace");
    await expect(slot.locator(".comma-chat-activity-line")).toHaveCount(1);
    await expect(slot.locator(".comma-chat-activity-avatar")).toHaveCount(2);
    await expect(slot).toHaveCSS("height", "40px");
    const routerAvatar = slot.locator('[data-actor-role="router"]');
    const workerAvatar = slot.locator('[data-actor-role="worker"]');
    await expect(routerAvatar).toBeVisible();
    await expect(routerAvatar).toHaveCSS("border-top-width", "0px");
    await expect(routerAvatar).toHaveCSS("padding", "0px");
    await expect(routerAvatar).toHaveCSS("outline-style", "none");
    // Router and Worker marks are both 16px in every state. Measure the
    // fixed clipping boundary, never a
    // painted path inside the animated transform (whose bounds vary by phase).
    const animatedMark = routerAvatar.locator('[data-slot="comma-logo-animation"]');
    await expect(routerAvatar).toHaveCSS("width", "16px");
    await expect(workerAvatar).toHaveCSS("width", "16px");
    await expect(workerAvatar).toHaveCSS("height", "16px");
    const transforms = new Set<string>();
    for (const elapsed of [0, 1000, 1999, 2500]) {
      await animatedMark.evaluate((svg, time) => {
        for (const animation of svg.getAnimations({ subtree: true })) {
          animation.pause();
          animation.currentTime = time;
        }
      }, elapsed);
      await expect(animatedMark).toHaveCSS("width", "16px");
      await expect(animatedMark).toHaveCSS("height", "16px");
      const boundary = await animatedMark.locator("clipPath path").evaluate((path) => {
        const bounds = (path as SVGGraphicsElement).getBBox();
        const matrix = (path as SVGGraphicsElement).getScreenCTM()!;
        return { width: bounds.width * matrix.a, height: bounds.height * matrix.d };
      });
      expect(boundary.width).toBeCloseTo(16, 1);
      expect(boundary.height).toBeCloseTo(16, 1);
      transforms.add(
        await animatedMark
          .locator(".comma-logo-animation__scene")
          .evaluate((scene) => getComputedStyle(scene).transform)
      );
    }
    expect(transforms.size).toBeGreaterThan(1);
    await page.emulateMedia({ reducedMotion: "reduce" });
    await expect(animatedMark.locator(".comma-logo-animation__scene")).toHaveCSS(
      "animation-name",
      "none"
    );
    await page.emulateMedia({ reducedMotion: "no-preference" });
    await expect(workerAvatar).toHaveCSS("background-image", /radial-gradient/);
    await expect
      .poll(async () => {
        const first = await routerAvatar.boundingBox();
        const second = await workerAvatar.boundingBox();
        return Math.round(second!.x - first!.x);
      })
      .toBe(16);
    const avatarElement = await workerAvatar.elementHandle();
    const longStatusWorker = {
      ...worker,
      status: "A much longer tool status that should not wrap or remount the group",
      updated_at: 2,
    };
    stub.setTaskParticipants([router, longStatusWorker]);
    await expect(slot).toHaveCSS("height", "40px");
    // Frames arrive in order: once the Router stops, the long status was applied.
    stub.setTaskParticipants([
      { ...router, state: "stopped", status: "", updated_at: 2 },
      longStatusWorker,
    ]);
    await expect(slot).not.toContainText("Router");
    await expect(slot.getByRole("status")).toHaveText("Worker is thinking");
    // The runtime's status text never becomes copy, and the group never remounts.
    await expect(slot).toHaveAttribute("title", "Worker · Working");
    expect(await activityElement!.evaluate((node) => node.isConnected)).toBe(true);
    expect(await avatarElement!.evaluate((node) => node.isConnected)).toBe(true);
    await expect(slot).toHaveCSS("height", "40px");
    stub.setTaskParticipants([
      {
        ...worker,
        issue: "recovery_exhausted",
        state: "error",
        status: "error: Waiting for runtime recovery",
        updated_at: 3,
      },
    ]);
    await expect(slot).toContainText(
      "Worker · Stopped after several attempts to recover. Try sending again."
    );
    await expect(slot).not.toContainText("runtime recovery");
    stub.setTaskParticipants([
      { ...router, state: "error", status: "Runtime unavailable", updated_at: 3 },
    ]);
    await expect(slot.locator(".comma-chat-activity-avatars")).toHaveCount(0);
    await expect(slot.locator(".comma-chat-activity-avatar")).toHaveCount(0);
    await expect(slot.locator('[data-slot="comma-product-mark"]')).toHaveCount(0);
    await expect(slot.locator('[data-slot="comma-logo-animation"]')).toHaveCount(0);
    stub.setTaskParticipants([]);
    await expect(slot).toHaveAttribute("data-active", "false");
    await expect(slot).toHaveCSS("height", "40px");
    await expect(task.locator('[data-message-id="msg-task-user-smoke"]')).toBeVisible();
  } finally {
    await stub.close();
  }
});

test("retained Comma conversation follows Participant active to stopped across routes", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    holdStreamingReplyStart: true,
    streamAssistantReply: true,
  });

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "comma-center-participant@comma.local",
      token: "comma_sess_center_participant",
    });
    await page.goto("/");

    const content = page.getByRole("region", { name: "Content" });
    const commaCenter = page.getByRole("link", { exact: true, name: "Home" });
    const prompt = content.getByRole("textbox", { name: "AI prompt" });
    await prompt.fill("Follow the Participant state");
    await content.getByRole("button", { name: "Send" }).click();

    const participantStatus = content.getByTestId("participant-status-slot");
    await expect(participantStatus).toHaveAttribute("data-active", "true");
    await expect(participantStatus).toContainText("Thinking");

    stub.startStreamingReply();
    await stub.waitForDraft();
    await expect(participantStatus).toHaveAttribute("data-state", "active");
    await expect(participantStatus).toHaveAttribute("data-active", "false");
    await expect(participantStatus).toBeHidden();

    await page.getByRole("link", { name: "Inbox", exact: true }).click();
    await expect(page).toHaveURL(/#\/inbox$/);
    await commaCenter.click();
    await expect(page).toHaveURL(/#\/$/);
    await expect(participantStatus).toHaveAttribute("data-state", "active");
    await expect(participantStatus).toHaveAttribute("data-active", "false");
    await expect(participantStatus).toBeHidden();

    stub.completeStreamingReply();

    await expect(
      content.getByText(chatSmokeAssistantReply, { exact: true })
    ).toHaveCount(1);
    await expect(participantStatus).toHaveAttribute("data-state", "stopped");
    await expect(participantStatus).toHaveAttribute("data-active", "false");
  } finally {
    await stub.close();
  }
});

test("committed inline Task opens a sidebar tab and Command-click opens its detail route", async ({
  page,
}) => {
  const assistantReply = "我已经处理了";
  const stub = await startChatSmokeStub({
    assistantReply,
    inlineTaskBoundaryCases: true,
    inlineTaskReference: true,
  });

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "inline-task@comma.local",
      token: "comma_sess_inline_task",
    });
    await page.goto("/");

    const content = page.getByRole("region", { name: "Content" });
    const composer = content.locator(".comma-chat-composer");
    await composer.getByRole("textbox", { name: "AI prompt" }).fill("请完成冒烟任务");
    const previewResponse = page.waitForResponse(
      (response) =>
        response.url().endsWith(`/${chatSmokeTaskConversation.id}/preview`) &&
        response.status() === 200
    );
    await composer.getByRole("button", { name: "Send" }).click();

    const assistantMessage = content.locator('[data-message-id="msg-assistant-smoke"]');
    const inlineTask = assistantMessage.getByTestId(
      `chat-inline-task-${chatSmokeTaskConversation.id}`
    );
    const sentence = assistantMessage.locator("p");

    await expect(inlineTask).toBeVisible();
    await expect(sentence).toHaveText(
      `${assistantReply} ${chatSmokeTaskConversation.title} 已完成。`
    );
    await expect(
      assistantMessage.getByTestId(`chat-ref-card-${chatSmokeTaskConversation.id}`)
    ).toHaveCount(0);

    for (const messageId of [
      "msg-assistant-inline-info",
      "msg-assistant-inline-quote",
      "msg-assistant-inline-indented",
      "msg-assistant-inline-cr",
    ]) {
      const boundaryMessage = content.locator(`[data-message-id="${messageId}"]`);
      const boundaryInline = boundaryMessage.getByTestId(
        `chat-inline-task-${chatSmokeTaskConversation.id}`
      );
      await expect(boundaryInline).toBeVisible();
      expect(
        await boundaryInline.evaluate(
          (element) => element.closest("code, pre, blockquote") === null
        )
      ).toBe(true);
    }

    const privateMessage = content.locator(
      '[data-message-id="msg-assistant-inline-private"]'
    );
    await expect(privateMessage).toContainText("Visible");
    await expect(privateMessage).not.toContainText("secret");
    await expect(
      privateMessage.getByTestId(`chat-inline-task-${chatSmokeTaskConversation.id}`)
    ).toHaveCount(0);

    const emphasisMessage = content.locator(
      '[data-message-id="msg-assistant-inline-emphasis"]'
    );
    const emphasisInline = emphasisMessage.getByTestId(
      `chat-inline-task-${chatSmokeTaskConversation.id}`
    );
    await expect(emphasisInline).toBeVisible();
    await expect(emphasisMessage.locator("strong")).toHaveText(
      `before ${chatSmokeTaskConversation.title} after`
    );
    expect(
      await emphasisInline.evaluate((element) => element.closest("strong") !== null)
    ).toBe(true);
    await expect(emphasisMessage).not.toContainText("**");

    const referenceMessage = content.locator(
      '[data-message-id="msg-assistant-inline-reference"]'
    );
    await expect(
      referenceMessage.getByRole("link", { name: "documentation" })
    ).toHaveAttribute("href", "https://example.com/docs");
    const referenceInline = referenceMessage.getByTestId(
      `chat-inline-task-${chatSmokeTaskConversation.id}`
    );
    await expect(referenceInline).toBeVisible();

    // This sentence closes with "." directly against the mention, the way
    // Chinese prose also sets its punctuation ("已完成并发布 <mention>："): the
    // surrounding text contributes no space of its own. The pill owns that
    // gutter, so the trailing prose must start outside its background rather
    // than sliding under it.
    const trailingGutter = await referenceInline.evaluate((element) => {
      const paragraph = element.parentElement;
      const last = paragraph?.lastChild;
      if (!paragraph || !last || last === element) return null;
      const trailing = document.createRange();
      trailing.setStartAfter(element);
      trailing.setEndAfter(last);
      const pill = element.getBoundingClientRect();
      const sameLine = Array.from(trailing.getClientRects()).find(
        (rect) => Math.abs(rect.top - pill.top) < pill.height
      );
      return sameLine ? sameLine.left - pill.right : null;
    });
    expect(trailingGutter).not.toBeNull();
    expect(trailingGutter!).toBeGreaterThanOrEqual(2);

    const hoverCard = page.locator('[data-slot="hover-card"]');
    // Rendering the boundary-case messages can still move the transcript after
    // the first pointer entry. Re-enter the trigger if that dismisses the card,
    // rather than waiting forever on a detached tooltip. Keep real hover and
    // pointer-transfer assertions; do not force actions or disable animation.
    await expect(async () => {
      await inlineTask.hover({ timeout: 1_000 });
      await expect(hoverCard).toBeVisible({ timeout: 1_000 });
      await expect(hoverCard.locator('[data-slot="task-card-title"]')).toHaveText(
        chatSmokeTaskConversation.title,
        { timeout: 1_000 }
      );
      await hoverCard.hover({ timeout: 1_000 });
      await page.waitForTimeout(150);
      await expect(hoverCard).toBeVisible({ timeout: 1_000 });
    }).toPass({ timeout: 10_000 });
    await previewResponse;

    const commaCenterUrl = page.url();
    await inlineTask.click();
    await expect(page).toHaveURL(commaCenterUrl);
    const sidebar = content.getByTestId("chat-sidebar");
    await expect(sidebar).toHaveAttribute("data-open", "true");
    await expect(
      sidebar.getByRole("tab", { name: chatSmokeTaskConversation.title })
    ).toHaveAttribute("aria-selected", "true");
    await expect(
      sidebar.getByTestId(`chat-sidebar-conversation-${chatSmokeTaskConversation.id}`)
    ).toBeVisible();

    // Command-click opens Task details from the inbox transcript.
    await page.goto(
      `/#/inbox/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeWorkspaceChat.id}`
    );
    await content
      .locator('[data-message-id="msg-assistant-smoke"]:visible')
      .getByTestId(`chat-inline-task-${chatSmokeTaskConversation.id}`)
      .click({ modifiers: ["Meta"] });
    await expect(page).toHaveURL(
      new RegExp(
        `#/tasks/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}$`
      )
    );
    await expect(
      content.getByRole("heading", { name: chatSmokeTaskConversation.title })
    ).toBeVisible();
  } finally {
    await stub.close();
  }
});

test("a Worker transcript preserves reading position and mounted message heights while expanding history", async ({
  page,
}) => {
  // Expanding the render window legitimately grows scrollHeight. Existing
  // messages must retain their height, and that growth must not move the reader.
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    taskAssistantMessages: Array.from(
      { length: 60 },
      (_, index) =>
        `第 ${index + 1} 条 Worker 记录。${"这是一段够长的正文，用来把转录撑过一屏。".repeat(8)}`
    ),
    taskSchedule: null,
    taskStatus: "completed",
  });

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "worker-scroll@comma.local",
      token: "comma_sess_worker_scroll",
    });
    await page.goto("/");

    // The reported path: the Task card in the Router chat, not a direct URL —
    // it leaves the Router surface mounted behind the Worker page.
    await page.locator('[data-slot="task-card"]').first().click();
    await expect(page).toHaveURL(
      new RegExp(
        `#/tasks/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}$`
      )
    );

    const content = page.getByRole("region", { name: "Content" });
    const viewport = content.locator(".comma-chat-scroll-viewport:visible");
    await expect(content.getByText("第 60 条 Worker 记录。").last()).toBeVisible();
    const readGeometry = () =>
      viewport.evaluate((element) => ({
        scrollHeight: element.scrollHeight,
        scrollTop: Math.round(element.scrollTop),
      }));
    await expect
      .poll(async () => (await readGeometry()).scrollHeight)
      .toBeGreaterThan(2000);

    const box = (await viewport.boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    const mountedHeights = () =>
      viewport
        .locator("article[data-message-id]")
        .evaluateAll((nodes) =>
          Object.fromEntries(
            nodes.map((node) => [
              node.getAttribute("data-message-id")!,
              node.getBoundingClientRect().height,
            ])
          )
        );
    const initialCount = await viewport.locator("article[data-message-id]").count();
    for (let burst = 0; burst < 8; burst += 1) {
      const heights = await mountedHeights();
      const anchorId = await viewport.evaluate((element) => {
        const top = element.getBoundingClientRect().top;
        return [...element.querySelectorAll("article[data-message-id]")]
          .find((node) => node.getBoundingClientRect().bottom > top)
          ?.getAttribute("data-message-id");
      });
      expect(anchorId).toBeTruthy();
      const anchor = viewport.locator(`article[data-message-id="${anchorId}"]`);
      const before = await anchor.evaluate((node) => node.getBoundingClientRect().top);
      for (let tick = 0; tick < 5; tick += 1) await page.mouse.wheel(0, -100);
      // Measure a stable message, not scrollTop: prepending older rows must
      // compensate the scroll offset while preserving the requested travel.
      await expect
        .poll(
          async () =>
            (await anchor.evaluate((node) => node.getBoundingClientRect().top)) - before
        )
        .toBeGreaterThan(350);
      const travelled =
        (await anchor.evaluate((node) => node.getBoundingClientRect().top)) - before;
      expect(travelled).toBeLessThan(650);
      const after = await mountedHeights();
      // Preserve the original regression guard against offscreen Markdown
      // height reservations collapsing when a message enters the viewport.
      for (const [id, height] of Object.entries(heights)) {
        expect(
          Math.abs(after[id]! - height),
          `message height changed: ${id}`
        ).toBeLessThanOrEqual(2);
      }
    }
    expect(await viewport.locator("article[data-message-id]").count()).toBeGreaterThan(
      initialCount
    );
  } finally {
    await stub.close();
  }
});

test("short chat stays non-scrollable and uses a compact latest turn after overflow", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    assistantReply: "我会从这里开始回答。",
    priorUserMessage: "这是上一条连续发送的用户消息。",
  });

  try {
    await page.setViewportSize({ width: 1_299, height: 1_245 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "chat-turn-anchor@comma.local",
      token: "comma_sess_chat_turn_anchor",
    });
    await page.goto("/");

    const content = page.getByRole("region", { name: "Content" });
    const composer = content.locator(".comma-chat-composer");
    const userText =
      "请仔细分析这个需要跨越多个阶段的长问题，并且确保在窗口变窄、文字重新换行以及回答继续增长时，我刚刚发出的消息仍然能作为这一轮对话的清晰起点；即使内容宽度发生变化，也保持连续消息之间的紧凑间距。";
    await composer.getByRole("textbox", { name: "AI prompt" }).fill(userText);
    await composer.getByRole("button", { name: "Send" }).click();

    const latestTurn = content.getByTestId("chat-latest-turn");
    const chatScrollArea = content.locator(
      '.comma-chat-thread-zone > [data-slot="scroll-area"]'
    );
    const chatViewport = chatScrollArea.locator(
      ':scope > [data-slot="scroll-area-viewport"]'
    );
    const verticalScrollbar = chatScrollArea.locator(
      ':scope > [data-slot="scroll-area-scrollbar"][data-axis="vertical"]'
    );
    const previousUserMessage = content.locator(
      '[data-message-id="msg-prior-user-smoke"]'
    );
    const latestUserMessage = latestTurn.locator(".comma-chat-message-user");
    await expect(previousUserMessage).toHaveCount(1);
    await expect(latestUserMessage).toContainText(userText);
    await expect(latestTurn.locator(".comma-chat-message-assistant")).toContainText(
      "我会从这里开始回答。"
    );

    const readTurnGeometry = () =>
      latestTurn.evaluate((turn) => {
        const viewport = turn
          .closest('[data-slot="scroll-area"]')
          ?.querySelector<HTMLElement>('[data-slot="scroll-area-viewport"]');
        const thread = turn.closest<HTMLElement>(".comma-chat-thread");
        const innerTurn = turn.querySelector<HTMLElement>(":scope > .comma-chat-turn");
        const userMessage = turn.querySelector<HTMLElement>(".comma-chat-message-user");
        if (!viewport || !thread || !innerTurn || !userMessage) {
          throw new Error("Missing chat turn geometry");
        }
        const viewportRect = viewport.getBoundingClientRect();
        const userRect = userMessage.getBoundingClientRect();
        const paddingBottom = Number.parseFloat(getComputedStyle(turn).paddingBottom);
        const reservedHeight = Math.max(
          0,
          turn.clientHeight - innerTurn.scrollHeight - paddingBottom
        );
        return {
          anchorDelta: Math.round(userRect.top - viewportRect.top),
          anchored: turn.classList.contains("comma-chat-latest-turn"),
          meaningfulOverflow: Math.round(
            thread.scrollHeight - reservedHeight - viewport.clientHeight
          ),
          minHeight: Math.round(Number.parseFloat(getComputedStyle(turn).minHeight)),
          paddingBottom,
          rawOverflow: Math.round(viewport.scrollHeight - viewport.clientHeight),
          scrollTop: Math.round(viewport.scrollTop),
          topInset: Math.round(Number.parseFloat(getComputedStyle(thread).paddingTop)),
          userHeight: Math.round(userRect.height),
          viewportHeight: Math.round(viewportRect.height),
        };
      });

    const readPreviousUserBottom = () =>
      previousUserMessage.evaluate((previous) => {
        const viewport = previous
          .closest('[data-slot="scroll-area"]')
          ?.querySelector<HTMLElement>('[data-slot="scroll-area-viewport"]');
        if (!viewport) {
          throw new Error("Missing chat viewport");
        }
        return Math.round(
          previous.getBoundingClientRect().bottom - viewport.getBoundingClientRect().top
        );
      });

    await expect
      .poll(async () => (await readTurnGeometry()).rawOverflow)
      .toBeLessThanOrEqual(1);
    await expect(latestTurn).toHaveCSS("padding-bottom", "48px");
    await expect(latestTurn).not.toHaveAttribute("data-chat-outgoing-turn", "true");
    const wideGeometry = await readTurnGeometry();
    expect(wideGeometry.anchored).toBe(false);
    expect(wideGeometry.paddingBottom).toBe(48);
    expect(wideGeometry.meaningfulOverflow).toBeLessThanOrEqual(1);
    expect(wideGeometry.scrollTop).toBe(0);
    expect(await readPreviousUserBottom()).toBeGreaterThan(0);
    await expect(chatScrollArea).toHaveAttribute("data-has-overflow-y", "false");
    await expect(verticalScrollbar).toHaveCount(0);
    await chatViewport.hover();
    // The browser scrolls a wheel itself, off the main thread, so the driver
    // is not told when it has been spent. Wait until this one has reached the
    // page and a frame has passed, or it can land on the overflow made below.
    const wheelSpent = chatViewport.evaluate(
      (viewport) =>
        new Promise<void>((resolve) => {
          viewport.addEventListener(
            "wheel",
            () => requestAnimationFrame(() => requestAnimationFrame(() => resolve())),
            { once: true, passive: true }
          );
        })
    );
    await page.mouse.wheel(0, 320);
    await wheelSpent;
    await expect.poll(async () => (await readTurnGeometry()).scrollTop).toBe(0);

    const asyncLayoutGrowth = await page.addStyleTag({
      content: '[data-testid="chat-current-turn"] { min-height: 1200px !important; }',
    });

    await expect
      .poll(async () => (await readTurnGeometry()).rawOverflow)
      .toBeGreaterThan(1);
    await expect(verticalScrollbar).toHaveCount(1);
    await expect(latestTurn).toHaveClass(/comma-chat-latest-turn/);
    await expect
      .poll(async () => {
        const geometry = await readTurnGeometry();
        return geometry.anchorDelta === geometry.topInset;
      })
      .toBe(true);
    await expect
      .poll(readPreviousUserBottom)
      .toBeLessThanOrEqual((await readTurnGeometry()).topInset - 4);

    await asyncLayoutGrowth.evaluate((style) => style.parentNode?.removeChild(style));

    await expect
      .poll(async () => (await readTurnGeometry()).rawOverflow)
      .toBeLessThanOrEqual(1);
    await expect(latestTurn).not.toHaveClass(/comma-chat-latest-turn/);
    await expect(verticalScrollbar).toHaveCount(0);
    await expect.poll(async () => (await readTurnGeometry()).scrollTop).toBe(0);

    await page.setViewportSize({ width: 861, height: 420 });

    await expect
      .poll(async () => (await readTurnGeometry()).meaningfulOverflow)
      .toBeGreaterThan(1);
    await expect(chatScrollArea).toHaveAttribute("data-has-overflow-y", "true");
    await expect(verticalScrollbar).toHaveCount(1);
    await expect
      .poll(async () => {
        const geometry = await readTurnGeometry();
        return geometry.anchorDelta === geometry.topInset;
      })
      .toBe(true);
    await expect
      .poll(readPreviousUserBottom)
      .toBeLessThanOrEqual((await readTurnGeometry()).topInset - 4);
    const overflowGeometry = await readTurnGeometry();
    expect(overflowGeometry.minHeight).toBe(200);
    expect(overflowGeometry.paddingBottom).toBe(48);
    expect(overflowGeometry.scrollTop).toBeGreaterThan(0);

    await page.setViewportSize({ width: 760, height: 420 });

    await expect
      .poll(async () => {
        const geometry = await readTurnGeometry();
        return geometry.anchorDelta === geometry.topInset;
      })
      .toBe(true);
    await expect
      .poll(readPreviousUserBottom)
      .toBeLessThanOrEqual((await readTurnGeometry()).topInset - 4);
    const resizedOverflowGeometry = await readTurnGeometry();
    expect(resizedOverflowGeometry.minHeight).toBe(200);
    expect(resizedOverflowGeometry.paddingBottom).toBe(48);

    await page.addStyleTag({
      content: ".comma-chat-user-bubble { max-width: 180px !important; }",
    });

    await expect
      .poll(async () => (await readTurnGeometry()).userHeight)
      .toBeGreaterThan(resizedOverflowGeometry.userHeight);
    await expect
      .poll(async () => {
        const geometry = await readTurnGeometry();
        return geometry.anchorDelta === geometry.topInset;
      })
      .toBe(true);
    await expect
      .poll(readPreviousUserBottom)
      .toBeLessThanOrEqual((await readTurnGeometry()).topInset - 4);

    const readChatEdgeMask = () =>
      chatScrollArea.evaluate((scrollArea) => {
        const viewport = scrollArea.querySelector<HTMLElement>(
          ':scope > [data-slot="scroll-area-viewport"]'
        );
        if (!viewport) throw new Error("Missing chat viewport");
        const styles = getComputedStyle(viewport);
        return {
          effect: scrollArea.getAttribute("data-edge-effect"),
          end: Number.parseFloat(
            viewport.style.getPropertyValue("--scroll-area-edge-mask-end")
          ),
          maskImage: styles.maskImage,
          start: Number.parseFloat(
            viewport.style.getPropertyValue("--scroll-area-edge-mask-start")
          ),
        };
      });
    await chatViewport.focus();
    await page.keyboard.press("Home");
    await expect.poll(async () => (await readTurnGeometry()).scrollTop).toBe(0);
    await expect.poll(readChatEdgeMask).toMatchObject({
      effect: "mask",
      end: 24,
      start: 0,
    });
    expect((await readChatEdgeMask()).maskImage).toContain("linear-gradient");

    await chatViewport.evaluate((viewport) => {
      viewport.scrollTop = (viewport.scrollHeight - viewport.clientHeight) / 2;
      viewport.dispatchEvent(new Event("scroll", { bubbles: true }));
    });
    await expect.poll(readChatEdgeMask).toMatchObject({ end: 24, start: 16 });

    await page.keyboard.press("End");
    await expect.poll(readChatEdgeMask).toMatchObject({ end: 0, start: 16 });

    // The chat rewraps with the window, not once it settles: the thread opts out
    // of the ScrollArea's window-resize inline-size freeze, so the text follows a
    // window drag exactly as it follows a Chat Sidebar drag. Sampled inside the
    // page — the freeze releases 120ms after the last resize event, which a
    // round-trip read would miss entirely.
    await page.evaluate(() => {
      const samples: { frozen: string | null; width: number }[] = [];
      (
        window as unknown as { commaChatWidthSamples: typeof samples }
      ).commaChatWidthSamples = samples;
      const tick = () => {
        const column = document.querySelector(".comma-chat-column");
        const scrollArea = column?.closest(".comma-scroll-area");
        samples.push({
          frozen: scrollArea?.getAttribute("data-freeze-content-inline-size") ?? null,
          width: Math.round(column?.getBoundingClientRect().width ?? 0),
        });
        if (samples.length < 40) requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    });
    await page.setViewportSize({ width: 1_020, height: 1_245 });
    await page.waitForTimeout(500);
    const widthSamples = await page.evaluate(
      () =>
        (
          window as unknown as {
            commaChatWidthSamples: { frozen: string | null; width: number }[];
          }
        ).commaChatWidthSamples
    );
    expect(widthSamples.length).toBeGreaterThan(5);
    expect(widthSamples.some((sample) => sample.frozen === "true")).toBe(false);
    // Was: every sample a constant 345 — Home's 393px chat floor minus the
    // column's 2x24px padding — because the window drag ate the rails 1:1
    // around a chat column pinned at its floor, which made a constant width the
    // control that isolated the freeze flag. A window drag with no Chat Sidebar
    // open now folds the rail in one transitioned step instead, so the column
    // moves through intermediate widths while the fold plays and no width is
    // constant across the samples. The freeze flag above is the claim; there is
    // no longer a stable width to hold alongside it.
  } finally {
    await stub.close();
  }
});

function readChatComposerBox(scope: Locator) {
  return scope.locator(".comma-chat-composer").evaluate((shell) => {
    const style = getComputedStyle(shell);
    return {
      borderRadius: style.borderTopLeftRadius,
      height: Math.round(shell.getBoundingClientRect().height),
      paddingBlockEnd: style.paddingBottom,
      paddingBlockStart: style.paddingTop,
    };
  });
}

for (const reducedMotion of [false, true]) {
  test(`sending reserves the final turn spacing${reducedMotion ? " without motion" : " before the bubble flight"}`, async ({
    page,
  }) => {
    const stub = await startChatSmokeStub({
      assistantReply: "A short reply.",
      priorUserMessage: "Earlier context that fills the conversation. ".repeat(100),
    });
    try {
      await page.emulateMedia({
        reducedMotion: reducedMotion ? "reduce" : "no-preference",
      });
      await page.setViewportSize({ width: 861, height: 600 });
      await installBrowserTestSession(page, {
        apiBaseUrl: stub.baseUrl,
        email: "chat-spacing@comma.local",
        token: "comma_sess_chat_spacing",
      });
      await page.goto("/");
      const content = page.getByRole("region", { name: "Content" });
      const composer = content.locator(".comma-chat-composer");
      await composer.getByRole("textbox", { name: "AI prompt" }).fill("A new question");
      // Sample from the first paint. Space grows with the flight and must
      // reach its final size before the bubble settles.
      await page.evaluate(() => {
        const samples: {
          minHeight: number;
          padding: number;
          landingDelta: number | undefined;
        }[] = [];
        (
          window as unknown as { turnSpacingSamples: typeof samples }
        ).turnSpacingSamples = samples;
        const deadline = performance.now() + 3000;
        const sample = () => {
          const turn = document.querySelector('[data-chat-outgoing-turn="true"]');
          if (turn) {
            const style = getComputedStyle(turn);
            const bubble = turn.querySelector('[data-outgoing-presentation="flying"]');
            const slot = bubble?.closest(".comma-chat-user-bubble-slot");
            samples.push({
              minHeight: parseFloat(style.minHeight),
              padding: parseFloat(style.paddingBottom),
              landingDelta:
                bubble && slot
                  ? Math.abs(
                      bubble.getBoundingClientRect().bottom -
                        slot.getBoundingClientRect().bottom
                    )
                  : undefined,
            });
          }
          if (performance.now() < deadline) requestAnimationFrame(sample);
        };
        requestAnimationFrame(sample);
      });
      await composer.getByRole("button", { name: "Send" }).click();
      const latestTurn = content.getByTestId("chat-latest-turn");
      await expect(latestTurn).toHaveCSS("min-height", "200px");
      await expect(latestTurn).toHaveCSS("padding-bottom", "48px");
      await expect(latestTurn).not.toHaveAttribute("data-chat-outgoing-turn", "true");
      const samples = await page.evaluate(
        () =>
          (
            window as unknown as {
              turnSpacingSamples: {
                minHeight: number;
                padding: number;
                landingDelta: number | undefined;
              }[];
            }
          ).turnSpacingSamples
      );
      expect(samples.length).toBeGreaterThan(0);
      expect(
        samples.every((sample) => sample.padding >= 0 && sample.padding <= 48)
      ).toBe(true);
      expect(
        samples.every((sample) => sample.minHeight >= 0 && sample.minHeight <= 200)
      ).toBe(true);
      if (reducedMotion) {
        expect(samples.every((sample) => sample.padding === 48)).toBe(true);
      } else {
        expect(
          samples.some((sample) => sample.padding > 0 && sample.padding < 48)
        ).toBe(true);
      }
      if (!reducedMotion) {
        // The last painted flight frame must already land in the real slot;
        // clearing the top-layer presentation must not teleport the bubble.
        const landing = samples.findLast((sample) => sample.landingDelta !== undefined);
        expect(landing?.landingDelta).toBeLessThanOrEqual(1);
      }
      const viewport = content.locator(
        '.comma-chat-thread-zone [data-slot="scroll-area-viewport"]'
      );
      await viewport.evaluate((element) => {
        element.scrollTop = element.scrollHeight;
      });
      const bottomGap = await latestTurn.evaluate((turn) => {
        const inner = turn.querySelector(".comma-chat-turn")!;
        const scrollport = turn.closest('[data-slot="scroll-area-viewport"]')!;
        return (
          scrollport.getBoundingClientRect().bottom -
          inner.getBoundingClientRect().bottom
        );
      });
      expect(Math.round(bottomGap)).toBe(48);
    } finally {
      await stub.close();
    }
  });
}

test("the task route composer is the same input as the Comma assistant's", async ({
  page,
}) => {
  const stub = await startChatSmokeStub();

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "task-composer@comma.local",
      token: "comma_sess_task_composer",
    });

    await page.goto("/");
    const home = page.getByTestId("home-responsive-layout");
    await expect(home.locator(".comma-chat-composer")).toBeVisible();
    const homeComposer = await readChatComposerBox(home);

    await page.goto(
      `/#/inbox/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`
    );
    const taskPane = page.getByTestId("inbox-detail-pane");
    await expect(
      (await openTaskDetails(page)).getByTestId("task-conversation-status")
    ).toContainText(/Done/);
    await page.keyboard.press("Escape");
    const taskComposer = await readChatComposerBox(taskPane);

    // The Worker conversation and the Comma assistant share one composer, so the
    // route input is the same size the Comma assistant already uses.
    expect(taskComposer).toEqual(homeComposer);
  } finally {
    await stub.close();
  }
});

test("chat turn rows sit at the turn gap while the timestamp keeps its own", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    priorAssistantReply: "上一轮的回答。",
    priorUserMessage: "这是上一条用户消息。",
  });

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "chat-turn-rhythm@comma.local",
      token: "comma_sess_chat_turn_rhythm",
    });
    await page.goto("/");

    const content = page.getByRole("region", { name: "Content" });
    const composer = content.locator(".comma-chat-composer");
    await composer.getByRole("textbox", { name: "AI prompt" }).fill("继续。");
    await composer.getByRole("button", { name: "Send" }).click();

    // The prior turn carries the conversation's first user message, so it is the
    // one that owns a timestamp on top of its own user and assistant rows.
    const turn = content.locator(".comma-chat-turn").first();
    await expect(turn.locator(".comma-chat-conversation-timestamp")).toBeVisible();
    await expect(turn.locator(".comma-chat-message-assistant")).toContainText(
      "上一轮的回答。"
    );

    const rhythm = await turn.evaluate((element) => {
      const timestamp = element.querySelector<HTMLElement>(
        ".comma-chat-conversation-timestamp"
      );
      const user = element.querySelector<HTMLElement>(".comma-chat-message-user");
      const assistant = element.querySelector<HTMLElement>(
        ".comma-chat-message-assistant"
      );
      if (!timestamp || !user || !assistant) {
        throw new Error("Chat turn rhythm is unavailable.");
      }
      return {
        timestampToUser:
          user.getBoundingClientRect().top - timestamp.getBoundingClientRect().bottom,
        userToAssistant:
          assistant.getBoundingClientRect().top - user.getBoundingClientRect().bottom,
      };
    });

    // The rows share the turn's own 8px rhythm; the timestamp labels the turn
    // rather than being one of its rows, so it keeps the wider 16px separation.
    expect(rhythm.userToAssistant).toBeCloseTo(8, 1);
    expect(rhythm.timestampToUser).toBeCloseTo(16, 1);
  } finally {
    await stub.close();
  }
});

test("quotes selected reply text into the composer and sends it as its own block", async ({
  page,
}) => {
  const quotedPassage = "圆橡皮，中间留出金属箍空隙。";
  const stub = await startChatSmokeStub({ assistantReply: quotedPassage });

  try {
    await page.setViewportSize({ width: 1_100, height: 800 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "chat-quote@comma.local",
      token: "comma_sess_chat_quote",
    });
    await page.goto("/");

    const content = page.getByRole("region", { name: "Content" });
    const composer = content.locator(".comma-chat-composer");
    const prompt = composer.getByRole("textbox", { name: "AI prompt" });
    await prompt.fill("先给我一段可以引用的说明。");
    await composer.getByRole("button", { name: "Send" }).click();

    const reply = content.locator('[data-slot="chat-assistant-output"]').last();
    await expect(reply).toContainText(quotedPassage);

    // Drag across the reply exactly as a reader would, so the bar sees a real
    // settled pointer gesture rather than a synthesized selection.
    const passage = reply.locator("p").last();
    const passageBox = (await passage.boundingBox())!;
    await page.mouse.move(passageBox.x + 2, passageBox.y + passageBox.height / 2);
    await page.mouse.down();
    await page.mouse.move(
      passageBox.x + passageBox.width - 2,
      passageBox.y + passageBox.height / 2,
      { steps: 10 }
    );
    await page.mouse.up();

    const bar = page.locator('[data-slot="selection-action-bar"]');
    await expect(bar).toBeVisible();
    await bar.getByRole("button", { name: "Add to chat" }).click();

    const chip = composer.locator('[data-slot="quote-attachment"]');
    await expect(chip).toHaveCount(1);
    // Staging the quote consumes the selection, so the bar leaves with it.
    await expect(bar).toBeHidden();

    await prompt.fill("这段是什么意思？");
    await composer.getByRole("button", { name: "Send" }).click();

    const sent = content.locator('[data-slot="chat-user-output"]').last();
    const quoteBlock = sent.getByTestId("chat-message-quote");
    // The sent quote is the composer chip's icon-only tile: the passage lives
    // on the trigger's label and in its hover card, not in the flow.
    await expect(quoteBlock).not.toContainText(quotedPassage);
    const quoteTile = quoteBlock.getByRole("button", {
      name: `Quoted text: ${quotedPassage}`,
    });
    await expect(quoteTile).toBeVisible();
    // The block owns a full line of its own, ahead of the message bubble.
    const quoteBox = (await quoteBlock.boundingBox())!;
    const bubbleBox = (await sent
      .getByTestId("chat-user-bubble-content")
      .boundingBox())!;
    expect(quoteBox.y + quoteBox.height).toBeLessThanOrEqual(bubbleBox.y);
    await expect(sent.getByTestId("chat-user-bubble-content")).toHaveText(
      "这段是什么意思？"
    );
    await expect(sent).not.toContainText("Quoted from this conversation:");
    // The staged quote is spent once it ships.
    await expect(chip).toHaveCount(0);

    // With the send acknowledged and the turn settled, hovering the tile
    // reveals the passage in the same hover card the composer chip uses.
    await page.mouse.move(10, 10);
    await quoteTile.hover();
    const quoteCard = page.locator('[data-slot="hover-card"]');
    await expect(quoteCard).toContainText(quotedPassage);
    await page.mouse.move(10, 10);
    await expect(quoteCard).toHaveCount(0);
  } finally {
    await stub.close();
  }
});

test("keeps the quote bar when the drag overshoots below the message", async ({
  page,
}) => {
  const quotedPassage = "圆橡皮，中间留出金属箍空隙。";
  const stub = await startChatSmokeStub({ assistantReply: quotedPassage });

  try {
    await page.setViewportSize({ width: 1_100, height: 800 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "chat-quote-overshoot@comma.local",
      token: "comma_sess_chat_quote_overshoot",
    });
    await page.goto("/");

    const content = page.getByRole("region", { name: "Content" });
    const composer = content.locator(".comma-chat-composer");
    await composer.getByRole("textbox", { name: "AI prompt" }).fill("给我一段说明。");
    await composer.getByRole("button", { name: "Send" }).click();

    const reply = content.locator('[data-slot="chat-assistant-output"]').last();
    await expect(reply).toContainText(quotedPassage);

    // Drag from the reply and keep going well past its bottom edge, the way a
    // reader overshoots without seeing what else they caught.
    const passage = reply.locator("p").last();
    const box = (await passage.boundingBox())!;
    await page.mouse.move(box.x + 2, box.y + box.height / 2);
    await page.mouse.down();
    await page.mouse.move(box.x + box.width, box.y + box.height + 220, { steps: 12 });
    await page.mouse.up();

    const bar = page.locator('[data-slot="selection-action-bar"]');
    await expect(bar).toBeVisible();
    // The overshoot is pulled back inside the message, so the highlight the
    // reader sees is exactly what the quote will carry.
    const selected = await page.evaluate(() =>
      window.getSelection()?.toString().trim()
    );
    expect(selected).toBe(quotedPassage);

    await bar.getByRole("button", { name: "Add to chat" }).click();
    await expect(composer.locator('[data-slot="quote-attachment"]')).toHaveCount(1);
  } finally {
    await stub.close();
  }
});

test("keyboard focus on an older chat action stays visible", async ({ page }) => {
  const stub = await startChatSmokeStub({
    assistantReply: "我会继续处理最新问题。",
    priorAssistantReply: "这是上一轮已经完成的回答。",
    priorUserMessage: "这是上一轮的用户问题。",
  });

  try {
    await page.setViewportSize({ width: 1_000, height: 600 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "chat-focus-intent@comma.local",
      token: "comma_sess_chat_focus_intent",
    });
    await page.goto("/");

    const content = page.getByRole("region", { name: "Content" });
    const composer = content.locator(".comma-chat-composer");
    const prompt = composer.getByRole("textbox", { name: "AI prompt" });
    await prompt.fill(
      "请继续分析这个足够长的新问题，让上一轮操作位于当前 viewport 的上方。"
    );
    await composer.getByRole("button", { name: "Send" }).click();

    const olderAssistant = content.locator(
      '[data-message-id="msg-prior-assistant-smoke"]'
    );
    const olderCopy = olderAssistant.getByRole("button", { name: "Copy reply" });
    const chatViewport = content.locator(".comma-chat-scroll-viewport");
    const readFocusState = () =>
      olderCopy.evaluate((button) => {
        const scrollViewport = button
          .closest('[data-slot="scroll-area"]')
          ?.querySelector<HTMLElement>('[data-slot="scroll-area-viewport"]');
        if (!scrollViewport) {
          throw new Error("Missing chat viewport");
        }
        const buttonRect = button.getBoundingClientRect();
        const viewportRect = scrollViewport.getBoundingClientRect();
        return {
          distanceFromBottom:
            scrollViewport.scrollHeight -
            scrollViewport.clientHeight -
            scrollViewport.scrollTop,
          focused: document.activeElement === button,
          visible:
            buttonRect.top >= viewportRect.top &&
            buttonRect.bottom <= viewportRect.bottom,
        };
      });
    await expect(content.getByTestId("chat-latest-turn")).toBeVisible();
    await expect(olderCopy).toHaveCount(1);
    const shrinkSpacer = await olderAssistant.evaluate((message) => {
      const spacer = document.createElement("div");
      spacer.dataset.testid = "focus-shrink-spacer";
      spacer.style.flex = "0 0 700px";
      spacer.style.height = "700px";
      message.before(spacer);
      // Keep the target outside the latest viewport independently of the
      // latest turn's compact 200px reserve. The leading spacer still tests
      // retaining focus when content above the target shrinks.
      const trailing = document.createElement("div");
      trailing.style.flex = "0 0 700px";
      trailing.style.height = "700px";
      message.after(trailing);
      return "focus-shrink-spacer";
    });
    const spacer = content.getByTestId(shrinkSpacer);
    await expect
      .poll(() => readFocusState().then((state) => state.visible))
      .toBe(false);

    await prompt.focus();
    for (let attempt = 0; attempt < 12; attempt += 1) {
      await page.keyboard.press("Shift+Tab");
      if (await olderCopy.evaluate((button) => document.activeElement === button)) {
        break;
      }
    }
    await expect(olderCopy).toBeFocused();
    expect((await readFocusState()).visible).toBe(true);

    const expandedScrollHeight = await chatViewport.evaluate(
      (viewport) => viewport.scrollHeight
    );
    await spacer.evaluate((element) => {
      element.style.flexBasis = "300px";
      element.style.height = "300px";
    });
    await expect
      .poll(() => chatViewport.evaluate((viewport) => viewport.scrollHeight))
      .toBeLessThanOrEqual(expandedScrollHeight - 350);
    await expect.poll(() => readFocusState().then((state) => state.visible)).toBe(true);
    await page.waitForTimeout(1_250);

    const focusState = await readFocusState();

    expect(focusState.focused).toBe(true);
    expect(focusState.visible).toBe(true);
    expect(focusState.distanceFromBottom).toBeGreaterThan(1);
  } finally {
    await stub.close();
  }
});

test("automatic chat following stays hidden while native wheel remains visible", async ({
  page,
}) => {
  const assistantReply = Array.from(
    { length: 24 },
    (_, index) => `这是用于滚动回归的第 ${index + 1} 段回答。`
  ).join("\n\n");
  const stub = await startChatSmokeStub({
    assistantReply,
    priorAssistantReply: "这是更早一轮已经完成的回答。",
    priorUserMessage: "这是更早一轮的用户问题。",
  });

  try {
    await page.setViewportSize({ width: 1_000, height: 600 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "chat-wheel-intent@comma.local",
      token: "comma_sess_chat_wheel_intent",
    });
    await page.goto("/");

    const content = page.getByRole("region", { name: "Content" });
    const composer = content.locator(".comma-chat-composer");
    const chatScrollArea = content.locator(
      '.comma-chat-thread-zone > [data-slot="scroll-area"]'
    );
    const verticalScrollbar = chatScrollArea.locator(
      ':scope > [data-slot="scroll-area-scrollbar"][data-axis="vertical"]'
    );
    await content.evaluate((region) => {
      const host = region as HTMLElement & {
        commaProgrammaticScrollProbe?: {
          observer: MutationObserver;
          scrollingTrueTransitions: number;
        };
      };
      const probe = {
        observer: undefined as unknown as MutationObserver,
        scrollingTrueTransitions: 0,
      };
      probe.observer = new MutationObserver(() => {
        // The scrollbar carries the reveal state it shows.
        const scrollbar = region.querySelector<HTMLElement>(
          '.comma-chat-thread-zone > [data-slot="scroll-area"] > [data-slot="scroll-area-scrollbar"][data-axis="vertical"]'
        );
        if (scrollbar?.dataset.scrolling === "true") {
          probe.scrollingTrueTransitions += 1;
        }
      });
      probe.observer.observe(region, {
        attributeFilter: ["data-scrolling"],
        attributes: true,
        subtree: true,
      });
      host.commaProgrammaticScrollProbe = probe;
    });
    await composer
      .getByRole("textbox", { name: "AI prompt" })
      .fill("请生成足够长的回复用于滚动测试。");
    await composer.getByRole("button", { name: "Send" }).click();
    await expect(content.getByText("这是用于滚动回归的第 24 段回答。")).toBeVisible();

    await expect(chatScrollArea).toHaveAttribute("data-has-overflow-y", "true");
    await expect(verticalScrollbar).toHaveCount(1);
    await page.waitForTimeout(1_250);
    const automaticRevealCount = await content.evaluate((region) => {
      const host = region as HTMLElement & {
        commaProgrammaticScrollProbe?: {
          observer: MutationObserver;
          scrollingTrueTransitions: number;
        };
      };
      const probe = host.commaProgrammaticScrollProbe;
      if (!probe) {
        throw new Error("Missing programmatic scroll reveal probe");
      }
      probe.observer.disconnect();
      delete host.commaProgrammaticScrollProbe;
      return probe.scrollingTrueTransitions;
    });
    expect(automaticRevealCount).toBe(0);
    await expect(verticalScrollbar).toHaveCSS("opacity", "0");

    const chatViewport = content.locator(".comma-chat-scroll-viewport");
    const readScrollTop = () =>
      chatViewport.evaluate((viewport) => Math.round(viewport.scrollTop));
    // Following rests the newest turn's top on the reading inset, which is the
    // thread's end only while that turn still fits the viewport. This reply is
    // far taller, so assert the inset rather than a distance from the bottom.
    const readNewestTurnTopInset = () =>
      chatViewport.evaluate((viewport) => {
        const turn = viewport.querySelector<HTMLElement>(
          '.comma-chat-turn-shell[data-chat-latest-turn="true"]'
        );
        if (!turn) return Number.NaN;
        const inset = Number.parseFloat(
          getComputedStyle(turn).getPropertyValue("--comma-chat-thread-top-inset")
        );
        const top =
          turn.getBoundingClientRect().top - viewport.getBoundingClientRect().top;
        return Math.round(top - (Number.isFinite(inset) ? inset : 0));
      });
    await expect.poll(readNewestTurnTopInset).toBeLessThanOrEqual(1);
    const restingScrollTop = await readScrollTop();
    const viewportBox = await chatViewport.boundingBox();
    if (!viewportBox) {
      throw new Error("Missing chat viewport bounds");
    }

    await page.mouse.move(
      viewportBox.x + viewportBox.width / 2,
      viewportBox.y + viewportBox.height / 2
    );
    await page.mouse.wheel(0, -10);
    await expect.poll(readScrollTop).toBeLessThan(restingScrollTop);
    await expect(verticalScrollbar).toHaveAttribute("data-scrolling", "true");
    await expect(verticalScrollbar).toHaveCSS("opacity", "1");

    const scrolledScrollTop = await readScrollTop();
    await page.waitForTimeout(1_250);
    await page.setViewportSize({ width: 1_000, height: 590 });
    await page.evaluate(
      () =>
        new Promise<void>((resolve) => {
          requestAnimationFrame(() => requestAnimationFrame(() => resolve()));
        })
    );

    // The reflow must not haul the reader back: their wheel position stands.
    await expect.poll(readScrollTop).toBeLessThanOrEqual(scrolledScrollTop);
  } finally {
    await stub.close();
  }
});

test("production-shaped task header preserves its title at the minimum width", async ({
  page,
}) => {
  const stub = await startChatSmokeStub();

  try {
    await page.setViewportSize({ width: 641, height: 800 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "task-layout@comma.local",
      token: "comma_sess_task_layout",
    });
    await page.goto(
      `/#/inbox/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`
    );

    const header = page
      .getByRole("region", { name: "Content" })
      .getByTestId("inbox-detail-pane")
      .locator('[data-slot="content-header"]');
    const title = header.getByRole("heading", {
      name: chatSmokeTaskConversation.title,
    });
    const toggle = header.getByTestId("task-panel-toggle");
    await expect(title).toBeVisible();
    // Folded at this width: the status reads from the toggle's popover.
    await expect(toggle).toBeVisible();
    await expect(
      (await openTaskDetails(page)).getByTestId("task-conversation-status")
    ).toContainText(/Done/);
    await page.keyboard.press("Escape");
    await expect(page.getByTestId("task-panel-popover")).toHaveCount(0);
    await expect(page.getByRole("complementary", { name: "Chat" })).toHaveCount(0);

    const chatRouteNoDragSelectors = await page.evaluate(() => {
      const selectors: string[] = [];
      const visitRules = (rules: CSSRuleList) => {
        for (const rule of Array.from(rules)) {
          if (rule instanceof CSSStyleRule) {
            const appRegion = rule.style.getPropertyValue("-webkit-app-region").trim();
            if (
              appRegion === "no-drag" &&
              rule.selectorText.includes(".comma-chat-route")
            ) {
              selectors.push(rule.selectorText);
            }
          } else if ("cssRules" in rule) {
            visitRules((rule as CSSGroupingRule).cssRules);
          }
        }
      };

      for (const sheet of Array.from(document.styleSheets)) {
        visitRules(sheet.cssRules);
      }
      return selectors;
    });
    expect(chatRouteNoDragSelectors).toEqual([".comma-chat-route"]);

    const geometry = await header.evaluate((element) => {
      const headerRect = element.getBoundingClientRect();
      const titleElement = element.querySelector<HTMLElement>(".comma-chat-title")!;
      const titleGroup = titleElement.parentElement!;
      const metadataElement = element.querySelector<HTMLElement>(
        '[data-testid="task-panel-toggle"]'
      )!;
      const titleRect = titleElement.getBoundingClientRect();
      const metadataRect = metadataElement.getBoundingClientRect();
      return {
        dragRegion: getComputedStyle(element, "::before").getPropertyValue(
          "-webkit-app-region"
        ),
        headerRight: headerRect.right,
        hasFixedBackLink: element.querySelector(".comma-chat-back") !== null,
        metadataRight: metadataRect.right,
        titleAppRegion:
          getComputedStyle(titleElement).getPropertyValue("-webkit-app-region"),
        titleGroupAppRegion:
          getComputedStyle(titleGroup).getPropertyValue("-webkit-app-region"),
        titleWidth: titleRect.width,
        windowDragRegion: element.dataset.windowDragRegion,
      };
    });

    const toggleBox = await toggle.boundingBox();
    expect(toggleBox!.x + toggleBox!.width).toBeLessThanOrEqual(geometry.headerRight);

    // A short title must not grow to fill the header: its box hugs its text.
    await page.setViewportSize({ width: 1920, height: 800 });
    await expect
      .poll(async () =>
        title.evaluate((element) => {
          const range = document.createRange();
          range.selectNodeContents(element);
          const textRight = range.getBoundingClientRect().right;
          return Math.round(element.getBoundingClientRect().right - textRight);
        })
      )
      .toBe(0);

    expect(geometry.titleWidth).toBeGreaterThan(0);
    expect(geometry.metadataRight).toBeLessThanOrEqual(geometry.headerRight);
    expect(geometry).toMatchObject({
      dragRegion: "drag",
      hasFixedBackLink: false,
      titleAppRegion: "drag",
      titleGroupAppRegion: "drag",
      windowDragRegion: "true",
    });
  } finally {
    await stub.close();
  }
});

test("terminal Workflow escalation appears in Needs Review", async ({ page }) => {
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    taskStatus: "escalated",
  });

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "workflow-escalation@comma.local",
      token: "comma_sess_workflow_escalation",
    });
    await page.addInitScript((workspaceId) => {
      localStorage.setItem("comma.activeWorkspaceId", workspaceId);
    }, chatSmokeWorkspace.id);
    await page.goto("/#/tasks");

    const tasksRoute = page.getByTestId("tasks-route");
    const task = tasksRoute.getByRole("button", {
      name: chatSmokeTaskConversation.title,
    });
    await expect(task).toBeVisible();
    const columnLabel = await task
      .locator('xpath=ancestor::*[@data-slot="task-board-column"]')
      .locator('[data-slot="task-board-column-label"]')
      .textContent();

    expect(columnLabel).toBe("Needs Review");
  } finally {
    await stub.close();
  }
});

test("archived Tasks stay out of the board and its columns", async ({ page }) => {
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    taskStatus: "archived",
  });

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "archived-task@comma.local",
      token: "comma_sess_archived_task",
    });
    await page.addInitScript((workspaceId) => {
      localStorage.setItem("comma.activeWorkspaceId", workspaceId);
    }, chatSmokeWorkspace.id);
    await page.goto("/#/tasks");

    const tasksRoute = page.getByTestId("tasks-route");
    const task = tasksRoute.getByRole("button", {
      name: chatSmokeTaskConversation.title,
    });
    await expect(tasksRoute).toBeVisible();
    await expect(
      tasksRoute.getByRole("heading", { name: "No tasks", exact: true })
    ).toBeVisible();
    await expect(task).toHaveCount(0);
    await expect(
      tasksRoute.getByRole("heading", { name: "Archived", exact: true })
    ).toHaveCount(0);
  } finally {
    await stub.close();
  }
});

test("task filters keep intrinsic checkbox geometry and list rows show keyboard focus", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    taskAssistantMessages: ["Task started", "Task is running", "Task completed"],
    taskStatus: "active",
  });

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "task-keyboard@comma.local",
      token: "comma_sess_task_keyboard",
    });
    await page.goto("/#/tasks");

    const tasksRoute = page.getByTestId("tasks-route");
    await expect(
      tasksRoute.getByRole("button", { name: chatSmokeTaskConversation.title })
    ).toBeVisible();
    await page.getByRole("button", { name: "Filter tasks" }).click();
    const filterMenu = page.getByRole("menu", { name: "Filter tasks" });
    const statusFilter = filterMenu.getByRole("menuitem", { name: "Status" });
    await statusFilter.click();

    const statusDialog = page.getByRole("dialog", { name: "Status" });
    const doneItem = statusDialog.getByRole("menuitemcheckbox", { name: "Done" });
    const checkboxControl = doneItem.locator('[data-slot="checkbox-control"]');
    const checkGlyph = checkboxControl.locator("span.opacity-100 [data-comma-icon]");
    await expect(checkboxControl).toBeVisible();
    await expect(checkGlyph).toBeVisible();
    await waitForSettledMotion(
      statusDialog.locator('xpath=ancestor::*[@data-slot="menu-popover"][1]')
    );
    const checkboxGeometry = await checkboxControl.evaluate((control) => {
      const glyph = control.querySelector<HTMLElement>(
        "span.opacity-100 [data-comma-icon]"
      );
      if (!glyph) throw new Error("Expected selected checkbox glyph");
      const controlRect = control.getBoundingClientRect();
      const glyphRect = glyph.getBoundingClientRect();
      return {
        control: { height: controlRect.height, width: controlRect.width },
        glyph: { height: glyphRect.height, width: glyphRect.width },
        glyphScale: getComputedStyle(glyph).scale,
      };
    });
    // The design system insets the glyph 12.5% inside the 16px box; it used to
    // be scaled to 24px, painting past the box's own edges.
    expect(checkboxGeometry).toEqual({
      control: { height: 16, width: 16 },
      glyph: { height: 12, width: 12 },
      glyphScale: "1",
    });

    await page.keyboard.press("Escape");
    await expect(statusDialog).toBeHidden();
    await expect(statusFilter).toBeFocused();
    await page.keyboard.press("Escape");
    await expect(filterMenu).toBeHidden();
    await page.getByRole("button", { name: "List view" }).click();
    await page.getByRole("menuitemradio", { name: "List" }).click();

    const row = tasksRoute.getByRole("button", {
      name: chatSmokeTaskConversation.title,
    });
    await expect(row).toBeVisible();
    // The row hosts a selection checkbox, so it is a div playing button (a
    // button may not hold another control): same role, same tab stop.
    expect(await row.evaluate((element) => element.getAttribute("role"))).toBe(
      "button"
    );
    expect(await row.evaluate((element) => (element as HTMLElement).tabIndex)).toBe(0);

    // Establish keyboard modality before script focus so :focus-visible applies.
    await page.keyboard.press("Tab");
    await row.focus();
    await expect(row).toBeFocused();
    await expect
      .poll(() => row.evaluate((element) => getComputedStyle(element).boxShadow))
      .not.toBe("none");

    await page.keyboard.press("Enter");
    await expect(page).toHaveURL(
      new RegExp(
        `#/tasks/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}$`
      )
    );
    await expect(page.getByTestId("inbox-workspace")).toHaveCount(0);
    await expect(
      page.getByRole("heading", {
        level: 1,
        name: chatSmokeTaskConversation.title,
      })
    ).toBeVisible();
    const latestTurn = page.getByTestId("chat-current-turn");
    await expect(page.locator(".comma-chat-turn-shell")).toHaveCount(1);
    await expect(latestTurn).toContainText("Task started");
    await expect(latestTurn).toContainText("Task is running");
    await expect(latestTurn).toContainText("Task completed");
  } finally {
    await stub.close();
  }
});

test("Home Tasks rail opens on a status that holds Tasks", async ({ page }) => {
  // The rail's default bucket is "backlog"; this workspace's only Task is
  // running, so opening on the default would show "No tasks" beside a status
  // switcher that only appears when Tasks exist.
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    taskStatus: "active",
  });

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "home-tasks-rail@comma.local",
      token: "comma_sess_home_tasks_rail",
    });
    await page.goto("/");

    const tasksRail = page.getByTestId("home-tasks-rail");
    await expect(tasksRail).toBeVisible();

    // No interaction: the card is there on arrival.
    await expect(
      tasksRail.getByTestId("home-task-card").filter({
        hasText: chatSmokeTaskConversation.title,
      })
    ).toBeVisible();
    await expect(tasksRail.getByText("No tasks", { exact: true })).toHaveCount(0);
    await expect(tasksRail.locator("status-indicator")).toHaveAttribute(
      "value",
      "in-progress"
    );
  } finally {
    await stub.close();
  }
});

test("the window bar's Recent tasks menu opens the canonical Group route", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({ includeTaskInInbox: true });

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "sidebar-tasks@comma.local",
      token: "comma_sess_sidebar_tasks",
    });
    await page.goto("/#/tasks");

    const tasksLink = page.getByRole("link", { exact: true, name: "Tasks" });
    await expect(tasksLink).toHaveAttribute("aria-current", "page");
    // The rail lists no tasks any more; the window bar's clock menu holds the
    // workspace's most recent ones.
    await expect(page.getByRole("region", { name: "Task collections" })).toHaveCount(0);
    await page
      .getByTestId("comma-window-bar")
      .getByRole("button", { name: "Recent tasks" })
      .click();
    const recentMenu = page.getByRole("menu", { name: "Recent tasks" });
    await expect(recentMenu).toBeVisible();
    const recentTask = recentMenu.getByRole("menuitem", {
      name: chatSmokeTaskConversation.title,
    });
    await expect(recentTask).toBeVisible();
    await recentTask.click();
    await expect(page).toHaveURL(
      new RegExp(
        `#/tasks/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}$`
      )
    );
    await expect(recentMenu).toHaveCount(0);
    await expect(tasksLink).not.toHaveAttribute("aria-current", "page");
    await expect(tasksLink).toHaveAttribute("data-selected", "false");

    await tasksLink.click();
    await expect(page).toHaveURL(/#\/tasks$/);
    await expect(tasksLink).toHaveAttribute("aria-current", "page");
    await expect(tasksLink).toHaveAttribute("data-selected", "true");
  } finally {
    await stub.close();
  }
});

test("an accepted one-shot Task moves from Needs Review to Done", async ({ page }) => {
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    taskSchedule: null,
    taskStatus: "ready_for_review",
  });

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "task-reviewer@comma.local",
      token: "comma_sess_task_reviewer",
    });
    await page.goto(
      `/#/inbox/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`
    );

    const details = await openTaskDetails(page);
    await expect(details.getByTestId("task-conversation-status")).toContainText(
      /Needs Review/
    );
    const inboxTask = page
      .getByTestId("inbox-item")
      .filter({ hasText: chatSmokeTaskConversation.title });
    await expect(inboxTask).toHaveAttribute("data-task-status", "ready_for_review");
    await expect.poll(() => stub.activeTaskListEventStreams).toBeGreaterThan(0);
    await expect
      .poll(() => stub.conversationListRequestCount)
      .toBeGreaterThanOrEqual(2);
    const taskListEventStreamsBeforeFailure = stub.taskListEventStreamRequestCount;
    // The route's details panel owns the review; the transcript carries no action.
    const done = taskDoneButton(details);
    await expect(done).toBeVisible();
    await expect(page.getByTestId("task-review-action")).toHaveCount(0);

    stub.failNextConversationListRead();
    await done.click();
    await stub.waitForFailedConversationListRead();
    await expect(
      (await openTaskDetails(page)).getByTestId("task-conversation-status")
    ).toContainText(/Done/);
    await expect(done).toHaveCount(0);
    expect(stub.taskAcceptRequestCount).toBe(1);
    await expect(inboxTask).toHaveAttribute("data-task-status", "completed");
    await expect
      .poll(() => stub.taskListEventStreamRequestCount)
      .toBeGreaterThan(taskListEventStreamsBeforeFailure);
    await page.goto("/#/tasks");
    const task = page.getByTestId("tasks-route").getByRole("button", {
      name: chatSmokeTaskConversation.title,
    });
    await expect(task).toBeVisible();
    await expect(
      task
        .locator('xpath=ancestor::*[@data-slot="task-board-column"]')
        .locator('[data-slot="task-board-column-label"]')
    ).toHaveText(/Done|已完成/);
  } finally {
    await stub.close();
  }
});

test("a stale Task accept refreshes the canonical review version before retry", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    taskAcceptConflictOnce: true,
    taskSchedule: null,
    taskStatus: "ready_for_review",
  });

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "stale-task-reviewer@comma.local",
      token: "comma_sess_stale_task_reviewer",
    });
    await page.goto(
      `/#/inbox/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`
    );

    const accept = taskDoneButton(await openTaskDetails(page));
    const detailReadsBeforeAccept = stub.taskDetailRequestCount;
    await accept.click();
    // The SharedWorker owns this request, outside page response events.
    await expect.poll(() => stub.taskAcceptRequestCount).toBe(1);
    await expect
      .poll(() => stub.taskDetailRequestCount)
      .toBeGreaterThan(detailReadsBeforeAccept);

    await expect(accept).toBeEnabled();
    expect(stub.taskAcceptRequestCount).toBe(1);

    await accept.click();
    await expect(
      (await openTaskDetails(page)).getByTestId("task-conversation-status")
    ).toContainText(/Done/);
    await expect(accept).toHaveCount(0);
    expect(stub.taskAcceptRequestCount).toBe(2);
  } finally {
    await stub.close();
  }
});

test("Appearance Custom theme is edited from Settings and restored after reload", async ({
  page,
}) => {
  const stub = await startChatSmokeStub();

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "custom-theme@comma.local",
      token: "comma_sess_custom_theme",
    });
    await page.goto("/#/settings");
    await page.getByRole("button", { name: "Appearance" }).click();
    const themeTrigger = page.getByRole("button", { name: /Select theme/ });
    await themeTrigger.click();
    const selectedThemeOption = page.getByRole("option", { name: "Default" });
    await expect(themeTrigger).toHaveClass(/opacity-0/);
    await expect(page.locator('[data-slot="dropdown-popover"]')).toHaveAttribute(
      "data-positioning",
      "selection-aligned"
    );
    await expect
      .poll(() =>
        Promise.all([
          themeTrigger.evaluate((element) => element.getBoundingClientRect().top),
          selectedThemeOption.evaluate(
            (element) => element.getBoundingClientRect().top
          ),
        ]).then(([triggerTop, optionTop]) => Math.abs(optionTop - triggerTop))
      )
      .toBeLessThanOrEqual(1);
    const customOption = page.getByRole("option", { name: "Custom" });
    await customOption.click();

    const studio = page.getByRole("dialog", { name: "Custom", exact: true });
    await expect(studio).toBeVisible();
    await expect(customOption).toBeHidden();
    await waitForSettledMotion(studio);
    await expect(themeTrigger).toHaveAttribute("aria-label", "Select theme: Custom");
    const back = studio.getByRole("button", { name: "Back to themes" });
    await expect(back).toBeFocused();

    // The studio popover raises its own focus scope inside the settings modal,
    // and both scopes step the first Tab, so it skips Auto. Light and Dark come
    // before the channel row.
    for (let step = 0; step < 5; step += 1) await page.keyboard.press("Tab");
    const keyboardHue = studio.getByRole("slider", { name: "Hue" });
    await expect(keyboardHue).toBeFocused();
    const keyboardHueStart = Number(await keyboardHue.getAttribute("aria-valuenow"));
    await page.keyboard.press("ArrowUp");
    await expect(keyboardHue).toHaveAttribute(
      "aria-valuenow",
      String(keyboardHueStart + 1)
    );
    await page.keyboard.press("ArrowDown");
    await expect(keyboardHue).toHaveAttribute(
      "aria-valuenow",
      String(keyboardHueStart)
    );
    await page.keyboard.press("ArrowRight");
    await expect(keyboardHue).toHaveAttribute(
      "aria-valuenow",
      String(keyboardHueStart + 1)
    );
    await page.keyboard.press("ArrowLeft");
    await expect(keyboardHue).toHaveAttribute(
      "aria-valuenow",
      String(keyboardHueStart)
    );
    await page.keyboard.press("Home");
    await expect(keyboardHue).toHaveAttribute("aria-valuenow", "0");
    await page.keyboard.press("ArrowLeft");
    await expect(keyboardHue).toHaveAttribute("aria-valuenow", "0");
    await page.keyboard.press("ArrowDown");
    await expect(keyboardHue).toHaveAttribute("aria-valuenow", "0");
    await page.keyboard.press("End");
    await expect(keyboardHue).toHaveAttribute("aria-valuenow", "360");
    await page.keyboard.press("ArrowRight");
    await expect(keyboardHue).toHaveAttribute("aria-valuenow", "360");
    await page.keyboard.press("ArrowUp");
    await expect(keyboardHue).toHaveAttribute("aria-valuenow", "360");
    await expect(keyboardHue).toHaveAttribute("aria-valuemax", "360");
    await page.keyboard.press("Home");
    await expect(keyboardHue).toHaveAttribute("aria-valuenow", "0");
    for (let step = 0; step < 6; step += 1) await page.keyboard.press("Shift+Tab");
    await expect(back).toBeFocused();
    await page.keyboard.press("Enter");
    await expect(page.locator('[data-slot="menu-popover"]')).toHaveCount(0);
    await page.evaluate(
      () =>
        new Promise<void>((resolve) => {
          requestAnimationFrame(() => requestAnimationFrame(() => resolve()));
        })
    );
    await expect(page.locator('[data-slot="dropdown-popover"]')).toHaveAttribute(
      "data-anchor-index",
      "5"
    );
    await expect(customOption).toBeFocused();
    await page.keyboard.press("ArrowUp");
    const signalDarkOption = page.getByRole("option", { name: "Signal Dark" });
    await expect(signalDarkOption).toBeFocused();

    // Return to Custom for the rest of this scenario after the keyboard-only path.
    await signalDarkOption.click();
    await themeTrigger.click();
    await customOption.click();
    await expect(studio).toBeVisible();

    // Mutation records retain intermediate values, including a synchronous
    // clear-and-restore that a final DOM assertion or frame sample would miss.
    const themeMutations = await page.evaluateHandle(() => {
      const records: MutationRecord[] = [];
      const observer = new MutationObserver((mutations) => records.push(...mutations));
      observer.observe(document.documentElement, {
        attributes: true,
        attributeOldValue: true,
        attributeFilter: [
          "data-theme",
          "data-comma-theme",
          "data-comma-font-size",
          "data-comma-pointer-cursors",
          "data-comma-reduced-motion",
          "style",
        ],
      });
      return { observer, records };
    });

    await studio.getByRole("button", { name: "Light" }).click();

    const lightness = studio.getByRole("slider", { name: "Lightness" });
    const chroma = studio.getByRole("slider", { name: "Chroma" });
    const hue = studio.getByRole("slider", { name: "Hue" });
    await lightness.focus();
    const lightnessBefore = await lightness.getAttribute("aria-valuenow");
    await page.keyboard.press("End");
    await expect(lightness).not.toHaveAttribute("aria-valuenow", lightnessBefore ?? "");
    await expect(lightness).toHaveAttribute(
      "aria-valuenow",
      String(Math.round(commaThemeLightnessMax * 100))
    );

    const description = studio.getByText(
      "Drag any indicator to move the color. The other two follow on their own planes."
    );
    expect(await contrastOfPrimaryTextOnPrimaryBg(page)).toBeGreaterThanOrEqual(4.5);
    expect(await contrastAgainstPaintedBackground(description)).toBeGreaterThanOrEqual(
      3
    );

    await hue.focus();
    const hueBeforeKeyboard = await hue.getAttribute("aria-valuenow");
    await page.keyboard.press("ArrowRight");
    await expect(hue).not.toHaveAttribute("aria-valuenow", hueBeforeKeyboard ?? "");

    await chroma.focus();
    const chromaBeforeKeyboard = await chroma.getAttribute("aria-valuenow");
    await page.keyboard.press("ArrowUp");
    await expect(chroma).not.toHaveAttribute(
      "aria-valuenow",
      chromaBeforeKeyboard ?? ""
    );

    await studio.getByRole("button", { name: "Dark" }).click();
    await expect(page.locator("html")).toHaveAttribute("data-theme", "Dark mode");
    await lightness.focus();
    await page.keyboard.press("Home");
    await expect(lightness).toHaveAttribute(
      "aria-valuenow",
      String(Math.round(commaThemeLightnessMin * 100))
    );
    expect(await contrastOfPrimaryTextOnPrimaryBg(page)).toBeGreaterThanOrEqual(4.5);
    expect(await contrastAgainstPaintedBackground(description)).toBeGreaterThanOrEqual(
      3
    );

    const pad = studio.getByRole("group", { name: "Hue, chroma, and lightness pad" });
    const box = await pad.boundingBox();
    expect(box).not.toBeNull();
    // The mode switch sits above the pad, so it never covers an indicator.
    const schemeBox = await studio.getByRole("button", { name: "Auto" }).boundingBox();
    expect(schemeBox!.y + schemeBox!.height).toBeLessThanOrEqual(box!.y);
    const channelValues = async () => ({
      chroma: await chroma.getAttribute("aria-valuenow"),
      hue: await hue.getAttribute("aria-valuenow"),
      lightness: await lightness.getAttribute("aria-valuenow"),
    });
    const beforeDrag = await channelValues();
    // Restyling the app restyles the whole document (about 250 ms with Settings
    // open), so a drag previews in the studio and writes the theme on release.
    const dragThemeWrites = await page.evaluateHandle(() => {
      const root = document.documentElement;
      const read = () =>
        ["--comma-theme-h", "--comma-theme-c", "--comma-theme-l"]
          .map((property) => root.style.getPropertyValue(property))
          .join(" ");
      const state = {
        count: 0,
        last: read(),
        observer: null as MutationObserver | null,
      };
      state.observer = new MutationObserver(() => {
        const next = read();
        if (next === state.last) return;
        state.last = next;
        state.count += 1;
      });
      state.observer.observe(root, { attributes: true, attributeFilter: ["style"] });
      return state;
    });
    await page.mouse.move(box!.x + box!.width * 0.2, box!.y + box!.height * 0.55);
    await page.mouse.down();
    await page.mouse.move(box!.x + box!.width * 0.85, box!.y + box!.height * 0.2, {
      steps: 8,
    });
    const duringDrag = await channelValues();
    expect(duringDrag).not.toEqual(beforeDrag);
    expect(await dragThemeWrites.evaluate((state) => state.count)).toBe(0);
    await page.mouse.up();
    await expect.poll(() => dragThemeWrites.evaluate((state) => state.count)).toBe(1);
    await dragThemeWrites.evaluate((state) => state.observer?.disconnect());
    await dragThemeWrites.dispose();
    expect(await channelValues()).toEqual(duringDrag);
    expect(
      await page.evaluate(() =>
        Math.round(
          Number.parseFloat(
            document.documentElement.style.getPropertyValue("--comma-theme-h")
          )
        )
      )
    ).toBe(Number(duringDrag.hue));

    const themeGaps = await themeMutations.evaluate(({ observer, records }) => {
      records.push(...observer.takeRecords());
      observer.disconnect();
      const styleProbe = document.createElement("div");
      return records
        .filter((record) => {
          if (record.attributeName !== "style") return record.oldValue === null;
          styleProbe.setAttribute("style", record.oldValue ?? "");
          return ["--comma-theme-h", "--comma-theme-c", "--comma-theme-l"].some(
            (property) => !styleProbe.style.getPropertyValue(property)
          );
        })
        .map((record) => ({ attribute: record.attributeName, value: record.oldValue }));
    });
    await themeMutations.dispose();
    expect(themeGaps).toEqual([]);

    await studio.getByRole("button", { name: "Auto" }).click();
    await page.emulateMedia({ colorScheme: "dark" });
    await expect(page.locator("html")).toHaveAttribute("data-theme", "Dark mode");
    const stored = await page.evaluate(
      () =>
        JSON.parse(localStorage.getItem("comma.client-settings") ?? "null")?.appearance
    );
    expect(stored).toMatchObject({
      theme: "custom",
      customScheme: "system",
    });

    await page.reload();
    await expect(page.locator("html")).toHaveAttribute("data-theme", "Dark mode");
    await page.emulateMedia({ colorScheme: "light" });
    await expect(page.locator("html")).toHaveAttribute("data-theme", "Light mode");
    await page.getByRole("button", { name: "Appearance" }).click();
    await expect(page.getByRole("button", { name: /Select theme/ })).toHaveAttribute(
      "aria-label",
      "Select theme: Custom"
    );
    await expect(page.getByRole("button", { name: /Select theme/ })).toContainText(
      "Custom"
    );
    await page.getByRole("button", { name: /Select theme/ }).click();
    await expect(
      page.getByRole("dialog", { name: "Custom", exact: true })
    ).toBeVisible();
    const restored = await page.evaluate(
      () =>
        JSON.parse(localStorage.getItem("comma.client-settings") ?? "null")?.appearance
    );
    expect(restored).toMatchObject({
      theme: "custom",
      customScheme: "system",
      customHue: stored.customHue,
      customChroma: stored.customChroma,
      customLightness: stored.customLightness,
    });
  } finally {
    await stub.close();
  }
});

test("pointer cursor preference covers visible controls and restores after reload", async ({
  page,
}) => {
  const stub = await startChatSmokeStub();
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "pointer-cursors@comma.local",
      token: "comma_sess_pointer_cursors",
    });
    await page.goto("/#/settings");
    await page.getByRole("button", { name: "Appearance", exact: true }).click();
    const preference = page.getByRole("switch", { name: "Use pointer cursors" });
    const row = page.locator('[data-setting-id="appearance.pointer-cursors"]');
    const label = row.locator("label");
    const track = row.locator('[data-slot="toggle-base"]');
    const theme = page.getByRole("button", { name: /Select theme/ });

    await expect(preference).not.toBeChecked();
    await track.click();
    await expect(preference).toBeChecked();
    await expect(page.locator("html")).toHaveAttribute(
      "data-comma-pointer-cursors",
      "true"
    );
    // React Aria's input is visually hidden. Its surrounding label and
    // visible track, not just the input, are the actual pointer hit regions.
    await label.hover();
    await expect(label).toHaveCSS("cursor", "pointer");
    await expect(track).toHaveCSS("cursor", "pointer");
    await expect(theme).toHaveCSS("cursor", "pointer");
    await expect(theme.locator("svg").first()).toHaveCSS("cursor", "pointer");
    // A child with its own cursor must follow the preference across its hit area.
    // Previously only the button changed, leaving this child with an arrow.
    const themeIcon = theme.locator("svg").first();
    await themeIcon.evaluate((element) => {
      element.style.cursor = "default";
    });
    await expect(themeIcon).toHaveCSS("cursor", "pointer");
    await themeIcon.evaluate((element) => element.style.removeProperty("cursor"));
    // The Custom theme pad is a drag surface, not a native control, so it
    // previously kept the arrow while every button around it followed.
    await theme.click();
    await page.getByRole("option", { name: "Custom" }).click();
    const studio = page.getByRole("dialog", { name: "Custom", exact: true });
    await expect(
      studio.getByRole("group", { name: "Hue, chroma, and lightness pad" })
    ).toHaveCSS("cursor", "pointer");
    await studio.getByRole("button", { name: "Back to themes" }).click();
    await page.getByRole("option", { name: "Default", exact: true }).click();
    await expect(page.locator("html")).toHaveAttribute("data-comma-theme", "default");
    await expect(page.locator("button:disabled").first()).not.toHaveCSS(
      "cursor",
      "pointer"
    );
    await expect(page.locator("[data-comma-functional-cursor]").first()).toHaveCSS(
      "cursor",
      "col-resize"
    );

    await page.reload();
    await page.getByRole("button", { name: "Appearance", exact: true }).click();
    await expect(preference).toBeChecked();
    await expect(label).toHaveCSS("cursor", "pointer");
    await track.click();
    await expect(preference).not.toBeChecked();
    await expect(label).toHaveCSS("cursor", "default");
    await expect(track).toHaveCSS("cursor", "default");
    await expect(theme).toHaveCSS("cursor", "default");
    await theme.click();
    const option = page.getByRole("option", { name: "Default", exact: true });
    await expect(option).toBeVisible();
    await expect(option).toHaveCSS("cursor", "default");
    await expect(option.locator("span").last()).toHaveCSS("cursor", "default");
    await page.keyboard.press("Escape");
    await expect(page.locator("[data-comma-functional-cursor]").first()).toHaveCSS(
      "cursor",
      "col-resize"
    );
  } finally {
    await stub.close();
  }
});

test("reduce motion minimizes animation and restores the persisted setting", async ({
  page,
}) => {
  const stub = await startChatSmokeStub();

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "reduce-motion@comma.local",
      token: "comma_sess_reduce_motion",
    });
    await page.goto("/#/settings");
    await page.getByRole("button", { name: "Appearance" }).click();

    const reduceMotion = page.getByRole("switch", { name: "Reduce motion" });
    const reduceMotionRow = page.locator(
      '[data-setting-id="appearance.reduce-motion"]'
    );
    const reduceMotionControl = reduceMotionRow.locator(
      '[data-slot="settings-control"] .cursor-pointer'
    );
    const reduceMotionThumb = reduceMotionRow.locator(".comma-toggle-thumb-motion");

    await expect(reduceMotion).not.toBeChecked();
    // Both knob edges are transitioned; the trailing one also carries the lag
    // that produces the stretch.
    await expect(reduceMotionThumb).toHaveCSS("transition-duration", "0.12s, 0.12s");
    await expect(reduceMotionThumb).toHaveCSS("transition-delay", "0s, 0.03s");
    await reduceMotionControl.click();

    await expect(reduceMotion).toBeChecked();
    await expect(page.locator("html")).toHaveAttribute(
      "data-comma-reduced-motion",
      "true"
    );
    await expect
      .poll(() =>
        reduceMotionThumb.evaluate((element) =>
          Number.parseFloat(getComputedStyle(element).transitionDuration)
        )
      )
      .toBeLessThanOrEqual(0.00001);
    expect(
      await page.evaluate(
        () =>
          JSON.parse(localStorage.getItem("comma.client-settings") ?? "null")
            ?.appearance
      )
    ).toEqual({
      fontFamily: null,
      fontSize: "default",
      pointerCursors: false,
      reducedMotion: true,
      theme: "default",
      customHue: 263,
      customChroma: defaultCustomChroma,
      customScheme: "system",
      customLightness: commaThemeLightnessNeutral,
    });

    await page.evaluate(() => {
      const originalScrollIntoView = HTMLElement.prototype.scrollIntoView;
      HTMLElement.prototype.scrollIntoView = function scrollIntoView(options) {
        document.body.dataset.e2eSettingsScrollBehavior =
          typeof options === "object" && options?.behavior ? options.behavior : "unset";
        return originalScrollIntoView.call(this, options);
      };
    });
    await page.getByRole("searchbox", { name: "Search settings" }).fill("locale");
    await page.getByRole("button", { name: /Language.*locale/ }).click();
    await expect(page.locator("body")).toHaveAttribute(
      "data-e2e-settings-scroll-behavior",
      "auto"
    );
    await expect(page.locator('[data-setting-id="app.language"]')).toBeFocused();

    await page.reload();
    await page.getByRole("button", { name: "Appearance" }).click();
    await expect(page.getByRole("switch", { name: "Reduce motion" })).toBeChecked();
    await expect(page.locator("html")).toHaveAttribute(
      "data-comma-reduced-motion",
      "true"
    );
  } finally {
    await stub.close();
  }
});

test("system reduced motion is effective without changing the manual preference", async ({
  page,
}) => {
  const stub = await startChatSmokeStub();

  try {
    await page.emulateMedia({ reducedMotion: "reduce" });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "system-reduce-motion@comma.local",
      token: "comma_sess_system_reduce_motion",
    });
    await page.goto("/#/settings");
    await page.getByRole("button", { name: "Appearance" }).click();

    await expect(page.locator("html")).toHaveAttribute(
      "data-comma-reduced-motion",
      "true"
    );
    await expect(page.getByRole("switch", { name: "Reduce motion" })).not.toBeChecked();
    expect(
      await page.evaluate(() => localStorage.getItem("comma.appearance"))
    ).toBeNull();

    const pulseMotion = await page.evaluate(() => {
      const pulse = document.createElement("span");
      pulse.className = "comma-chat-pulse-dot";
      document.body.append(pulse);
      const style = getComputedStyle(pulse, "::after");
      return {
        animationDuration: Number.parseFloat(style.animationDuration),
        animationIterationCount: style.animationIterationCount,
      };
    });
    expect(pulseMotion.animationDuration).toBeLessThanOrEqual(0.00001);
    expect(pulseMotion.animationIterationCount).toBe("1");
  } finally {
    await stub.close();
  }
});

test("font size preference scales core conversation typography without changing icon geometry", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    taskAssistantReply: "Core conversation typography",
  });

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "font-size@comma.local",
      token: "comma_sess_font_size",
    });
    const conversationUrl = `/#/inbox/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`;
    await page.goto(conversationUrl);

    const assistantMessage = page.locator(".comma-chat-message-assistant").first();
    await expect(assistantMessage).toBeVisible();
    const defaultFontSize = await assistantMessage.evaluate((element) =>
      Number.parseFloat(getComputedStyle(element).fontSize)
    );

    await page.goto("/#/settings");
    await expectSettledSettingsModal(page);
    await expect(page.locator("html")).toHaveAttribute(
      "data-comma-font-size",
      "default"
    );
    const computerUseButton = page.getByRole("button", { name: "Computer use" });
    const mixedStrokeIcon = computerUseButton.locator("svg[data-comma-icon]");
    await expect(mixedStrokeIcon).toBeVisible();
    const readMixedStrokeIcon = () =>
      mixedStrokeIcon.evaluate((element) => {
        const readStroke = (nominal: string) => {
          const shape = element.querySelector(`[stroke-width="${nominal}"]`);
          if (!shape) throw new Error(`Missing stroke-width=${nominal}`);
          const computed = getComputedStyle(shape).getPropertyValue("stroke-width");
          return {
            computed: Number(computed.match(/[\d.]+/)?.[0]),
            nominal: Number(shape.getAttribute("stroke-width")),
          };
        };

        return {
          stroke075: readStroke("0.75"),
          stroke2: readStroke("2"),
          globalStroke: Number(
            getComputedStyle(element).getPropertyValue("--comma-icon-stroke-width")
          ),
          scale: getComputedStyle(element).scale,
          width: element.getBoundingClientRect().width,
        };
      });
    const readActionRect = () =>
      computerUseButton.evaluate((element) => {
        const { height, width } = element.getBoundingClientRect();
        return {
          clientHeight: element.clientHeight,
          height,
          scrollHeight: element.scrollHeight,
          rootFontSize: Number.parseFloat(
            getComputedStyle(document.documentElement).fontSize
          ),
          width,
        };
      });
    const defaultIcon = await readMixedStrokeIcon();
    expect(defaultIcon.globalStroke).toBe(iconStrokeWidth);
    expect(defaultIcon.scale).toBe("1");
    expect(defaultIcon.stroke2.computed).toBeCloseTo(iconStrokeWidth, 4);
    expect(defaultIcon.stroke075.computed).toBeCloseTo(0.75, 4);
    const defaultActionRect = await readActionRect();
    // Compact category rows are 1.75rem, so their height follows font size.
    // Labels must remain contained while icon geometry stays unchanged.
    expect(defaultActionRect.height).toBeCloseTo(
      1.75 * defaultActionRect.rootFontSize,
      1
    );
    expect(defaultActionRect.scrollHeight).toBeLessThanOrEqual(
      defaultActionRect.clientHeight
    );

    await page.getByRole("button", { name: "Appearance" }).click();
    await page.getByRole("button", { name: /Select font size/ }).click();
    await page.getByRole("option", { name: "Small" }).click();
    await expect(page.locator("html")).toHaveAttribute("data-comma-font-size", "small");
    await expect
      .poll(async () => (await readMixedStrokeIcon()).width)
      .toBeCloseTo(defaultIcon.width, 1);
    const smallIcon = await readMixedStrokeIcon();
    expect(smallIcon.globalStroke).toBe(iconStrokeWidth);
    expect(smallIcon.scale).toBe("1");
    expect(smallIcon.stroke2.nominal).toBe(defaultIcon.stroke2.nominal);
    expect(smallIcon.stroke075.nominal).toBe(defaultIcon.stroke075.nominal);
    expect(smallIcon.stroke2.computed).toBeCloseTo(defaultIcon.stroke2.computed, 4);
    expect(smallIcon.stroke075.computed).toBeCloseTo(0.75, 4);
    const smallActionRect = await readActionRect();
    expect(smallActionRect.width).toBe(defaultActionRect.width);
    expect(smallActionRect.height).toBeCloseTo(1.75 * smallActionRect.rootFontSize, 1);
    expect(smallActionRect.scrollHeight).toBeLessThanOrEqual(
      smallActionRect.clientHeight
    );

    await page.getByRole("button", { name: /Select font size/ }).click();
    await page.getByRole("option", { name: "Large" }).click();
    await expect(page.locator("html")).toHaveAttribute("data-comma-font-size", "large");
    await expect
      .poll(async () => (await readMixedStrokeIcon()).width)
      .toBeCloseTo(defaultIcon.width, 1);
    const largeIcon = await readMixedStrokeIcon();
    expect(largeIcon.globalStroke).toBe(iconStrokeWidth);
    expect(largeIcon.scale).toBe("1");
    expect(largeIcon.stroke2.nominal).toBe(defaultIcon.stroke2.nominal);
    expect(largeIcon.stroke075.nominal).toBe(defaultIcon.stroke075.nominal);
    expect(largeIcon.stroke2.computed).toBeCloseTo(defaultIcon.stroke2.computed, 4);
    expect(largeIcon.stroke075.computed).toBeCloseTo(0.75, 4);
    const largeActionRect = await readActionRect();
    expect(largeActionRect.width).toBe(defaultActionRect.width);
    expect(largeActionRect.height).toBeCloseTo(1.75 * largeActionRect.rootFontSize, 1);
    expect(largeActionRect.scrollHeight).toBeLessThanOrEqual(
      largeActionRect.clientHeight
    );

    const fontSizeTrigger = page.getByRole("button", { name: /Select font size/ });
    const dropdownCollisionPadding = await page
      .locator("html")
      .evaluate((element) =>
        Number.parseFloat(getComputedStyle(element).getPropertyValue("--spacing-lg"))
      );
    await fontSizeTrigger.click();
    const selectedLargeOption = page.getByRole("option", { name: "Large" });
    await expect
      .poll(() =>
        Promise.all([
          fontSizeTrigger.evaluate((element) => element.getBoundingClientRect().top),
          selectedLargeOption.evaluate(
            (element) => element.getBoundingClientRect().top
          ),
        ]).then(([triggerTop, optionTop]) => Math.abs(optionTop - triggerTop))
      )
      .toBeLessThanOrEqual(1);
    await page.keyboard.press("Escape");
    await expect(fontSizeTrigger).toHaveAttribute("aria-expanded", "false");
    await expect(page.locator('[data-slot="dropdown-popover"]')).toHaveCount(0);

    await page.setViewportSize({ width: 1280, height: 180 });
    await fontSizeTrigger.evaluate((element, targetTop) => {
      const panel = element.closest('[data-slot="settings-panel"]');
      const viewport = panel?.querySelector<HTMLElement>(
        '[data-slot="scroll-area-viewport"]'
      );

      if (!viewport) {
        throw new Error("Missing Settings scroll viewport");
      }

      viewport.scrollTop += element.getBoundingClientRect().top - targetTop;
    }, dropdownCollisionPadding);
    await expect
      .poll(() =>
        fontSizeTrigger.evaluate((element) => element.getBoundingClientRect().top)
      )
      .toBeLessThanOrEqual(dropdownCollisionPadding + 1);

    await fontSizeTrigger.click();
    const constrainedPopover = page.locator('[data-slot="dropdown-popover"]');
    await expect(constrainedPopover).toHaveAttribute(
      "data-viewport-constrained",
      "true"
    );
    await expect
      .poll(() =>
        constrainedPopover.evaluate((element) => element.getBoundingClientRect().top)
      )
      .toBeGreaterThanOrEqual(dropdownCollisionPadding - 1);

    await waitForSettledMotion(constrainedPopover);
    await expect(
      page.getByRole("option", { name: "Large", exact: true })
    ).toBeFocused();
    await page.keyboard.press("ArrowUp");
    await page.keyboard.press("ArrowUp");
    const firstFontSizeOption = page.getByRole("option", { name: "Small" });
    await expect(firstFontSizeOption).toBeFocused();
    const firstOptionRect = await firstFontSizeOption.evaluate((element) => {
      const { bottom, top } = element.getBoundingClientRect();
      return { bottom, top };
    });
    expect(firstOptionRect.top).toBeGreaterThanOrEqual(dropdownCollisionPadding - 1);
    expect(firstOptionRect.bottom).toBeLessThanOrEqual(
      page.viewportSize()!.height - dropdownCollisionPadding + 1
    );
    await page.keyboard.press("Enter");
    await expect(page.locator("html")).toHaveAttribute("data-comma-font-size", "small");

    await fontSizeTrigger.click();
    await page.getByRole("option", { name: "Large" }).click();
    await expect(page.locator("html")).toHaveAttribute("data-comma-font-size", "large");
    await page.setViewportSize({ width: 1280, height: 800 });

    await page.goto(conversationUrl);

    await expect
      .poll(() =>
        assistantMessage.evaluate((element) =>
          Number.parseFloat(getComputedStyle(element).fontSize)
        )
      )
      .toBeGreaterThan(defaultFontSize);
  } finally {
    await stub.close();
  }
});

test("font preference sets the whole client in an installed family", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    taskAssistantReply: "Installed family typography",
  });

  try {
    // Without a granted permission, the list is read when the menu opens.
    await page.addInitScript(() => {
      Object.defineProperty(window, "queryLocalFonts", {
        value: async () => [{ family: "Georgia" }, { family: "Avenir Next" }],
      });
    });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "font-family@comma.local",
      token: "comma_sess_font_family",
    });
    await page.goto("/#/settings");
    await expectSettledSettingsModal(page);
    await page.getByRole("button", { name: "Appearance" }).click();
    const fontTrigger = page.getByRole("button", { name: /Select font$/ });
    await expect(fontTrigger).toHaveText("Default");
    await fontTrigger.click();
    const georgia = page.getByRole("option", { name: "Georgia" });
    await expect(georgia.locator('[data-slot="dropdown-option-label"]')).toHaveCSS(
      "font-family",
      /^"?Georgia"?, "?Inter Variable"?/
    );
    await georgia.click();
    await expect(page.locator("html")).toHaveAttribute(
      "data-comma-font-family",
      "Georgia"
    );

    await page.goto(
      `/#/inbox/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`
    );
    const assistantMessage = page.locator(".comma-chat-message-assistant").first();
    await expect(assistantMessage).toBeVisible();
    await expect(assistantMessage).toHaveCSS(
      "font-family",
      /^"?Georgia"?, "?Inter Variable"?/
    );
    // Inter's optical 450 would select an installed family's Medium face.
    await expect(assistantMessage).toHaveCSS("font-weight", "400");

    await page.reload();
    await expect(page.locator("html")).toHaveAttribute(
      "data-comma-font-family",
      "Georgia"
    );
    await expect(assistantMessage).toHaveCSS(
      "font-family",
      /^"?Georgia"?, "?Inter Variable"?/
    );

    // Toasts too, although sonner sets its own stack. A failed workspace
    // read on a fresh load raises the Plugins load error as a toast.
    await page.route(`${stub.baseUrl}/v1/comma/workspaces`, (route) =>
      route.abort("connectionrefused")
    );
    await page.goto("/#/plugins");
    await page.reload();
    await expect(
      page.getByRole("button", { name: "Dismiss notification" }).first()
    ).toBeVisible();
    await expect(page.locator("[data-sonner-toaster]")).toHaveCSS(
      "font-family",
      /^"?Georgia"?, "?Inter Variable"?/
    );
  } finally {
    await stub.close();
  }
});

test("task header remains visible after the sidebar collapses", async ({ page }) => {
  const stub = await startChatSmokeStub();

  try {
    await page.setViewportSize({ width: 860, height: 700 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "transition-ownership@comma.local",
      token: "comma_sess_transition_ownership",
    });
    await page.goto(
      `/#/inbox/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`
    );

    const title = page.getByRole("heading", {
      level: 1,
      name: chatSmokeTaskConversation.title,
    });
    const slot = page.getByTestId("comma-sidebar-slot");
    await expect(slot).toHaveAttribute("data-collapsed", "false");
    await expect(page.getByRole("complementary", { name: "Chat" })).toHaveCount(0);
    await expect(title).toBeVisible();
    await expect(page.locator(".comma-chat-back")).toHaveCount(0);

    await page.locator(".comma-sidebar-edge-toggle").click();
    await expect(slot).toHaveAttribute("data-collapsed", "true");
    await expect.poll(async () => (await slot.boundingBox())?.width ?? -1).toBe(8);
    await expect(title).toBeVisible();
  } finally {
    await stub.close();
  }
});

test("minimum-width Inbox keeps its rail and filter usable without a global Chat Rail", async ({
  page,
}) => {
  const stub = await startChatSmokeStub();

  try {
    await page.setViewportSize({ width: 900, height: 700 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "minimum-inbox@comma.local",
      token: "comma_sess_minimum_inbox",
    });
    await page.goto("/#/inbox");

    const rail = page.getByTestId("inbox-conversation-rail");
    const trigger = page.getByTestId("inbox-filter-trigger");
    await expect(page.getByTestId("inbox-source")).toBeVisible();
    await expect(page.getByRole("complementary", { name: "Chat" })).toHaveCount(0);
    await expect(rail).toBeVisible();
    await expect(trigger).toBeVisible();

    const geometry = await trigger.evaluate((element) => {
      const inboxRail = element.closest<HTMLElement>(
        '[data-testid="inbox-conversation-rail"]'
      )!;
      const content = document.querySelector<HTMLElement>(".comma-content")!;
      const triggerRect = element.getBoundingClientRect();
      const railRect = inboxRail.getBoundingClientRect();
      const contentRect = content.getBoundingClientRect();
      const x = triggerRect.left + triggerRect.width / 2;
      const y = triggerRect.top + triggerRect.height / 2;
      return {
        contentRight: contentRect.right,
        inboxRight: railRect.right,
        topmostTrigger:
          document
            .elementFromPoint(x, y)
            ?.closest('[data-testid="inbox-filter-trigger"]') === element,
        x,
        y,
      };
    });
    expect.soft(geometry.inboxRight).toBeLessThanOrEqual(geometry.contentRight);
    expect.soft(geometry.topmostTrigger).toBe(true);
    await page.mouse.click(geometry.x, geometry.y);
    await expect(trigger).toHaveAttribute("aria-expanded", "true");
    await expect(page.getByRole("menuitem", { name: /Task status/ })).toBeVisible();
  } finally {
    await stub.close();
  }
});

test("responsive conversation navigation uses titlebar history controls", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({ includeTaskInInbox: true });

  try {
    await page.setViewportSize({ width: 861, height: 700 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "responsive-route@comma.local",
      token: "comma_sess_responsive_route",
    });
    await page.goto("/#/inbox");
    await page
      .getByTestId("inbox-item")
      .filter({ hasText: chatSmokeTaskConversation.title })
      .click();
    await expect(page).toHaveURL(
      new RegExp(
        `#/inbox/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}$`
      )
    );

    const inboxWorkspace = page.getByTestId("inbox-workspace");
    const inboxRail = inboxWorkspace.getByTestId("inbox-conversation-rail");
    const detailPane = inboxWorkspace.getByTestId("inbox-detail-pane");
    await expect(inboxRail).toBeVisible();
    await expect(
      detailPane.getByRole("heading", {
        level: 1,
        name: chatSmokeTaskConversation.title,
      })
    ).toBeVisible();
    await expect
      .poll(async () => {
        const railBox = await inboxRail.boundingBox();
        const detailBox = await detailPane.boundingBox();
        return Boolean(
          railBox && detailBox && detailBox.x >= railBox.x + railBox.width - 1
        );
      })
      .toBe(true);

    await expect(page.locator(".comma-chat-back")).toHaveCount(0);

    const titlebarBack = page.getByRole("button", { name: "Back" });
    await expect(titlebarBack).toBeEnabled();
    await expect
      .poll(() =>
        titlebarBack.evaluate((element) => {
          const rect = element.getBoundingClientRect();
          return document
            .elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2)
            ?.closest("button")
            ?.getAttribute("aria-label");
        })
      )
      .toBe("Back");
    await titlebarBack.click();
    await expect(page).toHaveURL(/#\/inbox$/);
  } finally {
    await stub.close();
  }
});

test("settings navigation and controls remain usable at narrow supported widths", async ({
  page,
}) => {
  await installBrowserTestSession(page, {
    apiBaseUrl: "http://127.0.0.1:65535",
    email: "responsive-settings@comma.local",
    token: "comma_sess_responsive_settings",
  });

  const widths = [320, 375, 560, 561, 600, 640, 641, 700];
  await page.setViewportSize({ width: 700, height: 700 });
  await page.goto("/#/settings");
  await expectSettledSettingsModal(page);

  for (const locale of ["en", "zh-CN"]) {
    const languageRow = page.locator('[data-setting-id="app.language"]');
    const languageControl = languageRow.locator(
      '[data-slot="settings-control"] button'
    );

    if (locale === "zh-CN") {
      await languageControl.click();
      const simplifiedChineseOption = page.getByRole("option", {
        name: "Simplified Chinese",
      });
      await simplifiedChineseOption.focus();
      await simplifiedChineseOption.press("Enter");
      await expect(page.locator("html")).toHaveAttribute("lang", "zh-CN");
      // Choosing an option closes the listbox on its own. Escape here would
      // fall through to the settings modal and dismiss it.
      await expect(page.getByRole("option", { name: "简体中文" })).toBeHidden();
    }

    for (const width of widths) {
      await page.setViewportSize({ width, height: 700 });

      await expect(languageControl).toBeVisible();
      // Settings is a modal over the shell; the rail stays and marks its item.
      await expect(
        page.getByRole("button", {
          exact: true,
          name: locale === "en" ? "Settings" : "设置",
        })
      ).toHaveAttribute("aria-current", "page");
      await expect(
        page.getByRole("link", { exact: true, name: locale === "en" ? "Home" : "主页" })
      ).toBeVisible();

      const geometry = await page.evaluate(() => {
        const sidebarElement = document.querySelector<HTMLElement>(
          ".comma-settings-sidebar"
        );
        const contentElement = document.querySelector<HTMLElement>(
          ".comma-settings-content"
        );
        const control = document.querySelector<HTMLElement>(
          '[data-setting-id="app.language"] [data-slot="settings-control"]'
        );
        const button = control?.querySelector<HTMLButtonElement>("button");
        const copy = document.querySelector<HTMLElement>(
          '[data-setting-id="app.language"] [data-slot="settings-copy"]'
        );
        const toggleRow = document.querySelector<HTMLElement>(
          '[data-setting-id="app.launch-at-login"]'
        );
        const toggleCopy = toggleRow?.querySelector<HTMLElement>(
          '[data-slot="settings-copy"]'
        );
        const toggleTrack = toggleRow?.querySelector<HTMLElement>(
          '[data-slot="toggle-base"]'
        );
        const pageTitle = document.querySelector<HTMLElement>(
          '[data-slot="settings-panel-content"] > h1'
        );
        const sectionTitle = toggleRow
          ?.closest("section")
          ?.querySelector<HTMLElement>("h2");
        const paragraphs = Array.from(
          document.querySelectorAll<HTMLElement>(
            '[data-setting-id="app.language"] [data-slot="settings-copy"] > p'
          )
        );
        if (
          !sidebarElement ||
          !contentElement ||
          !control ||
          !button ||
          !copy ||
          !toggleRow ||
          !toggleCopy ||
          !toggleTrack ||
          !pageTitle ||
          !sectionTitle
        ) {
          throw new Error("Responsive settings geometry was unavailable.");
        }

        const sidebarRect = sidebarElement.getBoundingClientRect();
        const contentRect = contentElement.getBoundingClientRect();
        const controlRect = control.getBoundingClientRect();
        const buttonRect = button.getBoundingClientRect();
        const copyRect = copy.getBoundingClientRect();
        const pageTitleRect = pageTitle.getBoundingClientRect();
        const pageTitleTextLeft =
          pageTitleRect.left +
          Number.parseFloat(getComputedStyle(pageTitle).paddingInlineStart);
        const sectionTitleRect = sectionTitle.getBoundingClientRect();
        const toggleCopyRect = toggleCopy.getBoundingClientRect();
        const toggleRowStyle = getComputedStyle(toggleRow);
        const toggleTrackRect = toggleTrack.getBoundingClientRect();
        return {
          buttonFitsControl:
            buttonRect.left >= controlRect.left - 0.5 &&
            buttonRect.right <= controlRect.right + 0.5,
          contentFitsViewport:
            contentRect.left >= 0 &&
            contentRect.right <= window.innerWidth &&
            contentRect.top >= 0 &&
            contentRect.bottom <= window.innerHeight,
          copyFitsContent:
            copyRect.left >= contentRect.left && copyRect.right <= contentRect.right,
          copyTextIsUnclipped: paragraphs.every(
            (paragraph) =>
              paragraph.scrollWidth <= paragraph.clientWidth + 0.5 &&
              paragraph.scrollHeight <= paragraph.clientHeight + 0.5
          ),
          documentFitsViewport:
            document.documentElement.scrollWidth <= window.innerWidth,
          labelIsUnclipped:
            button.scrollWidth <= button.clientWidth + 0.5 &&
            button.scrollHeight <= button.clientHeight + 0.5,
          settingsTitlesAlign:
            Math.abs(pageTitleTextLeft - toggleCopyRect.left) <= 1 &&
            Math.abs(sectionTitleRect.left - toggleCopyRect.left) <= 1,
          sidebarFitsViewport:
            sidebarRect.top >= 0 && sidebarRect.bottom <= window.innerHeight,
          stacked: sidebarRect.bottom <= contentRect.top + 0.5,
          toggleHasFixedGeometry:
            Math.abs(toggleTrackRect.width - 36) <= 0.5 &&
            Math.abs(toggleTrackRect.height - 22) <= 0.5,
          toggleRowHas16pxInlinePadding:
            toggleRowStyle.paddingInlineStart === "16px" &&
            toggleRowStyle.paddingInlineEnd === "16px",
        };
      });

      expect(geometry, `${locale} settings geometry at ${width}px`).toEqual({
        buttonFitsControl: true,
        contentFitsViewport: true,
        copyFitsContent: true,
        copyTextIsUnclipped: true,
        documentFitsViewport: true,
        labelIsUnclipped: true,
        settingsTitlesAlign: true,
        sidebarFitsViewport: true,
        stacked: true,
        toggleHasFixedGeometry: true,
        toggleRowHas16pxInlinePadding: true,
      });

      await languageControl.click();
      await expect(
        page.getByRole("option", {
          name: locale === "en" ? "English" : "简体中文",
        })
      ).toBeVisible();
      await page.keyboard.press("Escape");
      await expect(
        page.getByRole("option", {
          name: locale === "en" ? "English" : "简体中文",
        })
      ).toBeHidden();
    }
  }
});

test("a narrow settings card moves its categories into a tab row", async ({ page }) => {
  await installBrowserTestSession(page, {
    apiBaseUrl: "http://127.0.0.1:65535",
    email: "settings-tabs@comma.local",
    token: "comma_sess_settings_tabs",
  });
  await page.setViewportSize({ width: 640, height: 800 });
  await page.goto("/#/settings");
  await expectSettledSettingsModal(page);

  // The card measures itself: too narrow for a rail beside a legible column,
  // so the categories become one scrolling row above the content.
  const card = page.locator(".comma-settings-page");
  await expect(card).toHaveAttribute("data-layout", "tabs");
  const tabs = page.locator('[data-slot="settings-tab"]');
  await expect(tabs.first()).toHaveText("General");
  // The row is the whole chrome the card can spare: no search field above it.
  await expect(page.getByRole("searchbox", { name: "Search settings" })).toHaveCount(0);
  await expect(tabs.first()).toHaveAttribute("aria-current", "page");
  expect(
    await page.evaluate(() => {
      const bar = document.querySelector<HTMLElement>(".comma-settings-sidebar")!;
      const content = document.querySelector<HTMLElement>(".comma-settings-content")!;
      const nav = bar.querySelector<HTMLElement>("nav")!;
      return {
        aboveContent:
          bar.getBoundingClientRect().bottom <=
          content.getBoundingClientRect().top + 0.5,
        rowScrollsSideways: nav.getBoundingClientRect().width > bar.clientWidth,
        rowDirection: getComputedStyle(nav).flexDirection,
      };
    })
  ).toEqual({ aboveContent: true, rowDirection: "row", rowScrollsSideways: true });

  // The card's close control shares the row: the tabs, the button and the bar
  // itself all sit on one centre line.
  expect(
    await page.evaluate(() => {
      const bar = document.querySelector<HTMLElement>(".comma-settings-sidebar")!;
      const tab = bar.querySelector<HTMLElement>('[data-slot="settings-tab"]')!;
      const close = document.querySelector<HTMLElement>(
        '.comma-settings-dialog button[aria-label*="Close"]'
      )!;
      // oxlint-disable-next-line unicorn/consistent-function-scoping -- Playwright serializes this browser callback without outer functions.
      const centre = (element: Element) => {
        const box = element.getBoundingClientRect();
        return Math.round((box.top + box.bottom) / 2);
      };
      const rowHeight = Number.parseFloat(
        getComputedStyle(document.documentElement).getPropertyValue("--spacing-6xl")
      );
      return {
        closeOffCentre: Math.abs(centre(close) - centre(bar)) <= 1,
        // The row stands one 6xl step tall (48px): the 40px close box and an
        // xs inset above and below it.
        rowOnToken: Math.abs(bar.getBoundingClientRect().height - rowHeight) <= 1,
        tabsOffCentre: Math.abs(centre(tab) - centre(bar)) <= 1,
      };
    })
  ).toEqual({ closeOffCentre: true, rowOnToken: true, tabsOffCentre: true });

  // The row's scrollbar rides the divider under the tabs.
  await page.locator(".comma-settings-sidebar").hover();
  expect(
    await page.evaluate(() => {
      const bar = document.querySelector<HTMLElement>(".comma-settings-sidebar")!;
      const scrollbar = bar.querySelector<HTMLElement>(
        '[data-slot="scroll-area-scrollbar"][data-axis="horizontal"]'
      );
      if (!scrollbar) return "no scrollbar";
      const gap =
        bar.getBoundingClientRect().bottom - scrollbar.getBoundingClientRect().bottom;
      // The bar's own hairline is all that separates them.
      return gap <= 1 ? "on the divider" : `floating ${Math.round(gap)}px above it`;
    })
  ).toBe("on the divider");

  await tabs.filter({ hasText: "Appearance" }).click();
  await expect(
    page.getByRole("heading", { level: 1, name: "Appearance" })
  ).toBeVisible();

  // Widening the window hands the categories back to the standing rail.
  await page.setViewportSize({ width: 1280, height: 800 });
  await expect(card).toHaveAttribute("data-layout", "rail");
  await expect(tabs).toHaveCount(0);
  await expect(
    page.getByRole("button", { exact: true, name: "Appearance" })
  ).toHaveAttribute("aria-current", "page");
});

test("a category selected past the end of the tab row is scrolled into view", async ({
  page,
}) => {
  await installBrowserTestSession(page, {
    apiBaseUrl: "http://127.0.0.1:65535",
    email: "settings-tabs-deep-link@comma.local",
    token: "comma_sess_settings_tabs_deep_link",
  });
  await page.setViewportSize({ width: 640, height: 800 });
  const card = page.locator(".comma-settings-page");
  const selectedTab = () =>
    page.evaluate(() => {
      const bar = document.querySelector<HTMLElement>(".comma-settings-sidebar")!;
      const viewport = bar.querySelector<HTMLElement>(
        '[data-slot="scroll-area-viewport"]'
      )!;
      const tab = bar.querySelector<HTMLElement>(
        '[data-slot="settings-tab"][aria-current="page"]'
      )!;
      const view = viewport.getBoundingClientRect();
      const box = tab.getBoundingClientRect();
      // oxlint-disable-next-line unicorn/consistent-function-scoping -- Playwright serializes this browser callback without outer functions.
      const inset = (token: string) =>
        Number.parseFloat(
          getComputedStyle(document.documentElement).getPropertyValue(token)
        );
      return {
        // In view means clear of the row's edge masks as well: an md fade at
        // the start of the row and a 3xl fade at its end.
        inView:
          box.left >= view.left + inset("--spacing-md") - 0.5 &&
          box.right <= view.right - inset("--spacing-3xl") + 0.5,
        label: tab.textContent,
        scrolled: viewport.scrollLeft > 0,
      };
    });

  // A deep link to a category past the row's end: its first paint shows it.
  await page.goto("/#/settings?category=usage-billing");
  await expectSettledSettingsModal(page);
  await expect(card).toHaveAttribute("data-layout", "tabs");
  await expect
    .poll(selectedTab)
    .toEqual({ inView: true, label: "Usage & billing", scrolled: true });

  // A category that becomes selected while the row is showing follows too.
  await page.evaluate(() => {
    location.hash = "#/settings?category=archived-tasks";
  });
  await expect
    .poll(selectedTab)
    .toEqual({ inView: true, label: "Archived tasks", scrolled: true });

  // And a card that narrows from the rail into tabs carries the selection
  // into view on the row's first paint.
  await page.setViewportSize({ width: 1280, height: 800 });
  await expect(card).toHaveAttribute("data-layout", "rail");
  await page.setViewportSize({ width: 640, height: 800 });
  await expect(card).toHaveAttribute("data-layout", "tabs");
  await expect
    .poll(selectedTab)
    .toEqual({ inView: true, label: "Archived tasks", scrolled: true });
});

test("the 500px minimum window yields the rail to usable full-height primary content", async ({
  page,
}) => {
  await page.setViewportSize({ width: 500, height: 700 });
  await installBrowserTestSession(page, {
    apiBaseUrl: "http://127.0.0.1:65535",
    email: "usable-content-boundary@comma.local",
    token: "comma_sess_usable_content_boundary",
  });
  await page.goto("/");

  const content = page.locator(".comma-content");
  const slot = page.getByTestId("comma-sidebar-slot");
  const prompt = page.getByRole("textbox", { name: "AI prompt" });
  // 500px cannot hold the rail beside Home's 425px minimum, so the rail
  // yields: its slot keeps only the window's 8px gutter and the panel gets the
  // rest of the frame (500 - 8 - 8), minus the 42px window bar (700 - 8 - 42),
  // full height to the frame's bottom edge.
  await expect(slot).toHaveAttribute("data-collapsed", "true");
  await expect(page.getByRole("complementary", { name: "Chat" })).toHaveCount(0);
  await expect
    .poll(() =>
      content.evaluate((element) => {
        const frameRect = document
          .querySelector<HTMLElement>(".comma-window-frame")!
          .getBoundingClientRect();
        const barRect = document
          .querySelector<HTMLElement>('[data-testid="comma-window-bar"]')!
          .getBoundingClientRect();
        const slotRect = document
          .querySelector<HTMLElement>('[data-testid="comma-sidebar-slot"]')!
          .getBoundingClientRect();
        const rect = element.getBoundingClientRect();
        return {
          barHeight: barRect.height,
          contentHeight: rect.height,
          contentWidth: rect.width,
          expectedHeight: frameRect.height - barRect.height,
          expectedWidth: frameRect.width - slotRect.width,
          reachesFrameBottom: rect.bottom === frameRect.bottom,
          slotWidth: slotRect.width,
        };
      })
    )
    .toEqual({
      barHeight: 42,
      contentHeight: 650,
      contentWidth: 484,
      expectedHeight: 650,
      expectedWidth: 484,
      reachesFrameBottom: true,
      slotWidth: 8,
    });
  await expect
    .poll(async () => (await prompt.boundingBox())?.width ?? 0)
    .toBeGreaterThan(0);
  // Both Home rails are folded with no handles, so chat drops the route inset
  // that hosts them and the empty avatar gutter, keeping one 16px edge on
  // each side.
  await expect
    .poll(() =>
      content.evaluate((element) => {
        const rect = element.getBoundingClientRect();
        const composer = element
          .querySelector<HTMLElement>(".comma-chat-composer")!
          .getBoundingClientRect();
        return { left: composer.left - rect.left, right: rect.right - composer.right };
      })
    )
    .toEqual({ left: 16, right: 16 });
  const dismissToasts = page.getByRole("button", { name: "Dismiss notification" });
  const toastCount = await dismissToasts.count();
  for (let index = 0; index < toastCount; index += 1) {
    await dismissToasts.first().click();
  }
  await expect(dismissToasts).toHaveCount(0);
  await prompt.click();
  await expect(prompt).toBeFocused();
});

test("empty Home composers hide unavailable access without collapsing the prompt", async ({
  browser,
}) => {
  const startupContext = await browser.newContext({
    baseURL: webBaseURL,
    viewport: { width: 500, height: 700 },
  });
  const startupPage = await startupContext.newPage();
  await installBrowserTestSession(startupPage, {
    apiBaseUrl: "http://127.0.0.1:65535",
    email: "compact-startup@comma.local",
    token: "comma_sess_compact_startup",
  });
  await startupPage.goto("/");
  await assertCompactHomeControls(startupPage);
  await startupContext.close();

  const stub = await startChatSmokeStub();
  try {
    const readyContext = await browser.newContext({
      baseURL: webBaseURL,
      viewport: { width: 500, height: 700 },
    });
    const readyPage = await readyContext.newPage();
    await installBrowserTestSession(readyPage, {
      apiBaseUrl: stub.baseUrl,
      email: "compact-ready@comma.local",
      token: "comma_sess_compact_ready",
    });
    await readyPage.goto("/");
    await expect.poll(() => stub.workspaceChatResponseStatuses).toEqual([200]);
    await assertCompactHomeControls(readyPage);
    await expect(
      readyPage.getByRole("heading", { level: 1, name: "聊天" })
    ).toHaveCount(0);
    await readyContext.close();
  } finally {
    await stub.close();
  }
});

test("Settings returns to the complete Home without committing the startup page", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({ workspaceChatDelayMs: 350 });

  try {
    await page.setViewportSize({ width: 1440, height: 800 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "settings-home@comma.local",
      token: "comma_sess_settings_home",
    });
    await page.goto("/");
    await expect.poll(() => stub.workspaceChatResponseStatuses).toEqual([200]);
    await expect(page.getByTestId("home-responsive-layout")).toBeVisible();
    await expect(page.getByTestId("home-tasks-section")).toBeVisible();

    const prompt = page.getByRole("textbox", { name: "AI prompt" });
    await prompt.fill("keep this through settings");
    await page.getByRole("button", { name: "Send" }).click();
    const assistantMessage = page.locator('[data-message-id="msg-assistant-smoke"]');
    await expect(assistantMessage).toBeVisible();
    await expect(page.getByTestId("chat-empty")).toHaveCount(0);
    await expect(page.getByRole("button", { name: "Voice input" })).toHaveCount(0);
    const homeLayout = page.getByTestId("home-responsive-layout");
    await homeLayout.evaluate((element) => {
      Reflect.set(element, "__commaRetainedHome", true);
    });
    const homeWidthBeforeSettings = await homeLayout.evaluate(
      (element) => element.getBoundingClientRect().width
    );

    const primaryModifier = await page.evaluate(() => {
      const platform = `${
        (
          navigator as Navigator & {
            userAgentData?: { platform?: string };
          }
        ).userAgentData?.platform ?? ""
      } ${navigator.platform} ${navigator.userAgent}`.toLocaleLowerCase();
      return platform.includes("mac") ||
        platform.includes("iphone") ||
        platform.includes("ipad")
        ? "Meta"
        : "Control";
    });
    await page.keyboard.press(`${primaryModifier}+,`);
    // Settings opens as a modal over the shell: the location stays on Home, and
    // the window bar and rail stay mounted and marked underneath it.
    await expect(page).toHaveURL(/\/(#\/)?$/);
    await expectSettledSettingsModal(page);
    await expect(
      page.getByRole("heading", { level: 1, name: "General" })
    ).toBeVisible();
    await expect(page.getByTestId("comma-window-bar")).toBeVisible();
    await expectActiveRailItem(page, "Settings", "button");
    const sidebarSlot = page.getByTestId("comma-sidebar-slot");
    await expect(sidebarSlot).toHaveAttribute("data-collapsed", "false");
    await page.keyboard.press(`${primaryModifier}+b`);
    await expect(sidebarSlot).toHaveAttribute("data-collapsed", "true");
    await page.keyboard.press(`${primaryModifier}+b`);
    await expect(sidebarSlot).toHaveAttribute("data-collapsed", "false");
    // Home is not swapped out for Settings any more: it stays mounted, live and
    // at its own width behind the modal.
    await expect(page.getByTestId("home-responsive-layout")).toHaveCount(1);
    await expect(page.getByTestId("home-responsive-layout")).toBeVisible();
    await expect(
      page.locator(
        '[data-comma-surface-paused="true"] [data-testid="home-responsive-layout"]'
      )
    ).toHaveCount(0);
    await expect
      .poll(() =>
        homeLayout.evaluate((element) => element.getBoundingClientRect().width)
      )
      .toBe(homeWidthBeforeSettings);

    await page.evaluate(() => {
      // oxlint-disable-next-line unicorn/consistent-function-scoping -- Playwright serializes this browser callback without outer functions.
      const isLegacyHomeNode = (node: Node) => {
        if (!(node instanceof Element)) return false;
        if (
          node.matches(".comma-home-route") ||
          node.querySelector(".comma-home-route")
        ) {
          return true;
        }
        const headings = [
          ...(node.matches("h1") ? [node] : []),
          ...node.querySelectorAll("h1"),
        ];
        return headings.some(
          (heading) => heading.textContent?.trim() === "What do you want to do"
        );
      };
      const probe = {
        badFrames: [] as Array<{ hash: string; missing: string[] }>,
        homeFrames: 0,
        legacyAdds: 0,
        observer: undefined as MutationObserver | undefined,
        running: true,
      };
      probe.observer = new MutationObserver((records) => {
        for (const record of records) {
          for (const node of record.addedNodes) {
            if (isLegacyHomeNode(node)) probe.legacyAdds += 1;
          }
        }
      });
      probe.observer.observe(document.body, { childList: true, subtree: true });

      const sample = () => {
        if (!probe.running) return;
        const isHome =
          window.location.hash === "" ||
          window.location.hash === "#" ||
          window.location.hash === "#/";
        const outlet = document.querySelector('[data-testid="comma-route-outlet"]');
        if (isHome && outlet) {
          probe.homeFrames += 1;
          const required = {
            chat: outlet?.querySelector(".comma-home-chat"),
            greet: outlet?.querySelector('[data-testid="home-greet-rail"]'),
            history: outlet?.querySelector('[data-message-id="msg-assistant-smoke"]'),
            layout: outlet?.querySelector('[data-testid="home-responsive-layout"]'),
            route: outlet?.querySelector('.comma-chat-route[data-variant="home"]'),
            tasks: outlet?.querySelector('[data-testid="home-tasks-rail"]'),
            tasksSection: outlet?.querySelector('[data-testid="home-tasks-section"]'),
          };
          const missing = Object.entries(required)
            .filter(([, element]) => !element)
            .map(([name]) => name);
          const starter = Boolean(
            outlet?.querySelector('[data-placeholder="Do anything"]')
          );
          const layout = required.layout;
          const layoutRect = layout?.getBoundingClientRect();
          const layoutStyle = layout ? getComputedStyle(layout) : undefined;
          const layoutVisible = Boolean(
            layoutRect &&
            layoutRect.width > 0 &&
            layoutRect.height > 0 &&
            layoutStyle?.display !== "none" &&
            layoutStyle?.visibility === "visible"
          );
          if (!layoutVisible) missing.push("visible-layout");
          if (missing.length > 0 || starter) {
            probe.badFrames.push({
              hash: window.location.hash,
              missing: starter ? [...missing, "starter"] : missing,
            });
          }
        }
        requestAnimationFrame(sample);
      };
      requestAnimationFrame(sample);
      Reflect.set(window, "__commaHomeReturnProbe", probe);
    });

    const firstReturnedSurface = Promise.race([
      page
        .locator('[data-message-id="msg-assistant-smoke"]')
        .waitFor({ state: "visible" })
        .then(() => "history" as const),
      page
        .getByTestId("home-tasks-section")
        .waitFor({ state: "visible" })
        .then(() => "home" as const),
    ]);
    await page.keyboard.press("Escape");
    await expect(page.getByRole("dialog", { name: "Settings sections" })).toBeHidden();
    expect(await firstReturnedSurface).toMatch(/^(history|home)$/);
    await expect(assistantMessage).toBeVisible();
    await expect(page.getByTestId("chat-empty")).toHaveCount(0);
    await expect(page.getByRole("button", { name: "Voice input" })).toHaveCount(0);
    expect(stub.workspaceChatRequestCount).toBe(1);

    await expect(homeLayout).toBeVisible();
    expect(
      await homeLayout.evaluate((element) =>
        Reflect.get(element, "__commaRetainedHome")
      )
    ).toBe(true);
    await expect
      .poll(() =>
        homeLayout.evaluate((element) => element.getBoundingClientRect().width)
      )
      .toBe(homeWidthBeforeSettings);
    await expect(page.getByTestId("home-greet-rail")).toBeVisible();
    await expect(assistantMessage).toBeVisible();
    await expect(page.getByTestId("home-tasks-rail")).toBeVisible();
    await expect(page.getByTestId("home-tasks-section")).toBeVisible();
    await page.evaluate(
      () =>
        new Promise<void>((resolve) => {
          requestAnimationFrame(() => requestAnimationFrame(() => resolve()));
        })
    );
    const homeReturnProbe = await page.evaluate(() => {
      const probe = Reflect.get(window, "__commaHomeReturnProbe") as {
        badFrames: Array<{ hash: string; missing: string[] }>;
        homeFrames: number;
        legacyAdds: number;
        observer?: MutationObserver;
        running: boolean;
      };
      probe.running = false;
      probe.observer?.disconnect();
      Reflect.deleteProperty(window, "__commaHomeReturnProbe");
      return {
        badFrames: probe.badFrames,
        homeFrames: probe.homeFrames,
        legacyAdds: probe.legacyAdds,
      };
    });
    expect(homeReturnProbe.homeFrames).toBeGreaterThan(0);
    expect(homeReturnProbe.badFrames).toEqual([]);
    expect(homeReturnProbe.legacyAdds).toBe(0);
  } finally {
    await stub.close();
  }
});

// A modal locks page scroll by writing `overflow` on the document root. The
// document never scrolls, and any new style on the root restyles every
// element, so opening and closing Settings must leave the root style as is.
test("Settings opens and closes without rewriting the document root style", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({ taskSchedule: null });

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "settings-root-style@comma.local",
      token: "comma_sess_settings_root_style",
    });
    await page.goto("/#/inbox");
    await expect(page.getByTestId("inbox-workspace")).toBeVisible();
    await page.evaluate(() => {
      const writes: string[] = [];
      Reflect.set(window, "__commaRootStyleWrites", writes);
      new MutationObserver((records) => {
        for (const record of records) writes.push(record.oldValue ?? "");
      }).observe(document.documentElement, {
        attributeFilter: ["style"],
        attributeOldValue: true,
      });
    });

    const settings = page.getByRole("dialog", { name: "Settings sections" });
    await page
      .locator(".comma-sidebar-body")
      .getByRole("button", { name: "Settings", exact: true })
      .click();
    await expect(settings).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(settings).toBeHidden();

    expect(
      await page.evaluate(() => Reflect.get(window, "__commaRootStyleWrites"))
    ).toEqual([]);
  } finally {
    await stub.close();
  }
});

test("Tasks returns to the kept Home without remounting Comma assistant", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({ workspaceChatDelayMs: 350 });

  try {
    await page.setViewportSize({ width: 1440, height: 800 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "tasks-home@comma.local",
      token: "comma_sess_tasks_home",
    });
    await page.goto("/");
    await expect.poll(() => stub.workspaceChatResponseStatuses).toEqual([200]);
    await expect(page.getByTestId("home-responsive-layout")).toBeVisible();

    const prompt = page.getByRole("textbox", { name: "AI prompt" });
    await prompt.fill("keep this through tasks");
    await page.getByRole("button", { name: "Send" }).click();
    const assistantMessage = page.locator('[data-message-id="msg-assistant-smoke"]');
    await expect(assistantMessage).toBeVisible();
    await expect(page.getByTestId("chat-empty")).toHaveCount(0);
    const homeLayout = page.getByTestId("home-responsive-layout");

    await page.getByRole("link", { name: "Tasks" }).click();
    await expect(page).toHaveURL(/#\/tasks$/);
    await expect(page.getByTestId("tasks-route")).toBeVisible();
    await expect(homeLayout).toHaveCount(1);
    await expect(homeLayout).toBeHidden();
    // Retention must hide the content too. A descendant must not override
    // the route owner's visibility and paint behind the active route.
    await expect(page.getByTestId("home-tasks-section")).toBeHidden();
    await expect(
      page.locator(
        '[data-comma-surface-paused="true"] [data-testid="home-responsive-layout"]'
      )
    ).toHaveCount(1);

    await page.getByRole("link", { exact: true, name: "Home" }).click();
    await expect(page).toHaveURL(/#\/$/);
    await expect(homeLayout).toBeVisible();
    await expect(page.getByTestId("home-tasks-section")).toBeVisible();
    await expect(assistantMessage).toBeVisible();
    await expect(page.getByTestId("chat-empty")).toHaveCount(0);
    expect(stub.workspaceChatRequestCount).toBe(1);
  } finally {
    await stub.close();
  }
});

test("Home keeps Workspace recovery available when startup send resolves hidden", async ({
  page,
}) => {
  let releaseWorkspaceChatRequests!: () => void;
  const workspaceChatRequestsHeld = new Promise<void>((resolve) => {
    releaseWorkspaceChatRequests = resolve;
  });
  const stub = await startChatSmokeStub({
    beforeWorkspaceChat: () => workspaceChatRequestsHeld,
  });
  stub.setWorkspaceChatHidden(true);

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "home-recovery@comma.local",
      token: "comma_sess_home_recovery",
    });
    await page.goto("/");
    await expect.poll(() => stub.workspaceChatRequestCount).toBe(1);

    const prompt = page.getByRole("textbox", { name: "AI prompt" });
    await expect(page.getByTestId("home-responsive-layout")).toBeVisible();
    await prompt.fill("recover this");
    await page.getByRole("button", { name: "Send" }).click();
    // Startup and send share the host's pending resolution.
    expect(stub.workspaceChatRequestCount).toBe(1);
    releaseWorkspaceChatRequests();

    const recoveryNotice = page.getByTestId("workspace-resolution");
    await expect(recoveryNotice).toContainText(/No workspace is available for chat\./);
    await expect(prompt).toBeEditable();
    await expect(prompt).toHaveText("recover this");
    const retry = recoveryNotice.getByRole("button", { name: "Retry" });
    await expect(retry).toBeVisible();

    stub.setWorkspaceChatHidden(false);
    await retry.click();
    await expect.poll(() => stub.workspaceChatResponseStatuses).toEqual([403, 200]);
    expect(stub.workspaceChatRequestCount).toBe(2);
    await expect(recoveryNotice).toBeHidden();

    await expect(prompt).toHaveText("recover this");
    await expect(prompt).toBeEditable();
    await expect(page.getByTestId("home-responsive-layout")).toBeVisible();
  } finally {
    releaseWorkspaceChatRequests();
    await stub.close();
  }
});

test("Home preserves focused draft selection across deferred Workspace and conversation resolution", async ({
  page,
}) => {
  let releaseWorkspaceChat!: () => void;
  let observeWorkspaceChat!: () => void;
  let releaseConversationDetail!: () => void;
  let observeConversationDetail!: () => void;
  const workspaceChatHeld = new Promise<void>((resolve) => {
    releaseWorkspaceChat = resolve;
  });
  const workspaceChatObserved = new Promise<void>((resolve) => {
    observeWorkspaceChat = resolve;
  });
  const conversationDetailHeld = new Promise<void>((resolve) => {
    releaseConversationDetail = resolve;
  });
  const conversationDetailObserved = new Promise<void>((resolve) => {
    observeConversationDetail = resolve;
  });

  const stub = await startChatSmokeStub({
    beforeWorkspaceChat: async () => {
      observeWorkspaceChat();
      await workspaceChatHeld;
    },
    beforeWorkspaceChatDetail: async () => {
      observeConversationDetail();
      await conversationDetailHeld;
    },
  });

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "home-handoff@comma.local",
      token: "comma_sess_home_handoff",
    });
    await page.goto("/");
    await workspaceChatObserved;

    const prompt = page.getByRole("textbox", { name: "AI prompt" });
    await prompt.fill("keep typing here");
    await prompt.evaluate((editor) => {
      editor.dataset.e2eHomeEditor = "stable";
      editor.focus();
      const text = editor.firstChild;
      if (!text) throw new Error("Missing Home editor text node");
      const range = document.createRange();
      range.setStart(text, 5);
      range.collapse(true);
      const selection = window.getSelection();
      selection?.removeAllRanges();
      selection?.addRange(range);
    });

    releaseWorkspaceChat();
    await conversationDetailObserved;

    await expect
      .poll(() =>
        prompt.evaluate((editor) => {
          const selection = window.getSelection();
          return {
            focused: document.activeElement === editor,
            identity: editor.dataset.e2eHomeEditor,
            selection:
              selection && editor.contains(selection.anchorNode)
                ? selection.anchorOffset
                : -1,
            text: editor.textContent,
          };
        })
      )
      .toEqual({
        focused: true,
        identity: "stable",
        selection: 5,
        text: "keep typing here",
      });

    releaseConversationDetail();
    await expect.poll(() => stub.workspaceChatDetailResponseStatuses).toEqual([200]);

    await expect(prompt).toHaveAttribute("data-e2e-home-editor", "stable");
    await expect(prompt).toBeFocused();
    await expect(prompt).toHaveText("keep typing here");
  } finally {
    releaseWorkspaceChat();
    releaseConversationDetail();
    await stub.close();
  }
});

test("Home rails collapse by container width and fold in place", async ({ page }) => {
  const stub = await startChatSmokeStub();

  try {
    await page.setViewportSize({ width: 1440, height: 800 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "home-responsive@comma.local",
      token: "comma_sess_home_responsive",
    });
    await page.goto("/");

    const homeLayout = page.getByTestId("home-responsive-layout");
    const greetRail = page.getByTestId("home-greet-rail");
    const tasksRail = page.getByTestId("home-tasks-rail");
    await expect(homeLayout).toBeVisible();
    await expect(greetRail).toBeVisible();
    await expect(page.getByTestId("chat-empty")).toBeVisible();
    await expect(tasksRail).toBeVisible();

    const recommendationRailWidth = async () =>
      greetRail.evaluate((element) => element.getBoundingClientRect().width);
    await expect.poll(recommendationRailWidth).toBe(300);

    await page.setViewportSize({ width: 1900, height: 800 });
    await expect.poll(recommendationRailWidth).toBe(300);
    await page.setViewportSize({ width: 1440, height: 800 });
    await expect.poll(recommendationRailWidth).toBe(300);

    const prompt = page.getByRole("textbox", { name: "AI prompt" });
    await prompt.fill("Open the responsive Home layout");
    await page.getByRole("button", { name: "Send" }).click();

    const greetTrigger = page.getByRole("button", { name: "Show Greet panel" });
    const tasksTrigger = page.getByRole("button", { name: "Show Tasks panel" });
    const composer = page.locator(".comma-home-chat .comma-chat-composer");
    const indicatorFooter = tasksRail.locator(".comma-home-tasks-footer");
    const statusIndicator = tasksRail.locator("status-indicator");
    const readComposerIndicatorGeometry = async () => {
      const [composerBox, footerBox, indicatorBox] = await Promise.all([
        composer.boundingBox(),
        indicatorFooter.boundingBox(),
        statusIndicator.boundingBox(),
      ]);
      if (!composerBox || !footerBox || !indicatorBox) return null;
      const composerCenter = composerBox.y + composerBox.height / 2;
      const indicatorCenter = indicatorBox.y + indicatorBox.height / 2;
      const compactBaseline = await page
        .locator("html")
        .evaluate(
          (root, contentHeight) =>
            contentHeight +
            2 *
              Number.parseFloat(
                getComputedStyle(root).getPropertyValue("--border-width-default")
              ),
          AI_INPUT_SMALL_TEXTAREA_MIN_HEIGHT_PX
        );
      return {
        centerDelta: Math.abs(composerCenter - indicatorCenter),
        compactBaseline,
        composerCenter,
        composerHeight: composerBox.height,
        footerHeight: footerBox.height,
        indicatorCenter,
      };
    };
    await expect(homeLayout).toBeVisible();
    await expect(greetRail).toBeVisible();
    await expect(tasksRail).toBeVisible();
    await expect(greetTrigger).toBeHidden();
    await expect(tasksTrigger).toBeHidden();
    await expect(statusIndicator).toBeVisible();
    await expect(composer).toHaveClass(/ai-input-small-shell-motion/);
    await expect
      .poll(
        async () => (await readComposerIndicatorGeometry())?.centerDelta ?? Infinity
      )
      .toBeLessThanOrEqual(1);
    await expect.poll(readComposerIndicatorGeometry).toMatchObject({
      compactBaseline: 38,
      composerHeight: 38,
      footerHeight: 38,
    });

    // A status the user picks themselves is theirs to keep, even with tasks
    // sitting in another bucket — and the empty state then says so.
    await statusIndicator.getByRole("radio", { name: "Backlog" }).click();
    await expect(statusIndicator).toHaveAttribute("value", "backlog");
    const emptyTasks = tasksRail.getByText("No tasks in this status");
    const homeTasksSection = tasksRail.getByTestId("home-tasks-section");
    await expect(emptyTasks).toBeVisible();
    await expect
      .poll(() =>
        emptyTasks.evaluate((element) => ({
          animations: element.getAnimations().length,
          opacity: getComputedStyle(element).opacity,
        }))
      )
      .toEqual({ animations: 0, opacity: "1" });
    await emptyTasks.evaluate((element) => {
      const section = element.closest<HTMLElement>(
        '[data-testid="home-tasks-section"]'
      );
      if (!section) throw new Error("Missing Home Tasks section");
      element.dataset.e2eEmptyIdentity = "original";
      section.dataset.e2eEmptyDisconnected = "false";
      const observer = new MutationObserver(() => {
        if (element.isConnected) return;
        section.dataset.e2eEmptyDisconnected = "true";
        observer.disconnect();
      });
      observer.observe(section, { childList: true, subtree: true });
      Reflect.set(section, "__commaE2eEmptyObserver", observer);
    });
    await statusIndicator.evaluate((element) => {
      const inProgress =
        element.shadowRoot?.querySelectorAll<HTMLElement>('[role="radio"]')[1];
      if (!inProgress) throw new Error("Missing In Progress status indicator item");
      inProgress.click();
    });
    await expect(statusIndicator).toHaveAttribute("value", "in-progress");
    await page.evaluate(
      () =>
        new Promise<void>((resolve) => {
          requestAnimationFrame(() => requestAnimationFrame(() => resolve()));
        })
    );
    await expect(emptyTasks).toHaveAttribute("data-e2e-empty-identity", "original");
    await expect(homeTasksSection).toHaveAttribute(
      "data-e2e-empty-disconnected",
      "false"
    );
    await expect(emptyTasks).toHaveCSS("opacity", "1");
    await homeTasksSection.evaluate((element) => {
      const observer = Reflect.get(element, "__commaE2eEmptyObserver");
      if (observer instanceof MutationObserver) observer.disconnect();
    });

    const assistantMessage = page
      .locator(".comma-home-chat .comma-chat-message-assistant")
      .last();
    const copyButton = assistantMessage.locator(".comma-chat-message-action-button");
    await expect(assistantMessage).toBeVisible();
    await assistantMessage.hover();
    await expect(copyButton).toBeVisible();
    await expect(copyButton).not.toHaveAttribute("title");
    await copyButton.hover();
    const copyTooltip = page.locator(".comma-tooltip").filter({ hasText: /^Copy$/ });
    await expect(copyTooltip).toBeVisible();
    await expect(copyTooltip).toHaveAttribute("data-side", "bottom");
    await expect
      .poll(async () => {
        const [buttonBox, tooltipBox] = await Promise.all([
          copyButton.boundingBox(),
          copyTooltip.boundingBox(),
        ]);
        if (!buttonBox || !tooltipBox) return false;
        return tooltipBox.y >= buttonBox.y + buttonBox.height;
      })
      .toBe(true);
    await expect
      .poll(() =>
        assistantMessage.evaluate((article) => {
          const text = article.querySelector<HTMLElement>(".markdown-stream");
          const actions = article.querySelector<HTMLElement>(
            ".comma-chat-message-actions"
          );
          if (!text || !actions) return Number.POSITIVE_INFINITY;
          const gap = parseFloat(getComputedStyle(article).columnGap);
          return Math.abs(
            actions.getBoundingClientRect().left -
              text.getBoundingClientRect().right -
              gap
          );
        })
      )
      .toBeLessThanOrEqual(1);
    await expect
      .poll(async () => {
        const box = await copyButton.boundingBox();
        return box ? { height: box.height, width: box.width } : null;
      })
      .toEqual({ height: 20, width: 20 });

    const initialIndicatorGeometry = await readComposerIndicatorGeometry();
    expect(initialIndicatorGeometry).not.toBeNull();
    const initialIndicatorCenter = initialIndicatorGeometry!.indicatorCenter;
    const initialIndicatorFooterHeight = initialIndicatorGeometry!.footerHeight;
    await prompt.fill(
      [
        "Keep the indicator fixed.",
        "The composer can grow upward.",
        "This line makes the input taller.",
        "And this one verifies the stable rail.",
      ].join("\n")
    );
    await expect
      .poll(async () => (await readComposerIndicatorGeometry())?.composerHeight ?? 0)
      .toBeGreaterThan(initialIndicatorGeometry!.composerHeight + 20);
    await expect
      .poll(async () => {
        const geometry = await readComposerIndicatorGeometry();
        return geometry
          ? Math.abs(geometry.indicatorCenter - initialIndicatorCenter)
          : Infinity;
      })
      .toBeLessThanOrEqual(1);
    await expect
      .poll(async () => (await readComposerIndicatorGeometry())?.footerHeight ?? 0)
      .toBe(initialIndicatorFooterHeight);
    await expect
      .poll(async () => {
        const geometry = await readComposerIndicatorGeometry();
        return geometry
          ? Math.abs(geometry.composerCenter - initialIndicatorGeometry!.composerCenter)
          : 0;
      })
      .toBeGreaterThan(10);

    // At both 300px preferred widths and the 393px chat floor, all columns fit.
    await page.setViewportSize({ width: 1140, height: 800 });
    await expect(greetRail).toBeVisible();
    const readRailTracks = () =>
      homeLayout.evaluate((layout) => {
        const chat = layout.querySelector<HTMLElement>(".comma-home-chat");
        const greet = layout.querySelector<HTMLElement>(".comma-home-greet-rail");
        const tasks = layout.querySelector<HTMLElement>(".comma-home-tasks-rail");
        if (!chat || !greet || !tasks) return null;
        const chatBox = chat.getBoundingClientRect();
        const greetBox = greet.getBoundingClientRect();
        const tasksBox = tasks.getBoundingClientRect();
        const style = getComputedStyle(layout);
        const columns = style.gridTemplateColumns
          .split(" ")
          .map((value) => Number.parseFloat(value));
        const expectedGreetGap = Number.parseFloat(
          getComputedStyle(document.documentElement).getPropertyValue("--spacing-xl")
        );
        // oxlint-disable-next-line unicorn/consistent-function-scoping -- Playwright serializes this browser callback without outer functions.
        const surfaceOpacity = (rail: HTMLElement) =>
          Math.round(
            Number(
              getComputedStyle(rail.querySelector(".comma-home-rail-surface")!).opacity
            ) * 100
          ) / 100;
        // oxlint-disable-next-line unicorn/consistent-function-scoping -- Playwright serializes this browser callback without outer functions.
        const surfaceWidth = (rail: HTMLElement) =>
          Math.round(
            rail.querySelector(".comma-home-rail-surface")!.getBoundingClientRect()
              .width
          );
        return {
          chat: Math.round(chatBox.width),
          chatTrackDelta: Math.round(Math.abs(chatBox.width - (columns[1] ?? 0))),
          greetGapDelta: Math.round(
            Math.abs(chatBox.left - greetBox.right - expectedGreetGap)
          ),
          greetOpacity: surfaceOpacity(greet),
          // Reflowed, not clipped: an unfolded rail's surface is the rail's
          // own width.
          greetSurfaceDelta: Math.round(greetBox.width) - surfaceWidth(greet),
          greetWidth: Math.round(greetBox.width),
          tasksOpacity: surfaceOpacity(tasks),
          tasksSurfaceDelta: Math.round(tasksBox.width) - surfaceWidth(tasks),
          tasksWidth: Math.round(tasksBox.width),
        };
      });
    await expect(tasksRail).toBeVisible();
    await expect(tasksRail).toHaveAttribute("data-folded", "false");
    await expect(statusIndicator).toBeVisible();
    await expect.poll(readRailTracks).toMatchObject({
      chat: 393,
      chatTrackDelta: 0,
      greetGapDelta: 0,
      greetOpacity: 1,
      greetWidth: 300,
      tasksOpacity: 1,
      tasksSurfaceDelta: 0,
      tasksWidth: 300,
    });
    await expect(tasksTrigger).toHaveCount(0);

    // Below the combined floor, Tasks folds and chat takes its track.
    await page.setViewportSize({ width: 965, height: 800 });
    await expect(tasksRail).toBeHidden();
    await expect(tasksRail).toHaveAttribute("data-folded", "true");
    await expect(greetRail).toHaveAttribute("data-folded", "false");
    await expect(statusIndicator).toBeHidden();
    await expect.poll(readRailTracks).toMatchObject({
      chat: 534,
      chatTrackDelta: 0,
      greetGapDelta: 0,
      greetOpacity: 1,
      greetSurfaceDelta: 0,
      greetWidth: 300,
      tasksOpacity: 0,
      tasksWidth: 0,
    });
    // Folded rails have no header trigger — they come back when the route
    // widens.
    await expect(tasksTrigger).toHaveCount(0);

    // Narrower still (a 574px route): Greet folds the same way and the chat
    // column keeps the whole route.
    await page.setViewportSize({ width: 665, height: 800 });
    await expect(greetRail).toBeHidden();
    await expect(greetRail).toHaveAttribute("data-folded", "true");
    await expect.poll(readRailTracks).toMatchObject({
      chat: 550,
      chatTrackDelta: 0,
      greetOpacity: 0,
      greetWidth: 0,
      tasksOpacity: 0,
      tasksWidth: 0,
    });
    // The minimum window cannot hold the rail beside Home, so the rail yields;
    // even with its column, both Home rails stay folded.
    await page.setViewportSize({ width: 500, height: 800 });
    await expect(page.getByTestId("comma-sidebar-slot")).toHaveAttribute(
      "data-collapsed",
      "true"
    );
    await expect(greetRail).toBeHidden();
    await expect(tasksRail).toBeHidden();
    await expect(greetRail).toHaveAttribute("data-folded", "true");
    await expect(tasksRail).toHaveAttribute("data-folded", "true");
    await expect(greetTrigger).toHaveCount(0);
    await expect(tasksTrigger).toHaveCount(0);
  } finally {
    await stub.close();
  }
});

test("sidebar collapse honors reduced motion", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await installBrowserTestSession(page, {
    apiBaseUrl: "http://127.0.0.1:65535",
    email: "reduced-motion-collapse@comma.local",
    token: "comma_sess_reduced_motion_collapse",
  });
  await page.goto("/");

  const slot = page.getByTestId("comma-sidebar-slot");
  const toggle = page.locator(".comma-sidebar-edge-toggle");
  await expect(slot).toHaveAttribute("data-collapsed", "false");
  await expect
    .poll(() =>
      slot.evaluate((element) => ({
        animations: element.getAnimations().length,
        duration: getComputedStyle(element).transitionDuration,
      }))
    )
    .toEqual({ animations: 0, duration: "0s" });

  await toggle.click();
  await expect(slot).toHaveAttribute("data-collapsed", "true");
  await expect.poll(async () => (await slot.boundingBox())?.width ?? -1).toBe(8);
  expect(await slot.evaluate((element) => element.getAnimations().length)).toBe(0);
  await toggle.click();
  await expect(slot).toHaveAttribute("data-collapsed", "false");
  await expect.poll(async () => (await slot.boundingBox())?.width ?? 0).toBe(75);
});

test("the window bar's Chat sidebar toggle stays clickable on every product route", async ({
  page,
}) => {
  await installBrowserTestSession(page, {
    apiBaseUrl: "http://127.0.0.1:65535",
    email: "hidden-rail@comma.local",
    token: "comma_sess_hidden_rail",
  });
  await page.route("http://127.0.0.1:65535/v1/comma/me/bootstrap", async (route) => {
    await route.fulfill({
      body: JSON.stringify({ error: "forbidden" }),
      contentType: "application/json",
      status: 403,
    });
  });
  // Settings is not in this list: it opens as a modal that owns the pointer,
  // so the bar below it is deliberately out of reach while it is up.
  for (const route of ["/", "/#/inbox", "/#/tasks", "/#/plugins"]) {
    await page.goto(route);

    const toggle = page
      .getByTestId("comma-window-bar")
      .getByRole("button", { name: "Toggle chat sidebar" });
    await expect(toggle).toBeVisible();
    await expect(toggle).toHaveAttribute("aria-expanded", "false");
    // The toggle is a no-drag control of the drag bar, above a panel that
    // paints no drag strip of its own; it is the hit target at its centre.
    await expect
      .poll(() =>
        toggle.evaluate((button) => {
          const rect = button.getBoundingClientRect();
          const bar = button.closest<HTMLElement>('[data-testid="comma-window-bar"]')!;
          const frameRect = document
            .querySelector<HTMLElement>(".comma-window-frame")!
            .getBoundingClientRect();
          const content = document.querySelector<HTMLElement>(".comma-content")!;
          const contentRect = content.getBoundingClientRect();
          return {
            aboveContent: rect.bottom <= contentRect.top,
            appRegion: getComputedStyle(button).getPropertyValue("-webkit-app-region"),
            barAppRegion: getComputedStyle(bar).getPropertyValue("-webkit-app-region"),
            contentAligned: Math.abs(contentRect.right - frameRect.right) < 0.5,
            contentDragStrip: getComputedStyle(content, "::before").content,
            hitTarget: document
              .elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2)
              ?.closest("button")
              ?.getAttribute("aria-label"),
          };
        })
      )
      .toEqual({
        aboveContent: true,
        appRegion: "no-drag",
        barAppRegion: "drag",
        contentAligned: true,
        contentDragStrip: "none",
        hitTarget: "Toggle chat sidebar",
      });

    await toggle.click();
    await expect(toggle).toHaveAttribute("aria-expanded", "true");
    const sidebar = page.getByRole("complementary", { name: "Chat" });
    await expect(sidebar).toHaveAttribute("data-open", "true");
    // The sidebar opens inside the panel, beside the route's own surface.
    expect(
      await sidebar.evaluate((element) => Boolean(element.closest(".comma-content")))
    ).toBe(true);
    await expect(sidebar.getByRole("tab", { name: "New tab" })).toBeVisible();
    await expect(sidebar.getByRole("textbox", { name: "Address" })).toBeVisible();
    await toggle.click();
    await expect(toggle).toHaveAttribute("aria-expanded", "false");
    await expect(sidebar).toHaveCount(0);
  }
});

// A Home rail is eaten by a drag as a continuous function of the route width,
// and only 0 and 1 are shapes it can rest in. A Chat Sidebar drag snaps to one
// of them on pointer release; a window drag used to stop wherever the pointer
// left it, resting on a half-clipped column at a quarter opacity.
const readHomeRailGeometry = (page: Page) =>
  page.evaluate(() => {
    const rails = ["greet", "tasks"].map((name) => {
      const rail = document.querySelector<HTMLElement>(`.comma-home-${name}-rail`);
      const surface = rail?.querySelector<HTMLElement>(".comma-home-rail-surface");
      return {
        folded: rail?.dataset.folded ?? "missing",
        railWidth: Math.round(rail?.getBoundingClientRect().width ?? -1),
        surfaceWidth: Math.round(surface?.getBoundingClientRect().width ?? -1),
      };
    });
    const route = document.querySelector<HTMLElement>(
      '.comma-chat-route[data-variant="home"]'
    );
    const sidebar = document.querySelector<HTMLElement>(".comma-chat-sidebar");
    return {
      greet: rails[0]!,
      routeWidth: Math.round(route?.getBoundingClientRect().width ?? -1),
      sidebarWidth: Math.round(sidebar?.getBoundingClientRect().width ?? 0),
      tasks: rails[1]!,
    };
  });

// Open or fully closed, never a fraction of the way — and reporting the shape
// it is actually in. Both endpoints of the fold transition satisfy the width
// half alone, so the marker is what says the transition is over.
const railIsSettled = (rail: {
  folded: string;
  railWidth: number;
  surfaceWidth: number;
}) =>
  (rail.railWidth === 0 || rail.railWidth === rail.surfaceWidth) &&
  rail.folded === (rail.railWidth === 0 ? "true" : "false");

test("Home rails never rest half eaten after a window resize", async ({ page }) => {
  test.setTimeout(120_000);
  await page.setViewportSize({ width: 1440, height: 900 });
  await installBrowserTestSession(page, {
    apiBaseUrl: "http://127.0.0.1:65535",
    email: "home-rail-window-settle@comma.local",
    token: "comma_sess_home_rail_window_settle",
  });
  await page.goto("/");
  await expect(page.getByTestId("home-responsive-layout")).toBeVisible();
  await expect(page.getByTestId("home-greet-rail")).toHaveCount(1);

  // Every width across both rails' tracks, including the ones that used to
  // leave a rail mid-eat (the screenshot's ~45% Greet sat around 1000px here).
  for (const width of [1440, 1240, 1120, 1040, 980, 900, 860, 1000, 1180, 1340]) {
    await page.setViewportSize({ height: 900, width });
    await expect
      .poll(
        async () => {
          const geometry = await readHomeRailGeometry(page);
          return railIsSettled(geometry.greet) && railIsSettled(geometry.tasks);
        },
        { message: `rails settled at viewport width ${width}`, timeout: 15_000 }
      )
      .toBe(true);
  }
});

// The indicator lives on a pseudo-element, so its painted length is only
// readable through the computed style of `::after`.
const readRailHandleIndicator = (page: Page, name: "greet" | "tasks") =>
  page.evaluate((rail) => {
    const handle = document.querySelector<HTMLElement>(
      `.comma-home-${rail}-rail-handle`
    );
    if (!handle) return null;
    const indicator = getComputedStyle(handle, "::after");
    const box = handle.getBoundingClientRect();
    return {
      handleCenter: Math.round(box.left + box.width / 2),
      handleWidth: Math.round(box.width),
      height: Math.round(Number.parseFloat(indicator.height)),
      opacity: Math.round(Number(indicator.opacity) * 100) / 100,
    };
  }, name);

const readRailAndShellHandleHitTest = (
  page: Page,
  name: "greet" | "tasks",
  shellHandleSelector: string
) =>
  page.evaluate(
    ({ rail, shellSelector }) => {
      const railHandle = document.querySelector<HTMLElement>(
        `.comma-home-${rail}-rail-handle`
      );
      const shellHandle = document.querySelector<HTMLElement>(shellSelector);
      if (!railHandle || !shellHandle) return null;

      const railBox = railHandle.getBoundingClientRect();
      const shellBox = shellHandle.getBoundingClientRect();
      const center = {
        x: railBox.left + railBox.width / 2,
        y: railBox.top + railBox.height / 2,
      };
      const owner = document.elementFromPoint(center.x, center.y);

      return {
        center,
        centerOwnedByRail: owner?.closest(".comma-home-rail-handle") === railHandle,
        horizontalOverlap: Math.max(
          0,
          Math.min(railBox.right, shellBox.right) -
            Math.max(railBox.left, shellBox.left)
        ),
      };
    },
    { rail: name, shellSelector: shellHandleSelector }
  );

test("Home rails collapse and expand from their edge handles", async ({ page }) => {
  const stub = await startChatSmokeStub();

  try {
    await page.setViewportSize({ width: 1440, height: 900 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "home-rail-collapse@comma.local",
      token: "comma_sess_home_rail_collapse",
    });
    await page.goto("/");

    const homeLayout = page.getByTestId("home-responsive-layout");
    const greetRail = page.getByTestId("home-greet-rail");
    const tasksRail = page.getByTestId("home-tasks-rail");
    const greetHandle = page.getByTestId("home-greet-rail-handle");
    const tasksHandle = page.getByTestId("home-tasks-rail-handle");
    await expect(homeLayout).toBeVisible();
    await expect(greetRail).toBeVisible();
    await expect(tasksRail).toBeVisible();

    // A handle sits in the gutter beside its open rail, not over it.
    const gutterGeometry = await homeLayout.evaluate((layout) => {
      const box = (selector: string) =>
        layout.querySelector<HTMLElement>(selector)!.getBoundingClientRect();
      const greet = box(".comma-home-greet-rail");
      const tasks = box(".comma-home-tasks-rail");
      const chat = box(".comma-home-chat");
      return {
        chatCenter: Math.round(chat.left + chat.width / 2),
        greetGutter: Math.round((greet.right + chat.left) / 2),
        tasksGutter: Math.round((chat.right + tasks.left) / 2),
      };
    });
    expect((await readRailHandleIndicator(page, "greet"))?.handleCenter).toBe(
      gutterGeometry.greetGutter
    );
    expect((await readRailHandleIndicator(page, "tasks"))?.handleCenter).toBe(
      gutterGeometry.tasksGutter
    );

    // React Aria opens a tooltip on hover only once the interaction modality is
    // a pointer, and the modality is set by the first move — which a synthetic
    // hover would otherwise spend entering the handle itself.
    await page.mouse.move(gutterGeometry.chatCenter, 400);

    // Idle Home paints nothing in its gutters.
    expect(await readRailHandleIndicator(page, "greet")).toMatchObject({ opacity: 0 });
    const restingLength = (await readRailHandleIndicator(page, "greet"))!.height;

    // Landing on the handle lengthens it and names the action.
    await greetHandle.hover();
    await expect
      .poll(async () => (await readRailHandleIndicator(page, "greet"))?.height)
      .toBeGreaterThan(restingLength);
    await expect(page.getByRole("tooltip")).toHaveText(
      "Click to collapseDrag to resize"
    );

    // Greet alone: the rail leaves, Tasks keeps its width, and the handle has
    // ridden the boundary out to the route's own inset.
    const tasksWidth = async () =>
      tasksRail.evaluate((element) =>
        Math.round(element.getBoundingClientRect().width)
      );
    const openTasksWidth = await tasksWidth();
    await greetHandle.click();
    await expect(greetRail).toBeHidden();
    await expect(greetRail).toHaveAttribute("data-folded", "true");
    await expect(tasksRail).toBeVisible();
    expect(await tasksWidth()).toBe(openTasksWidth);
    await expect
      .poll(async () => (await readRailHandleIndicator(page, "greet"))?.handleCenter)
      .toBeLessThan(gutterGeometry.greetGutter);
    await greetHandle.hover();
    await expect(page.getByRole("tooltip")).toHaveText("Click to expand");
    await expect(greetHandle).toHaveAttribute("aria-expanded", "false");

    // Both at once: the chat column takes the whole route.
    await tasksHandle.click();
    await expect(tasksRail).toBeHidden();
    await expect(tasksRail).toHaveAttribute("data-folded", "true");
    const chatSpansRoute = () =>
      homeLayout.evaluate((layout) => {
        const chat = layout.querySelector<HTMLElement>(".comma-home-chat")!;
        const style = getComputedStyle(layout);
        return (
          Math.round(chat.getBoundingClientRect().width) ===
          Math.round(
            layout.getBoundingClientRect().width -
              Number.parseFloat(style.paddingLeft) -
              Number.parseFloat(style.paddingRight)
          )
        );
      });
    await expect.poll(chatSpansRoute).toBe(true);

    // Tasks alone, then both back: every combination is reachable from the
    // handles, and each rail returns to the width it left.
    await tasksHandle.click();
    await expect(tasksRail).toBeVisible();
    await expect(greetRail).toBeHidden();
    await expect.poll(tasksWidth).toBe(openTasksWidth);

    await greetHandle.click();
    await expect(greetRail).toBeVisible();
    await expect(greetRail).toHaveAttribute("data-folded", "false");
    await expect(greetHandle).toHaveAttribute("aria-expanded", "true");
    await expect
      .poll(async () => (await readRailHandleIndicator(page, "greet"))?.handleCenter)
      .toBe(gutterGeometry.greetGutter);

    // The shape survives a relaunch: collapse Tasks, reload, and Home comes
    // back the way it was left rather than re-opening a rail the reader shut.
    await tasksHandle.click();
    await expect(tasksRail).toHaveAttribute("data-folded", "true");
    await page.reload();
    await expect(homeLayout).toBeVisible();
    await expect(tasksRail).toHaveAttribute("data-folded", "true");
    await expect(tasksRail).toBeHidden();
    await expect(greetRail).toBeVisible();
    await expect(tasksHandle).toHaveAttribute("aria-expanded", "false");
    await expect(greetHandle).toHaveAttribute("aria-expanded", "true");
    await tasksHandle.click();
    await expect(tasksRail).toBeVisible();

    // A rail the route itself folded has nothing to expand into, so it offers
    // no handle — it comes back with the width, as it always has. (657px past
    // the 75px rail and the 8px inset leaves the route the 574px an 880px
    // window used to.)
    await page.setViewportSize({ width: 657, height: 900 });
    await expect(greetRail).toHaveAttribute("data-folded", "true");
    await expect(greetHandle).toHaveCount(0);
    await expect(tasksHandle).toHaveCount(0);
    await page.setViewportSize({ width: 1440, height: 900 });
    await expect(greetRail).toHaveAttribute("data-folded", "false");
    await expect(greetHandle).toHaveCount(1);
  } finally {
    await stub.close();
  }
});

test("collapsed Home rail handles do not share shell resize hit regions", async ({
  page,
}) => {
  const stub = await startChatSmokeStub();

  try {
    await page.setViewportSize({ width: 1800, height: 1000 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "home-rail-shell-hit-regions@comma.local",
      token: "comma_sess_home_rail_shell_hit_regions",
    });
    await page.goto("/");

    const greetRail = page.getByTestId("home-greet-rail");
    const tasksRail = page.getByTestId("home-tasks-rail");
    const greetHandle = page.getByTestId("home-greet-rail-handle");
    const tasksHandle = page.getByTestId("home-tasks-rail-handle");
    await expect(greetRail).toBeVisible();
    await expect(tasksRail).toBeVisible();

    await greetHandle.click();
    await expect(greetRail).toBeHidden();
    const greetHitTest = await readRailAndShellHandleHitTest(
      page,
      "greet",
      ".comma-sidebar-edge-toggle"
    );
    expect(greetHitTest).not.toBeNull();
    expect(greetHitTest!.horizontalOverlap).toBeLessThanOrEqual(0.01);
    expect(greetHitTest!.centerOwnedByRail).toBe(true);
    await page.mouse.click(greetHitTest!.center.x, greetHitTest!.center.y);
    await expect(greetRail).toBeVisible();

    const chatSidebarToggle = page.getByRole("button", {
      name: "Toggle chat sidebar",
    });
    await chatSidebarToggle.click();
    const chatSidebar = page.getByTestId("chat-sidebar");
    await expect(chatSidebar).toHaveAttribute("data-open", "true");

    await tasksHandle.click();
    await expect(tasksRail).toBeHidden();
    const tasksHitTest = await readRailAndShellHandleHitTest(
      page,
      "tasks",
      ".comma-chat-sidebar-resize-handle"
    );
    expect(tasksHitTest).not.toBeNull();
    expect(tasksHitTest!.horizontalOverlap).toBeLessThanOrEqual(0.01);
    expect(tasksHitTest!.centerOwnedByRail).toBe(true);
    await page.mouse.click(tasksHitTest!.center.x, tasksHitTest!.center.y);
    await expect(tasksRail).toBeVisible();
  } finally {
    await stub.close();
  }
});

test("Home rail controls keep working when persistence is unavailable", async ({
  page,
}) => {
  const stub = await startChatSmokeStub();

  try {
    await page.setViewportSize({ width: 1440, height: 900 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "home-rail-storage-failure@comma.local",
      token: "comma_sess_home_rail_storage_failure",
    });
    await page.goto("/");

    await page.evaluate(() => {
      const nativeSetItem = Storage.prototype.setItem;
      Storage.prototype.setItem = function (this: Storage, key, value) {
        if (key === "comma.homeRailCollapsed") {
          throw new DOMException("Storage quota exhausted", "QuotaExceededError");
        }
        nativeSetItem.call(this, key, value);
      };
    });

    const greetRail = page.getByTestId("home-greet-rail");
    const tasksRail = page.getByTestId("home-tasks-rail");
    const greetHandle = page.getByTestId("home-greet-rail-handle");
    const tasksHandle = page.getByTestId("home-tasks-rail-handle");
    await expect(greetRail).toBeVisible();
    await expect(tasksRail).toBeVisible();

    await greetHandle.click();
    await expect(greetRail).toBeHidden();
    await tasksHandle.click();
    await expect(tasksRail).toBeHidden();
    await greetHandle.click();
    await expect(greetRail).toBeVisible();
    await expect(tasksRail).toBeHidden();
  } finally {
    await stub.close();
  }
});

test("settings omit unsupported permission rows and search entries", async ({
  page,
  unavailableProductApi,
}) => {
  await installBrowserTestSession(page, {
    apiBaseUrl: unavailableProductApi,
    email: "permissions-settings@comma.local",
    token: "comma_sess_permissions_settings",
  });
  await page.goto("/#/settings");
  await expectSettledSettingsModal(page);
  await expect(
    page.locator('[data-setting-id="permissions.label-changes"]')
  ).toBeVisible();
  const search = page.getByRole("searchbox", { name: "Search settings" });
  for (const name of ["Default permissions", "Auto-review", "Full access"]) {
    await expect(page.getByText(name, { exact: true })).toHaveCount(0);
    await search.fill(name);
    await expect(page.getByText(name, { exact: true })).toHaveCount(0);
    await expect(
      page.locator('[data-slot="settings-search-results"] [data-setting-id]')
    ).toHaveCount(0);
  }
});

// The chat column's width, sampled once per animation frame across a Chat
// Sidebar toggle. Responsive folds beside the sidebar (the Task details
// column, Home's Tasks rail) decide from the route width the sidebar leaves
// once it settles, so the column reflows once and in one direction; deciding
// from a frame of the sidebar's width transition squeezed the column under
// the still-open panel and let it spring back when the fold landed.
async function sampleChatColumnAcrossToggle(page: Page, chatSelector: string) {
  await page.evaluate((selector) => {
    const aside = document.querySelector<HTMLElement>('[data-testid="chat-sidebar"]');
    const chat = document.querySelector<HTMLElement>(selector);
    if (!aside || !chat) throw new Error("toggle probe: missing elements");
    const widths: number[] = [];
    const start = performance.now();
    const sample = (now: number) => {
      widths.push(Math.round(chat.getBoundingClientRect().width));
      if (now - start < 700) requestAnimationFrame(sample);
    };
    requestAnimationFrame(sample);
    (window as Window & { commaChatColumnSamples?: number[] }).commaChatColumnSamples =
      widths;
  }, chatSelector);
  await page.getByTestId("chat-sidebar-toggle").click();
  await page.waitForTimeout(900);
  return page.evaluate(
    () =>
      (window as Window & { commaChatColumnSamples?: number[] })
        .commaChatColumnSamples ?? []
  );
}

// Frame-to-frame moves against the direction of travel. The two transitions
// that make up the reflow (the sidebar's width and the fold) run on their own
// easing, and Home's rail track is itself responsive to the route width, so a
// few pixels of wobble are legal; a squeeze-and-rebound is not.
function largestReverseStep(samples: number[], direction: "shrink" | "grow") {
  let largest = 0;
  for (let index = 1; index < samples.length; index += 1) {
    const step = samples[index]! - samples[index - 1]!;
    const reverse = direction === "shrink" ? step : -step;
    if (reverse > largest) largest = reverse;
  }
  return largest;
}

test("the Chat Sidebar folds the Task details column without squeezing the thread", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    taskAssistantMessages: Array.from(
      { length: 40 },
      (_, index) =>
        `第 ${index + 1} 条 Worker 记录。${"这是一段够长的正文，用来把转录撑过一屏。".repeat(6)}`
    ),
    taskSchedule: null,
    taskStatus: "completed",
  });

  try {
    await page.setViewportSize({ width: 1280, height: 800 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "sidebar-fold@comma.local",
      token: "comma_sess_sidebar_fold",
    });
    await page.goto(
      `/#/tasks/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`
    );
    const body = page.locator(".comma-chat-body");
    await expect(body).toHaveAttribute("data-panel-open", "true");
    await expect(page.getByText("第 40 条 Worker 记录。").last()).toBeVisible();

    // Opening: 1280 less the rail leaves the route under the panel's 1024px
    // breakpoint once the 440px sidebar is in, so the column folds — in the
    // same commit the sidebar starts moving, never after a squeeze.
    const opening = await sampleChatColumnAcrossToggle(page, ".comma-chat-main");
    await expect(body).toHaveAttribute("data-panel-open", "false");
    expect(opening.length).toBeGreaterThan(10);
    expect(opening.at(-1)!).toBeLessThan(opening[0]!);
    expect(Math.min(...opening)).toBe(opening.at(-1));
    expect(largestReverseStep(opening, "shrink")).toBe(0);

    const closing = await sampleChatColumnAcrossToggle(page, ".comma-chat-main");
    await expect(body).toHaveAttribute("data-panel-open", "true");
    expect(closing.at(-1)!).toBeGreaterThan(closing[0]!);
    expect(Math.max(...closing)).toBe(closing.at(-1));
    expect(largestReverseStep(closing, "grow")).toBe(0);
  } finally {
    await stub.close();
  }
});

test("a window drag folds the Task details column in step with the window", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    taskAssistantMessages: Array.from(
      { length: 40 },
      (_, index) =>
        `第 ${index + 1} 条 Worker 记录。${"这是一段够长的正文，用来把转录撑过一屏。".repeat(6)}`
    ),
    taskSchedule: null,
    taskStatus: "completed",
  });
  let labelReads = 0;
  page.on("request", (request) => {
    if (new URL(request.url()).pathname.endsWith("/task-labels")) labelReads += 1;
  });

  try {
    await page.setViewportSize({ width: 1280, height: 800 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "window-fold@comma.local",
      token: "comma_sess_window_fold",
    });
    await page.goto(
      `/#/tasks/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`
    );
    const body = page.locator(".comma-chat-body");
    await expect(body).toHaveAttribute("data-panel-open", "true");
    await expect(page.getByText("第 40 条 Worker 记录。").last()).toBeVisible();
    // Showing the details reads the Group's label catalog once.
    await expect.poll(() => labelReads).toBeGreaterThan(0);

    // Straddle the column's breakpoint (the route's --container-2xl, 1024px).
    const chrome = await page.evaluate(
      () =>
        window.innerWidth -
        document.querySelector(".comma-chat-route")!.getBoundingClientRect().width
    );
    const wide = Math.ceil(1024 + chrome) + 8;
    const narrow = wide - 16;
    await page.setViewportSize({ width: wide, height: 800 });
    await expect(body).toHaveAttribute("data-panel-open", "true");
    await page.waitForTimeout(700);
    const readsBeforeDrag = labelReads;

    const cdp = await page.context().newCDPSession(page);
    const restyled: number[] = [];
    cdp.on("Tracing.dataCollected", ({ value }) => {
      for (const event of value as {
        args?: { elementCount?: number };
        name?: string;
      }[])
        if (event.name === "UpdateLayoutTree" && event.args?.elementCount)
          restyled.push(event.args.elementCount);
    });
    const tracingDone = new Promise<void>((resolve) =>
      cdp.once("Tracing.tracingComplete", () => resolve())
    );
    await cdp.send("Tracing.start", {
      categories: "devtools.timeline",
      transferMode: "ReportEvents",
    });
    await page.evaluate(() => {
      const panel = document.querySelector('[data-testid="task-details-panel"]')!;
      const widths: number[] = [];
      let sampling = true;
      const sample = () => {
        widths.push(Math.round(panel.getBoundingClientRect().width));
        if (sampling) requestAnimationFrame(sample);
      };
      requestAnimationFrame(sample);
      (window as Window & { commaTaskPanelSamples?: unknown }).commaTaskPanelSamples = {
        stop: () => {
          sampling = false;
          return widths;
        },
      };
    });
    // A hand dragging the window edge back and forth across the breakpoint.
    for (let pass = 0; pass < 3; pass += 1) {
      await page.setViewportSize({ width: narrow, height: 800 });
      await expect(body).toHaveAttribute("data-panel-open", "false");
      await page.waitForTimeout(80);
      await page.setViewportSize({ width: wide, height: 800 });
      await expect(body).toHaveAttribute("data-panel-open", "true");
      await page.waitForTimeout(80);
    }
    const widths = await page.evaluate(() =>
      (
        window as Window & { commaTaskPanelSamples?: { stop: () => number[] } }
      ).commaTaskPanelSamples!.stop()
    );
    await cdp.send("Tracing.end");
    await tracingDone;

    // The column is either there or folded in every frame: the fold lands in
    // the frame the window crosses the breakpoint, with no track transition
    // chasing the edge. Was: a 150ms grid transition played every crossing.
    const openWidth = widths[0]!;
    expect(openWidth).toBeGreaterThan(0);
    expect(widths).toContain(0);
    expect(widths.filter((width) => width !== 0 && width !== openWidth)).toEqual([]);
    // A fold restyles the grid it changes, not the transcript inside it. Was:
    // an inherited custom property flipped on the body restyled every node of
    // the thread in the frame of each crossing.
    const threadNodes = await page
      .locator(".comma-chat-main")
      .evaluate((main) => main.querySelectorAll("*").length);
    expect(Math.max(...restyled)).toBeLessThan(threadNodes / 4);
    // Width is not a new look at the Task: unfolding reads nothing more.
    expect(labelReads).toBe(readsBeforeDrag);
  } finally {
    await stub.close();
  }
});

test("the Chat Sidebar folds Home's Tasks rail without squeezing the chat column", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({ includeTaskInInbox: true });

  try {
    await page.setViewportSize({ width: 1440, height: 800 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "home-rail-fold@comma.local",
      token: "comma_sess_home_rail_fold",
    });
    await page.goto("/");
    const chatColumn = '[data-testid="comma-route-outlet"] .comma-chat-composer';
    await expect(page.locator(chatColumn)).toBeVisible();
    const foldValue = () =>
      page.evaluate(() =>
        Number.parseFloat(
          getComputedStyle(
            document.querySelector(".comma-home-layout")!
          ).getPropertyValue("--comma-home-tasks-fold")
        )
      );
    expect(await foldValue()).toBe(0);

    // The Tasks rail folds under the open sidebar; the chat column narrows
    // from its full width to the folded one in one motion — before the fix it
    // dropped over 200px under the still-open rail, then sprang back. The
    // rail's own easing and responsive track leave a wobble of a few pixels.
    const wobblePx = 8;
    const opening = await sampleChatColumnAcrossToggle(page, chatColumn);
    await expect.poll(foldValue).toBe(1);
    expect(opening.length).toBeGreaterThan(10);
    expect(opening.at(-1)!).toBeLessThan(opening[0]!);
    expect(Math.min(...opening)).toBeGreaterThanOrEqual(opening.at(-1)! - wobblePx);
    expect(largestReverseStep(opening, "shrink")).toBeLessThanOrEqual(wobblePx);

    const closing = await sampleChatColumnAcrossToggle(page, chatColumn);
    await expect.poll(foldValue).toBe(0);
    expect(closing.at(-1)!).toBeGreaterThan(closing[0]!);
    expect(Math.max(...closing)).toBeLessThanOrEqual(closing.at(-1)! + wobblePx);
    expect(largestReverseStep(closing, "grow")).toBeLessThanOrEqual(wobblePx);
  } finally {
    await stub.close();
  }
});
