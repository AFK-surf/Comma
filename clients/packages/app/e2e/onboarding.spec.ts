import { readFileSync } from "node:fs";
import { expect, test, type Locator, type Page, type Route } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { chatSmokeWorkspace, startChatSmokeStub } from "../../../e2e/p0/chat-stub";

const workspacePath = `**/v1/comma/workspaces/${chatSmokeWorkspace.id}`;

const linear = {
  brand: "linear",
  category: "Integrations",
  description: "Plan product work",
  id: "linear",
  installed: false,
  locked: false,
  mcps: [],
  name: "Linear",
  skills: [],
  summary: "Plan product work",
};
const github = {
  ...linear,
  brand: "github",
  id: "github",
  installed: true,
  name: "GitHub",
  summary: "Issues, pull requests and code",
};

const routerModel = (name: string) => ({
  agent_id: "agt_router",
  model: "gpt-5",
  name,
  provider: "openai",
  role: "router",
  source: "platform_default",
  template_id: "tpl_default",
  template_name: "Default",
});

// The stub serves the page from another origin, so each answer carries the
// CORS headers a real API sends, and preflights are answered.
async function fulfillJson(route: Route, body: unknown) {
  const request = route.request();
  const headers = {
    "access-control-allow-credentials": "true",
    "access-control-allow-headers":
      request.headers()["access-control-request-headers"] ??
      "authorization,content-type,x-comma-session-transport",
    "access-control-allow-methods": "GET,POST,PUT,OPTIONS",
    "access-control-allow-origin": request.headers().origin ?? "*",
    "content-type": "application/json",
  };
  if (request.method() === "OPTIONS") {
    await route.fulfill({ headers, status: 204 });
    return;
  }
  await route.fulfill({ body: JSON.stringify(body), headers, status: 200 });
}

async function routeOnboardingApi(
  page: Page,
  { plugins = [linear, github] }: { plugins?: readonly (typeof linear)[] } = {}
) {
  const renames: unknown[] = [];
  const installChecks: unknown[] = [];
  let routerName = "Default workspace Router";
  let authorized = false;

  await page.route(`${workspacePath}/agent-models`, (route) =>
    fulfillJson(route, {
      agents: { router: routerModel(routerName), worker: routerModel("Worker") },
      available_models: [],
      platform_defaults: { router: null, worker: null },
      worker_default_template_id: null,
      workers: { items: [], next_cursor: null },
      workspace_id: chatSmokeWorkspace.id,
    })
  );
  // The Router is renamed as its Agent.
  await page.route(`${workspacePath}/agents/agt_router`, async (route) => {
    if (route.request().method() === "PATCH") {
      const body = route.request().postDataJSON() as { name: string };
      renames.push(body);
      routerName = body.name;
    }
    await fulfillJson(route, { agent_id: "agt_router", name: routerName });
  });
  await page.route(`${workspacePath}/plugins`, (route) =>
    fulfillJson(route, { data: plugins })
  );
  await page.route(`${workspacePath}/plugins/linear/install`, async (route) => {
    const body =
      route.request().method() === "POST"
        ? (route.request().postDataJSON() as { verify_only?: boolean })
        : {};
    if (body.verify_only) installChecks.push(body);
    await fulfillJson(
      route,
      authorized && body.verify_only
        ? { authorization: null, plugin: { ...linear, installed: true } }
        : { authorization: { state: "pending-linear" }, plugin: linear }
    );
  });

  return {
    authorize: () => {
      authorized = true;
    },
    installChecks,
    renames,
  };
}

/** The shadows a control draws around itself: its resting shadow, or a focus ring. */
const shadowOf = (control: Locator) =>
  control.evaluate((element) =>
    getComputedStyle(element)
      .boxShadow.split(/,(?![^(]*\))/)
      .map((layer) => layer.trim())
      .filter((layer) => !layer.startsWith("rgba(0, 0, 0, 0)"))
      .join(", ")
  );

// The shell's Search chord: Command on macOS, Control elsewhere.
const searchChord = (page: Page) =>
  page.evaluate(() =>
    /mac|iphone|ipad/i.test(`${navigator.platform} ${navigator.userAgent}`)
      ? "Meta+KeyK"
      : "Control+KeyK"
  );

const english = JSON.parse(
  readFileSync(new URL("../../i18n/messages/en.json", import.meta.url), "utf8")
) as Record<string, unknown>;

/** `text` matched literally inside a regular expression. */
const escape = (text: string) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

