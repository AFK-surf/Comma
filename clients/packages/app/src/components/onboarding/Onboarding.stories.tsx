import { initializeCommaI18n } from "@comma/i18n";
import { CommaI18nProvider } from "@comma/i18n/react";
import { Button } from "@comma/ui";
import type { Meta, StoryObj } from "@storybook/react-vite";
import { useCallback, useEffect, useRef, useState, type ReactNode } from "react";
import { expect, userEvent, waitFor, within } from "storybook/test";
import "../../styles.css";
import {
  defaultOpenCommaShortcut,
  defaultSideChatShortcut,
} from "@comma/native-bridge";
import { OnboardingOverlay, type OnboardingPermissionsSlot } from "./OnboardingOverlay";
import type {
  OnboardingPresentation,
  OnboardingResults,
  OnboardingStart,
} from "./onboardingSetup";
import {
  PermissionsPanel,
  type OnboardingPermissionRow,
} from "./permissions/PermissionsPanel";
import { permissionIds, type PermissionId } from "./permissions/usePermissionsStep";
import type {
  OnboardingPluginConnection,
  OnboardingPluginList,
  OnboardingPluginRow,
} from "./useOnboardingPlugins";
import type { OnboardingWorkspace } from "./useOnboardingWorkspace";

// Story fixtures: what lies behind the onboarding, a small catalog, and
// stand-ins for the browser sign-in, the Router rename and macOS.

const storyPlugins: readonly Omit<OnboardingPluginRow, "connection">[] = [
  { brand: "google", id: "google", name: "Google Workspace", summary: "Workspace" },
  { brand: "github", id: "github", name: "GitHub", summary: "Repositories" },
  { brand: "notion", id: "notion", name: "Notion", summary: "Pages" },
  { brand: "slack", id: "slack", name: "Slack", summary: "Messaging" },
  { brand: "linear", id: "linear", name: "Linear", summary: "Plan product work" },
  { brand: "feishu", id: "feishu", name: "Feishu", summary: "Messages" },
];

/** A long catalog: forty apps, so the list scrolls inside the card. */
const storyLongCatalog = Array.from({ length: 7 }, (_, round) =>
  storyPlugins.map((plugin) =>
    round === 0
      ? plugin
      : { ...plugin, id: `${plugin.id}-${round}`, name: `${plugin.name} ${round + 1}` }
  )
)
  .flat()
  .slice(0, 40);

/** The product shell as the in-window overlay finds it. */
function StoryAppBackdrop() {
  return (
    <div
      aria-hidden="true"
      className="fixed inset-0 flex bg-window pr-md pb-md text-primary"
    >
      <div className="flex w-16 flex-col items-center gap-xl pt-7xl">
        {Array.from({ length: 6 }, (_, index) => (
          <span className="size-8 rounded-lg bg-tertiary" key={index} />
        ))}
      </div>
      <div className="mt-5xl flex flex-1 flex-col gap-3xl rounded-xl bg-main-panel-bg p-7xl shadow-sm">
        <div className="mt-auto flex h-10xl flex-col justify-between rounded-2xl bg-primary p-xl shadow-md ring-1 ring-primary">
          <span className="text-md text-placeholder">Ask anything</span>
          <span className="size-8 self-end rounded-full bg-brand-solid" />
        </div>
      </div>
    </div>
  );
}

/**
 * A desktop wallpaper for the full-screen window. The window is transparent,
 * so the wallpaper stays visible, dimmed, through the light field. Only the
 * wallpaper stands in here: the real menu bar and Dock are the system's.
 */
function StoryWallpaper() {
  return (
    <div
      aria-hidden="true"
      className="fixed inset-0"
      style={{
        background: [
          "radial-gradient(ellipse 60% 45% at 78% 30%, var(--color-orange-300), transparent 70%)",
          "radial-gradient(ellipse 55% 40% at 50% 62%, var(--color-yellow-300), transparent 70%)",
          "radial-gradient(ellipse 70% 50% at 16% 88%, var(--color-teal-500), transparent 70%)",
          "linear-gradient(170deg, var(--color-blue-light-400), var(--color-cyan-600) 55%, var(--color-teal-700))",
        ].join(", "),
      }}
    />
  );
}

