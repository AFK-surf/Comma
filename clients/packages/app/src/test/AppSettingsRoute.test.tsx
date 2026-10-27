import userEvent from "@testing-library/user-event";
import type {
  ProfileValue,
  RecommendationsValue,
  TelegramIntegration,
  TelegramValue,
} from "@comma/core/contract";
import { initializeCommaI18n } from "@comma/i18n";
import {
  appPreferencesSchema,
  defaultAppPreferences,
  defaultCommaClientSettings,
  type AppPreferences,
  type AppPreferencesPatch,
  type NativeStateBridge,
} from "@comma/native-bridge";
import { advance, flush } from "@comma/test-utils/fake-clock";
import { act, render, screen, waitFor, within } from "@comma/test-utils/render";
import { createScriptedCore, resolvedWorkspace } from "@comma/test-utils/scripted-core";
import {
  createNativeStateBridgeMock,
  installNativeBridgeMock,
} from "@comma/test-utils/native-bridge";
import {
  APP_KEYBINDING_SEQUENCE_TIMEOUT_MS,
  detectAppKeybindingPlatform,
} from "@comma/ui/components/settings-shortcut";
import { toast } from "@comma/ui/components/toast";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { CommaApiSessionTransport } from "../session/controller";
import { AppSettingsRoute } from "../components/AppSettingsRoute";
import {
  CommaAuthContext,
  type CommaAuthContextValue,
} from "../components/auth-context";
import {
  CommaAppearanceProvider,
  defaultCommaAppearancePreferences,
} from "../components/commaAppearance";
import {
  CommaClientSettingsI18nProvider,
  CommaElectronClientSettingsProvider,
  CommaWebClientSettingsProvider,
  commaClientSettingsStorageKey,
} from "../components/commaClientSettings";
import { RouterIdentityProvider } from "../components/router-identity/RouterIdentityProvider";
import { CommaAppShortcutsProvider } from "../components/shortcuts/commaAppShortcuts";
import type { AppShortcutPlatform } from "../components/shortcuts/appShortcutRegistry";

const telegramSettings = () => within(screen.getByRole("region", { name: "Telegram" }));
const instructionsDialog = () => screen.getByRole("dialog", { name: "System prompt" });
// Closed once the dialog is gone and the page behind it answers again.
const instructionsClosed = () =>
  waitFor(() => {
    expect(screen.queryByRole("dialog", { name: "System prompt" })).toBeNull();
    setting("router.instructions").getByRole("button", { name: "Edit" });
  });

const testSessionTransport = (signal: AbortSignal): CommaApiSessionTransport => ({
  applyHeaders: () => undefined,
  credentials: "include",
  reportSessionRejection: () => undefined,
  signal,
});

const defaultAuth = (): CommaAuthContextValue => {
  const sessionController = new AbortController();
  const sessionTransport = testSessionTransport(sessionController.signal);

  return {
    apiBaseUrl: "https://api.example",
    authenticated: true,
    productLease: {
      audience: "https://api.example",
      authorityInstanceId: "test-authority",
      generation: 1,
      sessionId: "session-1",
    },
    sessionSignal: sessionController.signal,
    sessionTransport,
    signOut: vi.fn(),
    userDisplayName: "Ada",
    userEmail: "ada@example.com",
  };
};

type Scripted = ReturnType<typeof createScriptedCore>;

const renderSettings = (
  auth = defaultAuth(),
  appShortcutPlatform?: AppShortcutPlatform,
  core: Scripted = createScriptedCore()
) =>
  render(
    core.wrap(
      <CommaWebClientSettingsProvider>
        <CommaClientSettingsI18nProvider>
          <CommaAuthContext.Provider value={auth}>
            <RouterIdentityProvider>
              <CommaAppearanceProvider>
                <CommaAppShortcutsProvider
                  {...(appShortcutPlatform ? { platform: appShortcutPlatform } : {})}
                >
                  <AppSettingsRoute />
                </CommaAppShortcutsProvider>
              </CommaAppearanceProvider>
            </RouterIdentityProvider>
          </CommaAuthContext.Provider>
        </CommaClientSettingsI18nProvider>
      </CommaWebClientSettingsProvider>
    )
  );

const renderProfileSettings = (auth: CommaAuthContextValue, core: Scripted) =>
  renderSettings(auth, undefined, core);

// Only the Electron owner reports a client-settings write as pending; the web
// provider stores locally and is never in flight.
const renderElectronSettings = (auth = defaultAuth()) =>
  render(
    createScriptedCore().wrap(
      <CommaElectronClientSettingsProvider>
        <CommaClientSettingsI18nProvider>
          <CommaAuthContext.Provider value={auth}>
            <RouterIdentityProvider>
              <CommaAppearanceProvider>
                <CommaAppShortcutsProvider>
                  <AppSettingsRoute />
                </CommaAppShortcutsProvider>
              </CommaAppearanceProvider>
            </RouterIdentityProvider>
          </CommaAuthContext.Provider>
        </CommaClientSettingsI18nProvider>
      </CommaElectronClientSettingsProvider>
    )
  );

const readStoredClientSettings = () =>
  JSON.parse(localStorage.getItem(commaClientSettingsStorageKey)!);

/** Quick Chat's shortcut recorder in Keyboard shortcuts. */
const quickChatRecorder = () => screen.getByRole("button", { name: /^Quick Chat:/ });
/** A setting's row, by its id. */
const setting = (id: string) =>
  within(document.querySelector<HTMLElement>(`[data-setting-id="${id}"]`)!);
/** The options of the dropdown that is open. */
const dropdownOptions = () =>
  within(document.querySelector<HTMLElement>('[data-slot="dropdown-popover"]')!);