/**
 * One of Comma's lines in whichever tone this onboarding picked: the
 * catalog wordings in every voice of `key`, with `params` filled in.
 */
const said = (key: string, params: Record<string, string> = {}) => {
  const variants = ["", "_brisk", "_playful", "_warm", "_witty", "_minimal"].map(
    (suffix) =>
      escape(
        Object.entries(params).reduce(
          (text, [name, value]) => text.replace(`{${name}}`, value),
          english[`${key}${suffix}`] as string
        )
      )
  );
  return new RegExp(`^(?:${variants.join("|")})$`);
};

const greeting = said("onboarding_greeting_value");
const appsQuestion = said("onboarding_question_apps");

/** The intro's Start: it has the focus once the screen has dimmed and the mark has appeared. */
const introStart = (onboarding: Locator) =>
  onboarding.getByRole("button", { name: "Start", exact: true });

/** The onboarding's sound, as the page plays it. */
const sound = (page: Page) =>
  page.evaluate(() => {
    const audio = document.querySelector<HTMLAudioElement>(".comma-onboarding audio");
    return (
      audio && { playing: !audio.paused, time: audio.currentTime, volume: audio.volume }
    );
  });

/** Whether two boxes share any area. */
const overlaps = (
  a: { x: number; y: number; width: number; height: number },
  b: { x: number; y: number; width: number; height: number }
) =>
  a.x < b.x + b.width &&
  b.x < a.x + a.width &&
  a.y < b.y + b.height &&
  b.y < a.y + a.height;