type Catalog = "ready" | "loading" | "failed" | "long";
type Connections = Record<string, OnboardingPluginConnection>;

function useStoryPlugins(
  workspace: OnboardingWorkspace,
  catalog: Catalog,
  initial: Connections
): { list: OnboardingPluginList; connect: (pluginId: string) => void } {
  const [connections, setConnections] = useState(initial);
  const timer = useRef<number>(undefined);
  useEffect(() => () => window.clearTimeout(timer.current), []);

  // Another Connect replaces the sign-in in flight; the browser answers later.
  const connect = useCallback((pluginId: string) => {
    window.clearTimeout(timer.current);
    setConnections((current) => ({
      ...Object.fromEntries(
        Object.entries(current).map(([id, connection]) => [
          id,
          connection === "connecting" ? "idle" : connection,
        ])
      ),
      [pluginId]: "connecting",
    }));
    timer.current = window.setTimeout(
      () => setConnections((current) => ({ ...current, [pluginId]: "connected" })),
      2400
    );
  }, []);

  if (workspace.status === "preparing")
    return { list: { status: "preparing" }, connect };
  if (workspace.status === "unavailable" || catalog === "failed") {
    return { list: { status: "unavailable" }, connect };
  }
  if (catalog === "loading") return { list: { status: "loading" }, connect };
  return {
    connect,
    list: {
      status: "ready",
      rows: (catalog === "long" ? storyLongCatalog : storyPlugins).map((plugin) => ({
        ...plugin,
        connection: connections[plugin.id] ?? "idle",
      })),
    },
  };
}

type StoryMac = "idle" | "checking" | "waiting" | "allowed" | "refused";

const macRows: Record<
  StoryMac,
  Record<PermissionId, OnboardingPermissionRow["action"]>
> = {
  idle: { accessibility: "idle", screenRecording: "idle", notifications: "idle" },
  checking: {
    accessibility: "checking",
    screenRecording: "checking",
    notifications: "checking",
  },
  waiting: { accessibility: "done", screenRecording: "pending", notifications: "idle" },
  allowed: { accessibility: "done", screenRecording: "done", notifications: "done" },
  refused: {
    accessibility: "done",
    screenRecording: "idle",
    notifications: "settings",
  },
};

/**
 * Stands in for macOS: Allow waits a moment for the user to answer
 * elsewhere, then lands. Story-only; the app reads macOS.
 */
function StoryPermissions({
  assistantName,
  mac,
  onAdvance,
}: OnboardingPermissionsSlot & { mac: StoryMac }) {
  const [actions, setActions] = useState(macRows[mac]);
  const timers = useRef<number[]>([]);
  useEffect(() => {
    const scheduled = timers.current;
    return () => scheduled.forEach((timer) => window.clearTimeout(timer));
  }, []);
  const set = (id: PermissionId, action: OnboardingPermissionRow["action"]) =>
    setActions((current) => ({ ...current, [id]: action }));
  const allow = (id: PermissionId) => {
    set(id, "pending");
    timers.current.push(window.setTimeout(() => set(id, "done"), 1800));
  };
  return (
    <PermissionsPanel
      assistantName={assistantName}
      onAdvance={onAdvance}
      onAllow={allow}
      onOpenSettings={() => allow("notifications")}
      rows={(Object.keys(actions) as PermissionId[]).map((id) => ({
        action: actions[id],
        failed: false,
        id,
        waiting: actions[id] === "pending",
      }))}
    />
  );
}

