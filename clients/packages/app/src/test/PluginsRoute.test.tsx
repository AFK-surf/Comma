import userEvent from "@testing-library/user-event";
import { CommaI18nProvider } from "@comma/i18n/react";
import {
  fireEvent,
  render as renderUI,
  screen,
  within,
} from "@comma/test-utils/render";
import { advance, flush } from "@comma/test-utils/fake-clock";
import {
  createNativeStateBridgeMock,
  installNativeBridgeMock,
} from "@comma/test-utils/native-bridge";
import {
  macAppIds,
  type MacAppState,
  type MacAppsSnapshot,
} from "@comma/native-bridge";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import type {
  Plugin as CommaPlugin,
  PluginActivity,
  PluginCategory,
  PluginInstallAnswer,
  PluginNotice,
  PluginsValue,
  SessionValue,
  Skill,
  SkillDetail,
  SkillsValue,
} from "@comma/core-client";
import { Toaster } from "@comma/ui/components/toast";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ReactNode } from "react";
import { useOnboardingPlugins } from "../components/onboarding/useOnboardingPlugins";
import { PluginNotices } from "../components/plugins/pluginInstall";
import { PluginsRoute } from "../components/plugins/PluginsRoute";

const harness = vi.hoisted(() => ({
  navigate: vi.fn(),
  openNativePlatformExternalUrl: vi.fn(),
}));

vi.mock("@tanstack/react-router", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@tanstack/react-router")>()),
  useNavigate: () => harness.navigate,
}));

vi.mock("../nativePlatformActions", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../nativePlatformActions")>()),
  openNativePlatformExternalUrl: harness.openNativePlatformExternalUrl,
}));

const WS = "wsp_1";

/** Plugins the core keeps off the Plugins page's lists (core test: "keeps Feishu off the Plugins page's lists"). */
const UNLISTED = new Set(["feishu", "lark", "mac-apps"]);

/**
 * What the core says the Plugins page shows: each plugin with what is under way
 * for it, the installed ones, and the rest by category.
 */
function catalogValue(
  plugins: readonly CommaPlugin[],
  activity: Record<string, PluginActivity>
): PluginsValue {
  const listed = plugins.filter((plugin) => !UNLISTED.has(plugin.id));
  const categories = new Map<string, PluginCategory>();
  for (const plugin of listed) {
    if (plugin.installed) continue;
    const name = plugin.category.trim() || "Integrations";
    let category = categories.get(name);
    if (!category) {
      category = {
        id: name.toLowerCase(),
        name: name === "Integrations" ? null : name,
        plugins: [],
      };
      categories.set(name, category);
    }
    category.plugins.push(plugin.id);
  }
  return {
    status: "ready",
    workspace: WS,
    plugins: plugins.map((plugin) => ({
      ...plugin,
      activity: activity[plugin.id] ?? "idle",
    })),
    installed: listed.filter((plugin) => plugin.installed).map((plugin) => plugin.id),
    categories: [...categories.values()],
  };
}

/** What the scripted core says now; a test changes it with `say`. */
type Script = {
  /** The catalog as read, or the `plugins` value before there is one. */
  catalog: readonly CommaPlugin[] | Exclude<PluginsValue, { status: "ready" }>;
  activity: Record<string, PluginActivity>;
  notices: PluginNotice[];
  skills: SkillsValue;
  session: SessionValue;
};

let script: Script;
let core: ReturnType<typeof createScriptedCore>;
/** How the core answers each call, by name (a call with none answers null). */
let answers: Record<string, (params: Record<string, unknown>) => unknown>;
/** The topics the UI subscribed to. */
let subscribed: Record<string, unknown>[];
let nextNotice = 0;

const signedIn = (userId: string): SessionValue => ({
  phase: "signed_in",
  userId,
  audience: "https://api.comma.test",
  sessionId: `session-${userId}`,
});

/** Changes what the core says, and sends it to each subscriber (they get it on the next `flush`). */
function say(change: Partial<Script>) {
  Object.assign(script, change);
  for (const topic of ["plugins", "pluginNotices", "skills", "session"])
    core.changed(topic);
}

/** The core says something went wrong (or what to open next), for one window to say. */
function notify(notice: Omit<PluginNotice, "id">) {
  say({ notices: [...script.notices, { ...notice, id: ++nextNotice }] });
}

function installed(plugin: CommaPlugin): CommaPlugin {
  return { ...plugin, installed: true };
}

/** The catalog with `plugin` as the core last read it. */
function withPlugin(plugin: CommaPlugin) {
  const catalog = script.catalog as readonly CommaPlugin[];
  return catalog.map((p) => (p.id === plugin.id ? plugin : p));
}

function scriptedCore() {
  return createScriptedCore({
    values: (topic) => {
      switch (topic.topic) {
        case "plugins":
          return Array.isArray(script.catalog)
            ? catalogValue(script.catalog, script.activity)
            : script.catalog;
        case "pluginNotices":
          return { notices: script.notices };
        case "skills":
          return topic.workspace === WS ? script.skills : undefined;
        case "session":
          return script.session;
        default:
          return undefined;
      }
    },
    calls: (name, params) => answers[name]?.(params as Record<string, unknown>) ?? null,
    onSubscribe: (topic) => subscribed.push(topic),
  });
}

/** A window on the test's core: its UI, and the core's notices said in it. */
function inWindow(ui: ReactNode) {
  return core.wrap(
    <>
      <PluginNotices />
      {ui}
    </>
  );
}

function render(ui: ReactNode) {
  return renderUI(inWindow(ui));
}

/** A user whose waits run on the fake clock. */
function setupUser() {
  return userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
}

/** Presses a button and lets what it starts finish. */
async function press(element: Element) {
  fireEvent.click(element);
  await flush();
}

/** The window gets the focus back from the browser. */
async function focusWindow() {
  window.dispatchEvent(new Event("focus"));
  await flush();
}

/** The onboarding's apps card, down to its Connect for Linear. */
function OnboardingConnectLinear() {
  const { connect } = useOnboardingPlugins({
    workspace: { status: "ready", workspaceId: "wsp_1" },
  });
  return (
    <button onClick={() => connect("linear")} type="button">
      Connect Linear
    </button>
  );
}

const notionPlugin: CommaPlugin = {
  brand: "notion",
  category: "Integrations",
  description: "Search and update your workspace",
  id: "notion",
  installed: true,
  locked: false,
  mcps: [{ id: "notion-mcp", name: "Notion" }],
  name: "Notion",
  skills: [{ id: "search-workspace", name: "Search workspace" }],
  summary: "Search and update your workspace",
};