test("a first sign-in walks the onboarding once, connects an app and names the assistant", async ({
  page,
}) => {
  const stub = await startChatSmokeStub();
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "onboarding@comma.local",
      onboardingCompleted: false,
      token: "comma_sess_onboarding",
    });
    const api = await routeOnboardingApi(page);
    await page.goto("/");

    const onboarding = page.getByRole("dialog", { name: "Welcome to Comma" });
    const thread = onboarding.locator(".comma-onboarding-thread");
    /** A message in the thread: the client's own bubble. */
    const bubble = (text: string | RegExp) =>
      thread
        .locator(".comma-chat-user-bubble-content")
        .getByText(text, { exact: typeof text === "string" });
    // The screen dims, then the Comma mark welcomes the user over Start,
    // which has the focus: Return starts at once.
    const start = introStart(onboarding);
    await expect(start).toBeFocused({ timeout: 10_000 });
    await expect(
      onboarding.getByRole("heading", { name: "Welcome to Comma" })
    ).toBeVisible();
    await page.keyboard.press("Enter");
    // Under the mark, Comma greets in the chat's own bubbles.
    await expect(bubble(greeting)).toBeVisible();
    await expect(start).toHaveCount(0);
    // The intro's sound plays: by itself, or from that first key where the
    // browser waits for one.
    await expect
      .poll(async () => {
        const playing = await sound(page);
        return Boolean(playing?.playing && playing.time > 0);
      })
      .toBe(true);

    // Return, as a click anywhere, brings the rest of what Comma says at once,
    // and its question comes with the apps card under it. The web has no
    // macOS grants, so there are two things to do.
    await expect(onboarding.getByRole("button", { name: "Continue" })).toBeFocused();
    await page.keyboard.press("Enter");
    const apps = onboarding.getByRole("group", { name: appsQuestion });
    await expect(apps).toBeVisible();
    await expect(bubble(said("onboarding_greeting_items_two"))).toBeVisible();
    await expect(onboarding.getByText(/this Mac/)).toHaveCount(0);

    // The card takes the focus itself, not its primary: the key that hurried
    // Comma along never answers the card, and pressing it again does nothing.
    await expect(apps).toBeFocused();
    await page.keyboard.press("Enter");
    await expect(apps).toBeFocused();
    await expect(onboarding.getByRole("group", { name: appsQuestion })).toBeVisible();
    // Tab moves into its controls, and only that shows a ring: focus the
    // onboarding moves itself shows none.
    const firstControl = apps.getByRole("button").first();
    const restingShadow = await shadowOf(firstControl);
    await page.keyboard.press("Tab");
    await expect(firstControl).toBeFocused();
    expect(await shadowOf(firstControl)).not.toBe(restingShadow);

    // The shell's shortcuts stand down under the onboarding: neither Search
    // nor a navigation sequence reaches the app behind it. Both would act on
    // the key press, before the next card below arrives.
    const search = page.getByRole("dialog", { name: "Search Comma" });
    await page.keyboard.press(await searchChord(page));
    await page.keyboard.press("KeyG");
    await page.keyboard.press("KeyI");

    // Electron merges window drag regions in document order. The overlay
    // follows the shell, so its drag strip moves the window and its card stays
    // clickable over the shell's own drag regions.
    const regions = await page.evaluate(() => {
      const shell = document.querySelector(".comma-app-shell");
      const card = document.querySelector(".comma-onboarding-card");
      const strip = document.querySelector(".comma-onboarding__drag-strip");
      return {
        card: card && getComputedStyle(card).getPropertyValue("-webkit-app-region"),
        followsShell: Boolean(
          shell &&
          card &&
          shell.compareDocumentPosition(card) & Node.DOCUMENT_POSITION_FOLLOWING
        ),
        strip: strip && getComputedStyle(strip).getPropertyValue("-webkit-app-region"),
      };
    });
    expect(regions).toEqual({ card: "no-drag", followsShell: true, strip: "drag" });

    // GitHub was connected before; Linear is signed in to in the browser, and
    // its row says where to finish.
    await expect(apps.getByRole("button", { name: "Connect GitHub" })).toHaveCount(0);
    await apps.getByRole("button", { name: "Connect Linear" }).click();
    await expect(
      apps.getByText("Finish in your browser, then come back here.")
    ).toBeVisible();
    api.authorize();
    await expect(apps.getByRole("button", { name: "Connect Linear" })).toHaveCount(0);
    expect(api.installChecks.length).toBeGreaterThan(0);

    // The card leaves, the user's reply is sent in its place, and Comma
    // answers it before asking for a name.
    await apps.getByRole("button", { name: "Continue" }).click();
    await expect(bubble("Connected GitHub and Linear")).toBeVisible();
    await expect(
      // It says what it does with each app it knows.
      bubble(
        said("onboarding_bridge_apps_uses", {
          apps: "GitHub and Linear",
          uses: "GitHub issues and PRs that mention you and Linear issues that mention you",
        })
      )
    ).toBeVisible();
    const name = onboarding.getByRole("textbox", { name: "Assistant name" });
    await expect(name).toBeFocused({ timeout: 10_000 });
    await expect(onboarding.getByRole("group", { name: appsQuestion })).toHaveCount(0);
    await expect(search).toHaveCount(0);
    await expect(page).toHaveURL(/\/(?:#\/)?$/);

    await name.fill("  Atlas ");
    await name.press("Enter");
    // The reply is the name, and Comma speaks under it from then on, saying
    // what the Router does for the user from now on.
    await expect(bubble("Atlas")).toBeVisible();
    await expect(
      bubble(said("onboarding_bridge_name_named", { name: "Atlas" }))
    ).toBeVisible();
    await expect(thread.locator(".comma-onboarding-thread__speaker").last()).toHaveText(
      "Atlas"
    );
    await expect(bubble(said("onboarding_bridge_name_router"))).toBeVisible();
    expect(api.renames).toEqual([{ name: "Atlas" }]);

    // After the last answer, a light sweeps the conversation away for the
    // welcome page.
    await expect(
      onboarding.getByRole("heading", { name: "Atlas is ready." })
    ).toBeVisible();
    await expect(onboarding.getByText("Ask it for anything.")).toBeVisible();
    await expect(onboarding.locator(".comma-onboarding-thread")).toHaveCount(0);
    const startChatting = onboarding.getByRole("button", { name: "Start chatting" });
    await expect(startChatting).toBeFocused();
    await startChatting.click();

    await expect(onboarding).toHaveCount(0);
    const content = page.getByRole("region", { name: "Content" });
    await expect(content).toBeVisible();
    // Start chatting lands in the chat: Home's composer has the focus.
    await expect(content.getByRole("textbox", { name: "AI prompt" })).toBeFocused();

    // With the onboarding gone, the shortcuts are the shell's again.
    await page.keyboard.press(await searchChord(page));
    await expect(search).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(search).toHaveCount(0);

    await page.reload();
    await expect(content.getByRole("textbox", { name: "AI prompt" })).toBeVisible();
    await expect(page.getByRole("dialog", { name: "Welcome to Comma" })).toHaveCount(0);
  } finally {
    await stub.close();
  }
});