type OnboardingStoryArgs = {
  /** In the product window (web), or full screen over the desktop (macOS app). */
  presentation: OnboardingPresentation;
  start: OnboardingStart;
  /** Items answered on the way to `start` were skipped, instead of done. */
  skipped: boolean;
  /** The macOS app: a third exchange, "Let me work on this Mac". */
  mac: boolean;
  /**
   * The macOS app's shortcuts: Comma tells of the Side Chat's, and the Open
   * Comma shortcut comes before the welcome page.
   */
  shortcuts: boolean;
  macState: StoryMac;
  workspace: OnboardingWorkspace["status"];
  catalog: Catalog;
  connections: Connections;
  /** The Router's stored name; the provisioned default reads as unnamed. */
  routerName: string;
  /** How the rename answers: saved after a moment, never, or with an error. */
  save: "saved" | "hang" | "fail";
  locale: "en" | "zh-CN";
};

/** What the items passed on the way to the story's start came to. */
function storyResults(args: OnboardingStoryArgs): OnboardingResults {
  if (args.skipped) return {};
  const named = args.routerName !== "Default workspace Router";
  return {
    apps: {
      item: "apps",
      connected: storyPlugins
        .filter((plugin) => args.connections[plugin.id] === "connected")
        .map((plugin) => plugin.name),
    },
    ...(named
      ? { name: { item: "name" as const, name: args.routerName, named: true } }
      : {}),
    permissions: {
      item: "permissions",
      allowed: Object.values(macRows[args.macState]).filter(
        (action) => action === "done"
      ).length,
      computerUse:
        macRows[args.macState].accessibility === "done" &&
        macRows[args.macState].screenRecording === "done",
      missing: permissionIds.filter((id) => macRows[args.macState][id] !== "done"),
      total: 3,
    },
  };
}

function OnboardingStory(args: OnboardingStoryArgs) {
  const [routerName, setRouterName] = useState(args.routerName);
  const [run, setRun] = useState(0);
  const [open, setOpen] = useState(true);
  const workspace: OnboardingWorkspace =
    args.workspace === "ready"
      ? { status: "ready", workspaceId: "wsp_story" }
      : { status: args.workspace };
  const plugins = useStoryPlugins(workspace, args.catalog, args.connections);
  const save = args.save;
  const saveRouterName = useCallback(
    (name: string) =>
      save === "hang"
        ? new Promise<void>(() => undefined)
        : new Promise<void>((resolve, reject) => {
            window.setTimeout(() => {
              if (save === "fail") {
                reject(new Error("The story's Router does not save names."));
                return;
              }
              setRouterName(name);
              resolve();
            }, 600);
          }),
    [save]
  );

  const story = (
    <>
      {args.presentation === "window" ? <StoryWallpaper /> : <StoryAppBackdrop />}
      {open ? (
        <OnboardingOverlay
          initialResults={storyResults(args)}
          initialStage={args.start}
          key={run}
          onComplete={() => undefined}
          onConnectPlugin={plugins.connect}
          onExited={() => setOpen(false)}
          onSaveRouterName={saveRouterName}
          plugins={plugins.list}
          presentation={args.presentation}
          renderPermissions={
            args.mac
              ? (slot) => <StoryPermissions {...slot} mac={args.macState} />
              : undefined
          }
          routerName={routerName}
          openShortcut={args.shortcuts ? defaultOpenCommaShortcut : undefined}
          sideChatShortcut={args.shortcuts ? defaultSideChatShortcut : undefined}
          workspace={workspace}
        />
      ) : (
        <div className="fixed right-3xl bottom-3xl">
          <Button
            hierarchy="secondary-gray"
            onPress={() => {
              setRun((current) => current + 1);
              setOpen(true);
            }}
          >
            Replay onboarding
          </Button>
        </div>
      )}
    </>
  );
  return args.locale === "zh-CN" ? <ChineseMessages>{story}</ChineseMessages> : story;
}

/**
 * The preview decorator pins the catalog to English. Messages are global, so
 * these stories load Chinese for themselves and restore English on unmount.
 */