const linearPlugin: CommaPlugin = {
  brand: "linear",
  category: "Integrations",
  description: "Plan and track product work",
  id: "linear",
  installed: false,
  locked: false,
  mcps: [{ id: "linear-mcp", name: "Linear" }],
  name: "Linear",
  skills: [],
  summary: "Plan and track product work",
};

const availablePlugins = [
  linearPlugin,
  {
    ...linearPlugin,
    brand: "github",
    id: "github",
    mcps: [],
    name: "GitHub",
    summary: "Work with repositories",
  },
  {
    ...linearPlugin,
    brand: "slack",
    id: "slack",
    mcps: [],
    name: "Slack",
    summary: "Collaborate with your team",
  },
  {
    ...linearPlugin,
    brand: "google",
    id: "google",
    mcps: [],
    name: "Google",
    summary: "Search across Google Workspace",
  },
  {
    ...linearPlugin,
    brand: "notion",
    id: "knowledge-base",
    mcps: [],
    name: "Knowledge Base",
    summary: "Keep shared guidance easy to find",
  },
  {
    ...linearPlugin,
    brand: "linear",
    id: "project-planning",
    mcps: [],
    name: "Project Planning",
    summary: "Plan milestones and track delivery",
  },
  {
    ...linearPlugin,
    brand: "slack",
    id: "release-coordination",
    mcps: [],
    name: "Release Coordination",
    summary: "Keep launch communication in sync",
  },
] satisfies readonly CommaPlugin[];

const skills: Skill[] = [
  {
    description: "Summarize a long thread",
    location: "skills/summarize/SKILL.md",
    name: "summarize",
    skill_id: "summarize",
    source: "custom",
  },
  {
    description: "Draft a weekly report",
    location: "skills/report/SKILL.md",
    name: "weekly-report",
    skill_id: "weekly-report",
    source: "system",
  },
];

const weeklyReport: SkillDetail = {
  content:
    "---\nname: weekly-report\ndescription: Draft a weekly report\n---\n\n# Reporting steps\n\nCollect finished tasks.",
  description: "Draft a weekly report",
  files: ["SKILL.md", "references/format.md"],
  location: "skills/report/SKILL.md",
  name: "weekly-report",
  skill_id: "weekly-report",
  source: "system",
};

/** An install the core has not answered yet: `answer` ends it as the core would. */
function pendingInstall() {
  const { promise, resolve, reject } = Promise.withResolvers<PluginInstallAnswer>();
  return { promise, answer: resolve, fail: reject };
}