test("a line flies in without laying the thread out again on every frame", async ({
  page,
}) => {
  const stub = await startChatSmokeStub();
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "onboarding-flight@comma.local",
      onboardingCompleted: false,
      token: "comma_sess_onboarding_flight",
    });
    await routeOnboardingApi(page);
    await page.goto("/");
    const onboarding = page.getByRole("dialog", { name: "Welcome to Comma" });
    await expect(introStart(onboarding)).toBeFocused({ timeout: 10_000 });
    await page.keyboard.press("Enter");
    const line = (id: number) =>
      onboarding.locator(`[data-onboarding-message="${id}"] .comma-chat-user-bubble`);
    await expect(line(0)).toBeVisible();
    await expect(line(0)).not.toHaveAttribute("data-outgoing-presentation");

    // Record the next line's flight: every layout, and where the Comma mark
    // at the group's latest bubble is drawn on each frame.
    const cdp = await page.context().newCDPSession(page);
    const events: { name: string; ts: number }[] = [];
    cdp.on("Tracing.dataCollected", ({ value }) => {
      for (const event of value as unknown as { name: string; ts: number }[])
        events.push(event);
    });
    await cdp.send("Tracing.start", {
      categories: "devtools.timeline,blink.user_timing",
      transferMode: "ReportEvents",
    });
    const flight = await page.evaluateHandle(() => {
      const marks: number[] = [];
      let flying = false;
      let done = false;
      const sample = () => {
        const bubble = document.querySelector(
          '[data-onboarding-message="1"] .comma-chat-user-bubble'
        );
        const now = bubble?.getAttribute("data-outgoing-presentation") === "flying";
        if (now && !flying) performance.mark("flight-start");
        if (flying && !now) {
          performance.mark("flight-end");
          done = true;
        }
        flying = now;
        if (now) {
          const mark = document.querySelector(".comma-onboarding-thread__avatar");
          marks.push(mark?.getBoundingClientRect().top ?? Number.NaN);
        }
        if (!done) requestAnimationFrame(sample);
      };
      requestAnimationFrame(sample);
      return {
        landed: () => done,
        marks: () => marks,
        rest: () =>
          document
            .querySelector(".comma-onboarding-thread__avatar")!
            .getBoundingClientRect().top,
      };
    });
    await expect.poll(() => flight.evaluate((record) => record.landed())).toBe(true);
    const complete = new Promise<void>((resolve) =>
      cdp.once("Tracing.tracingComplete", () => resolve())
    );
    await cdp.send("Tracing.end");
    await complete;

    const at = (name: string) => events.find((event) => event.name === name)!.ts;
    const layouts = events.filter(
      (event) =>
        event.name === "Layout" &&
        event.ts > at("flight-start") &&
        event.ts < at("flight-end")
    );
    // The new line's slot is laid out whole as it leaves; what it pushes
    // aside moves on the compositor. A slot growing frame by frame would lay
    // the thread out on every one of the flight's frames.
    expect(layouts.length).toBeLessThan(8);
    // The line flies for a real flight, however many frames a slow machine
    // draws of it (trace times are in microseconds; the flight lasts about
    // half a second, a jump or the reduced-motion fade far less)...
    expect(at("flight-end") - at("flight-start")).toBeGreaterThan(300_000);
    // ...and the mark glides with it to its new place.
    const marks = await flight.evaluate((record) => record.marks());
    expect(new Set(marks.map((top) => Math.round(top))).size).toBeGreaterThan(5);
    for (let index = 1; index < marks.length; index += 1) {
      expect(marks[index]!).toBeGreaterThanOrEqual(marks[index - 1]! - 0.5);
    }
    expect(
      Math.abs(marks.at(-1)! - (await flight.evaluate((record) => record.rest())))
    ).toBeLessThan(1);
  } finally {
    await stub.close();
  }
});