function ChineseMessages({ children }: { children: ReactNode }) {
  const [ready, setReady] = useState(false);
  useEffect(() => {
    initializeCommaI18n(["zh-CN"]);
    setReady(true);
    return () => {
      initializeCommaI18n(["en"]);
    };
  }, []);
  return ready ? (
    <CommaI18nProvider locale="zh-CN">{children}</CommaI18nProvider>
  ) : null;
}

const meta = {
  title: "App components/Onboarding",
  parameters: { layout: "fullscreen" },
  args: {
    catalog: "ready",
    connections: { github: "connected" },
    locale: "en",
    mac: false,
    macState: "idle",
    presentation: "overlay",
    routerName: "Default workspace Router",
    save: "saved",
    shortcuts: false,
    skipped: false,
    start: "intro",
    workspace: "ready",
  },
  argTypes: {
    start: {
      control: "select",
      options: [
        "intro",
        "greeting",
        "apps",
        "after-apps",
        "name",
        "after-name",
        "permissions",
        "after-permissions",
        "shortcut",
        "welcome",
      ],
    },
    presentation: { control: "inline-radio", options: ["overlay", "window"] },
    workspace: {
      control: "inline-radio",
      options: ["preparing", "ready", "unavailable"],
    },
    catalog: {
      control: "inline-radio",
      options: ["ready", "loading", "failed", "long"],
    },
    macState: {
      control: "inline-radio",
      options: ["idle", "checking", "waiting", "allowed", "refused"],
    },
    save: { control: "inline-radio", options: ["saved", "hang", "fail"] },
    locale: { control: "inline-radio", options: ["en", "zh-CN"] },
  },
  render: (args) => <OnboardingStory {...args} />,
} satisfies Meta<OnboardingStoryArgs>;

export default meta;
type Story = StoryObj<typeof meta>;

/** Comma's first line, once the intro has welcomed the user. */
const storyGreeting =
  "I’m your Router. Tell me what needs doing, and I’ll split it into Tasks and hand them to Workers that work at the same time.";

// The onboarding is a modal: it portals out of the story's canvas.
const onboardingOf = (canvasElement: HTMLElement) =>
  within(canvasElement.ownerDocument.body);

/**
 * The whole flow on the web, as the product starts it: the screen dims, the
 * Comma mark welcomes the user, and Start begins the conversation. It replays
 * once it exits.
 */
export const Intro: Story = {
  play: async ({ canvasElement }) => {
    const canvas = onboardingOf(canvasElement);
    // The mark arrives once the screen has dimmed; the welcome and Start
    // follow under it, and Start takes the focus as it appears.
    const start = await canvas.findByRole(
      "button",
      { name: "Start" },
      { timeout: 6000 }
    );
    await waitFor(() => expect(start).toHaveFocus(), { timeout: 3000 });
    await waitFor(() =>
      expect(canvas.getByRole("heading", { name: "Welcome to Comma" })).toBeVisible()
    );
    await waitFor(() => expect(start).toBeVisible());
    await userEvent.click(start);
    // The mark moves up to head the conversation, and Comma starts talking.
    await canvas.findByText(
      storyGreeting,
      { selector: ".comma-chat-user-bubble-content" },
      { timeout: 4000 }
    );
    await expect(
      canvas.queryByRole("heading", { name: "Welcome to Comma" })
    ).toBeNull();
  },
};

/**
 * Left alone for eight seconds, Start begins the onboarding by itself. It
 * waits without a countdown: nothing on it moves.
 */
export const IntroAutoStart: Story = {
  args: { mac: true, presentation: "window" },
  play: async ({ canvasElement }) => {
    const canvas = onboardingOf(canvasElement);
    const start = await canvas.findByRole(
      "button",
      { name: "Start" },
      { timeout: 6000 }
    );
    await waitFor(() => expect(start).toHaveFocus(), { timeout: 3000 });
    await expect(start.getAnimations({ subtree: true })).toEqual([]);
    // Eight seconds after it appeared, the onboarding begins: Start leaves
    // and the mark moves up to head the conversation.
    await waitFor(
      () => expect(canvas.queryByRole("button", { name: "Start" })).toBeNull(),
      { timeout: 9000 }
    );
    await expect(
      canvas.queryByRole("heading", { name: "Welcome to Comma" })
    ).toBeNull();
  },
};

