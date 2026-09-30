import userEvent from "@testing-library/user-event";
import { CommaI18nProvider } from "@comma/i18n/react";
import {
  act,
  fireEvent,
  render as renderUI,
  screen,
  waitFor,
  within,
} from "@comma/test-utils/render";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { Toaster } from "@comma/ui";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { CommaApiClient, CommaPlugin } from "../api";
import type { ReactNode } from "react";
import { PluginInstallProvider } from "../components/plugins/PluginInstallProvider";
import { PluginsRoute } from "../components/plugins/PluginsRoute";
import { resetWorkspaceSkillsCacheForTest } from "../components/chat/useWorkspaceSkills";

const harness = vi.hoisted(() => {
  const getWorkspaceSkill = vi.fn();
  const getWorkspaceSkillFile = vi.fn();
  const getPluginPersonalSources = vi.fn();
  const preparePluginAccountConfirmation = vi.fn();
  const confirmPluginAccount = vi.fn();
  const cancelPluginOperation = vi.fn();
  const reauthorizeWorkspacePlugin = vi.fn();
  const installWorkspacePlugin = vi.fn();
  const listWorkspacePlugins = vi.fn();
  const listWorkspaceSkills = vi.fn();
  const listWorkspaces = vi.fn();
  const uninstallWorkspacePlugin = vi.fn();

  return {
    api: {
      getWorkspaceSkill,
      getWorkspaceSkillFile,
      getPluginPersonalSources,
      preparePluginAccountConfirmation,
      confirmPluginAccount,
      cancelPluginOperation,
      reauthorizeWorkspacePlugin,
      installWorkspacePlugin,
      listWorkspacePlugins,
      listWorkspaceSkills,
      listWorkspaces,
      uninstallWorkspacePlugin,
    },
    getWorkspaceSkill,
    getWorkspaceSkillFile,
    getPluginPersonalSources,
    preparePluginAccountConfirmation,
    confirmPluginAccount,
    cancelPluginOperation,
    reauthorizeWorkspacePlugin,
    installWorkspacePlugin,
    listWorkspacePlugins,
    listWorkspaceSkills,
    listWorkspaces,
    navigate: vi.fn(),
    openNativePlatformExternalUrl: vi.fn(),
    uninstallWorkspacePlugin,
  };
});

vi.mock("@tanstack/react-router", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@tanstack/react-router")>()),
  useNavigate: () => harness.navigate,
}));

vi.mock("../runtime-chat/nativePlatformActions", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../runtime-chat/nativePlatformActions")>()),
  openNativePlatformExternalUrl: harness.openNativePlatformExternalUrl,
}));

vi.mock("../components/chat/ChatProvider", () => ({
  useChatApi: () => harness.api,
}));