test("Close ends the onboarding from the intro, and it stays finished", async ({
  page,
}) => {
  const stub = await startChatSmokeStub();
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "onboarding-skip@comma.local",
      onboardingCompleted: false,
      token: "comma_sess_onboarding_skip",
    });
    const api = await routeOnboardingApi(page);
    await page.goto("/");

    const onboarding = page.getByRole("dialog", { name: "Welcome to Comma" });
    // Close is there from the start, while the screen dims, in the
    // window's top-right corner under the strip that moves the window.
    const skip = onboarding.getByRole("button", { name: "Close onboarding" });
    await expect(skip).toBeVisible();
    const corner = (await skip.boundingBox())!;
    const { width } = page.viewportSize()!;
    expect(width - (corner.x + corner.width)).toBeLessThanOrEqual(32);
    expect(corner.y).toBeGreaterThanOrEqual(48);
    expect(corner.y).toBeLessThanOrEqual(64);

    // The sound's volume sits on the same line, left of Close. Its
    // slider opens under it; a press with the slider open mutes.
    const volume = onboarding.getByRole("button", { name: /^(Volume \d+%|Muted)$/ });
    await expect(volume).toHaveAccessibleName("Volume 100%");
    const disc = (await volume.boundingBox())!;
    expect(disc.width).toBe(corner.width);
    expect(Math.abs(disc.y - corner.y)).toBeLessThanOrEqual(0.5);
    expect(corner.x - (disc.x + disc.width)).toBeGreaterThanOrEqual(8);
    await volume.click();
    const slider = onboarding.getByRole("slider", { name: "Volume" });
    await expect(slider).toBeVisible();
    expect((await slider.boundingBox())!.y).toBeGreaterThan(disc.y + disc.height);
    await volume.click();
    await expect(volume).toHaveAccessibleName("Muted");
    await expect.poll(async () => (await sound(page))?.volume).toBe(0);
    await page.keyboard.press("Escape");
    await expect(slider).toBeHidden();
    // Close leaves from the intro, without the welcome page.
    await skip.click();
    await expect(onboarding).toHaveCount(0);
    expect(api.renames).toEqual([]);
    await page.reload();
    await expect(
      page
        .getByRole("region", { name: "Content" })
        .getByRole("textbox", { name: "AI prompt" })
    ).toBeVisible();
    await expect(page.getByRole("dialog", { name: "Welcome to Comma" })).toHaveCount(0);
  } finally {
    await stub.close();
  }
});

test("a long app catalog scrolls inside the card, which stays on screen", async ({
  page,
}) => {
  const stub = await startChatSmokeStub();
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "onboarding-catalog@comma.local",
      onboardingCompleted: false,
      token: "comma_sess_onboarding_catalog",
    });
    const catalog = Array.from({ length: 40 }, (_, index) => ({
      ...linear,
      id: `plugin-${index + 1}`,
      name: `Plugin ${index + 1}`,
    }));
    await routeOnboardingApi(page, { plugins: catalog });
    await page.goto("/");

    const onboarding = page.getByRole("dialog", { name: "Welcome to Comma" });
    await introStart(onboarding).click({ timeout: 10_000 });
    await onboarding.getByRole("button", { name: "Continue" }).click();
    const list = onboarding.getByRole("list", { name: "Apps to connect" });
    await expect(list.getByRole("listitem")).toHaveCount(40);

    // However long the catalog, the question, the card and its action stay in view.
    const apps = onboarding.getByRole("group", { name: appsQuestion });
    const primary = apps.getByRole("button", { name: "Skip for now" });
    const question = onboarding
      .locator(".comma-chat-user-bubble-content")
      .getByText(appsQuestion);
    await expect(primary).toBeInViewport();
    await expect(question).toBeInViewport();

    // The mark heads the conversation at the top, centred on Close's line,
    // clear of Close and of the question under it.
    const mark = (await onboarding
      .locator(".comma-onboarding-intro__mark")
      .boundingBox())!;
    const skip = (await onboarding
      .getByRole("button", { name: "Close onboarding" })
      .boundingBox())!;
    const asked = (await question.boundingBox())!;
    const conversation = (await onboarding
      .locator(".comma-onboarding-thread__content")
      .boundingBox())!;
    const { width } = page.viewportSize()!;
    expect(Math.abs(mark.x + mark.width / 2 - width / 2)).toBeLessThanOrEqual(1);
    expect(
      Math.abs(mark.y + mark.height / 2 - (skip.y + skip.height / 2))
    ).toBeLessThanOrEqual(1);
    expect(mark.width).toBeLessThanOrEqual(32);
    expect(overlaps(mark, skip)).toBe(false);
    expect(mark.y + mark.height).toBeLessThan(asked.y);
    expect(skip.x).toBeGreaterThan(conversation.x + conversation.width);

    // The last app is reached by scrolling the list, not the window.
    const last = apps.getByRole("button", { name: "Connect Plugin 40" });
    await expect(last).not.toBeInViewport();
    await last.scrollIntoViewIfNeeded();
    await expect(last).toBeInViewport();
    await expect(primary).toBeInViewport();
  } finally {
    await stub.close();
  }
});