/** The greeting under the mark, without the intro: three lines, then the apps. */
export const Greeting: Story = { args: { start: "greeting" } };

/** The macOS app's greeting: three things to do. */
export const GreetingMac: Story = { args: { mac: true, start: "greeting" } };

/** Comma asks for the apps; GitHub was connected before, so the primary continues. */
export const Apps: Story = { args: { start: "apps" } };

export const AppsNothingConnected: Story = {
  args: { connections: {}, start: "apps" },
};

/** Notion's sign-in is open in the browser; its row says where to finish it. */
export const AppsSigningIn: Story = {
  args: { connections: { github: "connected", notion: "connecting" }, start: "apps" },
};

export const AppsPreparingWorkspace: Story = {
  args: { start: "apps", workspace: "preparing" },
};

export const AppsLoading: Story = { args: { catalog: "loading", start: "apps" } };

export const AppsLoadFailed: Story = { args: { catalog: "failed", start: "apps" } };

/** Forty apps: the list scrolls inside the card, which stays on screen. */
export const AppsLongCatalog: Story = { args: { catalog: "long", start: "apps" } };

/** The user's reply (GitHub connected) and Comma's answer, before the next question. */
export const AfterApps: Story = { args: { start: "after-apps" } };

export const AfterAppsSkipped: Story = { args: { skipped: true, start: "after-apps" } };

export const Name: Story = { args: { start: "name" } };

/** A name the assistant already has fills the field. */
export const NameSaved: Story = { args: { routerName: "Atlas", start: "name" } };

const typeName = async (canvasElement: HTMLElement, name: string, submit: boolean) => {
  const canvas = onboardingOf(canvasElement);
  const field = await canvas.findByRole("textbox", { name: "Assistant name" });
  await userEvent.type(field, name);
  if (submit) await userEvent.keyboard("{Enter}");
};

/** A name typed: Continue saves it, and a quiet Skip beside it moves on without. */
export const NameTyped: Story = {
  args: { start: "name" },
  play: async ({ canvasElement }) => {
    await typeName(canvasElement, "Atlas", false);
    const canvas = onboardingOf(canvasElement);
    await expect(canvas.getByRole("button", { name: "Continue" })).toBeVisible();
    await expect(canvas.getByRole("button", { name: "Skip" })).toBeVisible();
  },
};

export const NameSaving: Story = {
  args: { save: "hang", start: "name" },
  play: async ({ canvasElement }) => typeName(canvasElement, "Atlas", true),
};

export const NameWaitingForWorkspace: Story = {
  args: { start: "name", workspace: "preparing" },
  play: async ({ canvasElement }) => typeName(canvasElement, "Atlas", true),
};

export const NameSaveFailed: Story = {
  args: { save: "fail", start: "name" },
  play: async ({ canvasElement }) => {
    await typeName(canvasElement, "Atlas", true);
    await expect(
      await onboardingOf(canvasElement).findByText("Couldn’t save the name. Try again.")
    ).toBeVisible();
  },
};

/** Named "Atlas": the reply is the name, and Comma now speaks as Atlas. */
export const AfterName: Story = {
  args: { mac: true, routerName: "Atlas", start: "after-name" },
};

export const AfterNameSkipped: Story = {
  args: { mac: true, skipped: true, start: "after-name" },
};

/** The macOS app's third card, before macOS has answered. */
export const PermissionsChecking: Story = {
  args: { mac: true, macState: "checking", routerName: "Atlas", start: "permissions" },
};

export const Permissions: Story = {
  args: { mac: true, routerName: "Atlas", start: "permissions" },
};

