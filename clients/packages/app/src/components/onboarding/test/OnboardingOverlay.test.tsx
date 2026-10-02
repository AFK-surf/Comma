import { initializeCommaI18n, messages as commaMessages } from "@comma/i18n";
import {
  defaultOpenCommaShortcut,
  defaultSideChatShortcut,
} from "@comma/native-bridge";
import { CommaI18nProvider } from "@comma/i18n/react";
import {
  act,
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
  within,
} from "@comma/test-utils/render";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import userEvent from "@testing-library/user-event";
import { StrictMode } from "react";
import {
  afterEach,
  beforeEach,
  describe,
  expect,
  it,
  vi,
  type MockInstance,
} from "vitest";
import {
  OnboardingOverlay,
  onboardingVoicedKeys,
  onboardingVoices,
  type OnboardingOverlayProps,
} from "../OnboardingOverlay";
import type { OnboardingPluginRow } from "../useOnboardingPlugins";

const readyWorkspace = { status: "ready", workspaceId: "wsp_ready" } as const;

type Connections = Partial<Record<string, OnboardingPluginRow["connection"]>>;

/** GitHub, Notion and Linear, each in the given state (idle by default). */
const apps = (connections: Connections = {}) => ({
  status: "ready" as const,
  rows: [
    { brand: "github", id: "github", name: "GitHub", summary: "Code" },
    { brand: "notion", id: "notion", name: "Notion", summary: "Docs" },
    { brand: "linear", id: "linear", name: "Linear", summary: "Plan product work" },
  ].map((row) => ({ ...row, connection: connections[row.id] ?? "idle" })),
});

/**
 * A stand-in for the macOS grants card: it moves on with two of three allowed,
 * both Computer Use grants unless `computerUse` is false.
 */
const grantsAllowing =
  ({ computerUse = true } = {}): OnboardingOverlayProps["renderPermissions"] =>
  ({ assistantName, onAdvance }) => (
    <button
      onClick={() =>
        onAdvance({
          allowed: 2,
          computerUse,
          missing: computerUse ? ["notifications"] : ["screenRecording"],
          total: 3,
        })
      }
      type="button"
    >
      {`Grants for ${assistantName}`}
    </button>
  );
const grants = grantsAllowing();

function renderOverlay({
  locale = "en",
  strict = false,
  ...props
}: Partial<OnboardingOverlayProps> & {
  locale?: "en" | "zh-CN";
  /** Inside StrictMode, as the app's development renderer mounts it. */
  strict?: boolean;
} = {}) {
  const handlers = {
    onComplete: vi.fn(),
    onConnectPlugin: vi.fn(),
    onExited: vi.fn(),
    onSaveRouterName: vi.fn(async () => undefined),
  };
  const view = (overrides: Partial<OnboardingOverlayProps>) => {
    const overlay = (
      <CommaI18nProvider locale={locale}>
        <OnboardingOverlay
          initialStage="apps"
          plugins={apps()}
          presentation="overlay"
          routerName="Default workspace Router"
          workspace={readyWorkspace}
          {...handlers}
          {...props}
          {...overrides}
        />
      </CommaI18nProvider>
    );
    return strict ? <StrictMode>{overlay}</StrictMode> : overlay;
  };
  const result = render(view({}));
  return {
    ...handlers,
    rerender: (overrides: Partial<OnboardingOverlayProps>) =>
      result.rerender(view(overrides)),
  };
}

const button = (name: string | RegExp) => screen.getByRole("button", { name });
/** The card on show: a group named by the question it answers. */
const card = (question: string) => screen.findByRole("group", { name: question });
/** A message in the thread, by its words. */
const message = (text: string, timeout = 3000) =>
  screen.findByText(text, { selector: ".comma-chat-user-bubble-content" }, { timeout });
/** The label over each of Comma's groups of messages, in thread order. */
const speakers = () =>
  [...document.querySelectorAll(".comma-onboarding-thread__speaker")].map(
    (label) => label.textContent
  );
/** Lets `ms` pass on the fake clock, rendering what each step brings. */
async function pass(ms: number) {
  for (let step = 0; step < ms; step += 50) {
    await act(() => vi.advanceTimersByTimeAsync(Math.min(50, ms - step)));
  }
}
/** A press as assistive tech makes it, which needs no real timer. */
const press = (control: HTMLElement) => act(() => control.click());
/** While Comma talks, a click anywhere brings the rest of what it says at once. */
const hurry = async (name = "Continue") =>
  userEvent.click(await screen.findByRole("button", { name }));

/** Comma's first line, once the intro has welcomed the user. */
const greeting =
  "I’m your Router. Tell me what needs doing, and I’ll split it into Tasks and hand them to Workers that work at the same time.";
const appsQuestion =
  "Let’s start with your apps: connect the ones you work in, so I can work with your email, calendar, docs and code.";
const nameQuestion = "Next, give me a name.";
const macQuestion = "Last, let me work on this Mac. All optional.";
/** What Comma says, after the naming, it does for the user from now on. */
const routerRole =
  "From now on, bring me anything. I’ll break it into Tasks, hand them to the right Workers, keep an eye on progress and bring you the results. When a call is yours to make, I’ll ask.";

/** The onboarding's sound. */
const soundElement = () => document.querySelector("audio")!;
/**
 * The thread as read out to assistive tech. React Aria keeps live regions of
 * its own on the page once anything has announced, so this one is found
 * inside the onboarding.
 */