describe("PluginsRoute", () => {
  beforeEach(() => {
    nextNotice = 0;
    subscribed = [];
    script = {
      catalog: [notionPlugin, linearPlugin],
      activity: {},
      notices: [],
      skills: { status: "ready", skills },
      session: signedIn("user-1"),
    };
    answers = {
      // A notice goes to the one window that claims it.
      "plugin.notice.claim": ({ id }) => {
        say({ notices: script.notices.filter((notice) => notice.id !== id) });
        return true;
      },
      "plugin.install": () => {
        say({ catalog: withPlugin(installed(linearPlugin)) });
        return {};
      },
      "plugin.uninstall": () => {
        say({ catalog: withPlugin({ ...notionPlugin, installed: false }) });
        return null;
      },
      "skills.detail": () => weeklyReport,
      "skills.file": () => ({
        content: "# Report format\n\nOne section per project.",
        path: "references/format.md",
      }),
    };
    core = scriptedCore();
    harness.navigate.mockReset();
    harness.openNativePlatformExternalUrl.mockReset();
    harness.openNativePlatformExternalUrl.mockResolvedValue(undefined);
  });

  it("reports loading until the plugin catalog is ready", async () => {
    script.catalog = { status: "loading" };
    render(<PluginsRoute />);
    await flush();

    const loading = screen.getByRole("status");
    expect(loading).toHaveAccessibleName("Loading…");
    expect(loading).toHaveAttribute("aria-busy", "true");

    say({ catalog: [notionPlugin, linearPlugin] });
    await flush();
    expect(screen.getByRole("heading", { name: "Installed" })).toBeVisible();
    expect(loading).not.toBeInTheDocument();
  });

  it("releases a stalled first request and ignores its late success after retry", async () => {
    // The core gives a request with no answer up after 30 s and keeps nothing of
    // its late answer (core test: "lets an install that never answered go after
    // 30 s, and keeps nothing of its late answer").
    const first = pendingInstall();
    answers["plugin.install"] = () => {
      say({ activity: { linear: "installing" } });
      return first.promise;
    };
    render(
      <>
        <PluginsRoute />
        <Toaster />
      </>
    );
    await flush();
    await press(screen.getByRole("button", { name: "Add Linear" }));
    expect(core.sentTo("plugin.install")).toEqual([
      { plugin: "linear", workspace: WS },
    ]);
    expect(screen.getByRole("button", { name: "Add Linear" })).toBeDisabled();

    say({ activity: {} });
    notify({ kind: "install_timed_out", origin: "plugins", plugin: "linear" });
    first.answer({});
    await flush();
    expect(screen.getByRole("button", { name: "Add Linear" })).not.toBeDisabled();
    expect(
      screen.getByText("The connection request timed out. Try adding the plugin again.")
    ).toBeVisible();
    expect(screen.getByRole("button", { name: "Add Linear" })).toBeVisible();
    expect(harness.navigate).not.toHaveBeenCalled();

    answers["plugin.install"] = () => {
      say({ catalog: withPlugin(installed(linearPlugin)), activity: {} });
      return {};
    };
    await press(screen.getByRole("button", { name: "Add Linear" }));
    // The confirmed retry stays in Plugins and shows the plugin as added.
    expect(screen.queryByRole("button", { name: "Add Linear" })).toBeNull();
    expect(core.sentTo("plugin.install")).toHaveLength(2);
    expect(harness.navigate).not.toHaveBeenCalled();
  });

  it("continues authorization while Plugins is unmounted and completes after returning", async () => {
    answers["plugin.install"] = () => {
      say({ activity: { linear: "authorizing" } });
      return { authorizationUrl: "https://linear.app/oauth" };
    };
    const view = (show: boolean) => inWindow(show ? <PluginsRoute /> : <div>Home</div>);
    const page = renderUI(view(true));
    await flush();
    await press(screen.getByRole("button", { name: "Add Linear" }));
    expect(harness.openNativePlatformExternalUrl).toHaveBeenCalledTimes(1);
    expect(harness.openNativePlatformExternalUrl).toHaveBeenCalledWith(
      "https://linear.app/oauth"
    );
    page.rerender(view(false));
    await flush();
    // The core goes on checking with no page showing the catalog, and finds the
    // browser done (core test: "keeps checking an authorization while no page
    // shows the catalog").
    say({ catalog: withPlugin(installed(linearPlugin)), activity: {} });
    await flush();
    page.rerender(view(true));
    await flush();
    expect(
      screen.getByRole("button", { name: "View Linear plugin details" })
    ).toBeVisible();
    expect(core.sentTo("plugin.install")).toHaveLength(1);
    expect(harness.openNativePlatformExternalUrl).toHaveBeenCalledTimes(1);
    expect(screen.queryByRole("button", { name: "Add Linear" })).toBeNull();
    expect(harness.navigate).not.toHaveBeenCalled();
  });

  it("cancels the old account's request when its session ends", async () => {
    // The core stops the old account's request (core test: "stops an install
    // under way when another account signs in, and says nothing of it").
    const first = pendingInstall();
    answers["plugin.install"] = () => {
      say({ activity: { linear: "installing" } });
      return first.promise;
    };
    render(<PluginsRoute />);
    await flush();
    await press(screen.getByRole("button", { name: "Add Linear" }));
    expect(core.sentTo("plugin.install")).toHaveLength(1);
    say({ session: signedIn("someone-else"), activity: {} });
    first.fail(Object.assign(new Error("cancelled"), { code: "cancelled" }));
    await flush();
    expect(harness.navigate).not.toHaveBeenCalled();
    expect(harness.openNativePlatformExternalUrl).not.toHaveBeenCalled();
  });

  it("keeps a plugin uninstalled until its install authorization completes", async () => {
    const user = setupUser();
    const firstInstall = pendingInstall();
    answers["plugin.install"] = () => {
      say({ activity: { linear: "installing" } });
      return firstInstall.promise;
    };
    answers["plugin.authorization.check"] = () => {
      say({ catalog: withPlugin(installed(linearPlugin)), activity: {} });
      return null;
    };
    render(<PluginsRoute />);
    await flush();

    expect(screen.getByRole("heading", { name: "Plugins" })).toBeVisible();
    expect(screen.getByRole("heading", { name: "Installed" })).toBeVisible();
    expect(
      document.querySelector(
        '[data-plugin-brand="linear"] [data-provider-logo="linear"]'
      )
    ).not.toBeNull();
    expect(
      document.querySelector(
        '[data-plugin-brand="notion"] [data-provider-logo="notion"]'
      )
    ).not.toBeNull();

    await user.click(screen.getByRole("button", { name: "Add Linear" }));
    await flush();

    expect(screen.getByRole("button", { name: "Add Linear" })).toBeDisabled();
    expect(
      screen.getByRole("button", { name: "Add Linear" }).querySelector(".animate-spin")
    ).not.toBeNull();
    say({ activity: { linear: "authorizing" } });
    firstInstall.answer({
      authorizationUrl: "https://linear.app/oauth/authorize?state=state-1",
    });
    await flush();

    expect(core.sentTo("plugin.install")).toEqual([
      { plugin: "linear", workspace: WS },
    ]);
    expect(harness.openNativePlatformExternalUrl).toHaveBeenCalledWith(
      "https://linear.app/oauth/authorize?state=state-1"
    );
    expect(screen.getByRole("button", { name: "Add Linear" })).not.toBeDisabled();

    // The core checks the authorization at once (core test: "checks an
    // authorization at once when a window gets the focus back").
    await focusWindow();

    expect(screen.queryByRole("button", { name: "Add Linear" })).toBeNull();
    expect(core.sentTo("plugin.authorization.check")).toEqual([{}]);
    expect(harness.openNativePlatformExternalUrl).toHaveBeenCalledTimes(1);
    expect(harness.navigate).not.toHaveBeenCalled();
    expect(
      screen.getByRole("button", { name: "View Linear plugin details" })
    ).toBeVisible();
  });

  it("installs an app the onboarding window left authorizing once the user finishes in the browser", async () => {
    const user = setupUser();
    answers["plugin.install"] = () => {
      say({ activity: { linear: "authorizing" } });
      return {
        authorizationUrl: "https://linear.app/oauth/authorize?state=onboarding-state",
      };
    };
    answers["plugin.authorization.check"] = () => {
      say({ catalog: withPlugin(installed(linearPlugin)), activity: {} });
      return null;
    };
    const onboardingWindow = renderUI(inWindow(<OnboardingConnectLinear />));
    render(<PluginsRoute />);
    await flush();
    expect(screen.getByRole("button", { name: "Add Linear" })).toBeEnabled();

    // The onboarding window opens Linear's consent, then closes with it still
    // open in the browser; the user finishes it there and comes back.
    await user.click(screen.getByRole("button", { name: "Connect Linear" }));
    await flush();
    expect(harness.openNativePlatformExternalUrl).toHaveBeenCalledTimes(1);
    expect(core.sentTo("plugin.install")).toEqual([
      { origin: "onboarding", plugin: "linear", workspace: WS },
    ]);
    onboardingWindow.unmount();
    await focusWindow();

    expect(screen.queryByRole("button", { name: "Add Linear" })).toBeNull();
    expect(core.sentTo("plugin.authorization.check")).toEqual([{}]);
    expect(harness.openNativePlatformExternalUrl).toHaveBeenCalledTimes(1);
  });

  it("says why an install failed in the reader's words, never the server's code", async () => {
    // The core words the server's code (core test: "words a refused install by
    // the server's code, and an unanswered one as timed out after 30 s").
    const user = setupUser();
    const reasons = ["unavailable", "generic"] as const;
    answers["plugin.install"] = () => {
      notify({
        kind: "install_failed",
        origin: "plugins",
        plugin: "linear",
        reason: reasons[core.sentTo("plugin.install").length - 1]!,
      });
      return {};
    };
    render(
      <>
        <PluginsRoute />
        <Toaster />
      </>
    );
    await flush();

    await user.click(screen.getByRole("button", { name: "Add Linear" }));
    await flush();
    expect(screen.getByText("Couldn’t add the plugin.")).toBeVisible();
    expect(
      screen.getByText("The service isn’t available right now. Try again in a moment.")
    ).toBeVisible();

    // A code with no wording of its own reads as a general failure.
    await user.click(screen.getByRole("button", { name: "Add Linear" }));
    await flush();
    expect(screen.getByText("Something went wrong. Try again.")).toBeVisible();
    expect(screen.queryByText(/upstream_unavailable|internal_error/)).toBeNull();
  });

  it("words a failure started from the onboarding for its apps, without sending the user to Plugins", async () => {
    const user = setupUser();
    answers["plugin.install"] = () => {
      notify({
        kind: "install_failed",
        origin: "onboarding",
        plugin: "linear",
        reason: "unavailable",
      });
      return {};
    };
    render(
      <>
        <OnboardingConnectLinear />
        <Toaster />
      </>
    );

    await user.click(screen.getByRole("button", { name: "Connect Linear" }));
    await flush();
    expect(core.sentTo("plugin.install")).toEqual([
      { origin: "onboarding", plugin: "linear", workspace: WS },
    ]);
    expect(screen.getByText("Couldn’t connect the app.")).toBeVisible();
    expect(
      screen.getByText("The service isn’t available right now. Try again in a moment.")
    ).toBeVisible();
    expect(screen.queryByText(/plugin/i)).toBeNull();
  });

  it("words an onboarding authorization that times out in another window for its apps", async () => {
    const user = setupUser();
    answers["plugin.install"] = () => {
      say({ activity: { linear: "authorizing" } });
      return {};
    };
    const onboardingWindow = renderUI(inWindow(<OnboardingConnectLinear />));
    render(<Toaster />);

    // The onboarding window closed with Linear's consent open, which the user
    // never finishes.
    await user.click(screen.getByRole("button", { name: "Connect Linear" }));
    await flush();
    expect(core.sentTo("plugin.install")).toHaveLength(1);
    onboardingWindow.unmount();
    await flush();
    // Two minutes on, the core gives it up, for the window still open to say
    // (core test: "gives an authorization up after two minutes, and one window
    // says so").
    say({ activity: {} });
    notify({
      kind: "authorization_timed_out",
      origin: "onboarding",
      plugin: "linear",
    });
    await flush();

    expect(
      screen.getByText("Authorization timed out. Try connecting the app again.")
    ).toBeVisible();
    expect(screen.queryByText(/Plugins/)).toBeNull();
  });

  it("retries pending authorization without focus or reopening the browser", async () => {
    answers["plugin.install"] = () => {
      say({ activity: { linear: "authorizing" } });
      return { authorizationUrl: "https://linear.app/oauth" };
    };
    render(<PluginsRoute />);
    await flush();
    await press(screen.getByRole("button", { name: "Add Linear" }));
    expect(harness.openNativePlatformExternalUrl).toHaveBeenCalledTimes(1);
    // The core checks every 2 s by itself (core test: "opens its authorization,
    // checks it every 2 s, and shows it installed once the browser is done").
    say({ activity: { linear: "verifying" } });
    await flush();
    say({ activity: { linear: "authorizing" } });
    await flush();
    say({ catalog: withPlugin(installed(linearPlugin)), activity: {} });
    await flush();
    expect(screen.queryByRole("button", { name: "Add Linear" })).toBeNull();
    expect(core.sentTo("plugin.install")).toHaveLength(1);
    expect(core.sentTo("plugin.authorization.check")).toEqual([]);
    expect(harness.openNativePlatformExternalUrl).toHaveBeenCalledTimes(1);
  });

  it("releases a hanging verification at the deadline and ignores its late success", async () => {
    // The core lets the check go at the authorization's deadline and keeps
    // nothing of its late answer (core test: "lets a check still under way at
    // the deadline go, and keeps nothing of its late answer").
    answers["plugin.install"] = () => {
      say({ activity: { linear: "authorizing" } });
      return {};
    };
    render(<PluginsRoute />);
    await flush();
    await press(screen.getByRole("button", { name: "Add Linear" }));
    say({ activity: { linear: "verifying" } });
    await flush();
    expect(screen.getByRole("button", { name: "Add Linear" })).toBeDisabled();
    say({ activity: {} });
    notify({ kind: "authorization_timed_out", origin: "plugins", plugin: "linear" });
    await flush();
    expect(screen.getByRole("button", { name: "Add Linear" })).not.toBeDisabled();
    const newAttempt = pendingInstall();
    answers["plugin.install"] = () => {
      say({ activity: { linear: "installing" } });
      return newAttempt.promise;
    };
    await press(screen.getByRole("button", { name: "Add Linear" }));
    expect(core.sentTo("plugin.install")).toHaveLength(2);
    expect(screen.getByRole("button", { name: "Add Linear" })).toBeDisabled();
    say({ activity: {} });
    newAttempt.answer({});
    await flush();
    expect(screen.getByRole("button", { name: "Add Linear" })).not.toBeDisabled();
  });

  it("retains the attempt after a transient verification failure", async () => {
    answers["plugin.install"] = () => {
      say({ activity: { linear: "authorizing" } });
      return { authorizationUrl: "https://linear.app/oauth" };
    };
    render(<PluginsRoute />);
    await flush();
    await press(screen.getByRole("button", { name: "Add Linear" }));
    expect(harness.openNativePlatformExternalUrl).toHaveBeenCalledTimes(1);
    // The check the focus starts fails; the core keeps the attempt and checks it
    // again 2 s on (core test: "checks the same attempt again after a check that
    // failed").
    await focusWindow();
    expect(core.sentTo("plugin.authorization.check")).toEqual([{}]);
    expect(screen.getByRole("button", { name: "Add Linear" })).toBeVisible();
    say({ catalog: withPlugin(installed(linearPlugin)), activity: {} });
    await flush();
    expect(screen.queryByRole("button", { name: "Add Linear" })).toBeNull();
    expect(harness.openNativePlatformExternalUrl).toHaveBeenCalledTimes(1);
  });

  it("treats closing an unfinished authorization page as cancellation", async () => {
    // The core ends the authorization when a check finds the attempt not
    // finished, and checks nothing more (core test: "lets an authorization go
    // when a check finds it unfinished, and checks nothing more").
    const user = setupUser();
    answers["plugin.install"] = () => {
      say({ activity: { linear: "authorizing" } });
      return { authorizationUrl: "https://linear.app/oauth/authorize?state=state-1" };
    };
    answers["plugin.authorization.check"] = () => {
      say({ activity: {} });
      return null;
    };
    render(<PluginsRoute />);
    await flush();

    await user.click(screen.getByRole("button", { name: "Add Linear" }));
    await flush();
    expect(harness.openNativePlatformExternalUrl).toHaveBeenCalledTimes(1);
    expect(screen.getByRole("button", { name: "Add Linear" })).not.toBeDisabled();

    await focusWindow();

    expect(core.sentTo("plugin.authorization.check")).toEqual([{}]);
    expect(harness.openNativePlatformExternalUrl).toHaveBeenCalledTimes(1);
    expect(screen.getByRole("button", { name: "Add Linear" })).toBeVisible();

    await focusWindow();
    expect(core.sentTo("plugin.install")).toHaveLength(1);
    expect(harness.openNativePlatformExternalUrl).toHaveBeenCalledTimes(1);
    expect(screen.getByRole("button", { name: "Add Linear" })).toBeVisible();
  });

  it("opens the next authorization after a completed partial install", async () => {
    // A check that finds the next account's attempt has the core say where to
    // authorize it (core test: "has one window open the next attempt a check
    // finds, and checks that one").
    const user = setupUser();
    const google: CommaPlugin = {
      ...linearPlugin,
      brand: "google",
      id: "google",
      name: "Google",
    };
    script.catalog = [google];
    answers["plugin.install"] = () => {
      say({ activity: { google: "authorizing" } });
      return {
        authorizationUrl: "https://accounts.google.com/gmail?state=gmail-state",
      };
    };
    answers["plugin.authorization.check"] = () => {
      notify({
        kind: "authorize",
        origin: "plugins",
        plugin: "google",
        url: "https://accounts.google.com/calendar?state=calendar-state",
      });
      answers["plugin.authorization.check"] = () => {
        say({ catalog: [installed(google)], activity: {} });
        return null;
      };
      return null;
    };
    render(<PluginsRoute />);
    await flush();

    await user.click(screen.getByRole("button", { name: "Add Google" }));
    await flush();
    expect(harness.openNativePlatformExternalUrl).toHaveBeenCalledWith(
      "https://accounts.google.com/gmail?state=gmail-state"
    );

    await focusWindow();
    expect(harness.openNativePlatformExternalUrl).toHaveBeenCalledWith(
      "https://accounts.google.com/calendar?state=calendar-state"
    );
    expect(core.sentTo("plugin.authorization.check")).toEqual([{}]);
    expect(screen.getByRole("button", { name: "Add Google" })).not.toBeDisabled();

    await focusWindow();
    expect(core.sentTo("plugin.authorization.check")).toEqual([{}, {}]);
    expect(screen.queryByRole("button", { name: "Add Google" })).toBeNull();
    expect(core.sentTo("plugin.install")).toEqual([
      { plugin: "google", workspace: WS },
    ]);
    expect(harness.openNativePlatformExternalUrl).toHaveBeenCalledTimes(2);
  });

  it("uses the supplied Google artwork throughout the plugin catalog and detail", async () => {
    const name = "Google";
    const logo = "google";
    const user = setupUser();
    script.catalog = [
      { ...notionPlugin, id: "feishu", brand: "feishu", name: "Feishu" },
      notionPlugin,
      ...availablePlugins,
    ];

    const { container } = render(<PluginsRoute />);
    await flush();
    expect(screen.getByRole("heading", { name: "Plugins" })).toBeVisible();

    for (const brand of ["github", "google", "linear", "notion", "slack"]) {
      expect(
        container.querySelector(
          `[data-plugin-brand="${brand}"] [data-provider-logo="${brand}"]`
        )
      ).toBeInTheDocument();
    }

    await user.click(
      screen.getByRole("button", { name: "Show all Integrations plugins" })
    );
    await user.click(
      screen.getByRole("button", { name: `View ${name} plugin details` })
    );
    await flush();
    expect(
      container.querySelector(
        `[data-slot="plugin-detail"] [data-provider-logo="${logo}"]`
      )
    ).toBeInTheDocument();
  });

  it("keeps unreleased Feishu out of catalog browsing and search", async () => {
    // The core keeps it off the lists it gives the page (core test: "keeps
    // Feishu off the Plugins page's lists").
    const user = setupUser();
    script.catalog = [
      { ...notionPlugin, id: "feishu", brand: "feishu", name: "Feishu" },
      ...availablePlugins,
    ];
    render(<PluginsRoute />);
    await flush();
    await user.click(
      screen.getByRole("button", { name: "Show all Integrations plugins" })
    );
    expect(
      screen.getByRole("button", { name: "View Google plugin details" })
    ).toBeVisible();
    expect(
      screen.queryByRole("button", { name: "View Feishu plugin details" })
    ).toBeNull();
    await user.type(screen.getByRole("textbox", { name: "Search plugins" }), "Feishu");
    expect(screen.getByText("No plugins found")).toBeVisible();
    expect(core.sentTo("plugin.install")).toEqual([]);
  });

  it("shows a skill loading state instead of an empty catalog", async () => {
    const user = setupUser();
    script.skills = { status: "loading", skills: [] };
    render(<PluginsRoute />);
    await flush();
    await user.click(screen.getByRole("tab", { name: "Skills" }));
    expect(screen.queryByText("No skills found")).toBeNull();
    expect(screen.getByRole("status", { name: "Loading…" })).toHaveAttribute(
      "aria-busy",
      "true"
    );
  });

  it("retries failed skill loads without poisoning the catalog cache", async () => {
    // The core keeps nothing of a failed read and reads again at once on
    // `skills.refresh` (core test: "says a failed read failed, keeps nothing for
    // it, and reads again at once on retry").
    const user = setupUser();
    script.skills = { status: "error", skills: [] };
    answers["skills.refresh"] = () => {
      say({ skills: { status: "ready", skills } });
      return null;
    };
    render(<PluginsRoute />);
    await flush();
    await user.click(screen.getByRole("tab", { name: "Skills" }));
    expect(screen.getByRole("alert")).toHaveTextContent("Couldn’t load skills.");
    expect(screen.queryByText("No skills found")).toBeNull();
    await user.click(screen.getByRole("tab", { name: "Plugins" }));
    expect(screen.queryByRole("alert")).toBeNull();
    expect(screen.getByText("Notion")).toBeVisible();
    await user.click(screen.getByRole("tab", { name: "Skills" }));
    await user.click(screen.getByRole("button", { name: "Retry" }));
    await flush();
    expect(screen.getByText("summarize")).toBeVisible();
    expect(core.sentTo("skills.refresh")).toEqual([{ workspace: WS }]);
    expect(screen.queryByRole("alert")).toBeNull();
  });

  it("refetches immediately after reopening a failed skill catalog", async () => {
    const user = setupUser();
    script.skills = { status: "error", skills: [] };
    answers["skills.refresh"] = () => {
      say({ skills: { status: "ready", skills } });
      return null;
    };
    const first = render(<PluginsRoute />);
    await flush();
    await user.click(screen.getByRole("tab", { name: "Skills" }));
    expect(screen.getByRole("alert")).toHaveTextContent("Couldn’t load skills.");
    expect(core.sentTo("skills.refresh")).toEqual([]);
    first.unmount();
    render(<PluginsRoute />);
    await flush();
    await user.click(screen.getByRole("tab", { name: "Skills" }));
    expect(screen.getByText("summarize")).toBeVisible();
    expect(core.sentTo("skills.refresh")).toEqual([{ workspace: WS }]);
  });

  it("shows the empty skill state only after a successful empty response", async () => {
    const user = setupUser();
    script.skills = { status: "ready", skills: [] };
    render(<PluginsRoute />);
    await flush();
    await user.click(screen.getByRole("tab", { name: "Skills" }));
    expect(screen.getByText("No skills found")).toBeVisible();
    expect(screen.queryByRole("alert")).toBeNull();
    expect(screen.queryByRole("button", { name: "Retry" })).toBeNull();
  });

  it("lists, categorizes, and searches workspace skills on the Skills tab", async () => {
    const user = setupUser();
    render(<PluginsRoute />);
    await flush();

    await user.click(screen.getByRole("tab", { name: "Skills" }));

    expect(subscribed).toContainEqual({ topic: "skills", workspace: WS });
    expect(screen.getByRole("heading", { level: 1, name: "Skills" })).toBeVisible();
    expect(screen.getByText("summarize")).toBeVisible();
    expect(screen.queryByText("weekly-report")).toBeNull();
    expect(screen.queryByText("Notion")).toBeNull();

    await user.click(screen.getByRole("button", { name: "System" }));
    expect(screen.getByText("Draft a weekly report")).toBeVisible();
    expect(screen.queryByText("summarize")).toBeNull();

    await user.type(screen.getByRole("textbox", { name: "Search skills" }), "summ");
    expect(screen.getByText("summarize")).toBeVisible();
    expect(screen.queryByText("weekly-report")).toBeNull();

    await user.click(screen.getByRole("tab", { name: "Plugins" }));
    expect(screen.getByRole("textbox", { name: "Search plugins" })).toHaveValue("");
    expect(screen.getByText("Notion")).toBeVisible();
  });

  it("opens a skill as a second-level page with its rendered instructions", async () => {
    // The core reads them (core test: "reads one skill and one of its files when
    // a page opens them").
    const user = setupUser();
    const { container } = render(<PluginsRoute />);
    await flush();

    await user.click(screen.getByRole("tab", { name: "Skills" }));
    await user.click(screen.getByRole("button", { name: "System" }));
    await user.click(
      screen.getByRole("button", { name: "View weekly-report skill details" })
    );

    expect(core.sentTo("skills.detail")).toEqual([
      { workspace: WS, skill: "weekly-report" },
    ]);
    expect(
      screen.getByRole("heading", { level: 1, name: "weekly-report" })
    ).toBeVisible();
    // The skill's file arrives after the detail page opens.
    expect(await screen.findByText("Reporting steps")).toBeVisible();
    const fileContent = container.querySelector('[data-slot="skill-file-content"]');
    expect(fileContent).not.toHaveTextContent("name: weekly-report");

    // Source view shows the raw file, front matter included.
    await user.click(screen.getByRole("button", { name: "Source" }));
    await flush();
    expect(fileContent).toHaveTextContent("name: weekly-report");
    expect(fileContent).toHaveTextContent("# Reporting steps");

    // A reference file loads on demand and keeps the chosen view.
    await user.click(screen.getByRole("button", { name: "format.md" }));
    expect(core.sentTo("skills.file")).toEqual([
      { workspace: WS, skill: "weekly-report", path: "references/format.md" },
    ]);
    await flush();
    // Highlighting splits a source line into token spans, so read the line as text.
    expect(fileContent).toHaveTextContent("# Report format");
    await user.click(screen.getByRole("button", { name: "Rendered" }));
    expect(screen.getByRole("heading", { name: "Report format" })).toBeVisible();

    await user.click(screen.getByRole("button", { name: "Back to skills" }));
    expect(screen.getByRole("tab", { name: "Skills" })).toHaveAttribute(
      "aria-selected",
      "true"
    );
    expect(screen.getByRole("button", { name: "System" })).toHaveAttribute(
      "aria-pressed",
      "true"
    );
  });

  it("opens, reveals, and copies a skill's Markdown from its actions menu", async () => {
    const downloadRef = "dnl1_9Sm2XQ0pW7hVn4Lr8Tc6Jd1Fb3Zy5Ku0Ae7Ri2Ot4Gx";
    const saveDownload = vi.fn(async () => ({
      downloadRef,
      fileName: "weekly-report.md",
      status: "saved" as const,
    }));
    const openDownload = vi.fn(async () => ({ status: "opened" as const }));
    const revealDownload = vi.fn(async () => ({ status: "revealed" as const }));
    const writeText = vi.fn(async () => ({ ok: true as const }));
    installNativeBridgeMock({
      clipboard: { writeText },
      files: { openDownload, revealDownload, saveDownload },
      os: "macos",
      platform: "electron",
    });
    const user = setupUser();
    render(<PluginsRoute />);
    await flush();

    await user.click(screen.getByRole("tab", { name: "Skills" }));
    await user.click(screen.getByRole("button", { name: "System" }));
    await user.click(
      screen.getByRole("button", { name: "View weekly-report skill details" })
    );
    // The skill's file arrives after the detail page opens.
    expect(await screen.findByText("Reporting steps")).toBeVisible();

    await user.click(screen.getByRole("button", { name: "Skill actions" }));
    await flush();
    await user.click(screen.getByRole("menuitem", { name: "Open" }));
    await flush();
    expect(openDownload).toHaveBeenCalledWith({ downloadRef });
    expect(saveDownload).toHaveBeenCalledWith(
      expect.objectContaining({ fileName: "weekly-report.md" })
    );

    await user.click(screen.getByRole("button", { name: "Skill actions" }));
    await flush();
    await user.click(screen.getByRole("menuitem", { name: "Reveal in Finder" }));
    await flush();
    expect(revealDownload).toHaveBeenCalledWith({ downloadRef });
    // The second action reuses the copy the first one placed in Downloads.
    expect(saveDownload).toHaveBeenCalledTimes(1);

    await user.click(screen.getByRole("button", { name: "Skill actions" }));
    await flush();
    await user.click(screen.getByRole("menuitem", { name: "Copy Markdown" }));
    await flush();
    expect(writeText).toHaveBeenCalledWith({
      text: expect.stringContaining("# Reporting steps"),
    });
  });

  it("opens an installed plugin detail and uninstalls it", async () => {
    // The core asks the server and keeps what it answers (core test:
    // "uninstalls, and says what the server said when it could not").
    const user = setupUser();
    const { container } = render(<PluginsRoute />);
    await flush();

    expect(screen.getByRole("heading", { name: "Plugins" })).toBeVisible();
    expect(container.querySelector('[data-slot="plugin-catalog"]')).toHaveClass(
      "comma-plugins-route"
    );

    await user.click(
      screen.getByRole("button", { name: "View Notion plugin details" })
    );
    expect(container.querySelector('[data-slot="plugin-detail"]')).toHaveClass(
      "comma-plugins-route"
    );
    expect(screen.getByRole("heading", { level: 1, name: "Notion" })).toBeVisible();
    expect(screen.queryByRole("button", { name: "Connect" })).toBeNull();
    expect(
      container.querySelector(
        '[data-slot="plugin-detail"] li [data-provider-logo="notion"]'
      )
    ).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "Uninstall Notion" }));
    await flush();

    expect(core.sentTo("plugin.uninstall")).toEqual([
      { plugin: "notion", workspace: WS },
    ]);
    expect(screen.getByRole("button", { name: "Add to Comma Notion" })).toBeVisible();

    await user.click(screen.getByRole("button", { name: "Back to plugins" }));
    expect(screen.getByRole("heading", { name: "Plugins" })).toBeVisible();
  });

  it("shows a retryable error when the catalog request fails", async () => {
    // The core says why its read failed (core test: "says why a first read
    // failed, and reads again every 10 s until it can").
    const user = setupUser();
    script.catalog = {
      status: "error",
      workspace: WS,
      error: { code: "failed", message: "offline" },
    };
    answers["plugins.refresh"] = () => {
      say({ catalog: [notionPlugin, linearPlugin] });
      return null;
    };
    render(
      <>
        <Toaster />
        <PluginsRoute />
      </>
    );
    await flush();

    const errorToast = screen.getByTestId("plugins-load-error");
    expect(errorToast).toHaveTextContent("Couldn’t load plugins.");
    expect(errorToast).toHaveTextContent("offline");
    await user.click(
      within(errorToast).getByRole("button", { name: "Dismiss notification" })
    );
    // A closed toast leaves after its exit animation, which starts once the
    // close has rendered.
    await advance(300);
    await advance(300);
    expect(screen.queryByTestId("plugins-load-error")).toBeNull();

    // Dismissing transient feedback must not remove the only recovery path.
    await user.click(screen.getByRole("button", { name: "Retry" }));
    await flush();

    expect(screen.getByRole("heading", { name: "Plugins" })).toBeVisible();
    expect(core.sentTo("plugins.refresh")).toEqual([{ workspace: WS }]);
  });

  it("shows one remaining plugin directly without Show all", async () => {
    const plugins = availablePlugins.slice(0, 4);
    script.catalog = [notionPlugin, ...plugins];

    render(<PluginsRoute />);
    await flush();

    expect(screen.getByRole("heading", { name: "Integrations" })).toBeVisible();
    expect(
      screen.queryByRole("button", { name: "Show all Integrations plugins" })
    ).toBeNull();
    expect(
      screen.getByRole("button", { name: "View Google plugin details" })
    ).toBeVisible();
  });

  it.each([
    {
      availableCount: 5,
      expectedPreviewIds: ["google", "knowledge-base"],
      name: "previews both hidden plugins when two remain",
    },
    {
      availableCount: 7,
      expectedPreviewIds: ["google", "knowledge-base", "project-planning"],
      name: "caps the preview at three plugins when more than two remain",
    },
  ])("$name", async ({ availableCount, expectedPreviewIds }) => {
    const user = setupUser();
    const plugins = availablePlugins.slice(0, availableCount);
    script.catalog = [notionPlugin, ...plugins];

    render(<PluginsRoute />);
    await flush();

    expect(screen.getByRole("heading", { name: "Integrations" })).toBeVisible();
    const showAllButton = screen.getByRole("button", {
      name: "Show all Integrations plugins",
    });

    expect(within(showAllButton).getByText("Show all")).toBeVisible();
    expect(
      Array.from(showAllButton.querySelectorAll("[data-plugin-id]"), (element) =>
        element.getAttribute("data-plugin-id")
      )
    ).toEqual(expectedPreviewIds);

    await user.click(showAllButton);

    expect(
      screen.queryByRole("button", { name: "Show all Integrations plugins" })
    ).toBeNull();
    for (const plugin of plugins.slice(3)) {
      expect(
        screen.getByRole("button", { name: `View ${plugin.name} plugin details` })
      ).toBeVisible();
    }
  });

  it("localizes the catalog, detail actions, and dynamic accessibility copy", async () => {
    const user = setupUser();
    script.catalog = [notionPlugin, ...availablePlugins.slice(0, 5)];

    render(
      <CommaI18nProvider locale="zh-CN">
        <PluginsRoute />
      </CommaI18nProvider>
    );
    await flush();

    expect(screen.getByRole("heading", { name: "插件" })).toBeVisible();
    const searchInput = screen.getByRole("textbox", { name: "搜索插件" });
    expect(searchInput).toHaveAttribute("placeholder", "搜索插件…");
    expect(screen.getByRole("heading", { name: "已安装" })).toBeVisible();
    expect(screen.getAllByText("已安装")).toHaveLength(2);
    expect(screen.getByRole("heading", { name: "集成" })).toBeVisible();
    expect(screen.getByRole("button", { name: "查看 Notion 插件详情" })).toBeVisible();
    expect(screen.getByRole("button", { name: "添加 Linear" })).toBeVisible();

    const showAllButton = screen.getByRole("button", {
      name: "显示全部 集成 插件",
    });
    expect(showAllButton).toHaveTextContent("显示全部");

    await user.type(searchInput, "missing-plugin");
    expect(screen.getByText("未找到插件")).toBeVisible();
    await user.clear(searchInput);

    await user.click(screen.getByRole("button", { name: "查看 Notion 插件详情" }));

    expect(screen.getByRole("button", { name: "返回插件列表" })).toBeVisible();
    expect(screen.getByRole("heading", { name: "描述" })).toBeVisible();
    expect(screen.getByRole("heading", { name: "MCP" })).toBeVisible();
    expect(screen.getByRole("heading", { name: "技能" })).toBeVisible();
    expect(screen.getByRole("button", { name: "卸载 Notion" })).toBeVisible();
    expect(screen.getByRole("button", { name: "在聊天中试用 Notion" })).toBeVisible();

    await user.click(screen.getByRole("button", { name: "卸载 Notion" }));
    await flush();

    expect(
      screen.getByRole("button", { name: "将 Notion 添加到 Comma" })
    ).toBeVisible();
  });
});