/** Accessibility allowed, Screen Recording waiting for the user in macOS. */
export const PermissionsWaiting: Story = {
  args: { mac: true, macState: "waiting", routerName: "Atlas", start: "permissions" },
};

export const PermissionsAllowed: Story = {
  args: { mac: true, macState: "allowed", routerName: "Atlas", start: "permissions" },
};

/** macOS refused notifications: only System Settings can allow them now. */
export const PermissionsNotificationsRefused: Story = {
  args: { mac: true, macState: "refused", routerName: "Atlas", start: "permissions" },
};

/** Two of three allowed; the welcome page follows Comma's answer. */
export const AfterPermissions: Story = {
  args: {
    mac: true,
    macState: "waiting",
    routerName: "Atlas",
    start: "after-permissions",
  },
};

/**
 * After Comma's last answer a white light sweeps up the screen, clearing the
 * conversation, and the welcome page follows it.
 */
export const OutroSweep: Story = {
  args: {
    mac: true,
    macState: "allowed",
    presentation: "window",
    routerName: "Atlas",
    start: "after-permissions",
  },
  play: async ({ canvasElement }) => {
    const canvas = onboardingOf(canvasElement);
    const ready = await canvas.findByRole(
      "heading",
      { name: "Atlas is ready." },
      { timeout: 5000 }
    );
    await waitFor(() => expect(ready).toBeVisible());
    await waitFor(() =>
      expect(canvas.getByRole("button", { name: "Start chatting" })).toHaveFocus()
    );
    // The light has taken the conversation and Close with it.
    await expect(canvas.queryByRole("button", { name: "Close onboarding" })).toBeNull();
    await expect(canvas.queryByText("Allowed 3 of 3")).toBeNull();
  },
};

/**
 * The macOS app's last step: the conversation steps back for the Open Comma
 * shortcut. Press Option and Comma: the keys turn green, the step says so,
 * and a beat later the welcome page follows.
 */
export const OpenCommaShortcut: Story = {
  args: {
    mac: true,
    macState: "allowed",
    presentation: "window",
    routerName: "Atlas",
    shortcuts: true,
    start: "shortcut",
  },
  play: async ({ canvasElement }) => {
    const canvas = onboardingOf(canvasElement);
    const step = await canvas.findByRole("group", { name: "Try Option + Comma" });
    await waitFor(() => expect(step).toHaveFocus(), { timeout: 3000 });
  },
};

/** Any other key says which two to press, under the keys. */
export const OpenCommaShortcutWrongKey: Story = {
  args: { ...OpenCommaShortcut.args },
  play: async ({ canvasElement }) => {
    const canvas = onboardingOf(canvasElement);
    const step = await canvas.findByRole("group", { name: "Try Option + Comma" });
    await waitFor(() => expect(step).toHaveFocus(), { timeout: 3000 });
    await userEvent.keyboard("y");
    await expect(within(step).getByRole("status")).toHaveTextContent(
      "That’s not it. Press Option and Comma together."
    );
  },
};

/** Both keys down: the keys turn green and the step says so. */
export const OpenCommaShortcutPressed: Story = {
  args: { ...OpenCommaShortcut.args },
  play: async ({ canvasElement }) => {
    const canvas = onboardingOf(canvasElement);
    const step = await canvas.findByRole("group", { name: "Try Option + Comma" });
    await waitFor(() => expect(step).toHaveFocus(), { timeout: 3000 });
    // By its physical key: user-event's own key map has no comma.
    await userEvent.keyboard("{Alt>}[Comma]{/Alt}");
    await waitFor(() =>
      expect(within(step).getByRole("status")).toHaveTextContent(
        "You’ve got it. Press it anytime to bring up Comma."
      )
    );
    // The success title fades in over the shortcut title.
    await waitFor(() =>
      expect(canvas.getByRole("heading", { name: "Beautiful" })).toBeVisible()
    );
  },
};

export const OpenCommaShortcutChinese: Story = {
  args: { ...OpenCommaShortcut.args, locale: "zh-CN", routerName: "小逗" },
};