describe("AppSettingsRoute", () => {
  // Every test runs on the fake clock: a step that waits on time (a recorded key
  // sequence, the Notch width) moves it with `advance`.
  let user: ReturnType<typeof userEvent.setup>;
  beforeEach(() => {
    user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
    installNativeBridgeMock({ platform: "electron" });
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    initializeCommaI18n(["en"]);
    localStorage.clear();
  });

  it("persists Meeting controls with Reminder, visible recorder and Smart summary defaults", async () => {
    // The recorder's notch, and so its row, is the macOS app's.
    installNativeBridgeMock({ platform: "electron", os: "macos" });
    renderSettings();
    await user.click(screen.getByRole("button", { name: "Meeting" }));
    expect(screen.getByRole("button", { name: /^Reminder/ })).toBeInTheDocument();
    const hide = screen.getByRole("switch", { name: /Hide recorder notch/ });
    const summary = screen.getByRole("switch", { name: /Smart summary/ });
    expect(hide).not.toBeChecked();
    expect(summary).toBeChecked();
    await user.click(hide);
    await user.click(summary);
    await flush();
    expect(readStoredClientSettings()).toMatchObject({
      meetingStartRecording: "reminder",
      meetingHideRecorder: true,
      meetingSmartSummary: false,
    });
  });
  it("gates every Meeting control while a client-settings write is in flight", async () => {
    let preferences = appPreferencesSchema.parse({
      clientSettings: defaultCommaClientSettings,
      launchAtLogin: false,
      notificationSound: true,
      notifyRouterMessages: true,
      showInDock: true,
      showInMenuBar: true,
      systemNotifications: true,
    });
    let release: (() => void) | undefined;
    const inFlight = new Promise<void>((resolve) => {
      release = resolve;
    });
    const update = vi.fn(async (patch: AppPreferencesPatch) => {
      await inFlight;
      preferences = appPreferencesSchema.parse({
        ...preferences,
        ...patch,
        clientSettings: {
          ...(preferences.clientSettings ?? defaultCommaClientSettings),
          ...patch.clientSettings,
        },
        revision: preferences.revision + 1,
      });
      return preferences;
    });
    installNativeBridgeMock({
      appPreferences: {
        state: createNativeStateBridgeMock(() => preferences),
        update,
      },
      os: "macos",
      platform: "electron",
    });
    renderElectronSettings();
    await user.click(screen.getByRole("button", { name: "Meeting" }));

    const start = screen.getByRole("button", { name: /^Reminder/ });
    const hide = screen.getByRole("switch", { name: /Hide recorder notch/ });
    const summary = screen.getByRole("switch", { name: /Smart summary/ });
    await user.click(hide);

    // One write in flight gates the whole section, not just the control that
    // started it: the owner serialises client-settings writes.
    await flush();
    expect(hide).toBeDisabled();
    expect(summary).toBeDisabled();
    expect(start).toBeDisabled();

    release?.();
    await flush();
    expect(hide).toBeEnabled();
    expect(summary).toBeEnabled();
    expect(start).toBeEnabled();
  });
  it("lists Inbound API, Devices, Tailscale and Debug under Advanced, after Shared", async () => {
    renderSettings();
    await flush();

    const nav = screen.getAllByRole("navigation")[0]!;
    const groupLabels = Array.from(nav.querySelectorAll(":scope > div > p")).map(
      (label) => label.textContent
    );
    expect(groupLabels.slice(-3)).toEqual(["Archived", "Shared", "Advanced"]);
    const groupItems = (label: string) =>
      within(within(nav).getByText(label, { selector: "p" }).parentElement!)
        .getAllByRole("button")
        .map((button) => button.textContent);
    expect(groupItems("Advanced")).toEqual([
      "Inbound API",
      "Devices",
      "Tailscale",
      "Debug",
    ]);
    expect(groupItems("System")).not.toEqual(
      expect.arrayContaining(["Inbound API", "Devices", "Tailscale", "Debug"])
    );
  });

  it("opens the category named by the settings deep link", async () => {
    const previousHash = window.location.hash;
    window.location.hash = "#/settings?category=recommendations";
    try {
      renderSettings();

      // The Routines menu links here; Settings must land on Routines
      // rather than its default General category.
      await flush();
      expect(
        screen.getByRole("heading", { level: 2, name: "Daily schedule" })
      ).toBeInTheDocument();
    } finally {
      window.location.hash = previousHash;
    }
  });

  it("loads and saves recommendations against the workspace the app works in", async () => {
    const asked: Record<string, unknown>[] = [];
    const envelope: RecommendationsValue["envelope"] = {
      settings: {
        autoEnableNewSources: true,
        schedule: { enabled: true, hour: 8, minute: 0, timezone: "Etc/UTC" },
        sourcesCheckedAt: "2026-08-18T00:00:00Z",
        sourceRevision: 1,
        sources: [
          {
            appId: "github",
            appName: "GitHub",
            connectionId: "mpb-1",
            enabled: true,
            kind: "composio",
            label: "github",
          },
        ],
      },
      snapshot: null,
      state: "empty",
    };
    const core = createScriptedCore({
      values: (topic) => {
        if (topic.topic === "workspace") return resolvedWorkspace("ws-2");
        if (topic.topic !== "recommendations") return undefined;
        asked.push(topic);
        return {
          workspace: "ws-2",
          envelope,
          failure: null,
          discovering: false,
          refreshing: false,
        } satisfies RecommendationsValue;
      },
    });

    renderSettings(undefined, undefined, core);
    await user.click(screen.getByRole("button", { name: "Routines" }));
    await flush();
    // Settings asks the core for the briefing of the workspace the app works in.
    expect(asked.map(({ workspace }) => workspace)).toEqual(["ws-2"]);
    const source = screen.getByRole("switch", { name: "GitHub" });
    await user.click(source);

    await flush();
    // A source toggle writes that one flag beside the unchanged schedule; it
    // never echoes the whole source list or the read-only projection fields.
    expect(core.sentTo("recommendations.updateSettings")).toEqual([
      {
        workspace: "ws-2",
        patch: {
          autoEnableNewSources: true,
          schedule: { enabled: true, hour: 8, minute: 0, timezone: "Etc/UTC" },
          sources: [{ connectionId: "mpb-1", enabled: false }],
        },
      },
    ]);
  });

  it.each([0, 2])(
    "does not choose a Telegram target when the account has %i workspaces",
    async () => {
      // The core refuses to choose among none or several workspaces: it names none, and says it failed.
      const core = createScriptedCore({
        values: (topic): TelegramValue | undefined =>
          topic.topic === "telegram"
            ? {
                workspace: null,
                state: null,
                attempt: null,
                checks: 0,
                error: true,
                busy: false,
              }
            : undefined,
      });
      renderSettings(undefined, undefined, core);
      await user.click(screen.getByRole("button", { name: "Channels" }));
      await flush();
      expect(
        telegramSettings().getByRole("button", { name: "Connect" })
      ).toBeDisabled();
      expect(core.sentTo("telegram.connect")).toEqual([]);
      expect(screen.queryByText("Comma workspace")).not.toBeInTheDocument();
    }
  );

  it.each([false])(
    "shows a completed Telegram OIDC reconnect from active=%s without reloading Settings",
    async (active) => {
      const openExternal = vi.fn(async () => ({ ok: true as const }));
      installNativeBridgeMock({
        platform: "electron",
        shell: { openExternal },
      });
      const integration = (reconnected: boolean): TelegramIntegration => ({
        bot_url: "https://t.me/CommaTestBot",
        bot_username: "CommaTestBot",
        configured: true,
        connection_active: reconnected || active,
        link: {
          connected_at: reconnected ? 1_788_400_100 : 1_788_400_000,
          telegram_user_id: reconnected ? "525252" : "424242",
          telegram_username: reconnected ? "grace" : "ada",
          updated_at: reconnected ? 1_788_400_100 : 1_788_400_000,
        },
        official_login_available: true,
        workspace_id: "ws-1",
        workspace_name: "Main",
      });
      let telegram: TelegramValue = {
        workspace: "ws-1",
        state: integration(false),
        attempt: null,
        checks: 0,
        error: false,
        busy: false,
      };
      const core = createScriptedCore({
        values: (topic) => (topic.topic === "telegram" ? telegram : undefined),
        calls: (name) => {
          if (name !== "telegram.connect") return null;
          telegram = { ...telegram, attempt: "reconnect", busy: true };
          core.changed("telegram");
          return {
            authorizationUrl: "https://oauth.telegram.org/auth?state=reconnect",
          };
        },
      });
      renderSettings(undefined, undefined, core);
      await user.click(screen.getByRole("button", { name: "Channels" }));
      await flush();
      expect(screen.getByText("@ada")).toBeInTheDocument();
      expect(
        telegramSettings().getByText(active ? "Connected" : "Needs attention")
      ).toBeInTheDocument();
      const settingsSearch = screen.getByRole("searchbox", { name: "Search settings" });
      await user.click(settingsSearch);
      await user.paste("Disconnect");
      expect(
        document.querySelector('[data-slot="settings-search-results"]')
      ).toHaveTextContent("Telegram");
      await user.clear(settingsSearch);

      await user.click(telegramSettings().getByRole("button", { name: "Manage" }));
      await user.click(screen.getByRole("menuitem", { name: "Reconnect" }));
      expect(openExternal).not.toHaveBeenCalled();
      await user.click(screen.getByRole("button", { name: "Cancel" }));
      expect(openExternal).not.toHaveBeenCalled();
      await user.click(telegramSettings().getByRole("button", { name: "Manage" }));
      await user.click(screen.getByRole("menuitem", { name: "Reconnect" }));
      await user.click(screen.getByRole("button", { name: "Reconnect" }));
      await flush();
      expect(core.sentTo("telegram.connect")).toHaveLength(1);
      expect(openExternal).toHaveBeenCalledWith({
        url: "https://oauth.telegram.org/auth?state=reconnect",
      });
      // The core follows the login until the new link shows.
      telegram = { ...telegram, state: integration(true), attempt: null, busy: false };
      act(() => core.changed("telegram"));
      await flush();

      expect(screen.getByText("@grace")).toBeInTheDocument();
      expect(telegramSettings().getByRole("button", { name: "Manage" })).toBeEnabled();
      expect(telegramSettings().getByText("Connected")).toBeInTheDocument();
    }
  );

  it("closes the name dialog once a name is asked for, and says so when the server refuses it", async () => {
    const refused = vi.spyOn(toast, "error");
    const core = createScriptedCore({
      values: (topic): ProfileValue | undefined =>
        topic.topic === "profile"
          ? {
              status: "ready",
              profile: { email: "ada@example.com", id: "usr_ada", name: "Ada" },
            }
          : undefined,
      calls: (name) => {
        // The core shows the name at once and the saved one again; the view only hears the refusal.
        if (name === "profile.update") throw new Error("refused");
        return null;
      },
    });
    renderProfileSettings(defaultAuth(), core);
    await user.click(screen.getByRole("button", { name: "Profile" }));
    await flush();
    await user.click(screen.getByRole("button", { name: "Edit name: Ada" }));
    const input = screen.getByRole("textbox", { name: "Name" });
    await user.clear(input);
    await user.type(input, "Grace");
    await user.click(screen.getByRole("button", { name: "Save" }));
    expect(screen.queryByRole("textbox", { name: "Name" })).not.toBeInTheDocument();
    await flush();
    expect(core.sentTo("profile.update")).toEqual([{ name: "Grace" }]);
    expect(refused).toHaveBeenCalledWith(
      "Could not save your profile. Please try again."
    );
  });

  it("opens the crop dialog before uploading a chosen avatar", async () => {
    const inputClick = vi.spyOn(HTMLInputElement.prototype, "click");
    // The avatar image is read through the session's API, not the core.
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = new URL(input.toString(), "https://api.example");
        if (!url.pathname.startsWith("/v1/comma/me/avatar/"))
          throw new Error(`Unexpected request: ${url.pathname}`);
        return new Response("existing-avatar", {
          headers: { "content-type": "image/png" },
          status: 200,
        });
      })
    );
    const core = createScriptedCore({
      values: (topic): ProfileValue | undefined =>
        topic.topic === "profile"
          ? {
              status: "ready",
              profile: {
                avatar_id: "avt_existing",
                email: "ada@example.com",
                id: "usr_ada",
                name: "Ada",
              },
            }
          : undefined,
    });

    renderProfileSettings(defaultAuth(), core);

    await user.click(screen.getByRole("button", { name: "Profile" }));
    await flush();
    const avatarButton = screen.getByRole("button", {
      name: "Choose image",
    });
    expect(avatarButton.querySelector(".comma-user-avatar")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Remove" })).not.toBeInTheDocument();
    await user.click(avatarButton);
    expect(inputClick).toHaveBeenCalledOnce();

    await flush();
    const fileInput = screen.getByLabelText("Choose image", {
      selector: 'input[type="file"]',
    });
    // Files between the old 100 KB bound and 2 MB are now accepted.
    const avatar = new File([new Uint8Array(1024 * 1024)], "avatar.png", {
      type: "image/png",
    });
    await user.upload(fileInput, avatar);

    await flush();
    const cropDialog = screen.getByRole("dialog", { name: "Crop avatar" });
    expect(cropDialog).toBeInTheDocument();
    expect(core.sentTo("profile.uploadAvatar")).toEqual([]);

    await user.click(screen.getByRole("button", { name: /Cancel/ }));
    await flush();
    expect(
      screen.queryByRole("dialog", { name: "Crop avatar" })
    ).not.toBeInTheDocument();
    expect(core.sentTo("profile.uploadAvatar")).toEqual([]);
  });

  it("lists the themes in a menu aligned to the choice, and applies and stores Dark", async () => {
    renderSettings();

    await user.click(screen.getByRole("button", { name: "Appearance" }));
    const themeTrigger = screen.getByRole("button", { name: /Select theme/ });
    expect(themeTrigger).toHaveTextContent("Default");
    expect(themeTrigger.querySelector('[data-slot="theme-swatch"]')).not.toBeNull();
    await user.click(themeTrigger);
    expect(themeTrigger).toHaveClass("pointer-events-none", "opacity-0");
    expect(document.querySelector('[data-slot="dropdown-popover"]')).toHaveAttribute(
      "data-positioning",
      "selection-aligned"
    );
    expect(document.querySelector('[data-slot="dropdown-popover"]')).toHaveClass(
      "rounded-xl"
    );
    expect(document.querySelectorAll('[data-slot="dropdown-separator"]')).toHaveLength(
      3
    );
    const themes = dropdownOptions();
    expect(themes.getByRole("option", { name: "Default" })).toBeInTheDocument();
    expect(themes.getByRole("option", { name: "Soft Light" })).toBeInTheDocument();
    expect(themes.getByRole("option", { name: "Signal Light" })).toBeInTheDocument();
    expect(themes.queryByRole("option", { name: /^Light$/ })).not.toBeInTheDocument();
    expect(themes.queryByRole("option", { name: "Paper" })).not.toBeInTheDocument();
    expect(themes.queryByRole("option", { name: "Auto" })).not.toBeInTheDocument();
    expect(themes.queryByRole("option", { name: "Twilight" })).not.toBeInTheDocument();
    expect(themes.queryByRole("option", { name: "Ink" })).not.toBeInTheDocument();
    expect(themes.queryByRole("button", { name: "Edit" })).not.toBeInTheDocument();
    await user.click(themes.getByRole("option", { name: "Dark" }));
    expect(document.documentElement.dataset.theme).toBe("Dark mode");
    expect(themeTrigger).toHaveTextContent("Dark");
    // Stored, and restored by the appearance provider (commaAppearance.test.tsx).
    expect(readStoredClientSettings().appearance).toEqual({
      ...defaultCommaAppearancePreferences,
      theme: "dark",
    });
  });

  it("previews each installed font family in its own face, and applies, resets and stores one", async () => {
    // Main lists the installed families; Appearance reads them on entry.
    installNativeBridgeMock({
      appearance: {
        fontFamilies: vi.fn(async () => ({ families: ["Avenir Next", "Georgia"] })),
      },
      platform: "electron",
    });
    renderSettings();

    await user.click(screen.getByRole("button", { name: "Appearance" }));
    const fontTrigger = screen.getByRole("button", { name: /Select font$/ });
    expect(fontTrigger).toHaveTextContent("Default");
    await user.click(fontTrigger);
    // Each family previews its own face.
    await flush();
    expect(
      dropdownOptions()
        .getAllByRole("option")
        .map((option) => option.textContent)
    ).toEqual(["Default", "Avenir Next", "Georgia"]);
    expect(
      dropdownOptions()
        .getByRole("option", { name: "Georgia" })
        .querySelector<HTMLElement>('[data-slot="dropdown-option-label"]')?.style
        .fontFamily
    ).toMatch(/^"Georgia", /);
    await user.click(dropdownOptions().getByRole("option", { name: "Georgia" }));
    expect(document.documentElement.dataset.commaFontFamily).toBe("Georgia");
    expect(document.documentElement.style.getPropertyValue("--font-sans")).toMatch(
      /^"Georgia", 'Inter Variable'/
    );
    await user.click(fontTrigger);
    await user.click(dropdownOptions().getByRole("option", { name: "Default" }));
    expect(document.documentElement.dataset.commaFontFamily).toBeUndefined();
    expect(document.documentElement.style.getPropertyValue("--font-sans")).toBe("");
    await user.click(fontTrigger);
    await user.click(dropdownOptions().getByRole("option", { name: "Avenir Next" }));
    expect(fontTrigger).toHaveTextContent("Avenir Next");
    expect(readStoredClientSettings().appearance).toEqual({
      ...defaultCommaAppearancePreferences,
      fontFamily: "Avenir Next",
    });
  });

  it("applies and stores the font size, pointer cursors and reduced motion", async () => {
    renderSettings();

    await user.click(screen.getByRole("button", { name: "Appearance" }));
    const size = screen.getByRole("button", { name: /Select font size/ });
    await user.click(size);
    await user.click(dropdownOptions().getByRole("option", { name: "Large" }));
    expect(document.documentElement.dataset.commaFontSize).toBe("large");
    expect(size).toHaveTextContent("Large");

    const pointerCursors = screen.getByRole("switch", {
      name: "Use pointer cursors",
    });
    await user.click(pointerCursors);
    expect(pointerCursors).toBeChecked();
    expect(document.documentElement.dataset.commaPointerCursors).toBe("true");
    const reduceMotion = screen.getByRole("switch", { name: "Reduce motion" });
    await user.click(reduceMotion);
    expect(reduceMotion).toBeChecked();
    expect(document.documentElement.dataset.commaReducedMotion).toBe("true");
    expect(readStoredClientSettings().appearance).toEqual({
      ...defaultCommaAppearancePreferences,
      fontSize: "large",
      pointerCursors: true,
      reducedMotion: true,
    });
  });

  it("turns the macOS window ground's translucency off and stores a new transparency", async () => {
    // Main drew this window over a system material.
    installNativeBridgeMock({
      platform: "electron",
      os: "macos",
      windowMaterial: "vibrancy",
    });
    renderSettings();

    await user.click(screen.getByRole("button", { name: "Appearance" }));
    const translucency = screen.getByRole("switch", { name: /Translucent window/ });
    expect(translucency).toBeChecked();
    const transparency = screen.getByRole("slider", { name: "Transparency" });
    expect(transparency).toHaveAttribute("aria-valuenow", "50");

    // Arrow keys glide the preview and store the value once they stop.
    transparency.focus();
    await user.keyboard("{ArrowRight}");
    await advance(1_000);
    expect(transparency).toHaveAttribute("aria-valuenow", "51");
    expect(
      document.documentElement.style.getPropertyValue("--comma-window-transparency")
    ).toBe("51%");
    await user.click(translucency);
    expect(translucency).not.toBeChecked();
    expect(document.documentElement.dataset.commaWindowTranslucency).toBe("off");
    await flush();
    expect(readStoredClientSettings().appearance).toEqual({
      ...defaultCommaAppearancePreferences,
      windowTranslucency: false,
      windowTransparency: 51,
    });
  });

  it("offers no window translucency when the window has no system material", async () => {
    // Windows before 11 22H2 draws no backdrop material.
    installNativeBridgeMock({ platform: "electron", os: "windows" });
    renderSettings();

    await user.click(screen.getByRole("button", { name: "Appearance" }));
    expect(screen.getByRole("switch", { name: "Reduce motion" })).toBeInTheDocument();
    expect(screen.queryByRole("switch", { name: /Translucent window/ })).toBeNull();
  });

  it("applies and stores Soft Light, and names it on the theme control", async () => {
    renderSettings();

    await user.click(screen.getByRole("button", { name: "Appearance" }));
    await user.click(screen.getByRole("button", { name: /Select theme/ }));
    await user.click(dropdownOptions().getByRole("option", { name: "Soft Light" }));

    expect(document.documentElement.dataset.theme).toBe("Light mode");
    expect(document.documentElement.dataset.commaTheme).toBe("light");
    // Stored, and restored by the appearance provider (commaAppearance.test.tsx).
    expect(readStoredClientSettings().appearance).toMatchObject({
      theme: "light",
    });
    expect(screen.getByRole("button", { name: /Select theme/ })).toHaveTextContent(
      "Soft Light"
    );
  });

  it("moves the custom color from the pad's sliders and presets, and forces or follows the scheme", async () => {
    localStorage.setItem(
      commaClientSettingsStorageKey,
      JSON.stringify({
        ...structuredClone(defaultCommaClientSettings),
        appearance: { ...defaultCommaAppearancePreferences, theme: "custom" },
      })
    );
    renderSettings();

    await user.click(screen.getByRole("button", { name: "Appearance" }));
    const themeTrigger = screen.getByRole("button", { name: /Select theme/ });
    // With Custom chosen, the theme control opens on its pad.
    await user.click(themeTrigger);
    const custom = within(screen.getByRole("dialog", { name: "Custom" }));

    custom.getByRole("slider", { name: "Lightness" }).focus();
    await user.keyboard("{ArrowUp}");
    expect(
      Number.parseFloat(
        document.documentElement.style.getPropertyValue("--comma-theme-l")
      )
    ).toBeGreaterThan(defaultCommaAppearancePreferences.customLightness);
    expect(custom.getByRole("slider", { name: "Lightness" })).toHaveAttribute(
      "aria-valuenow",
      String(
        Math.round(
          (Number.parseFloat(
            document.documentElement.style.getPropertyValue("--comma-theme-l")
          ) || 0) * 100
        )
      )
    );

    await user.click(custom.getByRole("button", { name: "Hue 263°" }));
    expect(document.documentElement.style.getPropertyValue("--comma-theme-h")).toBe(
      "263deg"
    );
    expect(
      (
        themeTrigger.querySelector('[data-slot="theme-swatch"]') as HTMLElement | null
      )?.style.getPropertyValue("--comma-theme-h")
    ).toBe("263deg");

    expect(custom.getByRole("button", { name: "Auto" })).toBeInTheDocument();
    await user.click(custom.getByRole("button", { name: "Dark", pressed: false }));
    expect(document.documentElement.dataset.theme).toBe("Dark mode");
    expect(document.documentElement.dataset.commaTheme).toBe("custom");
    await user.click(custom.getByRole("button", { name: "Auto" }));
    expect(readStoredClientSettings().appearance).toMatchObject({
      theme: "custom",
      customScheme: "system",
    });
  });

  it("keeps Default reachable in the theme menu while Custom is selected", async () => {
    localStorage.setItem(
      commaClientSettingsStorageKey,
      JSON.stringify({
        ...structuredClone(defaultCommaClientSettings),
        appearance: {
          ...defaultCommaAppearancePreferences,
          theme: "custom",
        },
      })
    );
    renderSettings();

    await user.click(screen.getByRole("button", { name: "Appearance" }));
    await user.click(screen.getByRole("button", { name: /Select theme/ }));

    const popover = document.querySelector("[data-slot='menu-popover']");
    expect(popover).toHaveClass("z-50", "[-webkit-app-region:no-drag]");
    const custom = within(screen.getByRole("dialog", { name: "Custom" }));
    expect(custom.queryByRole("option", { name: "Auto" })).not.toBeInTheDocument();
    const backButton = custom.getByRole("button", { name: "Back to themes" });
    expect(backButton).toHaveFocus();
    await user.keyboard("{Enter}");
    await flush();
    expect(screen.queryByRole("dialog", { name: "Custom" })).not.toBeInTheDocument();
    expect(document.querySelector("[data-slot='menu-popover']")).toBeNull();
    expect(document.querySelector("[data-slot='dropdown-popover']")).not.toBeNull();
    const customOption = dropdownOptions().getByRole("option", { name: "Custom" });
    expect(customOption).toHaveFocus();
    const defaultOption = dropdownOptions().getByRole("option", { name: "Default" });
    expect(defaultOption).toBeInTheDocument();
    expect(
      dropdownOptions().queryByRole("option", { name: "Twilight" })
    ).not.toBeInTheDocument();
    expect(
      dropdownOptions().queryByRole("option", { name: "Ink" })
    ).not.toBeInTheDocument();
    await user.click(defaultOption);

    expect(document.documentElement.dataset.commaTheme).toBe("default");
    expect(screen.getByRole("button", { name: /Select theme/ })).toHaveTextContent(
      "Default"
    );
    expect(readStoredClientSettings().appearance).toEqual(
      defaultCommaAppearancePreferences
    );
  });

  it("shows Quick Chat's shortcut where Main runs it", async () => {
    const { unmount } = renderSettings();
    await user.click(screen.getByRole("button", { name: "Keyboard shortcuts" }));
    await flush();
    expect(screen.queryByText("Quick Chat")).not.toBeInTheDocument();
    unmount();

    installNativeBridgeMock({
      appPreferences: {
        state: createNativeStateBridgeMock(() =>
          appPreferencesSchema.parse({
            ...defaultAppPreferences,
            quickChatSupported: true,
          })
        ),
      },
      platform: "electron",
    });
    renderSettings();
    await user.click(screen.getByRole("button", { name: "Keyboard shortcuts" }));
    await flush();
    expect(screen.getByText("Quick Chat")).toBeVisible();
    // A double tap of ⌘ on macOS, of Ctrl on Windows (and where the suite runs as Windows).
    const key = detectAppKeybindingPlatform() === "windows" ? "Ctrl" : "Cmd";
    expect(screen.getByRole("button", { name: `Quick Chat: ${key}` })).toBeVisible();
  });

  it("records the modifier or chord that opens Quick Chat", async () => {
    // macOS's keys: where the suite runs decides the platform's own otherwise.
    vi.spyOn(window.navigator, "platform", "get").mockReturnValue("MacIntel");
    installNativeBridgeMock({
      appPreferences: {
        state: createNativeStateBridgeMock(() =>
          appPreferencesSchema.parse({
            ...defaultAppPreferences,
            quickChatSupported: true,
          })
        ),
      },
      os: "macos",
      platform: "electron",
    });
    renderSettings();
    await user.click(screen.getByRole("button", { name: "Keyboard shortcuts" }));
    await flush();

    // Option alone: a double tap of it.
    await user.click(quickChatRecorder());
    await user.keyboard("{Alt}");
    await flush();
    expect(readStoredClientSettings().quickChatShortcut).toEqual({ tap: "alt" });
    expect(
      setting("keyboard.quick-chat").getByText(/Double-tap ⌥ and speak/)
    ).toBeVisible();

    // A chord.
    await user.click(quickChatRecorder());
    await user.keyboard("{Alt>}{Shift>}[Space]{/Shift}{/Alt}");
    await advance(16);
    expect(readStoredClientSettings().quickChatShortcut).toEqual({
      key: "space",
      modifiers: { alt: true, control: false, meta: false, shift: true },
    });
    expect(
      setting("keyboard.quick-chat").getByText(/Press ⌥⇧Space and speak/)
    ).toBeVisible();

    // Clearing returns to the platform's own double tap of ⌘, stored as none.
    await user.click(quickChatRecorder());
    await user.click(screen.getByRole("button", { name: "Clear shortcut" }));
    await flush();
    expect(readStoredClientSettings().quickChatShortcut).toBeNull();
    expect(quickChatRecorder()).toHaveAccessibleName("Quick Chat: Cmd");
  });

  it("turns Quick Chat off where this Mac can run it, and drops its shortcut", async () => {
    let preferences = appPreferencesSchema.parse({
      launchAtLogin: false,
      quickChatSupported: true,
      showInDock: true,
      showInMenuBar: true,
    });
    const update = vi.fn(async (patch: AppPreferencesPatch) => {
      preferences = appPreferencesSchema.parse({
        ...preferences,
        ...patch,
        revision: preferences.revision + 1,
      });
      return preferences;
    });
    installNativeBridgeMock({
      appPreferences: {
        state: createNativeStateBridgeMock(() => preferences),
        update,
      },
      os: "macos",
      platform: "electron",
    });
    renderSettings();
    await flush();

    const quickChat = screen.getByRole("switch", { name: "Quick Chat" });
    // Existing preference files predate the switch; Quick Chat stays on.
    expect(quickChat).toBeChecked();

    await user.click(quickChat);
    await flush();
    expect(quickChat).not.toBeChecked();
    expect(update.mock.calls.map(([patch]) => patch)).toEqual([
      { quickChatEnabled: false },
    ]);

    await user.click(screen.getByRole("button", { name: "Keyboard shortcuts" }));
    await flush();
    expect(
      screen.queryByRole("button", { name: /^Quick Chat:/ })
    ).not.toBeInTheDocument();
  });

  it("shows the Router's reply style in General and asks the core to save a new one", async () => {
    const core = createScriptedCore({
      values: (topic) => {
        if (topic.topic === "workspace") return resolvedWorkspace("ws-2");
        if (topic.topic === "router" && topic.workspace === "ws-2")
          return { agent: "router", name: "Comma", reply_style: "default" };
        return undefined;
      },
    });
    renderSettings(undefined, undefined, core);
    await flush();

    const trigger = setting("replies.style").getByRole("button", {
      name: /Reply style/,
    });
    expect(trigger).toHaveTextContent("Default");
    await user.click(trigger);
    await user.click(dropdownOptions().getByRole("option", { name: "Concise" }));
    await flush();
    expect(core.sentTo("models.setReplyStyle")).toEqual([
      { workspace: "ws-2", style: "concise" },
    ]);
  });

  it("edits the Router's system prompt beside the reply style, and resets it", async () => {
    let held = { content: "", hash: "h0" };
    const core = createScriptedCore({
      values: (topic) => {
        if (topic.topic === "workspace") return resolvedWorkspace("ws-2");
        if (topic.topic === "router" && topic.workspace === "ws-2")
          return { agent: "router", name: "Comma", reply_style: "concise" };
        return undefined;
      },
      calls: (name, params) => {
        if (name === "systemFiles.instructions") return held;
        if (name !== "systemFiles.writeInstructions") return null;
        const { content, expectedHash } = params as {
          content: string;
          expectedHash?: string;
        };
        if (expectedHash !== held.hash)
          throw Object.assign(new Error("changed"), { code: "conflict", status: 409 });
        held = { content, hash: `h-${content}` };
        return held;
      },
    });
    renderSettings(undefined, undefined, core);
    await flush();
    const edit = () =>
      setting("router.instructions").getByRole("button", { name: "Edit" });
    const field = () =>
      within(instructionsDialog()).getByRole("textbox", { name: "System prompt" });

    await user.click(edit());
    await user.type(field(), "Be brief.");
    await user.click(
      within(instructionsDialog()).getByRole("button", { name: /Save/ })
    );
    await instructionsClosed();
    expect(core.sentTo("systemFiles.writeInstructions")).toEqual([
      { group: "grp_ws-2", content: "Be brief.", expectedHash: "h0" },
    ]);
    // The prompt adds to the reply style; it does not replace it.
    expect(
      document.querySelector('[data-setting-id="replies.style"]')
    ).toHaveTextContent("Concise");

    // Drive saved it meanwhile: the save is refused and the typed text stays for a save over it.
    held = { content: "From Drive.", hash: "h2" };
    await user.click(edit());
    expect(field()).toHaveValue("Be brief.");
    await user.type(field(), " Always.");
    await user.click(
      within(instructionsDialog()).getByRole("button", { name: /Save/ })
    );
    await waitFor(() =>
      expect(
        within(instructionsDialog()).getByText(
          "The system prompt changed elsewhere. Your text is kept; save again to replace it."
        )
      ).toBeInTheDocument()
    );
    expect(field()).toHaveValue("Be brief. Always.");

    // Reset clears it.
    await user.click(
      within(instructionsDialog()).getByRole("button", { name: /Reset/ })
    );
    await instructionsClosed();
    expect(held.content).toBe("");
  });

  it("offers a guest no reply style, which belongs to an account's Router", () => {
    renderSettings({ ...defaultAuth(), isGuest: true, userId: "usr_guest" });
    expect(screen.queryByText("Reply style")).toBeNull();
  });

  it("replays the onboarding from General for an account that finished it", async () => {
    localStorage.setItem(
      commaClientSettingsStorageKey,
      JSON.stringify({
        ...structuredClone(defaultCommaClientSettings),
        onboardingCompletedUserIds: ["usr_other", "usr_ada"],
      })
    );
    renderSettings({ ...defaultAuth(), userId: "usr_ada" });

    await flush();
    const row = screen.getByText("Replay onboarding");
    await user.click(
      within(row.closest("[data-setting-id]") as HTMLElement).getByRole("button", {
        name: "Replay",
      })
    );
    // Forgetting the completion is what brings the onboarding back.
    await flush();
    expect(readStoredClientSettings().onboardingCompletedUserIds).toEqual([
      "usr_other",
    ]);
  });

  it("offers a guest no onboarding to replay", () => {
    renderSettings({ ...defaultAuth(), isGuest: true, userId: "usr_guest" });
    expect(screen.queryByText("Replay onboarding")).toBeNull();
  });

  it("customizes general shortcuts and can reset them to defaults", async () => {
    renderSettings();

    await user.click(screen.getByRole("button", { name: "Keyboard shortcuts" }));
    expect(
      screen.getByRole("heading", { level: 2, name: "Navigation" })
    ).toBeInTheDocument();
    const inbox = setting("keyboard.go-inbox");
    const inboxShortcut = inbox.getByRole("button", { name: "Go to Inbox: G then I" });
    await flush();
    expect(inboxShortcut).toBeEnabled();
    await user.click(inboxShortcut);
    // A two-key sequence is kept once the keys pause.
    await user.keyboard("gx");
    await advance(APP_KEYBINDING_SEQUENCE_TIMEOUT_MS);

    expect(
      inbox.getByRole("button", { name: "Go to Inbox: G then X" })
    ).toBeInTheDocument();
    expect(readStoredClientSettings().appShortcutOverrides).toEqual({
      "go-inbox": { kind: "sequence", codes: ["KeyG", "KeyX"] },
    });

    const reset = screen.getByRole("button", { name: "Reset all to defaults" });
    expect(reset).toBeEnabled();
    await user.click(reset);
    // Stored as no overrides, which the shortcuts provider reads back
    // (commaAppShortcuts.test.tsx).
    expect(readStoredClientSettings().appShortcutOverrides).toEqual({});
    expect(
      inbox.getByRole("button", { name: "Go to Inbox: G then I" })
    ).toBeInTheDocument();
    expect(reset).toBeDisabled();
  });

  it("rejects app and Open Comma collisions in both editing directions", async () => {
    renderSettings();

    await user.click(screen.getByRole("button", { name: "Keyboard shortcuts" }));
    await flush();
    const appShortcut = screen.getByRole("button", {
      name: /Toggle left sidebar: (?:Command|Control) \+ B/,
    });
    const appUsesCommand = appShortcut.getAttribute("aria-label")?.includes("Command");
    await user.click(appShortcut);
    await user.keyboard("{Alt>}[Comma]{/Alt}");

    expect(
      screen.getByRole("button", {
        name: /Toggle left sidebar: (?:Command|Control) \+ B/,
      })
    ).toBeInTheDocument();
    await flush();
    expect(
      screen.getByText("This shortcut is already used by another command.")
    ).toHaveAttribute("role", "alert");

    await user.click(screen.getByRole("button", { name: "Open Comma: Alt + ," }));
    await user.keyboard(appUsesCommand ? "{Meta>}b{/Meta}" : "{Control>}b{/Control}");
    await flush();

    expect(
      screen.getByRole("button", { name: "Open Comma: Alt + ," })
    ).toBeInTheDocument();
    expect(readStoredClientSettings().openCommaShortcut).toEqual(
      defaultCommaClientSettings.openCommaShortcut
    );
    expect(
      screen.getAllByText("This shortcut is already used by another command.")
    ).toHaveLength(2);
  });

  it("clears a stale app conflict after the conflicting binding is removed", async () => {
    renderSettings();

    await user.click(screen.getByRole("button", { name: "Keyboard shortcuts" }));
    const inbox = setting("keyboard.go-inbox");
    const inboxShortcut = inbox.getByRole("button", { name: "Go to Inbox: G then I" });
    await flush();
    expect(inboxShortcut).toBeEnabled();
    await user.click(inboxShortcut);
    await user.keyboard("gx");
    await advance(APP_KEYBINDING_SEQUENCE_TIMEOUT_MS);
    const customizedInbox = inbox.getByRole("button", {
      name: "Go to Inbox: G then X",
    });
    expect(readStoredClientSettings().appShortcutOverrides).toEqual({
      "go-inbox": { kind: "sequence", codes: ["KeyG", "KeyX"] },
    });

    // Three keys end a sequence at once: G X X starts with Inbox's G X.
    const plugins = setting("keyboard.go-plugins");
    await user.click(plugins.getByRole("button", { name: "Go to Plugin: G then P" }));
    await user.keyboard("gxx");
    expect(
      plugins.getByText("This shortcut is already used by another command.")
    ).toHaveAttribute("role", "alert");

    await user.click(customizedInbox);
    await user.click(inbox.getByRole("button", { name: "Clear shortcut" }));

    expect(
      screen.queryByText("This shortcut is already used by another command.")
    ).not.toBeInTheDocument();
  });

  it("disables the app default that collides with a stored Open Comma shortcut", async () => {
    const openCommaShortcut = {
      key: "b",
      modifiers: { alt: false, control: false, meta: true, shift: false },
    };
    localStorage.setItem(
      commaClientSettingsStorageKey,
      JSON.stringify({
        ...structuredClone(defaultCommaClientSettings),
        openCommaShortcut,
      })
    );

    renderSettings(defaultAuth(), "macos");
    await user.click(screen.getByRole("button", { name: "Keyboard shortcuts" }));

    await flush();
    expect(
      screen.getByRole("button", {
        name: "Toggle left sidebar: Not set",
      })
    ).toBeInTheDocument();
    expect(readStoredClientSettings().appShortcutOverrides).toEqual({
      "toggle-left-sidebar": null,
    });
    expect(readStoredClientSettings().openCommaShortcut).toEqual(openCommaShortcut);
  });

  it("shows no Computer use where the app has no helper to grant (outside macOS)", async () => {
    renderSettings();

    expect(
      screen.queryByRole("button", { name: "Computer use" })
    ).not.toBeInTheDocument();
  });

  it("reads computer permissions and refreshes after managing access", async () => {
    const getPermissions = vi.fn().mockResolvedValue({
      ok: true,
      permissions: { accessibility: false, screenRecording: false },
    });
    const openPermissionFlow = vi.fn().mockResolvedValue({ ok: true });
    installNativeBridgeMock({
      platform: "electron",
      os: "macos",
      computerUse: { getPermissions, openPermissionFlow },
    });
    renderSettings();
    expect(getPermissions).not.toHaveBeenCalled();
    await user.click(screen.getByRole("button", { name: "Computer use" }));
    await flush();
    expect(screen.getAllByText("Not granted")).toHaveLength(2);
    getPermissions.mockResolvedValue({
      ok: true,
      permissions: { accessibility: true, screenRecording: true },
    });
    await user.click(screen.getByRole("button", { name: "Manage permissions" }));
    await waitFor(() => expect(screen.getAllByText("Granted")).toHaveLength(2));
    expect(openPermissionFlow).toHaveBeenCalledOnce();
    getPermissions.mockResolvedValue({ ok: false, error: "Helper unavailable" });
    await user.click(screen.getByRole("button", { name: "Refresh status" }));
    await flush();
    screen.getByText("Helper unavailable");
    expect(screen.getAllByText("Not checked")).toHaveLength(2);
    expect(screen.getByRole("button", { name: "Refresh status" })).toBeEnabled();
  });

  it("coalesces permission checks and refreshes on return only while the category is open", async () => {
    let finish!: (value: {
      ok: boolean;
      permissions: { accessibility: boolean; screenRecording: boolean };
    }) => void;
    const getPermissions = vi.fn().mockImplementation(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        })
    );
    installNativeBridgeMock({
      platform: "electron",
      os: "macos",
      computerUse: { getPermissions },
    });
    renderSettings();
    await user.click(screen.getByRole("button", { name: "Computer use" }));
    expect(screen.getByRole("button", { name: "Refresh status" })).toBeDisabled();
    act(() => {
      window.dispatchEvent(new Event("focus"));
      window.dispatchEvent(new Event("focus"));
    });
    expect(getPermissions).toHaveBeenCalledTimes(1);
    await act(async () => {
      finish({
        ok: true,
        permissions: { accessibility: false, screenRecording: true },
      });
    });
    getPermissions.mockResolvedValue({
      ok: true,
      permissions: { accessibility: true, screenRecording: true },
    });
    await act(async () => {
      window.dispatchEvent(new Event("focus"));
    });
    expect(screen.getAllByText("Granted")).toHaveLength(2);
    expect(getPermissions).toHaveBeenCalledTimes(2);
    await user.click(screen.getByRole("button", { name: "General" }));
    act(() => {
      window.dispatchEvent(new Event("focus"));
    });
    expect(getPermissions).toHaveBeenCalledTimes(2);
  });

  it("loads and updates the native application preferences on macOS", async () => {
    let preferences = appPreferencesSchema.parse({
      launchAtLogin: false,
      showInDock: true,
      showInMenuBar: true,
    });
    const update = vi.fn(async (patch: AppPreferencesPatch) => {
      preferences = appPreferencesSchema.parse({
        ...preferences,
        ...patch,
        revision: preferences.revision + 1,
      });
      return preferences;
    });
    installNativeBridgeMock({
      appPreferences: {
        state: createNativeStateBridgeMock(() => preferences),
        update,
      },
      os: "macos",
      platform: "electron",
    });
    renderSettings();

    const launchAtLogin = screen.getByRole("switch", {
      name: "Launch Comma at login",
    });
    const showInMenuBar = screen.getByRole("switch", {
      name: "Show in menu bar",
    });
    const showInDock = screen.getByRole("switch", { name: "Show in dock" });
    const showInAirDrop = screen.getByRole("switch", { name: "Show Comma in AirDrop" });
    const keepAwake = screen.getByRole("switch", {
      name: "Keep awake with lid closed",
    });
    await flush();
    expect(launchAtLogin).toBeEnabled();
    expect(launchAtLogin).not.toBeChecked();
    expect(showInMenuBar).toBeChecked();
    expect(showInDock).toBeChecked();
    // Existing preference files predate AirDrop; Comma stays visible by default.
    expect(showInAirDrop).toBeChecked();
    expect(keepAwake).not.toBeChecked();

    await user.click(launchAtLogin);
    await flush();
    expect(launchAtLogin).toBeChecked();
    await user.click(showInMenuBar);
    await flush();
    expect(showInMenuBar).not.toBeChecked();
    await user.click(showInDock);
    await flush();
    expect(showInDock).not.toBeChecked();
    await user.click(showInAirDrop);
    await flush();
    expect(showInAirDrop).not.toBeChecked();
    await user.click(keepAwake);
    await flush();
    expect(keepAwake).toBeChecked();

    expect(update.mock.calls.map(([patch]) => patch)).toEqual([
      { launchAtLogin: true },
      { showInMenuBar: false },
      { showInDock: false },
      { showInAirDrop: false },
      { keepAwakeWhenLidClosed: true },
    ]);
  });

  it("guides the user to Login Items until macOS allows keeping the Mac awake", async () => {
    let preferences = appPreferencesSchema.parse({
      keepAwakeWhenLidClosedStatus: "not-registered",
      launchAtLogin: false,
      showInDock: true,
      showInMenuBar: true,
    });
    // Main registers the daemon on the first turn-on; macOS then waits for the user.
    const update = vi.fn(async (patch: AppPreferencesPatch) => {
      preferences = appPreferencesSchema.parse({
        ...preferences,
        ...patch,
        ...(patch.keepAwakeWhenLidClosed
          ? { keepAwakeWhenLidClosedStatus: "requires-approval" }
          : {}),
        revision: preferences.revision + 1,
      });
      return preferences;
    });
    const openLoginItemsSettings = vi.fn(async () => ({ opened: true }));
    installNativeBridgeMock({
      appPreferences: {
        openLoginItemsSettings,
        state: createNativeStateBridgeMock(() => preferences),
        update,
      },
      os: "macos",
      platform: "electron",
    });
    renderSettings();

    const keepAwake = screen.getByRole("switch", {
      name: "Keep awake with lid closed",
    });
    await flush();
    expect(keepAwake).toBeEnabled();
    await user.click(keepAwake);
    await flush();
    const dialog = screen.getByRole("dialog", {
      name: "Allow Comma in Login Items",
    });
    expect(keepAwake).toBeChecked();

    await user.click(
      within(dialog).getByRole("button", { name: "Open System Settings" })
    );
    expect(openLoginItemsSettings).toHaveBeenCalledOnce();
    expect(dialog).not.toBeInTheDocument();
    // The choice waits for approval: the switch reads off and says why.
    expect(keepAwake).not.toBeChecked();
    expect(
      screen.getByText(
        "Waiting for your approval. Allow Comma in System Settings › General › Login Items, and this turns on."
      )
    ).toBeInTheDocument();

    // Back from System Settings: Main's readback after approval turns it on.
    preferences = appPreferencesSchema.parse({
      ...preferences,
      keepAwakeWhenLidClosedStatus: "available",
      revision: preferences.revision + 1,
    });
    act(() => window.dispatchEvent(new Event("focus")));
    await flush();
    expect(keepAwake).toBeChecked();
    expect(update.mock.calls.map(([patch]) => patch)).toEqual([
      { keepAwakeWhenLidClosed: true },
    ]);
  });

  it("withdraws the keep-awake choice when the approval dialog is cancelled", async () => {
    let preferences = appPreferencesSchema.parse({
      keepAwakeWhenLidClosedStatus: "requires-approval",
      launchAtLogin: false,
      showInDock: true,
      showInMenuBar: true,
    });
    const update = vi.fn(async (patch: AppPreferencesPatch) => {
      preferences = appPreferencesSchema.parse({
        ...preferences,
        ...patch,
        revision: preferences.revision + 1,
      });
      return preferences;
    });
    installNativeBridgeMock({
      appPreferences: {
        openLoginItemsSettings: vi.fn(async () => ({ opened: true })),
        state: createNativeStateBridgeMock(() => preferences),
        update,
      },
      os: "macos",
      platform: "electron",
    });
    renderSettings();

    const keepAwake = screen.getByRole("switch", {
      name: "Keep awake with lid closed",
    });
    await flush();
    expect(keepAwake).toBeEnabled();
    await user.click(keepAwake);
    await flush();
    const dialog = screen.getByRole("dialog", {
      name: "Allow Comma in Login Items",
    });
    await user.click(within(dialog).getByRole("button", { name: "Cancel" }));

    await flush();
    expect(dialog).not.toBeInTheDocument();
    expect(keepAwake).not.toBeChecked();
    expect(update.mock.calls.map(([patch]) => patch)).toEqual([
      { keepAwakeWhenLidClosed: true },
      { keepAwakeWhenLidClosed: false },
    ]);
  });

  it("renames Comma in AirDrop while it shows there and clears back to the account's name", async () => {
    let preferences = appPreferencesSchema.parse({
      launchAtLogin: false,
      showInDock: true,
      showInMenuBar: true,
    });
    const update = vi.fn(async (patch: AppPreferencesPatch) => {
      preferences = appPreferencesSchema.parse({
        ...preferences,
        ...patch,
        revision: preferences.revision + 1,
      });
      return preferences;
    });
    installNativeBridgeMock({
      appPreferences: {
        state: createNativeStateBridgeMock(() => preferences),
        update,
      },
      os: "macos",
      platform: "electron",
    });
    renderSettings();

    // Until renamed, Comma carries the account's name, in English.
    await flush();
    const edit = screen.getByRole("button", {
      name: "Edit AirDrop name: Ada’s Comma",
    });
    await flush();
    expect(edit).toBeEnabled();
    await user.click(edit);
    const field = screen.getByRole("textbox", { name: "AirDrop name" });
    expect(field).toHaveValue("Ada’s Comma");
    await user.clear(field);
    await user.paste("Studio Mac");
    await user.keyboard("{Enter}");
    await flush();
    const renamed = screen.getByRole("button", {
      name: "Edit AirDrop name: Studio Mac",
    });

    await flush();
    expect(renamed).toBeEnabled();
    await user.click(renamed);
    await user.clear(screen.getByRole("textbox", { name: "AirDrop name" }));
    await user.click(screen.getByRole("button", { name: "Save" }));
    await screen.findByRole("button", { name: "Edit AirDrop name: Ada’s Comma" });
    expect(update.mock.calls.map(([patch]) => patch)).toEqual([
      { airDropName: "Studio Mac" },
      { airDropName: null },
    ]);
  });

  it("offers no AirDrop name to edit while Comma is hidden from AirDrop", async () => {
    let preferences = appPreferencesSchema.parse({
      launchAtLogin: false,
      showInDock: true,
      showInMenuBar: true,
    });
    const update = vi.fn(async (patch: AppPreferencesPatch) => {
      preferences = appPreferencesSchema.parse({
        ...preferences,
        ...patch,
        revision: preferences.revision + 1,
      });
      return preferences;
    });
    installNativeBridgeMock({
      appPreferences: {
        state: createNativeStateBridgeMock(() => preferences),
        update,
      },
      os: "macos",
      platform: "electron",
    });
    renderSettings();
    await flush();
    expect(
      screen.getByRole("button", { name: "Edit AirDrop name: Ada’s Comma" })
    ).toBeInTheDocument();
    // Hidden from AirDrop, Comma has no name to edit.
    const showInAirDrop = screen.getByRole("switch", { name: "Show Comma in AirDrop" });
    await flush();
    expect(showInAirDrop).toBeEnabled();
    await user.click(showInAirDrop);
    await flush();
    expect(screen.queryByRole("button", { name: /^Edit AirDrop name/ })).toBeNull();
    expect(update.mock.calls.map(([patch]) => patch)).toEqual([
      { showInAirDrop: false },
    ]);
  });

  it("previews the Notch width while the Notch is on and saves a resize once keys stop", async () => {
    let preferences = appPreferencesSchema.parse({
      launchAtLogin: false,
      showInDock: true,
      showInMenuBar: true,
    });
    const update = vi.fn(async (patch: AppPreferencesPatch) => {
      preferences = appPreferencesSchema.parse({
        ...preferences,
        ...patch,
        revision: preferences.revision + 1,
      });
      return preferences;
    });
    const bridge = installNativeBridgeMock({
      appPreferences: {
        state: createNativeStateBridgeMock(() => preferences),
        update,
      },
      os: "macos",
      platform: "electron",
    });
    renderSettings();

    const showInNotch = screen.getByRole("switch", { name: "Show in notch" });
    // Existing preference files predate the Notch settings; it stays on.
    await flush();
    expect(showInNotch).toBeChecked();
    const width = screen.getByRole("slider", { name: "Notch width" });
    expect(width).toHaveAttribute("aria-valuenow", "156");

    // The preview follows each key at once; Main hears only where it stops.
    width.focus();
    await user.keyboard("{ArrowRight}{ArrowRight}");
    expect(width).toHaveAttribute("aria-valuenow", "164");
    expect(update).not.toHaveBeenCalled();
    await advance(1_000);
    expect(update).toHaveBeenCalledWith({ notchSideWidth: 164 });
    expect(screen.getByRole("button", { name: "Reset" })).toBeEnabled();

    // The real Notch shows that width once, with the preview's sample Task.
    await user.click(screen.getByRole("button", { name: "Preview on notch" }));
    expect(bridge.notch.preview).toHaveBeenCalledWith({
      sideWidth: 164,
      title: "Summarize this week’s meetings",
    });

    await flush();
    expect(showInNotch).toBeEnabled();
    await user.click(showInNotch);
    await flush();
    expect(showInNotch).not.toBeChecked();
    await flush();
    expect(screen.queryByRole("slider", { name: "Notch width" })).toBeNull();
    expect(update.mock.calls.map(([patch]) => patch)).toEqual([
      { notchSideWidth: 164 },
      { showInNotch: false },
    ]);
  });

  it("updates the notification preferences and gates the sound on Router notifications", async () => {
    let preferences = appPreferencesSchema.parse({
      launchAtLogin: false,
      showInDock: true,
      showInMenuBar: true,
    });
    const update = vi.fn(async (patch: AppPreferencesPatch) => {
      preferences = appPreferencesSchema.parse({
        ...preferences,
        ...patch,
        revision: preferences.revision + 1,
      });
      return preferences;
    });
    installNativeBridgeMock({
      appPreferences: {
        state: createNativeStateBridgeMock(() => preferences),
        update,
      },
      os: "macos",
      platform: "electron",
    });
    renderSettings();
    await user.click(screen.getByRole("button", { name: "Notifications" }));

    const routerMessages = screen.getByRole("switch", {
      name: "Router message notifications",
    });
    const sound = screen.getByRole("switch", { name: "Notification sound" });
    await flush();
    expect(routerMessages).toBeEnabled();
    expect(routerMessages).toBeChecked();
    expect(sound).toBeChecked();

    await user.click(sound);
    await flush();
    expect(sound).not.toBeChecked();

    // Turning Router notifications off leaves no notification to sound.
    await user.click(routerMessages);
    await flush();
    expect(sound).toBeDisabled();

    expect(update.mock.calls.map(([patch]) => patch)).toEqual([
      { notificationSound: false },
      { notifyRouterMessages: false },
    ]);
  });

  it("gates every notification on the system notifications switch", async () => {
    let preferences = appPreferencesSchema.parse({
      launchAtLogin: false,
      showInDock: true,
      showInMenuBar: true,
    });
    const update = vi.fn(async (patch: AppPreferencesPatch) => {
      preferences = appPreferencesSchema.parse({
        ...preferences,
        ...patch,
        revision: preferences.revision + 1,
      });
      return preferences;
    });
    installNativeBridgeMock({
      appPreferences: {
        state: createNativeStateBridgeMock(() => preferences),
        update,
      },
      os: "macos",
      platform: "electron",
    });
    renderSettings();
    await user.click(screen.getByRole("button", { name: "Notifications" }));

    const system = screen.getByRole("switch", { name: "System notifications" });
    const routerMessages = screen.getByRole("switch", {
      name: "Router message notifications",
    });
    const sound = screen.getByRole("switch", { name: "Notification sound" });
    await flush();
    expect(system).toBeEnabled();
    expect(system).toBeChecked();
    expect(
      screen.getByText("Comma sends system notifications to remind you.")
    ).toBeInTheDocument();

    // The master switch is the only one that stays interactive once it is
    // off; the Router choices keep their stored values for when it returns.
    await user.click(system);
    await flush();
    expect(system).not.toBeChecked();
    expect(routerMessages).toBeDisabled();
    expect(routerMessages).toBeChecked();
    expect(sound).toBeDisabled();
    expect(update.mock.calls.map(([patch]) => patch)).toEqual([
      { systemNotifications: false },
    ]);
  });

  it("lets the user turn system notifications on and opens System Settings when the OS denies Comma", async () => {
    const preferences = appPreferencesSchema.parse({
      launchAtLogin: false,
      showInDock: true,
      showInMenuBar: true,
      systemNotificationsStatus: "denied",
    });
    const openNotificationSettings = vi.fn(async () => ({ opened: true }));
    installNativeBridgeMock({
      appPreferences: {
        openNotificationSettings,
        state: createNativeStateBridgeMock(() => preferences),
        update: vi.fn(),
      },
      os: "macos",
      platform: "electron",
    });
    renderSettings();
    await user.click(screen.getByRole("button", { name: "Notifications" }));

    const system = screen.getByRole("switch", { name: "System notifications" });
    await flush();
    expect(
      screen.getByText(
        "Notifications for Comma are turned off in System Settings. Allow them there to turn this on."
      )
    ).toBeInTheDocument();
    // Stored as on, but the OS has the final say: nothing can be delivered,
    // so the switch shows off until the user turns it on and allows Comma.
    expect(system).toBeEnabled();
    expect(system).not.toBeChecked();
    expect(
      screen.getByRole("switch", { name: "Router message notifications" })
    ).toBeDisabled();
    expect(screen.getByRole("switch", { name: "Notification sound" })).toBeDisabled();

    await user.click(system);
    await flush();
    const dialog = screen.getByRole("dialog", {
      name: "Allow notifications in System Settings",
    });
    expect(system).toBeChecked();
    expect(
      screen.getByText(
        "Notifications for Comma are turned off in System Settings. Open System Settings, then allow notifications for Comma."
      )
    ).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "Open System Settings" }));
    expect(openNotificationSettings).toHaveBeenCalledOnce();
    expect(dialog).not.toBeInTheDocument();
    expect(system).not.toBeChecked();
  });

  it("keeps the on choice when turning system notifications on while the OS denies Comma", async () => {
    let preferences = appPreferencesSchema.parse({
      launchAtLogin: false,
      showInDock: true,
      showInMenuBar: true,
      systemNotifications: false,
      systemNotificationsStatus: "denied",
    });
    const update = vi.fn(async (patch: AppPreferencesPatch) => {
      preferences = appPreferencesSchema.parse({
        ...preferences,
        ...patch,
        revision: preferences.revision + 1,
      });
      return preferences;
    });
    installNativeBridgeMock({
      appPreferences: {
        state: createNativeStateBridgeMock(() => preferences),
        update,
      },
      os: "macos",
      platform: "electron",
    });
    renderSettings();
    await user.click(screen.getByRole("button", { name: "Notifications" }));

    const system = screen.getByRole("switch", { name: "System notifications" });
    await flush();
    expect(system).toBeEnabled();
    await user.click(system);
    await flush();
    screen.getByRole("dialog", {
      name: "Allow notifications in System Settings",
    });
    expect(update.mock.calls.map(([patch]) => patch)).toEqual([
      { systemNotifications: true },
    ]);
  });

  it("keeps system notifications usable while macOS has not asked about Comma yet", async () => {
    let preferences = appPreferencesSchema.parse({
      launchAtLogin: false,
      showInDock: true,
      showInMenuBar: true,
      systemNotificationsStatus: "undetermined",
    });
    const update = vi.fn(async (patch: AppPreferencesPatch) => {
      preferences = appPreferencesSchema.parse({
        ...preferences,
        ...patch,
        revision: preferences.revision + 1,
      });
      return preferences;
    });
    installNativeBridgeMock({
      appPreferences: {
        state: createNativeStateBridgeMock(() => preferences),
        update,
      },
      os: "macos",
      platform: "electron",
    });
    renderSettings();
    await user.click(screen.getByRole("button", { name: "Notifications" }));

    // macOS asks on the first banner, so nothing is blocked yet: the stored
    // choice shows as is and the Router rows follow it.
    const system = screen.getByRole("switch", { name: "System notifications" });
    await flush();
    expect(system).toBeEnabled();
    expect(system).toBeChecked();
    expect(
      screen.getByText("Comma sends system notifications to remind you.")
    ).toBeInTheDocument();
    expect(
      screen.getByRole("switch", { name: "Router message notifications" })
    ).toBeEnabled();

    await user.click(system);
    await flush();
    expect(system).not.toBeChecked();
    expect(
      screen.queryByRole("dialog", { name: "Allow notifications in System Settings" })
    ).toBeNull();
    expect(update.mock.calls.map(([patch]) => patch)).toEqual([
      { systemNotifications: false },
    ]);
  });

  it("auditions the notification sound while its toggle is off", async () => {
    const play = vi
      .spyOn(window.HTMLMediaElement.prototype, "play")
      .mockResolvedValue(undefined);
    const preferences = appPreferencesSchema.parse({
      launchAtLogin: false,
      notificationSound: false,
      notifyRouterMessages: false,
      showInDock: true,
      showInMenuBar: true,
    });
    installNativeBridgeMock({
      appPreferences: {
        state: createNativeStateBridgeMock(() => preferences),
        update: vi.fn(),
      },
      os: "macos",
      platform: "electron",
    });
    renderSettings();
    await user.click(screen.getByRole("button", { name: "Notifications" }));

    const preview = screen.getByRole("button", { name: "Play sample" });
    await flush();
    expect(screen.getByRole("switch", { name: "Notification sound" })).toBeDisabled();

    // The sample is how you decide whether to turn the sound on, so it stays
    // reachable while the toggle it belongs to is disabled.
    expect(preview).toBeEnabled();
    await user.click(preview);
    expect(play).toHaveBeenCalledOnce();

    play.mockRestore();
  });

  it("gates every native preference toggle while a write is in flight", async () => {
    let preferences = appPreferencesSchema.parse({
      launchAtLogin: false,
      showInDock: true,
      showInMenuBar: true,
    });
    let release: (() => void) | undefined;
    const inFlight = new Promise<void>((resolve) => {
      release = resolve;
    });
    const update = vi.fn(async (patch: AppPreferencesPatch) => {
      await inFlight;
      preferences = appPreferencesSchema.parse({
        ...preferences,
        ...patch,
        revision: preferences.revision + 1,
      });
      return preferences;
    });
    installNativeBridgeMock({
      appPreferences: {
        state: createNativeStateBridgeMock(() => preferences),
        update,
      },
      os: "macos",
      platform: "electron",
    });
    renderSettings();

    const launchAtLogin = screen.getByRole("switch", {
      name: "Launch Comma at login",
    });
    const showInMenuBar = screen.getByRole("switch", { name: "Show in menu bar" });
    const showInDock = screen.getByRole("switch", { name: "Show in dock" });
    await flush();
    expect(launchAtLogin).toBeEnabled();

    await user.click(showInMenuBar);

    // A native write in flight gates all three, not just the one clicked. The
    // pending flag covers writes from any Main window, which is how concurrent
    // preference updates are serialised across windows.
    await flush();
    expect(showInMenuBar).toBeDisabled();
    expect(launchAtLogin).toBeDisabled();
    expect(showInDock).toBeDisabled();

    release?.();
    await flush();
    expect(showInMenuBar).toBeEnabled();
    expect(launchAtLogin).toBeEnabled();
    expect(showInDock).toBeEnabled();
  });

  it("guides macOS users to approve a pending login item", async () => {
    let preferences = appPreferencesSchema.parse({
      launchAtLogin: false,
      launchAtLoginStatus: "requires-approval",
      showInDock: true,
      showInMenuBar: true,
    });
    const update = vi.fn(async () => preferences);
    installNativeBridgeMock({
      appPreferences: {
        state: createNativeStateBridgeMock(() => preferences),
        update,
      },
      os: "macos",
      platform: "electron",
    });
    renderSettings();

    const launchAtLogin = screen.getByRole("switch", {
      name: "Launch Comma at login",
    });
    await flush();
    expect(launchAtLogin).toBeDisabled();
    expect(launchAtLogin).not.toBeChecked();
    expect(
      screen.getByText(
        "Approval is required in System Settings > General > Login Items."
      )
    ).toBeInTheDocument();

    await user.click(launchAtLogin);
    expect(update).not.toHaveBeenCalled();
    expect(
      screen.getByText(
        "Approval is required in System Settings > General > Login Items."
      )
    ).toBeInTheDocument();

    preferences = appPreferencesSchema.parse({
      launchAtLogin: true,
      launchAtLoginStatus: "enabled",
      revision: 1,
      showInDock: true,
      showInMenuBar: true,
    });
    window.dispatchEvent(new Event("focus"));

    await flush();
    expect(launchAtLogin).toBeChecked();
    expect(
      screen.queryByText(
        "Approval is required in System Settings > General > Login Items."
      )
    ).not.toBeInTheDocument();
  });

  it("disables unsupported native preferences on Linux", async () => {
    installNativeBridgeMock({
      os: "linux",
      platform: "electron",
    });
    renderSettings();

    await flush();
    expect(
      screen.getByRole("switch", { name: "Launch Comma at login" })
    ).toBeDisabled();
    expect(screen.getByRole("switch", { name: "Show in system tray" })).toBeEnabled();
    // The Dock, like AirDrop reception, exists only on macOS: no row to disable.
    expect(
      screen.queryByRole("switch", { name: "Show in dock" })
    ).not.toBeInTheDocument();
    expect(
      screen.queryByRole("switch", { name: "Show Comma in AirDrop" })
    ).not.toBeInTheDocument();
  });

  it("enables Windows preferences and refreshes external login-item changes", async () => {
    let preferences = appPreferencesSchema.parse({
      launchAtLogin: true,
      showInDock: true,
      showInMenuBar: true,
    });
    installNativeBridgeMock({
      appPreferences: {
        state: createNativeStateBridgeMock(() => preferences),
      },
      os: "windows",
      platform: "electron",
    });
    renderSettings();

    const launchAtLogin = screen.getByRole("switch", {
      name: "Launch Comma at login",
    });
    await flush();
    expect(launchAtLogin).toBeEnabled();
    expect(launchAtLogin).toBeChecked();
    expect(screen.getByRole("switch", { name: "Show in system tray" })).toBeEnabled();
    expect(
      screen.queryByRole("switch", { name: "Show in dock" })
    ).not.toBeInTheDocument();
    expect(
      screen.queryByRole("switch", { name: "Keep awake with lid closed" })
    ).not.toBeInTheDocument();

    preferences = appPreferencesSchema.parse({
      launchAtLogin: false,
      revision: 1,
      showInDock: true,
      showInMenuBar: true,
    });
    window.dispatchEvent(new Event("focus"));
    await flush();
    expect(launchAtLogin).not.toBeChecked();

    // Windows has no recorder notch to hide.
    await user.click(screen.getByRole("button", { name: "Meeting" }));
    expect(
      screen.queryByRole("switch", { name: /Hide recorder notch/ })
    ).not.toBeInTheDocument();
  });

  it("does not let a delayed update acknowledgement roll back a newer event", async () => {
    const initial = appPreferencesSchema.parse({
      launchAtLogin: false,
      revision: 0,
      showInDock: true,
      showInMenuBar: true,
    });
    // Every subscriber gets each event.
    const listeners = new Set<(snapshot: AppPreferences) => void>();
    const publish = (snapshot: AppPreferences) => {
      for (const listener of listeners) listener(snapshot);
    };
    const get = vi.fn(async () => initial);
    const state = Object.assign(get, {
      get,
      subscribe: vi.fn((listener: (snapshot: AppPreferences) => void) => {
        listeners.add(listener);
        void get().then(listener);
        return () => listeners.delete(listener);
      }),
    }) as unknown as NativeStateBridge<AppPreferences>;
    let resolveUpdate!: (snapshot: AppPreferences) => void;
    const update = vi.fn(
      () =>
        new Promise<AppPreferences>((resolve) => {
          resolveUpdate = resolve;
        })
    );
    installNativeBridgeMock({
      appPreferences: { state, update },
      os: "macos",
      platform: "electron",
    });
    renderSettings();

    await flush();
    const showInDock = screen.getByRole("switch", { name: "Show in dock" });
    const showInMenuBar = screen.getByRole("switch", { name: "Show in menu bar" });
    await flush();
    expect(showInDock).toBeEnabled();
    await user.click(showInDock);

    publish(
      appPreferencesSchema.parse({
        launchAtLogin: false,
        revision: 2,
        showInDock: false,
        showInMenuBar: false,
      })
    );
    await flush();
    expect(showInMenuBar).not.toBeChecked();

    resolveUpdate(
      appPreferencesSchema.parse({
        launchAtLogin: false,
        revision: 1,
        showInDock: false,
        showInMenuBar: true,
      })
    );

    await flush();
    expect(showInDock).toBeEnabled();
    expect(showInDock).not.toBeChecked();
    expect(showInMenuBar).not.toBeChecked();
  });

  it("shows Open Comma's default and clears it from its editor", async () => {
    renderSettings();
    await user.click(screen.getByRole("button", { name: "Keyboard shortcuts" }));
    await flush();
    const shortcut = screen.getByRole("button", { name: "Open Comma: Alt + ," });
    expect(shortcut).toBeEnabled();
    await user.click(shortcut);
    const clear = screen.getByRole("button", { name: "Clear shortcut" });
    expect(clear).toBeVisible();
    await user.click(clear);
    await flush();
    expect(readStoredClientSettings().openCommaShortcut).toBeNull();
    expect(screen.getByRole("button", { name: "Open Comma: Not set" })).toBeEnabled();
  });

  it("does not reserve the native Open Comma shortcut on the web", async () => {
    installNativeBridgeMock({ platform: "web" });
    renderSettings();

    await user.click(screen.getByRole("button", { name: "Keyboard shortcuts" }));
    await flush();
    const appShortcut = screen.getByRole("button", {
      name: /Toggle left sidebar: (?:Command|Control) \+ B/,
    });
    await user.click(appShortcut);
    await user.keyboard("{Alt>}[Comma]{/Alt}");

    expect(
      screen.getByRole("button", { name: /^Toggle left sidebar: (?:Alt|Option) \+ ,$/ })
    ).toBeInTheDocument();
    expect(
      screen.queryByText("This shortcut is already used by another command.")
    ).not.toBeInTheDocument();
  });
});