const threadLog = () =>
  within(screen.getByRole("dialog", { name: "Welcome to Comma" })).getByRole("log");

/** The step, once it has arrived and taken the focus. */
const shortcutStep = async () => {
  await pass(500);
  const step = screen.getByRole("group", { name: "Try Option + Comma" });
  expect(step).toHaveFocus();
  return step;
};
const status = (step: HTMLElement) => within(step).getByRole("status");
/** A key going down where the focus is, as the keyboard sends it. */
const keyDown = (target: HTMLElement, init: KeyboardEventInit) =>
  act(() => {
    fireEvent.keyDown(target, init);
  });
/** A key going up where the focus is. */
const keyUp = (target: HTMLElement, init: KeyboardEventInit) =>
  act(() => {
    fireEvent.keyUp(target, init);
  });
const optionDown = { altKey: true, code: "AltLeft", key: "Alt" };
const optionUp = { altKey: false, code: "AltLeft", key: "Alt" };
const commaDown = { code: "Comma", key: "," };

describe("OnboardingOverlay", () => {
  it("has every line Comma says worded in every voice, in both languages", () => {
    // A voice picked at random must never reach a line it has no wording for.
    const catalog = commaMessages as unknown as Record<string, unknown>;
    for (const key of onboardingVoicedKeys) {
      for (const voice of onboardingVoices) {
        const name = voice === "calm" ? key : `${key}_${voice}`;
        expect(typeof catalog[name], name).toBe("function");
      }
    }
  });

  // jsdom plays no media: playing resolves at once and pausing does nothing.
  let play: MockInstance<HTMLMediaElement["play"]>;
  let pause: MockInstance<HTMLMediaElement["pause"]>;

  beforeEach(() => {
    initializeCommaI18n(["en"]);
    play = vi.spyOn(HTMLMediaElement.prototype, "play").mockResolvedValue(undefined);
    pause = vi.spyOn(HTMLMediaElement.prototype, "pause").mockReturnValue(undefined);
  });

  afterEach(() => {
    vi.useRealTimers();
    // The onboarding stops its sound as it unmounts, still on the stand-ins.
    cleanup();
    vi.restoreAllMocks();
  });

  // On the fake clock the intro's timing is exact: the screen dims for three
  // seconds, the mark arrives, and Start appears 880ms after it. Presses are
  // dispatched directly: user-event waits on a real timer the fake clock
  // never runs.
  describe("intro", () => {
    const startAppears = 3000 + 880;

    it("dims the screen, welcomes, and begins by itself eight seconds after Start appears", async () => {
      vi.useFakeTimers();
      renderOverlay({ initialStage: "intro" });

      // While the screen dims, nothing is shown or reachable but Close.
      expect(screen.queryByRole("button", { name: "Start" })).toBeNull();
      await pass(3000);
      expect(screen.getByRole("heading", { name: "Welcome to Comma" })).toBeVisible();
      const start = screen.getByRole("button", { name: "Start" });
      await pass(startAppears - 3000);
      expect(start).toHaveFocus();
      // Start shows no countdown: it holds its label and nothing else.
      expect(
        [...start.querySelectorAll("*")].every((part) => part.textContent === "Start")
      ).toBe(true);

      // Nothing happens for eight seconds; then it starts by itself.
      await pass(7900);
      expect(start).toBeEnabled();
      await pass(100);
      expect(start).toBeDisabled();
      expect(screen.queryByText(greeting)).toBeNull();
      // The mark moves up to head the conversation, then Comma talks.
      await pass(1500);
      expect(screen.queryByRole("button", { name: "Start" })).toBeNull();
      expect(
        screen.getByText(greeting, { selector: ".comma-chat-user-bubble-content" })
      ).toBeInTheDocument();
      expect(speakers()).toEqual(["Comma"]);
    });

    it("begins at once when Start is clicked", async () => {
      vi.useFakeTimers();
      renderOverlay({ initialStage: "intro" });
      await pass(startAppears);

      const start = screen.getByRole("button", { name: "Start" });
      await press(start);
      expect(start).toBeDisabled();
      // The mark stops, moves up to head the conversation, and Comma talks.
      await pass(1500);

      expect(
        screen.getByText(greeting, { selector: ".comma-chat-user-bubble-content" })
      ).toBeInTheDocument();
      expect(screen.queryByRole("heading", { name: "Welcome to Comma" })).toBeNull();
    });

    it.each([
      ["while the screen dims", 1000],
      ["while Start waits", startAppears + 4000],
    ])(
      "closes the onboarding from Close %s, without the welcome page",
      async (_when, pressAt) => {
        vi.useFakeTimers();
        const { onComplete, onExited } = renderOverlay({ initialStage: "intro" });
        await pass(pressAt);

        await press(button("Close onboarding"));
        // Closing counts as finished, at once.
        expect(onComplete).toHaveBeenCalledOnce();
        await pass(3000);

        expect(onExited).toHaveBeenCalledOnce();
        expect(screen.queryByRole("heading", { name: "Comma is ready." })).toBeNull();
        expect(screen.queryByRole("button", { name: "Start chatting" })).toBeNull();
        expect(screen.queryByText(greeting)).toBeNull();
      }
    );
  });

  describe("sound", () => {
    it("plays once as the screen starts to dim, and fades out as the onboarding exits", async () => {
      const { onExited } = renderOverlay({ initialStage: "intro" });
      await waitFor(() => expect(play).toHaveBeenCalledOnce());
      expect(play.mock.contexts[0]).toBe(soundElement());

      // Closed while it plays: it fades to silence and stops before the
      // onboarding is gone, and nothing on the way plays it again.
      vi.spyOn(HTMLMediaElement.prototype, "paused", "get").mockReturnValue(false);
      await userEvent.click(button("Close onboarding"));
      expect(play).toHaveBeenCalledOnce();
      await waitFor(() => expect(pause).toHaveBeenCalledOnce());
      expect(soundElement().volume).toBe(0);
      expect(onExited).not.toHaveBeenCalled();
      await waitFor(() => expect(onExited).toHaveBeenCalledOnce());
    });

    it.each([
      ["30% quieter on a Mac over half volume", 0.8, 0.7],
      ["as set on a Mac at half volume or less", 0.4, 1],
      ["as set where the Mac's volume is unknown", null, 1],
    ])("plays %s", async (_case, system, expected) => {
      installNativeBridgeMock({
        onboarding: { outputVolume: vi.fn(async () => ({ volume: system })) },
      });
      renderOverlay({ initialStage: "intro" });
      // It starts at the volume it keeps: never loud first.
      await waitFor(() => expect(play).toHaveBeenCalledOnce());
      expect(soundElement().volume).toBe(expected);

      // The user's own volume applies on top of it.
      await userEvent.click(button("Volume 100%"));
      fireEvent.change(screen.getByRole("slider", { name: "Volume" }), {
        target: { value: "0.5" },
      });
      expect(soundElement().volume).toBeCloseTo(expected * 0.5);
    });

    it("clicks as Start and Start chatting are pressed, not as Start starts by itself", async () => {
      vi.useFakeTimers();
      const clicks = vi.spyOn(HTMLMediaElement.prototype, "play");
      const clicked = () =>
        clicks.mock.contexts.filter((element) =>
          (element as HTMLMediaElement).src.includes("onboarding-click")
        ).length;
      renderOverlay({ initialStage: "intro" });
      await pass(3000 + 880 + 8000);
      expect(clicked()).toBe(0);

      cleanup();
      renderOverlay({ initialStage: "intro" });
      await pass(3000 + 880);
      await press(button("Start"));
      expect(clicked()).toBe(1);

      cleanup();
      renderOverlay({ initialStage: "welcome" });
      await pass(3000);
      await press(button("Start chatting"));
      expect(clicked()).toBe(2);
    });

    it("plays on the first press or key when the browser refuses to play it by itself, and only once", async () => {
      play.mockRejectedValueOnce(new DOMException("No gesture yet", "NotAllowedError"));
      renderOverlay({ initialStage: "intro" });
      await waitFor(() => expect(play).toHaveBeenCalledOnce());

      // A modifier on its own is not the user acting on the page.
      fireEvent.keyDown(document.body, { key: "Shift" });
      fireEvent.pointerUp(document.body);
      await waitFor(() => expect(play).toHaveBeenCalledTimes(2));

      fireEvent.pointerUp(document.body);
      fireEvent.keyDown(document.body, { key: "Enter" });
      await new Promise((resolve) => setTimeout(resolve, 50));
      expect(play).toHaveBeenCalledTimes(2);
    });

    it("sits left of Close, and its slider and mute change the volume as they go", async () => {
      renderOverlay({ initialStage: "intro" });
      const volume = button("Volume 100%");
      // One corner, the volume first: it reads, and is reached, before Close.
      const corner = [
        ...volume.closest(".comma-onboarding__corner")!.querySelectorAll("button"),
      ];
      expect(corner).toEqual([volume, button("Close onboarding")]);
      expect(soundElement().volume).toBe(1);

      // The first press opens the slider under it.
      await userEvent.click(volume);
      expect(screen.getByRole("dialog", { name: "Sound volume" })).toBeVisible();
      fireEvent.change(screen.getByRole("slider", { name: "Volume" }), {
        target: { value: "0.42" },
      });
      expect(soundElement().volume).toBe(0.42);
      expect(button("Volume 42%")).toBe(volume);

      // A press with the slider open mutes, and the next one brings it back.
      await userEvent.click(volume);
      expect(soundElement().volume).toBe(0);
      expect(volume).toHaveAccessibleName("Muted");
      await userEvent.click(volume);
      expect(soundElement().volume).toBe(0.42);
    });

    it("mutes from M, except while a name is typed", async () => {
      initializeCommaI18n(["zh-CN"]);
      renderOverlay({ initialStage: "name", locale: "zh-CN" });
      const nameCard = await card("接下来，给我起个名字吧。");

      await userEvent.type(
        within(nameCard).getByRole("textbox", { name: "助手名字" }),
        "Momo"
      );
      expect(soundElement().volume).toBe(1);
      expect(button("音量 100%")).toBeInTheDocument();

      await userEvent.click(within(nameCard).getByRole("button", { name: "继续" }));
      await userEvent.keyboard("m");
      expect(soundElement().volume).toBe(0);
      expect(button("已静音")).toBeInTheDocument();
      await userEvent.keyboard("M");
      expect(soundElement().volume).toBe(1);
    });
  });

  it("greets as Comma in three lines, then asks for the apps with their card under the question", async () => {
    renderOverlay({ initialStage: "greeting" });

    expect(await message(greeting)).toBeInTheDocument();
    // An assistant without a name of its own is Comma, never "Router".
    expect(speakers()).toEqual(["Comma"]);
    expect(screen.queryByRole("group", { name: appsQuestion })).toBeNull();

    // A click anywhere sends the rest of the greeting and the question at once.
    await hurry();
    // The web has no macOS grants: two things to do.
    expect(await message("First, two quick things.")).toBeInTheDocument();
    const appsCard = await card(appsQuestion);
    expect(
      within(appsCard).getByRole("button", { name: "Skip for now" })
    ).toBeEnabled();
    expect(speakers()).toEqual(["Comma"]);
    // Three lines of greeting before the question; the intro said the welcome.
    expect(
      [...threadLog().querySelectorAll("p")].map((line) => line.textContent)
    ).toEqual([
      greeting,
      "No group chats to set up, no agents to add. Just talk to me.",
      "First, two quick things.",
      appsQuestion,
    ]);
  });

  it("labels the greeting with the stored name once it is read, however late", async () => {
    const { rerender } = renderOverlay({
      initialStage: "greeting",
      routerName: undefined,
    });
    expect(await message(greeting)).toBeInTheDocument();

    // The Router was named on another device; its name arrives after the first line.
    rerender({ routerName: "Nova" });
    await hurry();
    expect(await card(appsQuestion)).toBeInTheDocument();
    expect(speakers()).toEqual(["Nova"]);
  });

  it("sizes the apps list from a rendered row, which a larger font makes taller", async () => {
    // Stands in for layout: room for three rows of the default size's 60px
    // over the composer, and rows the large font size makes 66px tall.
    const listRoom = 190;
    const overThread = 164;
    class Layout {
      constructor(private readonly report: ResizeObserverCallback) {}
      observe(target: Element) {
        const height = target.matches(".comma-onboarding-app")
          ? 66
          : target.matches(".comma-onboarding-thread")
            ? listRoom + overThread
            : undefined;
        if (height === undefined) return;
        const entry = {
          borderBoxSize: [{ blockSize: height, inlineSize: 480 }],
          contentRect: { height },
          target,
        } as unknown as ResizeObserverEntry;
        this.report([entry], this as unknown as ResizeObserver);
      }
      unobserve() {}
      disconnect() {}
    }
    vi.stubGlobal("ResizeObserver", Layout);
    try {
      renderOverlay();
      const list = await screen.findByRole("list", { name: "Apps to connect" });
      // Three 66px rows do not fit in 190px: the list keeps two and a half
      // of them, the half row saying it scrolls.
      await waitFor(() => {
        const sized = getComputedStyle(list);
        expect(sized.getPropertyValue("--onboarding-app-row")).toBe("66px");
        expect(sized.getPropertyValue("--onboarding-list-rows")).toBe("2.5");
      });
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it("reads out every line Comma says at once when hurried, not only the last", async () => {
    renderOverlay({ initialStage: "greeting" });
    await message(greeting);

    await hurry();
    await card(appsQuestion);
    const log = threadLog();
    expect(log).toHaveTextContent("No group chats to set up");
    expect(log).toHaveTextContent("First, two quick things.");
    expect(log).toHaveTextContent(appsQuestion);
  });

  it("hands the focus to Continue and says so when a Connect the user pressed settles", async () => {
    const { rerender } = renderOverlay();
    const appsCard = await card(appsQuestion);
    const connect = within(appsCard).getByRole("button", { name: "Connect Linear" });
    connect.focus();
    await userEvent.keyboard("{Enter}");

    // The user authorizes Linear in the browser and comes back.
    rerender({ plugins: apps({ linear: "connected" }) });

    await waitFor(() =>
      expect(within(appsCard).getByRole("button", { name: "Continue" })).toHaveFocus()
    );
    expect(
      within(appsCard)
        .getAllByRole("status")
        .map((region) => region.textContent)
    ).toContain("Connected");
  });

  it("replies with the apps connected, joined as the language joins them, and Comma answers", async () => {
    const { onConnectPlugin, rerender } = renderOverlay();
    const appsCard = await card(appsQuestion);

    await userEvent.click(
      within(appsCard).getByRole("button", { name: "Connect Notion" })
    );
    expect(onConnectPlugin).toHaveBeenCalledExactlyOnceWith("notion");
    rerender({
      plugins: apps({ github: "connected", linear: "connected", notion: "connected" }),
    });
    await userEvent.click(within(appsCard).getByRole("button", { name: "Continue" }));

    expect(await message("Connected GitHub, Notion and Linear")).toBeInTheDocument();
    expect(
      // Comma says what it does with the apps it knows.
      await message(
        "Great, GitHub, Notion and Linear connected. Each day I’ll round up GitHub issues and PRs that mention you, your Notion to-dos and drafts and Linear issues that mention you, and Workers can use them on your tasks."
      )
    ).toBeInTheDocument();
    await hurry();
    expect(await card(nameQuestion)).toBeInTheDocument();
    expect(screen.queryByRole("group", { name: appsQuestion })).toBeNull();
  });

  it("replies Skip for now when no app is connected", async () => {
    renderOverlay();
    const appsCard = await card(appsQuestion);

    await userEvent.click(
      within(appsCard).getByRole("button", { name: "Skip for now" })
    );

    expect(await message("Skip for now")).toBeInTheDocument();
    expect(
      await message("No problem. You can connect apps anytime from Plugins.")
    ).toBeInTheDocument();
  });

  it("replies with the saved name, and Comma speaks under it from then on", async () => {
    const { onSaveRouterName, rerender } = renderOverlay({
      initialStage: "name",
      renderPermissions: grants,
    });
    const nameCard = await card(nameQuestion);
    const field = within(nameCard).getByRole("textbox", { name: "Assistant name" });
    expect(field).toHaveValue("");
    expect(
      within(nameCard).getByRole("button", { name: "Skip for now" })
    ).toBeInTheDocument();

    await userEvent.type(field, "  Atlas ");
    expect(
      within(nameCard).getByRole("button", { name: "Continue" })
    ).toBeInTheDocument();
    await userEvent.keyboard("{Enter}");

    expect(onSaveRouterName).toHaveBeenCalledExactlyOnceWith("Atlas", "wsp_ready");
    // The Router identity answers with the saved name.
    rerender({ routerName: "Atlas" });
    expect(await message("Atlas")).toBeInTheDocument();
    expect(await message("Atlas it is.")).toBeInTheDocument();
    // What Comma said before keeps its name; what it says now carries the new one.
    expect(speakers()).toEqual(["Comma", "Comma", "Atlas"]);
    // Then, a bubble later, what the Router does from now on.
    await hurry();
    expect(await message(routerRole)).toBeInTheDocument();
    expect(await card(macQuestion)).toBeInTheDocument();
    expect(button("Grants for Atlas")).toBeInTheDocument();
  });

  it("replies Skip for now to the name and keeps the one saved before", async () => {
    const { onSaveRouterName } = renderOverlay({ initialStage: "name" });
    const nameCard = await card(nameQuestion);

    await userEvent.click(
      within(nameCard).getByRole("button", { name: "Skip for now" })
    );

    expect(await message("Skip for now")).toBeInTheDocument();
    expect(
      await message("I’ll go by Comma for now. You can rename me anytime in Settings.")
    ).toBeInTheDocument();
    expect(onSaveRouterName).not.toHaveBeenCalled();
    // On the web the naming is the last exchange: after what the Router does,
    // the welcome page.
    await hurry();
    expect(await message(routerRole)).toBeInTheDocument();
    expect(
      await screen.findByRole("button", { name: "Start chatting" }, { timeout: 4000 })
    ).toBeInTheDocument();
  });

  it("skips the name once one is typed too, keeping the name it had", async () => {
    initializeCommaI18n(["zh-CN"]);
    const { onSaveRouterName } = renderOverlay({
      initialStage: "name",
      locale: "zh-CN",
      renderPermissions: grants,
      routerName: "Atlas",
    });
    const nameCard = await card("接下来，给我起个名字吧。");
    const field = within(nameCard).getByRole("textbox", { name: "助手名字" });
    await userEvent.clear(field);
    // Empty, its one action skips.
    expect(within(nameCard).getByRole("button", { name: "暂时跳过" })).toBeVisible();
    expect(within(nameCard).queryByRole("button", { name: "跳过" })).toBeNull();

    // Typed, Continue would save it; the quiet Skip beside it moves on without.
    await userEvent.type(field, "Nova");
    expect(within(nameCard).getByRole("button", { name: "继续" })).toBeVisible();
    await userEvent.click(within(nameCard).getByRole("button", { name: "跳过" }));

    expect(await message("先跳过")).toBeInTheDocument();
    expect(await message("那我先叫 Atlas，想好了随时在设置里改。")).toBeInTheDocument();
    expect(onSaveRouterName).not.toHaveBeenCalled();
    expect(speakers().at(-1)).toBe("Atlas");
    await hurry("继续");
    expect(
      await message(
        "以后有什么事都可以交给我：我会拆成任务、分给合适的 Worker，帮你盯着进度，做完把结果带回来；需要你拿主意的时候，我再来问你。"
      )
    ).toBeInTheDocument();

    // The grants answered, the reply says how many of them.
    await card("最后，允许我在这台 Mac 上工作，都是可选的。");
    await userEvent.click(button("Grants for Atlas"));
    expect(await message("3 项中已允许 2 项")).toBeInTheDocument();
  });

  it("moves on without a request when the name is unchanged", async () => {
    const { onSaveRouterName } = renderOverlay({
      initialStage: "name",
      routerName: "Atlas",
    });
    const nameCard = await card(nameQuestion);
    // A name the assistant already has fills the field.
    expect(
      within(nameCard).getByRole("textbox", { name: "Assistant name" })
    ).toHaveValue("Atlas");

    await userEvent.click(within(nameCard).getByRole("button", { name: "Continue" }));

    expect(await message("Atlas it is.")).toBeInTheDocument();
    expect(onSaveRouterName).not.toHaveBeenCalled();
  });

  it("keeps the card with an error when the name is not saved", async () => {
    const onSaveRouterName = vi.fn(async () => {
      throw new Error("unavailable");
    });
    renderOverlay({ initialStage: "name", onSaveRouterName });
    const nameCard = await card(nameQuestion);

    await userEvent.click(within(nameCard).getByRole("button", { name: "Nova" }));
    expect(
      within(nameCard).getByRole("textbox", { name: "Assistant name" })
    ).toHaveValue("Nova");
    await userEvent.click(within(nameCard).getByRole("button", { name: "Continue" }));

    expect(
      await screen.findByText("Couldn’t save the name. Try again.")
    ).toBeInTheDocument();
    expect(screen.getByRole("group", { name: nameQuestion })).toBeInTheDocument();
    expect(onSaveRouterName).toHaveBeenCalledExactlyOnceWith("Nova", "wsp_ready");

    // Editing clears the error.
    await userEvent.type(
      within(nameCard).getByRole("textbox", { name: "Assistant name" }),
      "h"
    );
    expect(screen.queryByText("Couldn’t save the name. Try again.")).toBeNull();
  });

  it("saves a name submitted while the workspace is prepared once it is ready", async () => {
    const { onSaveRouterName, rerender } = renderOverlay({
      initialStage: "name",
      workspace: { status: "preparing" },
    });
    const nameCard = await card(nameQuestion);
    await userEvent.type(
      within(nameCard).getByRole("textbox", { name: "Assistant name" }),
      "Juno"
    );
    await userEvent.click(within(nameCard).getByRole("button", { name: "Continue" }));

    expect(screen.getByText("Preparing your workspace…")).toBeInTheDocument();
    expect(onSaveRouterName).not.toHaveBeenCalled();

    rerender({ workspace: readyWorkspace });

    await waitFor(() =>
      expect(onSaveRouterName).toHaveBeenCalledExactlyOnceWith("Juno", "wsp_ready")
    );
    expect(await message("Juno")).toBeInTheDocument();
  });

  it("never answers a card with the key that hurried Comma along", async () => {
    const { onSaveRouterName } = renderOverlay({ initialStage: "greeting" });
    // Return pressed again and again: it hurries the greeting, then lands on
    // the apps card, which takes the focus itself rather than on Skip for now.
    await waitFor(() => expect(button("Continue")).toHaveFocus());
    await userEvent.keyboard("{Enter}");
    const appsCard = await card(appsQuestion);
    await waitFor(() => expect(appsCard).toHaveFocus());
    await userEvent.keyboard("{Enter}{Enter}{Enter}");
    expect(screen.getByRole("group", { name: appsQuestion })).toBeInTheDocument();
    expect(
      screen.queryByText("Skip for now", {
        selector: ".comma-chat-user-bubble-content",
      })
    ).toBeNull();

    // Return in an empty name field does nothing either.
    await userEvent.click(
      within(appsCard).getByRole("button", { name: "Skip for now" })
    );
    await hurry();
    const nameCard = await card(nameQuestion);
    const field = within(nameCard).getByRole("textbox", { name: "Assistant name" });
    await waitFor(() => expect(field).toHaveFocus());
    await userEvent.keyboard("{Enter}{Enter}");
    expect(screen.getByRole("group", { name: nameQuestion })).toBeInTheDocument();
    expect(onSaveRouterName).not.toHaveBeenCalled();
  }, 15_000);

  it("lets Skip leave a save that never answers", async () => {
    const onSaveRouterName = vi.fn(() => new Promise<void>(() => {}));
    renderOverlay({ initialStage: "name", onSaveRouterName });
    const nameCard = await card(nameQuestion);
    await userEvent.type(
      within(nameCard).getByRole("textbox", { name: "Assistant name" }),
      "Atlas{Enter}"
    );
    expect(onSaveRouterName).toHaveBeenCalledOnce();
    await userEvent.click(within(nameCard).getByRole("button", { name: "Skip" }));
    expect(await message("Skip for now")).toBeInTheDocument();
  });

  it("points to Settings, not another try, when the workspace cannot be used", async () => {
    const { onSaveRouterName } = renderOverlay({
      initialStage: "name",
      workspace: { status: "unavailable" },
    });
    const nameCard = await card(nameQuestion);
    await userEvent.type(
      within(nameCard).getByRole("textbox", { name: "Assistant name" }),
      "Juno"
    );
    await userEvent.click(within(nameCard).getByRole("button", { name: "Continue" }));

    expect(
      await screen.findByText(
        "Couldn’t reach your workspace. You can name me later in Settings."
      )
    ).toBeInTheDocument();
    expect(screen.queryByText("Couldn’t save the name. Try again.")).toBeNull();
    expect(onSaveRouterName).not.toHaveBeenCalled();
  });

  it("drops a name still waiting for the workspace when the onboarding is closed", async () => {
    const { onSaveRouterName, rerender } = renderOverlay({
      initialStage: "name",
      workspace: { status: "preparing" },
    });
    const nameCard = await card(nameQuestion);
    await userEvent.type(
      within(nameCard).getByRole("textbox", { name: "Assistant name" }),
      "Juno"
    );
    await userEvent.click(within(nameCard).getByRole("button", { name: "Continue" }));
    await userEvent.click(button("Close onboarding"));

    rerender({ workspace: readyWorkspace });
    await new Promise((resolve) => setTimeout(resolve, 50));

    expect(onSaveRouterName).not.toHaveBeenCalled();
  });

  it("does not claim to work on this Mac without both Computer Use grants", async () => {
    renderOverlay({
      initialStage: "permissions",
      renderPermissions: grantsAllowing({ computerUse: false }),
    });
    await card(macQuestion);

    await userEvent.click(button("Grants for Comma"));

    expect(await message("Allowed 2 of 3")).toBeInTheDocument();
    expect(
      await message("Got it. You can turn on the rest anytime in System Settings.")
    ).toBeInTheDocument();
    expect(
      screen.queryByText("Got it. Now I can work on this Mac for you.", {
        exact: false,
      })
    ).toBeNull();
  });

  it("replies with the grants allowed, answers, and closes on the welcome page", async () => {
    const { onComplete, onExited } = renderOverlay({
      initialStage: "permissions",
      renderPermissions: grants,
      routerName: "Atlas",
    });
    await card(macQuestion);

    await userEvent.click(button("Grants for Atlas"));

    expect(await message("Allowed 2 of 3")).toBeInTheDocument();
    expect(
      await message("Got it. Now I can work on this Mac for you.")
    ).toBeInTheDocument();
    // Comma reminds the user what is still off: the skipped apps and the
    // grant left unallowed.
    expect(
      await message(
        "A quick reminder. Still off: connecting apps and Notifications. You can turn them on anytime.",
        4000
      )
    ).toBeInTheDocument();
    // After a beat the light clears the conversation, and the welcome page
    // says the assistant is ready by its name.
    const start = await screen.findByRole(
      "button",
      { name: "Start chatting" },
      { timeout: 4000 }
    );
    expect(
      screen.getByRole("heading", { name: "Atlas is ready." })
    ).toBeInTheDocument();
    expect(screen.getByText("Ask it for anything.")).toBeInTheDocument();
    expect(screen.queryByText("Allowed 2 of 3")).toBeNull();
    expect(start).toHaveFocus();
    // The focus lands on Start chatting: the page's words are read with it.
    expect(start).toHaveAccessibleDescription("Atlas is ready. Ask it for anything.");
    // The welcome page has no Close: the thread leaves with it.
    await waitFor(() =>
      expect(screen.queryByRole("button", { name: "Close onboarding" })).toBeNull()
    );

    await userEvent.click(start);
    expect(onComplete).toHaveBeenCalledOnce();
    await waitFor(() => expect(onExited).toHaveBeenCalledTimes(1));
  }, 15_000);

  it("closes from Close during the greeting: Comma says no more and the onboarding leaves", async () => {
    const { onComplete, onExited, onSaveRouterName } = renderOverlay({
      initialStage: "greeting",
    });
    await message(greeting);

    await userEvent.click(button("Close onboarding"));
    expect(onComplete).toHaveBeenCalledOnce();

    await waitFor(() => expect(onExited).toHaveBeenCalledOnce(), { timeout: 3000 });
    expect(screen.queryByText("No group chats", { exact: false })).toBeNull();
    expect(screen.queryByRole("heading", { name: "Comma is ready." })).toBeNull();
    expect(onSaveRouterName).not.toHaveBeenCalled();
  });

  describe("Open Comma shortcut", () => {
    const shortcut = defaultOpenCommaShortcut;
    const done = "You’ve got it. Press it anytime to bring up Comma.";

    it("tells of the Side Chat, then steps the conversation back for the shortcut once Comma's last line has landed", async () => {
      renderOverlay({
        initialStage: "permissions",
        openShortcut: shortcut,
        renderPermissions: grants,
        routerName: "Atlas",
        sideChatShortcut: defaultSideChatShortcut,
      });
      await card(macQuestion);
      await userEvent.click(button("Grants for Atlas"));
      // After the grants, Comma tells of the Side Chat and its own shortcut.
      await message(
        "One more thing: press ⌃ + Z anytime to bring up Side Chat, a small chat at the edge of your screen for the quick everyday things.",
        4000
      );
      await message(
        "A quick reminder. Still off: connecting apps and Notifications. You can turn them on anytime.",
        4000
      );

      // Not the welcome page: the last step, named by its title and read
      // with its words and the shortcut spelled out.
      const step = await screen.findByRole(
        "group",
        { name: "Try Option + Comma" },
        { timeout: 6000 }
      );
      expect(step).toHaveAccessibleDescription(
        "Last step Press it anytime to bring up Comma, wherever you are. Press Option and Comma together."
      );
      await waitFor(() => expect(step).toHaveFocus());
      // The conversation stepped back: no longer read, nor reachable.
      expect(
        within(screen.getByRole("dialog", { name: "Welcome to Comma" })).queryByRole(
          "log"
        )
      ).toBeNull();
      expect(button("Close onboarding")).toBeEnabled();
      // Nothing happens until the user presses it.
      await new Promise((resolve) => setTimeout(resolve, 1000));
      expect(screen.queryByRole("heading", { name: "Atlas is ready." })).toBeNull();
    }, 15_000);

    it("says which keys to press when another key is pressed, once, however often", async () => {
      vi.useFakeTimers();
      renderOverlay({
        initialStage: "shortcut",
        renderPermissions: grants,
        openShortcut: shortcut,
      });
      const step = await shortcutStep();

      // Moving the focus, Escape, a repeat, a modifier the shortcut does not
      // use, and M (the sound) are not wrong keys.
      for (const init of [
        { code: "Tab", key: "Tab" },
        { code: "Escape", key: "Escape" },
        { code: "ShiftLeft", key: "Shift", shiftKey: true },
        { code: "KeyY", key: "y", repeat: true },
      ]) {
        await keyDown(step, init);
      }
      expect(status(step)).toBeEmptyDOMElement();
      await keyDown(step, { code: "KeyM", key: "m" });
      expect(soundElement().volume).toBe(0);
      expect(status(step)).toBeEmptyDOMElement();

      await keyDown(step, { code: "KeyY", key: "y" });
      expect(status(step)).toHaveTextContent(
        "That’s not it. Press Option and Comma together."
      );
      // Another wrong key is said again, in place of the first.
      const said = status(step).firstElementChild;
      await keyDown(step, { code: "Digit1", key: "1" });
      expect(status(step).children).toHaveLength(1);
      expect(status(step).firstElementChild).not.toBe(said);

      // It leaves after a while.
      await pass(3000);
      expect(status(step)).toBeEmptyDOMElement();
    });

    it("says it is done once both keys are down, in either order, then goes on to the welcome page", async () => {
      vi.useFakeTimers();
      renderOverlay({
        initialStage: "shortcut",
        renderPermissions: grants,
        routerName: "Atlas",
        openShortcut: shortcut,
      });
      const step = await shortcutStep();

      // Comma first, then Option.
      await keyDown(step, commaDown);
      expect(status(step)).toBeEmptyDOMElement();
      await keyDown(step, optionDown);
      expect(status(step)).toHaveTextContent(done);
      expect(screen.getByRole("heading", { name: "Beautiful" })).toBeVisible();
      // Done: another key is no longer a wrong one.
      await keyDown(step, { code: "KeyY", key: "y" });
      expect(status(step)).toHaveTextContent(done);

      // A beat later the light clears the step for the welcome page.
      await pass(2000);
      expect(screen.getByRole("heading", { name: "Atlas is ready." })).toBeVisible();
      expect(screen.getByRole("button", { name: "Start chatting" })).toHaveFocus();
      expect(screen.queryByRole("group", { name: "Beautiful" })).toBeNull();
    });

    it("counts the keys pressed one after the other", async () => {
      vi.useFakeTimers();
      renderOverlay({
        initialStage: "shortcut",
        renderPermissions: grants,
        openShortcut: shortcut,
      });
      const step = await shortcutStep();

      // Option pressed and let go, then Comma on its own: neither is a wrong key.
      await keyDown(step, optionDown);
      await keyUp(step, optionUp);
      expect(status(step)).toBeEmptyDOMElement();
      await keyDown(step, commaDown);
      expect(status(step)).toHaveTextContent(done);
    });

    it("listens for the keys inside StrictMode, as the development app mounts it", async () => {
      vi.useFakeTimers();
      renderOverlay({
        initialStage: "shortcut",
        renderPermissions: grants,
        openShortcut: shortcut,
        strict: true,
      });
      const step = await shortcutStep();

      await keyDown(step, { code: "KeyY", key: "y" });
      expect(status(step)).toHaveTextContent(
        "That’s not it. Press Option and Comma together."
      );
      await keyDown(step, commaDown);
      await keyDown(step, optionDown);
      expect(status(step)).toHaveTextContent(done);
    });

    it("goes on to the welcome page from Skip, without the keys", async () => {
      vi.useFakeTimers();
      const { onComplete } = renderOverlay({
        initialStage: "shortcut",
        renderPermissions: grants,
        openShortcut: shortcut,
      });
      const step = await shortcutStep();

      await press(within(step).getByRole("button", { name: "Skip" }));
      await pass(2000);
      expect(screen.getByRole("heading", { name: "Comma is ready." })).toBeVisible();
      expect(onComplete).not.toHaveBeenCalled();
    });

    it("goes on to the welcome page when the shortcut is turned off mid-step", async () => {
      vi.useFakeTimers();
      const { rerender } = renderOverlay({
        initialStage: "shortcut",
        renderPermissions: grants,
        openShortcut: shortcut,
      });
      await shortcutStep();

      rerender({ openShortcut: undefined });
      await pass(2000);
      expect(screen.getByRole("heading", { name: "Comma is ready." })).toBeVisible();
      expect(screen.queryByRole("group", { name: "Try Option + Comma" })).toBeNull();
    });
  });

  it("sets Chinese copy around a Chinese name, and joins app names as Chinese does", async () => {
    initializeCommaI18n(["zh-CN"]);
    renderOverlay({
      initialStage: "after-name",
      initialResults: {
        apps: { item: "apps", connected: ["GitHub", "Notion", "Slack"] },
        name: { item: "name", name: "小逗", named: true },
      },
      locale: "zh-CN",
      renderPermissions: grants,
    });

    expect(await message("已连接 GitHub、Notion 和 Slack")).toBeInTheDocument();
    expect(
      await message("好，之后任务需要时，我就能直接用上 GitHub、Notion 和 Slack。")
    ).toBeInTheDocument();
    expect(await message("小逗，好名字。")).toBeInTheDocument();
    expect(
      await message(
        "以后有什么事都可以交给我：我会拆成任务、分给合适的 Worker，帮你盯着进度，做完把结果带回来；需要你拿主意的时候，我再来问你。"
      )
    ).toBeInTheDocument();

    // The welcome page says the assistant is ready by its Chinese name.
    cleanup();
    renderOverlay({
      initialStage: "welcome",
      initialResults: { name: { item: "name", name: "小逗", named: true } },
      locale: "zh-CN",
    });
    expect(
      await screen.findByRole("heading", { name: "小逗已就绪。" }, { timeout: 3000 })
    ).toBeInTheDocument();
    expect(screen.getByText("有什么事，直接交给它。")).toBeInTheDocument();
  });
});