const macSnapshot = (
  revision: number,
  enabled: readonly string[],
  requirements: Partial<Record<string, MacAppState["requirements"]>> = {}
): MacAppsSnapshot => ({
  revision,
  status: "ready",
  apps: macAppIds.map((id) => ({
    id,
    enabled: enabled.includes(id),
    tools: [{ name: `${id}_tool`, title: "Tool", readOnly: true, destructive: false }],
    requirements: requirements[id] ?? [],
  })),
  activity: [],
});

/** The workspace's Mac apps plugin as Salix lists it; the core keeps it off every list. */
const macAppsPlugin: CommaPlugin = {
  brand: null,
  category: "Mac",
  description: "Mac apps on your own Mac.",
  id: "mac-apps",
  installed: false,
  locked: false,
  mcps: [{ id: "mac", name: "Mac apps" }],
  name: "Mac apps",
  skills: [],
  summary: "Mac apps on your own Mac.",
};

const CALENDAR_ICON = "data:image/png;base64,Y2FsZW5kYXI=";

describe("PluginsRoute Mac apps", () => {
  /** This Mac: its app switches as Main keeps them, connected to the workspace as `dev_mac`. */
  function onMac(snapshot: MacAppsSnapshot, setEnabled: ReturnType<typeof vi.fn>) {
    const openPrivacySettings = vi.fn(async () => ({ opened: true }));
    installNativeBridgeMock({
      os: "macos",
      platform: "electron",
      macApps: {
        state: createNativeStateBridgeMock(() => snapshot),
        setEnabled,
        openPrivacySettings,
        icons: async () => ({ calendar: CALENDAR_ICON }),
      },
      connectorRuntime: {
        state: createNativeStateBridgeMock(() => ({
          revision: 1,
          scopes: [
            {
              workspaceId: WS,
              available: true,
              scope: "" as const,
              deviceId: "dev_mac",
            },
          ],
        })),
      },
    } as Parameters<typeof installNativeBridgeMock>[0]);
    return { openPrivacySettings };
  }

  beforeEach(() => {
    script = {
      catalog: [notionPlugin, linearPlugin, macAppsPlugin],
      activity: {},
      notices: [],
      skills: { status: "ready", skills },
      session: signedIn("user-1"),
    };
    answers = { "plugin.install": () => ({}) };
    core = scriptedCore();
  });

  it("lists the Mac apps as one plugin and installs it with this Mac", async () => {
    const setEnabled = vi.fn();
    onMac(macSnapshot(1, []), setEnabled);
    render(<PluginsRoute />);
    await flush();

    expect(screen.getByRole("heading", { name: "Mac" })).toBeVisible();
    expect(screen.queryByRole("switch")).toBeNull();
    await press(screen.getByRole("button", { name: "View Mac apps plugin details" }));

    // Before it is installed, the apps are listed without their switches.
    expect(screen.getByRole("heading", { name: "Apps" })).toBeVisible();
    expect(screen.getByText("Calendar")).toBeVisible();
    expect(screen.queryByRole("switch")).toBeNull();

    await press(screen.getByRole("button", { name: "Add to Comma Mac apps" }));
    expect(core.sentTo("plugin.install")).toEqual([
      { workspace: WS, plugin: "mac-apps", deviceId: "dev_mac" },
    ]);
    expect(setEnabled).not.toHaveBeenCalled();
  });

  it("turns apps on inside the installed plugin, and leaves them to this Mac when it is uninstalled", async () => {
    say({ catalog: [notionPlugin, installed(macAppsPlugin)] });
    const setEnabled = vi.fn(async ({ enabled }: { enabled: boolean }) => ({
      enabled,
      snapshot: macSnapshot(enabled ? 2 : 3, enabled ? ["calendar"] : []),
    }));
    onMac(macSnapshot(1, []), setEnabled);
    const { container } = render(<PluginsRoute />);
    await flush();

    await press(screen.getByRole("button", { name: "View Mac apps plugin details" }));
    // Each app shows the icon this Mac draws for it.
    expect(container.querySelector(`image[href="${CALENDAR_ICON}"]`)).not.toBeNull();
    const calendar = screen.getByRole("switch", { name: "Turn Calendar on or off" });
    expect(calendar).not.toBeChecked();

    await press(calendar);
    expect(setEnabled).toHaveBeenCalledWith({ app: "calendar", enabled: true });
    // Salix rediscovers the tools this Mac serves.
    expect(core.sentTo("plugin.install")).toEqual([
      { workspace: WS, plugin: "mac-apps", deviceId: "dev_mac" },
    ]);
    expect(
      screen.getByRole("switch", { name: "Turn Calendar on or off" })
    ).toBeChecked();

    await press(screen.getByRole("button", { name: "Uninstall Mac apps" }));
    expect(core.sentTo("plugin.uninstall")).toEqual([
      { workspace: WS, plugin: "mac-apps" },
    ]);
    // Another workspace on this Mac may still use them.
    expect(setEnabled).toHaveBeenCalledTimes(1);
  });

  it("keeps an app off that macOS denied, and opens System Settings for it", async () => {
    say({ catalog: [notionPlugin, installed(macAppsPlugin)] });
    const denied = macSnapshot(1, [], {
      calendar: [
        { requirement: "calendars", state: "denied", onEnable: true, tools: [] },
      ],
    });
    const setEnabled = vi.fn(async () => ({ enabled: false, snapshot: denied }));
    const { openPrivacySettings } = onMac(denied, setEnabled);
    render(<PluginsRoute />);
    await flush();
    await press(screen.getByRole("button", { name: "View Mac apps plugin details" }));

    await press(screen.getByRole("switch", { name: "Turn Calendar on or off" }));
    expect(
      screen.getByRole("switch", { name: "Turn Calendar on or off" })
    ).not.toBeChecked();

    expect(screen.getByText("Denied")).toBeVisible();
    await press(screen.getByRole("button", { name: "Open System Settings" }));
    expect(openPrivacySettings).toHaveBeenCalledWith({ requirement: "calendars" });
  });

  it("says so when macOS did not allow an app, also when it never prompted", async () => {
    say({ catalog: [notionPlugin, installed(macAppsPlugin)] });
    // macOS could not show its prompt: the permission is still undecided.
    const undecided = macSnapshot(1, [], {
      calendar: [
        {
          requirement: "calendars",
          state: "not_determined",
          onEnable: true,
          tools: [],
        },
      ],
    });
    const setEnabled = vi.fn(async () => ({ enabled: false, snapshot: undecided }));
    const { openPrivacySettings } = onMac(undecided, setEnabled);
    render(
      <>
        <Toaster />
        <PluginsRoute />
      </>
    );
    await flush();
    await press(screen.getByRole("button", { name: "View Mac apps plugin details" }));
    expect(screen.queryByText("Denied")).toBeNull();

    await press(screen.getByRole("switch", { name: "Turn Calendar on or off" }));
    expect(
      screen.getByRole("switch", { name: "Turn Calendar on or off" })
    ).not.toBeChecked();
    expect(
      screen.getByText(
        "macOS did not allow Calendar. Allow Comma in System Settings, then turn Calendar on again."
      )
    ).toBeVisible();
    expect(screen.getByText("Denied")).toBeVisible();
    await press(screen.getByRole("button", { name: "Open System Settings" }));
    expect(openPrivacySettings).toHaveBeenCalledWith({ requirement: "calendars" });
  });

  it("lists no Mac apps outside the Mac app", async () => {
    installNativeBridgeMock({ platform: "web" } as Parameters<
      typeof installNativeBridgeMock
    >[0]);
    render(<PluginsRoute />);
    await flush();
    expect(screen.queryByRole("heading", { name: "Mac" })).toBeNull();
    expect(screen.queryByText("Mac apps")).toBeNull();
  });
});