function render(ui: ReactNode) {
  return renderUI(
    <PluginInstallProvider api={harness.api as unknown as CommaApiClient}>
      {ui}
    </PluginInstallProvider>
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

describe("PluginsRoute", () => {
  beforeEach(() => {
    localStorage.clear();
    harness.installWorkspacePlugin.mockReset();
    harness.getPluginPersonalSources.mockReset();
    harness.getPluginPersonalSources.mockResolvedValue({
      pluginId: "notion",
      sources: [],
    });
    harness.preparePluginAccountConfirmation.mockReset();
    harness.confirmPluginAccount.mockReset();
    harness.cancelPluginOperation.mockReset();
    harness.reauthorizeWorkspacePlugin.mockReset();
    harness.listWorkspacePlugins.mockReset();
    harness.listWorkspaces.mockReset();
    harness.navigate.mockReset();
    harness.uninstallWorkspacePlugin.mockReset();
    harness.listWorkspaces.mockResolvedValue([
      { id: "wsp_1", name: "Main", status: "ready" },
    ]);
    harness.listWorkspacePlugins.mockResolvedValue([notionPlugin, linearPlugin]);
    resetWorkspaceSkillsCacheForTest();
    harness.listWorkspaceSkills.mockReset();
    harness.listWorkspaceSkills.mockResolvedValue([
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
    ]);
    harness.getWorkspaceSkill.mockReset();
    harness.getWorkspaceSkill.mockResolvedValue({
      content:
        "---\nname: weekly-report\ndescription: Draft a weekly report\n---\n\n# Reporting steps\n\nCollect finished tasks.",
      description: "Draft a weekly report",
      files: ["SKILL.md", "references/format.md"],
      location: "skills/report/SKILL.md",
      name: "weekly-report",
      skill_id: "weekly-report",
      source: "system",
    });
    harness.getWorkspaceSkillFile.mockReset();
    harness.getWorkspaceSkillFile.mockResolvedValue({
      content: "# Report format\n\nOne section per project.",
      path: "references/format.md",
    });
    harness.installWorkspacePlugin.mockResolvedValue({
      authorization: null,
      plugin: { ...linearPlugin, installed: true },
    });
    harness.openNativePlatformExternalUrl.mockReset();
    harness.openNativePlatformExternalUrl.mockResolvedValue(undefined);
    harness.uninstallWorkspacePlugin.mockResolvedValue({
      ...notionPlugin,
      installed: false,
    });
  });

  afterEach(() => {
    vi.useRealTimers();
    localStorage.clear();
    Reflect.deleteProperty(globalThis, "commaNative");
  });

  it("reports loading until the plugin catalog is ready", async () => {
    const catalog = Promise.withResolvers<CommaPlugin[]>();
    harness.listWorkspacePlugins.mockReturnValueOnce(catalog.promise);
    render(<PluginsRoute />);

    const loading = screen.getByRole("status");
    expect(loading).toHaveAccessibleName("Loading…");
    expect(loading).toHaveAttribute("aria-busy", "true");

    await act(async () => catalog.resolve([notionPlugin, linearPlugin]));
    expect(await screen.findByRole("heading", { name: "Installed" })).toBeVisible();
    expect(loading).not.toBeInTheDocument();
  });

  it("releases a stalled first request and ignores its late success after retry", async () => {
    vi.useFakeTimers();
    const first = Promise.withResolvers<unknown>();
    harness.installWorkspacePlugin.mockReturnValueOnce(first.promise);
    render(
      <>
        <PluginsRoute />
        <Toaster />
      </>
    );
    await act(async () => Promise.resolve());
    fireEvent.click(screen.getByRole("button", { name: "Add Linear" }));
    await act(async () => vi.advanceTimersByTimeAsync(30_000));
    await act(async () => vi.advanceTimersByTimeAsync(100));
    expect(screen.getByRole("button", { name: "Add Linear" })).not.toBeDisabled();
    expect(harness.installWorkspacePlugin.mock.calls[0]?.[2]?.signal.aborted).toBe(
      true
    );
    expect(
      screen.getByText("The connection request timed out. Try adding the plugin again.")
    ).toBeVisible();
    await act(async () =>
      first.resolve({
        authorization: null,
        plugin: { ...linearPlugin, installed: true },
      })
    );
    expect(harness.navigate).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "Add Linear" }));
    await act(async () => Promise.resolve());
    // The confirmed retry stays in Plugins and shows the plugin as added.
    expect(screen.queryByRole("button", { name: "Add Linear" })).toBeNull();
    expect(harness.navigate).not.toHaveBeenCalled();
  });

  it("continues authorization while Plugins is unmounted and completes after returning", async () => {
    vi.useFakeTimers();
    harness.installWorkspacePlugin
      .mockResolvedValueOnce({
        authorization: {
          state: "route-state",
          authorizationUrl: "https://linear.app/oauth",
        },
        plugin: linearPlugin,
      })
      .mockResolvedValueOnce({
        authorization: { state: "route-state" },
        plugin: linearPlugin,
      })
      .mockResolvedValueOnce({
        authorization: null,
        plugin: { ...linearPlugin, installed: true },
      });
    const view = (show: boolean) => (
      <PluginInstallProvider api={harness.api as unknown as CommaApiClient}>
        {show ? <PluginsRoute /> : <div>Home</div>}
      </PluginInstallProvider>
    );
    const page = renderUI(view(true));
    await act(async () => Promise.resolve());
    fireEvent.click(screen.getByRole("button", { name: "Add Linear" }));
    await act(async () => Promise.resolve());
    page.rerender(view(false));
    await act(async () => vi.advanceTimersByTimeAsync(2_000));
    expect(harness.installWorkspacePlugin).toHaveBeenCalledTimes(2);
    page.rerender(view(true));
    await act(async () => Promise.resolve());
    await act(async () => vi.advanceTimersByTimeAsync(2_000));
    expect(harness.installWorkspacePlugin).toHaveBeenCalledTimes(3);
    expect(harness.openNativePlatformExternalUrl).toHaveBeenCalledTimes(1);
    expect(screen.queryByRole("button", { name: "Add Linear" })).toBeNull();
    expect(harness.navigate).not.toHaveBeenCalled();
  });

  it("cancels the old account's request when its session ends", async () => {
    vi.useFakeTimers();
    const session = new AbortController();
    const first = Promise.withResolvers<unknown>();
    harness.installWorkspacePlugin.mockReturnValueOnce(first.promise);
    renderUI(
      <PluginInstallProvider
        api={harness.api as unknown as CommaApiClient}
        sessionSignal={session.signal}
      >
        <PluginsRoute />
      </PluginInstallProvider>
    );
    await act(async () => Promise.resolve());
    fireEvent.click(screen.getByRole("button", { name: "Add Linear" }));
    await act(async () => session.abort());
    await act(async () =>
      first.resolve({
        authorization: null,
        plugin: { ...linearPlugin, installed: true },
      })
    );
    expect(harness.installWorkspacePlugin.mock.calls[0]?.[2]?.signal.aborted).toBe(
      true
    );
    expect(harness.navigate).not.toHaveBeenCalled();
    expect(harness.openNativePlatformExternalUrl).not.toHaveBeenCalled();
  });

  it("keeps a plugin uninstalled until its install authorization completes", async () => {
    const user = userEvent.setup();
    const firstInstall = Promise.withResolvers<{
      authorization: { authorizationUrl: string; state: string };
      plugin: CommaPlugin;
    }>();
    harness.installWorkspacePlugin
      .mockReturnValueOnce(firstInstall.promise)
      .mockResolvedValueOnce({
        authorization: null,
        plugin: { ...linearPlugin, installed: true },
      });
    render(<PluginsRoute />);

    expect(await screen.findByRole("heading", { name: "Plugins" })).toBeVisible();
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

    expect(screen.getByRole("button", { name: "Add Linear" })).toBeDisabled();
    expect(
      screen.getByRole("button", { name: "Add Linear" }).querySelector(".animate-spin")
    ).not.toBeNull();
    firstInstall.resolve({
      authorization: {
        authorizationUrl: "https://linear.app/oauth/authorize?state=state-1",
        state: "state-1",
      },
      plugin: linearPlugin,
    });

    await waitFor(() =>
      expect(harness.installWorkspacePlugin).toHaveBeenCalledWith("wsp_1", "linear", {
        signal: expect.any(AbortSignal),
      })
    );
    expect(harness.openNativePlatformExternalUrl).toHaveBeenCalledWith(
      "https://linear.app/oauth/authorize?state=state-1"
    );
    await waitFor(() =>
      expect(screen.getByRole("button", { name: "Add Linear" })).not.toBeDisabled()
    );

    window.dispatchEvent(new Event("focus"));

    await waitFor(() =>
      expect(screen.queryByRole("button", { name: "Add Linear" })).toBeNull()
    );
    expect(harness.installWorkspacePlugin).toHaveBeenNthCalledWith(
      2,
      "wsp_1",
      "linear",
      {
        authorizationState: "state-1",
        verifyOnly: true,
        signal: expect.any(AbortSignal),
      }
    );
    expect(harness.openNativePlatformExternalUrl).toHaveBeenCalledTimes(1);
    expect(harness.navigate).not.toHaveBeenCalled();
    expect(
      screen.getByRole("button", { name: "View Linear plugin details" })
    ).toBeVisible();
  });

  it("retries pending authorization without focus or reopening the browser", async () => {
    const user = userEvent.setup();
    harness.installWorkspacePlugin
      .mockResolvedValueOnce({
        authorization: {
          authorizationUrl: "https://linear.app/oauth",
          state: "pending-state",
        },
        plugin: linearPlugin,
      })
      .mockResolvedValueOnce({
        authorization: { state: "pending-state" },
        plugin: linearPlugin,
      })
      .mockResolvedValueOnce({
        authorization: null,
        plugin: { ...linearPlugin, installed: true },
      });
    render(<PluginsRoute />);
    await user.click(await screen.findByRole("button", { name: "Add Linear" }));
    await waitFor(
      () => expect(screen.queryByRole("button", { name: "Add Linear" })).toBeNull(),
      { timeout: 6_000 }
    );
    expect(harness.installWorkspacePlugin).toHaveBeenCalledTimes(3);
    expect(harness.installWorkspacePlugin).toHaveBeenNthCalledWith(
      3,
      "wsp_1",
      "linear",
      {
        authorizationState: "pending-state",
        verifyOnly: true,
        signal: expect.any(AbortSignal),
      }
    );
    expect(harness.openNativePlatformExternalUrl).toHaveBeenCalledTimes(1);
  }, 8_000);

  it("stops automatic verification after two minutes", async () => {
    vi.useFakeTimers();
    harness.installWorkspacePlugin
      .mockResolvedValueOnce({
        authorization: {
          authorizationUrl: "https://linear.app/oauth",
          state: "pending-state",
        },
        plugin: linearPlugin,
      })
      .mockResolvedValue({
        authorization: { state: "pending-state" },
        plugin: linearPlugin,
      });
    render(<PluginsRoute />);
    await act(async () => Promise.resolve());
    fireEvent.click(screen.getByRole("button", { name: "Add Linear" }));
    await act(async () => Promise.resolve());
    for (let check = 0; check < 61; check += 1) {
      await act(async () => vi.advanceTimersByTimeAsync(2_000));
    }
    const calls = harness.installWorkspacePlugin.mock.calls.length;
    expect(calls).toBeGreaterThan(1);
    expect(calls).toBeLessThanOrEqual(61);
    await act(async () => vi.advanceTimersByTimeAsync(120_000));
    expect(harness.installWorkspacePlugin).toHaveBeenCalledTimes(calls);
    expect(harness.openNativePlatformExternalUrl).toHaveBeenCalledTimes(1);
    expect(screen.getByRole("button", { name: "Add Linear" })).not.toBeDisabled();
  });

  it("releases a hanging verification at the deadline and ignores its late success", async () => {
    vi.useFakeTimers();
    let finishVerification!: (value: unknown) => void;
    let finishNewAttempt!: (value: unknown) => void;
    harness.installWorkspacePlugin
      .mockResolvedValueOnce({
        authorization: { state: "pending-state" },
        plugin: linearPlugin,
      })
      .mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            finishVerification = resolve;
          })
      )
      .mockImplementation(() => new Promise(() => {}));
    render(<PluginsRoute />);
    await act(async () => Promise.resolve());
    fireEvent.click(screen.getByRole("button", { name: "Add Linear" }));
    await act(async () => Promise.resolve());
    await act(async () => vi.advanceTimersByTimeAsync(2_000));
    expect(screen.getByRole("button", { name: "Add Linear" })).toBeDisabled();
    await act(async () => vi.advanceTimersByTimeAsync(118_000));
    expect(screen.getByRole("button", { name: "Add Linear" })).not.toBeDisabled();
    harness.installWorkspacePlugin.mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          finishNewAttempt = resolve;
        })
    );
    fireEvent.click(screen.getByRole("button", { name: "Add Linear" }));
    await act(async () => Promise.resolve());
    await act(async () =>
      finishVerification({
        authorization: null,
        plugin: { ...linearPlugin, installed: true },
      })
    );
    expect(screen.getByRole("button", { name: "Add Linear" })).toBeDisabled();
    await act(async () =>
      finishNewAttempt({
        authorization: null,
        plugin: linearPlugin,
      })
    );
    expect(screen.getByRole("button", { name: "Add Linear" })).not.toBeDisabled();
  });

  it("retains the attempt after a transient verification failure", async () => {
    const user = userEvent.setup();
    harness.installWorkspacePlugin
      .mockResolvedValueOnce({
        authorization: {
          authorizationUrl: "https://linear.app/oauth",
          state: "pending-state",
        },
        plugin: linearPlugin,
      })
      .mockRejectedValueOnce(new Error("provider unavailable"))
      .mockResolvedValueOnce({
        authorization: null,
        plugin: { ...linearPlugin, installed: true },
      });
    render(<PluginsRoute />);
    await user.click(await screen.findByRole("button", { name: "Add Linear" }));
    await waitFor(() =>
      expect(harness.openNativePlatformExternalUrl).toHaveBeenCalledTimes(1)
    );
    window.dispatchEvent(new Event("focus"));
    await waitFor(() =>
      expect(harness.installWorkspacePlugin).toHaveBeenCalledTimes(2)
    );
    await waitFor(
      () => expect(screen.queryByRole("button", { name: "Add Linear" })).toBeNull(),
      { timeout: 4_000 }
    );
    expect(harness.openNativePlatformExternalUrl).toHaveBeenCalledTimes(1);
  });

  it("treats closing an unfinished authorization page as cancellation", async () => {
    const user = userEvent.setup();
    harness.installWorkspacePlugin
      .mockResolvedValueOnce({
        authorization: {
          authorizationUrl: "https://linear.app/oauth/authorize?state=state-1",
          state: "state-1",
        },
        plugin: linearPlugin,
      })
      .mockResolvedValueOnce({ authorization: null, plugin: linearPlugin });
    render(<PluginsRoute />);

    await user.click(await screen.findByRole("button", { name: "Add Linear" }));
    await waitFor(() =>
      expect(harness.openNativePlatformExternalUrl).toHaveBeenCalledTimes(1)
    );
    await waitFor(() =>
      expect(screen.getByRole("button", { name: "Add Linear" })).not.toBeDisabled()
    );

    window.dispatchEvent(new Event("focus"));

    await waitFor(() =>
      expect(harness.installWorkspacePlugin).toHaveBeenCalledTimes(2)
    );
    expect(harness.installWorkspacePlugin).toHaveBeenNthCalledWith(
      2,
      "wsp_1",
      "linear",
      {
        authorizationState: "state-1",
        verifyOnly: true,
        signal: expect.any(AbortSignal),
      }
    );
    expect(harness.openNativePlatformExternalUrl).toHaveBeenCalledTimes(1);
    expect(screen.getByRole("button", { name: "Add Linear" })).toBeVisible();

    window.dispatchEvent(new Event("focus"));
    await new Promise((resolve) => window.setTimeout(resolve, 0));
    expect(harness.installWorkspacePlugin).toHaveBeenCalledTimes(2);
    expect(harness.openNativePlatformExternalUrl).toHaveBeenCalledTimes(1);
  });

  it("opens the next authorization after a completed partial install", async () => {
    const user = userEvent.setup();
    harness.installWorkspacePlugin
      .mockResolvedValueOnce({
        authorization: {
          authorizationUrl: "https://accounts.google.com/gmail?state=gmail-state",
          state: "gmail-state",
        },
        plugin: {
          ...linearPlugin,
          brand: "google",
          id: "google",
          name: "Google",
        },
      })
      .mockResolvedValueOnce({
        authorization: {
          authorizationUrl: "https://accounts.google.com/calendar?state=calendar-state",
          state: "calendar-state",
        },
        plugin: {
          ...linearPlugin,
          brand: "google",
          id: "google",
          name: "Google",
        },
      })
      .mockResolvedValueOnce({
        authorization: null,
        plugin: {
          ...linearPlugin,
          brand: "google",
          id: "google",
          installed: true,
          name: "Google",
        },
      });
    harness.listWorkspacePlugins.mockResolvedValue([
      { ...linearPlugin, brand: "google", id: "google", name: "Google" },
    ]);
    render(<PluginsRoute />);

    await user.click(await screen.findByRole("button", { name: "Add Google" }));
    await waitFor(() =>
      expect(harness.openNativePlatformExternalUrl).toHaveBeenCalledWith(
        "https://accounts.google.com/gmail?state=gmail-state"
      )
    );

    window.dispatchEvent(new Event("focus"));
    await waitFor(() =>
      expect(harness.openNativePlatformExternalUrl).toHaveBeenCalledWith(
        "https://accounts.google.com/calendar?state=calendar-state"
      )
    );
    expect(harness.installWorkspacePlugin).toHaveBeenNthCalledWith(
      2,
      "wsp_1",
      "google",
      {
        authorizationState: "gmail-state",
        verifyOnly: true,
        signal: expect.any(AbortSignal),
      }
    );

    await waitFor(() =>
      expect(screen.getByRole("button", { name: "Add Google" })).not.toBeDisabled()
    );

    window.dispatchEvent(new Event("focus"));
    await waitFor(() =>
      expect(harness.installWorkspacePlugin).toHaveBeenCalledTimes(3)
    );
    await waitFor(() =>
      expect(screen.queryByRole("button", { name: "Add Google" })).toBeNull()
    );
    expect(harness.installWorkspacePlugin).toHaveBeenNthCalledWith(
      3,
      "wsp_1",
      "google",
      {
        authorizationState: "calendar-state",
        verifyOnly: true,
        signal: expect.any(AbortSignal),
      }
    );
    expect(harness.openNativePlatformExternalUrl).toHaveBeenCalledTimes(2);
  });

  it("uses the supplied Google artwork throughout the plugin catalog and detail", async () => {
    const name = "Google";
    const logo = "google";
    const user = userEvent.setup();
    harness.listWorkspacePlugins.mockResolvedValue([
      { ...notionPlugin, id: "feishu", brand: "feishu", name: "Feishu" },
      notionPlugin,
      ...availablePlugins,
    ]);

    const { container } = render(<PluginsRoute />);
    expect(await screen.findByRole("heading", { name: "Plugins" })).toBeVisible();

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
    expect(
      container.querySelector(
        `[data-slot="plugin-detail"] [data-provider-logo="${logo}"]`
      )
    ).toBeInTheDocument();
  });

  it("keeps unreleased Feishu out of catalog browsing and search", async () => {
    const user = userEvent.setup();
    harness.listWorkspacePlugins.mockResolvedValue([
      { ...notionPlugin, id: "feishu", brand: "feishu", name: "Feishu" },
      ...availablePlugins,
    ]);
    render(<PluginsRoute />);
    await user.click(
      await screen.findByRole("button", { name: "Show all Integrations plugins" })
    );
    expect(
      screen.getByRole("button", { name: "View Google plugin details" })
    ).toBeVisible();
    expect(
      screen.queryByRole("button", { name: "View Feishu plugin details" })
    ).toBeNull();
    await user.type(screen.getByRole("textbox", { name: "Search plugins" }), "Feishu");
    expect(screen.getByText("No plugins found")).toBeVisible();
    expect(harness.installWorkspacePlugin).not.toHaveBeenCalled();
  });

  it("shows a skill loading state instead of an empty catalog", async () => {
    const user = userEvent.setup();
    harness.listWorkspaceSkills.mockReturnValue(new Promise(() => {}));
    render(<PluginsRoute />);
    await user.click(await screen.findByRole("tab", { name: "Skills" }));
    expect(screen.queryByText("No skills found")).toBeNull();
    expect(screen.getByRole("status", { name: "Loading…" })).toHaveAttribute(
      "aria-busy",
      "true"
    );
  });

  it("retries failed skill loads without poisoning the catalog cache", async () => {
    const user = userEvent.setup();
    harness.listWorkspaceSkills.mockRejectedValueOnce(new Error("503 unavailable"));
    render(<PluginsRoute />);
    await user.click(await screen.findByRole("tab", { name: "Skills" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Couldn’t load skills.");
    expect(screen.queryByText("No skills found")).toBeNull();
    await user.click(screen.getByRole("tab", { name: "Plugins" }));
    expect(screen.queryByRole("alert")).toBeNull();
    expect(screen.getByText("Notion")).toBeVisible();
    await user.click(screen.getByRole("tab", { name: "Skills" }));
    await user.click(screen.getByRole("button", { name: "Retry" }));
    expect(await screen.findByText("summarize")).toBeVisible();
    expect(harness.listWorkspaceSkills).toHaveBeenCalledTimes(2);
    expect(screen.queryByRole("alert")).toBeNull();
  });

  it("refetches immediately after reopening a failed skill catalog", async () => {
    const user = userEvent.setup();
    harness.listWorkspaceSkills.mockRejectedValueOnce(new Error("503 unavailable"));
    const first = render(<PluginsRoute />);
    await user.click(await screen.findByRole("tab", { name: "Skills" }));
    await screen.findByRole("alert");
    first.unmount();
    render(<PluginsRoute />);
    await user.click(await screen.findByRole("tab", { name: "Skills" }));
    expect(await screen.findByText("summarize")).toBeVisible();
    expect(harness.listWorkspaceSkills).toHaveBeenCalledTimes(2);
  });

  it("shows the empty skill state only after a successful empty response", async () => {
    const user = userEvent.setup();
    harness.listWorkspaceSkills.mockResolvedValue([]);
    render(<PluginsRoute />);
    await user.click(await screen.findByRole("tab", { name: "Skills" }));
    expect(await screen.findByText("No skills found")).toBeVisible();
    expect(screen.queryByRole("alert")).toBeNull();
    expect(screen.queryByRole("button", { name: "Retry" })).toBeNull();
  });

  it("lists, categorizes, and searches workspace skills on the Skills tab", async () => {
    const user = userEvent.setup();
    render(<PluginsRoute />);

    await user.click(await screen.findByRole("tab", { name: "Skills" }));

    expect(harness.listWorkspaceSkills).toHaveBeenCalledWith("wsp_1");
    expect(screen.getByRole("heading", { level: 1, name: "Skills" })).toBeVisible();
    expect(await screen.findByText("summarize")).toBeVisible();
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
    const user = userEvent.setup();
    const { container } = render(<PluginsRoute />);

    await user.click(await screen.findByRole("tab", { name: "Skills" }));
    await user.click(await screen.findByRole("button", { name: "System" }));
    await user.click(
      screen.getByRole("button", { name: "View weekly-report skill details" })
    );

    expect(harness.getWorkspaceSkill).toHaveBeenCalledWith(
      "wsp_1",
      "weekly-report",
      expect.anything()
    );
    expect(
      screen.getByRole("heading", { level: 1, name: "weekly-report" })
    ).toBeVisible();
    expect(await screen.findByText("Reporting steps")).toBeVisible();
    const fileContent = container.querySelector('[data-slot="skill-file-content"]');
    expect(fileContent).not.toHaveTextContent("name: weekly-report");

    // Source view shows the raw file, front matter included.
    await user.click(screen.getByRole("button", { name: "Source" }));
    expect(fileContent).toHaveTextContent("name: weekly-report");
    expect(fileContent).toHaveTextContent("# Reporting steps");

    // A reference file loads on demand and keeps the chosen view.
    await user.click(screen.getByRole("button", { name: "format.md" }));
    expect(harness.getWorkspaceSkillFile).toHaveBeenCalledWith(
      "wsp_1",
      "weekly-report",
      "references/format.md",
      expect.anything()
    );
    // Highlighting splits a source line into token spans, so read the line as text.
    await waitFor(() => expect(fileContent).toHaveTextContent("# Report format"));
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
    const user = userEvent.setup();
    render(<PluginsRoute />);

    await user.click(await screen.findByRole("tab", { name: "Skills" }));
    await user.click(await screen.findByRole("button", { name: "System" }));
    await user.click(
      screen.getByRole("button", { name: "View weekly-report skill details" })
    );
    await screen.findByText("Reporting steps");

    await user.click(screen.getByRole("button", { name: "Skill actions" }));
    await user.click(await screen.findByRole("menuitem", { name: "Open" }));
    await waitFor(() => expect(openDownload).toHaveBeenCalledWith({ downloadRef }));
    expect(saveDownload).toHaveBeenCalledWith(
      expect.objectContaining({ fileName: "weekly-report.md" })
    );

    await user.click(screen.getByRole("button", { name: "Skill actions" }));
    await user.click(await screen.findByRole("menuitem", { name: "Reveal in Finder" }));
    await waitFor(() => expect(revealDownload).toHaveBeenCalledWith({ downloadRef }));
    // The second action reuses the copy the first one placed in Downloads.
    expect(saveDownload).toHaveBeenCalledTimes(1);

    await user.click(screen.getByRole("button", { name: "Skill actions" }));
    await user.click(await screen.findByRole("menuitem", { name: "Copy Markdown" }));
    await waitFor(() =>
      expect(writeText).toHaveBeenCalledWith({
        text: expect.stringContaining("# Reporting steps"),
      })
    );
  });

  it("opens an installed plugin detail and uninstalls it", async () => {
    const user = userEvent.setup();
    const { container } = render(<PluginsRoute />);

    await screen.findByRole("heading", { name: "Plugins" });
    expect(container.querySelector('[data-slot="plugin-catalog"]')).toHaveClass(
      "comma-plugins-route"
    );

    await user.click(
      await screen.findByRole("button", { name: "View Notion plugin details" })
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

    await waitFor(() =>
      expect(harness.uninstallWorkspacePlugin).toHaveBeenCalledWith("wsp_1", "notion")
    );
    expect(
      await screen.findByRole("button", { name: "Add to Comma Notion" })
    ).toBeVisible();

    await user.click(screen.getByRole("button", { name: "Back to plugins" }));
    expect(screen.getByRole("heading", { name: "Plugins" })).toBeVisible();
  });

  it("does not expose a separate connection action for an installed plugin", async () => {
    const user = userEvent.setup();
    const githubPlugin: CommaPlugin = {
      ...linearPlugin,
      brand: "github",
      id: "github",
      installed: true,
      mcps: [{ id: "github-mcp", name: "github" }],
      name: "GitHub",
    };
    harness.listWorkspacePlugins.mockResolvedValue([githubPlugin]);

    render(<PluginsRoute />);
    await user.click(
      await screen.findByRole("button", { name: "View GitHub plugin details" })
    );

    expect(screen.queryByRole("button", { name: "Connect" })).toBeNull();
    expect(screen.getByRole("button", { name: "Uninstall GitHub" })).toBeVisible();
  });

  it("shows a retryable error when the catalog request fails", async () => {
    const user = userEvent.setup();
    harness.listWorkspacePlugins.mockRejectedValueOnce(new Error("offline"));
    render(
      <>
        <Toaster />
        <PluginsRoute />
      </>
    );

    const errorToast = await screen.findByTestId("plugins-load-error");
    expect(errorToast).toHaveTextContent("Couldn’t load plugins.");
    expect(errorToast).toHaveTextContent("offline");
    await user.click(
      within(errorToast).getByRole("button", { name: "Dismiss notification" })
    );
    await waitFor(() => expect(screen.queryByTestId("plugins-load-error")).toBeNull());

    // Dismissing transient feedback must not remove the only recovery path.
    await user.click(screen.getByRole("button", { name: "Retry" }));

    expect(await screen.findByRole("heading", { name: "Plugins" })).toBeVisible();
    expect(harness.listWorkspacePlugins).toHaveBeenCalledTimes(2);
  });

  it("shows one remaining plugin directly without Show all", async () => {
    const plugins = availablePlugins.slice(0, 4);
    harness.listWorkspacePlugins.mockResolvedValue([notionPlugin, ...plugins]);

    render(<PluginsRoute />);

    expect(await screen.findByRole("heading", { name: "Integrations" })).toBeVisible();
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
    const user = userEvent.setup();
    const plugins = availablePlugins.slice(0, availableCount);
    harness.listWorkspacePlugins.mockResolvedValue([notionPlugin, ...plugins]);

    render(<PluginsRoute />);

    expect(await screen.findByRole("heading", { name: "Integrations" })).toBeVisible();
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
    const user = userEvent.setup();
    harness.listWorkspacePlugins.mockResolvedValue([
      notionPlugin,
      ...availablePlugins.slice(0, 5),
    ]);

    render(
      <CommaI18nProvider locale="zh-CN">
        <PluginsRoute />
      </CommaI18nProvider>
    );

    expect(await screen.findByRole("heading", { name: "插件" })).toBeVisible();
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

    expect(
      await screen.findByRole("button", { name: "将 Notion 添加到 Comma" })
    ).toBeVisible();
  });

  it("localizes the plugin route status region accessibility label", () => {
    harness.listWorkspaces.mockReturnValue(new Promise<never>(() => undefined));

    render(
      <CommaI18nProvider locale="zh-CN">
        <PluginsRoute />
      </CommaI18nProvider>
    );

    expect(screen.getByRole("region", { name: "插件" })).toContainElement(
      screen.getByRole("status", { name: "加载中…" })
    );
  });
});