export const OpenCommaShortcutDark: Story = {
  args: { ...OpenCommaShortcut.args },
  globals: { theme: "dark" },
};

/** Reduced motion: a key presses flat where it stands; nothing shakes. */
export const OpenCommaShortcutReducedMotion: Story = {
  args: { ...OpenCommaShortcut.args },
  globals: { motionPreference: "reduced" },
};

/** The closing page: Atlas is ready, and Start chatting has the focus. */
export const Welcome: Story = {
  args: { routerName: "Atlas", start: "welcome" },
  play: async ({ canvasElement }) => {
    const canvas = onboardingOf(canvasElement);
    await expect(
      await canvas.findByRole("button", { name: "Start chatting" })
    ).toHaveFocus();
    // The page's parts arrive one after another.
    await waitFor(() =>
      expect(canvas.getByRole("heading", { name: "Atlas is ready." })).toBeVisible()
    );
    await waitFor(() => expect(canvas.getByText("Ask it for anything.")).toBeVisible());
  },
};

/**
 * Close during the intro: the onboarding leaves from where it is, without
 * the welcome page.
 */
export const CloseFromIntro: Story = {
  play: async ({ canvasElement }) => {
    const canvas = onboardingOf(canvasElement);
    await userEvent.click(
      await canvas.findByRole("button", { name: "Close onboarding" })
    );
    await waitFor(
      () =>
        expect(
          within(canvasElement).getByRole("button", { name: "Replay onboarding" })
        ).toBeVisible(),
      { timeout: 4000 }
    );
    await expect(canvas.queryByRole("heading", { name: "Comma is ready." })).toBeNull();
  },
};

/**
 * The sound's volume, left of Close: its slider opens under it, in the
 * light field's glass.
 */
export const SoundVolume: Story = {
  args: { mac: true, presentation: "window", start: "apps" },
  play: async ({ canvasElement }) => {
    const canvas = onboardingOf(canvasElement);
    await userEvent.click(await canvas.findByRole("button", { name: "Volume 100%" }));
    await waitFor(() =>
      expect(canvas.getByRole("slider", { name: "Volume" })).toBeVisible()
    );
  },
};

/** Reduced motion: the screen still dims; the mark fades in and out in place. */
export const IntroReducedMotion: Story = {
  args: { presentation: "window" },
  globals: { motionPreference: "reduced" },
};

export const AppsDark: Story = {
  args: { connections: { github: "connected", notion: "connecting" }, start: "apps" },
  globals: { theme: "dark" },
};

export const NameDark: Story = {
  args: { routerName: "Atlas", start: "name" },
  globals: { theme: "dark" },
};

export const IntroChinese: Story = { args: { locale: "zh-CN", mac: true } };

export const GreetingChinese: Story = {
  args: { locale: "zh-CN", mac: true, start: "greeting" },
};

export const AfterAppsChinese: Story = {
  args: {
    connections: { github: "connected", notion: "connected", slack: "connected" },
    locale: "zh-CN",
    mac: true,
    start: "after-apps",
  },
};

export const PermissionsChinese: Story = {
  args: {
    locale: "zh-CN",
    mac: true,
    macState: "waiting",
    routerName: "小逗",
    start: "permissions",
  },
};

export const WelcomeChinese: Story = {
  args: { locale: "zh-CN", routerName: "小逗", start: "welcome" },
};

/**
 * The macOS app: a transparent window over the whole display, the desktop
 * visible, dimmed, through the light field.
 */
export const WindowPresentation: Story = {
  args: { mac: true, presentation: "window", start: "greeting" },
};

export const WindowPresentationApps: Story = {
  args: { mac: true, presentation: "window", start: "apps" },
};

export const WindowPresentationWelcome: Story = {
  args: {
    connections: { github: "connected", notion: "connected" },
    mac: true,
    macState: "waiting",
    presentation: "window",
    routerName: "Atlas",
    start: "welcome",
  },
  globals: { theme: "dark" },
};
