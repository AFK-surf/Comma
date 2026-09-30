import userEvent from "@testing-library/user-event";
import { initializeCommaI18n } from "@comma/i18n";
import {
  appPreferencesSchema,
  defaultCommaClientSettings,
  type AppPreferences,
  type AppPreferencesPatch,
  type NativeStateBridge,
  type SideChatShortcut,
} from "@comma/native-bridge";
import { act, render, screen, waitFor, within } from "@comma/test-utils/render";
import {
  createNativeStateBridgeMock,
  installNativeBridgeMock,
} from "@comma/test-utils/native-bridge";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createCommaApi, type CommaApiSessionTransport } from "../api";
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
import { CommaSideChatShortcutProvider } from "../components/commaSideChatShortcut";
import { legacyCommaSideChatShortcutStorageKey } from "../components/readLegacyCommaClientSettings";
import { CommaAppShortcutsProvider } from "../components/shortcuts/commaAppShortcuts";
import type { AppShortcutPlatform } from "../components/shortcuts/appShortcutRegistry";

// jsdom cannot decode or encode images; the browser path is covered by the
// profile-settings Playwright spec.
const preparedAvatar = new File(["prepared"], "avatar.webp", { type: "image/webp" });
const { prepareProfileAvatar } = vi.hoisted(() => ({
  prepareProfileAvatar: vi.fn(),
}));
vi.mock("../components/profileAvatarImage", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../components/profileAvatarImage")>()),
  prepareProfileAvatar,
}));

const telegramSettings = () => within(screen.getByRole("region", { name: "Telegram" }));

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
    api: createCommaApi({
      baseUrl: "https://api.example",
      sessionTransport,
      token: "",
    }),
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

const renderSettings = (
  auth = defaultAuth(),
  appShortcutPlatform?: AppShortcutPlatform
) =>
  render(
    <CommaWebClientSettingsProvider>
      <CommaClientSettingsI18nProvider>
        <CommaAuthContext.Provider value={auth}>
          <CommaAppearanceProvider>
            <CommaSideChatShortcutProvider>
              <CommaAppShortcutsProvider
                {...(appShortcutPlatform ? { platform: appShortcutPlatform } : {})}
              >
                <AppSettingsRoute />
              </CommaAppShortcutsProvider>
            </CommaSideChatShortcutProvider>
          </CommaAppearanceProvider>
        </CommaAuthContext.Provider>
      </CommaClientSettingsI18nProvider>
    </CommaWebClientSettingsProvider>
  );

const renderProfileSettings = (auth: CommaAuthContextValue) => renderSettings(auth);

// Only the Electron owner reports a client-settings write as pending; the web
// provider stores locally and is never in flight.
const renderElectronSettings = (auth = defaultAuth()) =>
  render(
    <CommaElectronClientSettingsProvider>
      <CommaClientSettingsI18nProvider>
        <CommaAuthContext.Provider value={auth}>
          <CommaAppearanceProvider>
            <CommaSideChatShortcutProvider>
              <CommaAppShortcutsProvider>
                <AppSettingsRoute />
              </CommaAppShortcutsProvider>
            </CommaSideChatShortcutProvider>
          </CommaAppearanceProvider>
        </CommaAuthContext.Provider>
      </CommaClientSettingsI18nProvider>
    </CommaElectronClientSettingsProvider>
  );

const readStoredClientSettings = () =>
  JSON.parse(localStorage.getItem(commaClientSettingsStorageKey)!);

function installWorkspaceList(workspaceIds: readonly string[]) {
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL) => {
      const url = new URL(input.toString(), "https://api.example");
      if (url.pathname !== "/v1/comma/workspaces") {
        throw new Error(`Unexpected request: ${url.pathname}`);
      }
      return new Response(
        JSON.stringify({
          data: workspaceIds.map((id, index) => ({
            group_id: `grp-${index + 1}`,
            id,
            name: `Workspace ${index + 1}`,
          })),
        }),
        { headers: { "content-type": "application/json" }, status: 200 }
      );
    })
  );
}

describe("AppSettingsRoute", () => {
  beforeEach(() => {
    installWorkspaceList(["wsp_default"]);
    installNativeBridgeMock({
      platform: "electron",
      sideChat: {
        updateShortcut: vi.fn(async (shortcut) => shortcut),
      },
    });
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    initializeCommaI18n(["en"]);
    localStorage.clear();
  });

  it("persists Meeting controls with Reminder, visible recorder and Smart summary defaults", async () => {
    const user = userEvent.setup();
    renderSettings();
    await user.click(screen.getByRole("button", { name: "Meeting" }));
    expect(screen.getByRole("button", { name: /^Reminder/ })).toBeInTheDocument();
    const hide = screen.getByRole("switch", { name: /Hide recorder notch/ });
    const summary = screen.getByRole("switch", { name: /Smart summary/ });
    expect(hide).not.toBeChecked();
    expect(summary).toBeChecked();
    await user.click(hide);
    await user.click(summary);
    await waitFor(() =>
      expect(readStoredClientSettings()).toMatchObject({
        meetingStartRecording: "reminder",
        meetingHideRecorder: true,
        meetingSmartSummary: false,
      })
    );
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
      sideChat: { updateShortcut: vi.fn(async (shortcut) => shortcut) },
    });
    renderElectronSettings();
    await userEvent.click(screen.getByRole("button", { name: "Meeting" }));

    const start = screen.getByRole("button", { name: /^Reminder/ });
    const hide = screen.getByRole("switch", { name: /Hide recorder notch/ });
    const summary = screen.getByRole("switch", { name: /Smart summary/ });
    await userEvent.click(hide);

    // One write in flight gates the whole section, not just the control that
    // started it: the owner serialises client-settings writes.
    await waitFor(() => expect(hide).toBeDisabled());
    expect(summary).toBeDisabled();
    expect(start).toBeDisabled();

    release?.();
    await waitFor(() => expect(hide).toBeEnabled());
    expect(summary).toBeEnabled();
    expect(start).toBeEnabled();
  });
  it("finishes recommendation loading and renders callable plugin sources", async () => {
    const recommendationRequests: AbortSignal[] = [];
    const abortedBeforeResponse: boolean[] = [];

    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
        const url = new URL(input.toString(), "https://api.example");

        if (url.pathname === "/v1/comma/workspaces") {
          return new Response(
            JSON.stringify({
              data: [{ group_id: "grp-1", id: "ws-1", name: "Workspace" }],
            }),
            { headers: { "content-type": "application/json" }, status: 200 }
          );
        }

        if (url.pathname === "/v1/comma/workspaces/ws-1/recommendations") {
          if (init?.signal) recommendationRequests.push(init.signal);
          await new Promise((resolve) => window.setTimeout(resolve, 10));
          if (init?.signal?.aborted) {
            throw new DOMException("Aborted", "AbortError");
          }
          abortedBeforeResponse.push(false);

          return new Response(
            JSON.stringify({
              settings: {
                autoEnableNewSources: true,
                schedule: {
                  enabled: true,
                  hour: 8,
                  minute: 0,
                  timezone: "Etc/UTC",
                },
                sourcesCheckedAt: "2026-08-14T09:08:01Z",
                sourceRevision: 1,
                sources: [
                  {
                    appId: "github",
                    appName: "GitHub",
                    connectionId: "mpb-1",
                    enabled: true,
                    kind: "managed_oauth",
                    label: "github",
                  },
                ],
              },
              snapshot: null,
              state: "empty",
            }),
            { headers: { "content-type": "application/json" }, status: 200 }
          );
        }

        throw new Error(`Unexpected request: ${url.pathname}`);
      })
    );

    renderSettings();
    await userEvent.click(screen.getByRole("button", { name: "Routines" }));

    expect(await screen.findByText("GitHub")).toBeInTheDocument();
    expect(screen.getByText("Work activity from GitHub.")).toBeInTheDocument();
    expect(recommendationRequests).toHaveLength(1);
    expect(abortedBeforeResponse).toEqual([false]);
    expect(screen.getByRole("switch", { name: "GitHub" })).toBeEnabled();
  });

  it("opens the category named by the settings deep link", async () => {
    const previousHash = window.location.hash;
    window.location.hash = "#/settings?category=recommendations";
    try {
      renderSettings();

      // The Routines menu links here; Settings must land on Routines
      // rather than its default General category.
      expect(
        await screen.findByRole("heading", { level: 2, name: "Daily schedule" })
      ).toBeInTheDocument();
    } finally {
      window.location.hash = previousHash;
    }
  });

  it("loads and saves recommendations against the persisted active workspace", async () => {
    localStorage.setItem("comma.activeWorkspaceId", "ws-2");
    const recommendationRequests: Array<{ method: string; path: string }> = [];
    let savedSettings: unknown;

    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
        const url = new URL(input.toString(), "https://api.example");
        const method = init?.method ?? "GET";

        if (url.pathname === "/v1/comma/workspaces") {
          return new Response(
            JSON.stringify({
              data: [
                { group_id: "grp-1", id: "ws-1", name: "First workspace" },
                { group_id: "grp-2", id: "ws-2", name: "Active workspace" },
              ],
            }),
            { headers: { "content-type": "application/json" }, status: 200 }
          );
        }

        if (
          url.pathname === "/v1/comma/workspaces/ws-2/recommendations" ||
          url.pathname === "/v1/comma/workspaces/ws-2/recommendations/settings"
        ) {
          recommendationRequests.push({ method, path: url.pathname });
          if (method === "PATCH" && typeof init?.body === "string") {
            savedSettings = JSON.parse(init.body);
          }
          return new Response(
            JSON.stringify({
              settings: {
                autoEnableNewSources: true,
                schedule: {
                  enabled: true,
                  hour: 8,
                  minute: 0,
                  timezone: "Etc/UTC",
                },
                sourcesCheckedAt: "2026-08-18T00:00:00Z",
                sourceRevision: 1,
                sources: [
                  {
                    appId: "github",
                    appName: "GitHub",
                    connectionId: "mpb-1",
                    enabled: method === "GET",
                    kind: "composio",
                    label: "github",
                  },
                ],
              },
              snapshot: null,
              state: "empty",
            }),
            { headers: { "content-type": "application/json" }, status: 200 }
          );
        }

        throw new Error(`Unexpected request: ${method} ${url.pathname}`);
      })
    );

    renderSettings();
    await userEvent.click(screen.getByRole("button", { name: "Routines" }));
    const source = await screen.findByRole("switch", { name: "GitHub" });
    await userEvent.click(source);

    await waitFor(() =>
      expect(recommendationRequests).toEqual([
        { method: "GET", path: "/v1/comma/workspaces/ws-2/recommendations" },
        { method: "PATCH", path: "/v1/comma/workspaces/ws-2/recommendations/settings" },
      ])
    );
    // A source toggle writes that one flag beside the unchanged schedule; it
    // never echoes the whole source list or the read-only projection fields.
    expect(savedSettings).toEqual({
      autoEnableNewSources: true,
      schedule: { enabled: true, hour: 8, minute: 0, timezone: "Etc/UTC" },
      sources: [{ connectionId: "mpb-1", enabled: false }],
    });
  });

  it("connects Telegram only through official login without exposing codes", async () => {
    const openExternal = vi.fn(async () => ({ ok: true as const }));
    const writeText = vi.fn(async () => ({ ok: true as const }));
    installNativeBridgeMock({
      clipboard: { writeText },
      platform: "electron",
      shell: { openExternal },
      sideChat: {
        updateShortcut: vi.fn(async (shortcut) => shortcut),
      },
    });
    const requests: Array<{ method: string; path: string }> = [];

    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
        const url = new URL(input.toString(), "https://api.example");
        const method = init?.method ?? "GET";
        requests.push({ method, path: url.pathname });

        if (url.pathname === "/v1/comma/workspaces") {
          return new Response(
            JSON.stringify({
              data: [{ group_id: "grp-1", id: "ws-1", name: "Main" }],
            }),
            { headers: { "content-type": "application/json" }, status: 200 }
          );
        }

        if (
          url.pathname === "/v1/comma/workspaces/ws-1/integrations/telegram" &&
          method === "GET"
        ) {
          return new Response(
            JSON.stringify({
              bot_url: "https://t.me/CommaTestBot",
              bot_username: "CommaTestBot",
              configured: true,
              link: null,
              official_login_available: true,
              pending_claim: null,
              workspace_id: "ws-1",
              workspace_name: "Main",
            }),
            { headers: { "content-type": "application/json" }, status: 200 }
          );
        }

        if (url.pathname.endsWith("/connect") && method === "POST") {
          return new Response(
            JSON.stringify({
              authorization_url: "https://oauth.telegram.org/auth?state=test",
              expires_in_seconds: 600,
              workspace_id: "ws-1",
            }),
            { headers: { "content-type": "application/json" }, status: 200 }
          );
        }

        throw new Error(`Unexpected request: ${method} ${url.pathname}`);
      })
    );

    renderSettings();
    await userEvent.click(screen.getByRole("button", { name: "Channels" }));
    expect(await screen.findByRole("region", { name: "Telegram" })).toBeInTheDocument();

    expect(
      screen.queryByRole("button", { name: "Generate code" })
    ).not.toBeInTheDocument();
    expect(screen.queryByText("Comma workspace")).not.toBeInTheDocument();
    expect(screen.queryByText("Main")).not.toBeInTheDocument();
    expect(
      document.querySelector('[data-provider-logo="telegram"]')
    ).toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "Disconnect" })
    ).not.toBeInTheDocument();
    expect(screen.queryByText("Connect with /link")).not.toBeInTheDocument();
    await userEvent.click(
      await screen.findByRole("button", { name: "Open in Telegram (@CommaTestBot)" })
    );
    expect(openExternal).toHaveBeenCalledWith({ url: "https://t.me/CommaTestBot" });
    openExternal.mockClear();
    await userEvent.click(telegramSettings().getByRole("button", { name: "Connect" }));
    await waitFor(() =>
      expect(openExternal).toHaveBeenCalledWith({
        url: "https://oauth.telegram.org/auth?state=test",
      })
    );
    expect(requests.some((request) => request.path.endsWith("/claim-code"))).toBe(
      false
    );
    expect(writeText).not.toHaveBeenCalled();
  });

  it.each([0, 2])(
    "does not choose a Telegram target when the account has %i workspaces",
    async (count) => {
      const requests: string[] = [];
      vi.stubGlobal(
        "fetch",
        vi.fn(async (input: RequestInfo | URL) => {
          const path = new URL(input.toString(), "https://api.example").pathname;
          requests.push(path);
          if (path === "/v1/comma/workspaces") {
            return new Response(
              JSON.stringify({
                data: Array.from({ length: count }, (_, index) => ({
                  group_id: `grp-${index}`,
                  id: `ws-${index}`,
                  name: `Workspace ${index}`,
                })),
              }),
              { headers: { "content-type": "application/json" }, status: 200 }
            );
          }
          throw new Error(`Unexpected request: ${path}`);
        })
      );
      renderSettings();
      await userEvent.click(screen.getByRole("button", { name: "Channels" }));
      await waitFor(() => expect(requests).toContain("/v1/comma/workspaces"));
      expect(
        telegramSettings().getByRole("button", { name: "Connect" })
      ).toBeDisabled();
      expect(requests.some((path) => path.includes("/integrations/telegram"))).toBe(
        false
      );
      expect(screen.queryByText("Comma workspace")).not.toBeInTheDocument();
    }
  );

  it.each([true, false])(
    "shows a completed Telegram OIDC reconnect from active=%s without reloading Settings",
    async (active) => {
      const openExternal = vi.fn(async () => ({ ok: true as const }));
      installNativeBridgeMock({
        platform: "electron",
        shell: { openExternal },
        sideChat: {
          updateShortcut: vi.fn(async (shortcut) => shortcut),
        },
      });
      let connectStarted = false;
      let postConnectReads = 0;

      vi.stubGlobal(
        "fetch",
        vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
          const url = new URL(input.toString(), "https://api.example");
          const method = init?.method ?? "GET";

          if (url.pathname === "/v1/comma/workspaces") {
            return new Response(
              JSON.stringify({
                data: [{ group_id: "grp-1", id: "ws-1", name: "Main" }],
              }),
              { headers: { "content-type": "application/json" }, status: 200 }
            );
          }

          if (url.pathname.endsWith("/connect") && method === "POST") {
            connectStarted = true;
            return new Response(
              JSON.stringify({
                authorization_url: "https://oauth.telegram.org/auth?state=reconnect",
                expires_in_seconds: 600,
                workspace_id: "ws-1",
              }),
              { headers: { "content-type": "application/json" }, status: 200 }
            );
          }

          if (
            url.pathname === "/v1/comma/workspaces/ws-1/integrations/telegram" &&
            method === "GET"
          ) {
            if (connectStarted) postConnectReads += 1;
            const reconnected = postConnectReads >= 2;
            return new Response(
              JSON.stringify({
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
              }),
              { headers: { "content-type": "application/json" }, status: 200 }
            );
          }

          throw new Error(`Unexpected request: ${method} ${url.pathname}`);
        })
      );

      renderSettings();
      await userEvent.click(screen.getByRole("button", { name: "Channels" }));
      await screen.findByText("@ada");
      await telegramSettings().findByText(active ? "Connected" : "Needs attention");
      const settingsSearch = screen.getByRole("searchbox", { name: "Search settings" });
      await userEvent.type(settingsSearch, "Disconnect");
      expect(
        document.querySelector('[data-slot="settings-search-results"]')
      ).toHaveTextContent("Telegram");
      await userEvent.clear(settingsSearch);

      await userEvent.click(telegramSettings().getByRole("button", { name: "Manage" }));
      await userEvent.click(screen.getByRole("menuitem", { name: "Reconnect" }));
      expect(openExternal).not.toHaveBeenCalled();
      await userEvent.click(screen.getByRole("button", { name: "Cancel" }));
      expect(openExternal).not.toHaveBeenCalled();
      await userEvent.click(telegramSettings().getByRole("button", { name: "Manage" }));
      await userEvent.click(screen.getByRole("menuitem", { name: "Reconnect" }));
      await userEvent.click(screen.getByRole("button", { name: "Reconnect" }));

      expect(
        await screen.findByText("@grace", {}, { timeout: 3_000 })
      ).toBeInTheDocument();
      expect(telegramSettings().getByRole("button", { name: "Manage" })).toBeEnabled();
      expect(postConnectReads).toBeGreaterThanOrEqual(2);
      expect(telegramSettings().getByText("Connected")).toBeInTheDocument();
    }
  );

  it("edits the signed-in user's name directly from the Profile settings item", async () => {
    const publishProfile = vi.fn();
    const sessionController = new AbortController();
    const requests: Array<{ method: string; path: string; body?: string }> = [];

    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
        const url = new URL(input.toString(), "https://api.example");
        const method = init?.method ?? "GET";
        requests.push({
          method,
          path: url.pathname,
          ...(typeof init?.body === "string" ? { body: init.body } : {}),
        });
        const name = method === "PATCH" ? "Ada Lovelace" : "Ada";
        return new Response(
          JSON.stringify({
            avatar_id: null,
            email: "ada@example.com",
            id: "usr_ada",
            name,
          }),
          { headers: { "content-type": "application/json" }, status: 200 }
        );
      })
    );

    const sessionTransport = testSessionTransport(sessionController.signal);
    renderProfileSettings({
      api: createCommaApi({
        baseUrl: "https://api.example",
        sessionTransport,
        token: "",
      }),
      apiBaseUrl: "https://api.example",
      authenticated: true,
      productLease: {
        audience: "https://api.example",
        authorityInstanceId: "test-authority",
        generation: 1,
        sessionId: "session-1",
      },
      publishProfile,
      sessionSignal: sessionController.signal,
      sessionTransport,
      signOut: vi.fn(),
      userDisplayName: "Ada",
      userEmail: "ada@example.com",
    });

    await userEvent.click(screen.getByRole("button", { name: "Profile" }));
    const editName = await screen.findByRole("button", {
      name: "Edit name: Ada",
    });
    expect(screen.queryByRole("textbox", { name: "Name" })).not.toBeInTheDocument();
    expect(screen.queryByRole("dialog", { name: "Name" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Manage" })).not.toBeInTheDocument();
    expect(screen.getByText("Avatar")).toBeInTheDocument();
    await userEvent.click(editName);
    expect(screen.getByRole("dialog", { name: "Name" })).toBeInTheDocument();
    const name = screen.getByRole("textbox", { name: "Name" });
    // The field spans the dialog instead of falling back to the input's own width.
    const nameField = name.closest("div.flex-col");
    expect(nameField).toHaveClass("w-full");
    expect(nameField).not.toHaveClass("w-80");
    await userEvent.clear(name);
    await userEvent.type(name, "Ada Lovelace");
    await userEvent.click(screen.getByRole("button", { name: "Save" }));

    expect(requests).toContainEqual({
      body: JSON.stringify({ name: "Ada Lovelace" }),
      method: "PATCH",
      path: "/v1/comma/me/profile",
    });
    expect(publishProfile).toHaveBeenCalledWith({
      avatar_id: null,
      email: "ada@example.com",
      id: "usr_ada",
      name: "Ada Lovelace",
    });
    expect(screen.queryByRole("dialog", { name: "Name" })).not.toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: "Edit name: Ada Lovelace" })
    ).toBeInTheDocument();
    expect(requests.filter(({ method }) => method === "GET")).toHaveLength(1);
  });

  it("uploads an avatar directly from the Profile settings item", async () => {
    const publishProfile = vi.fn();
    const inputClick = vi.spyOn(HTMLInputElement.prototype, "click");
    const requests: Array<{ body?: BodyInit | null; method: string; path: string }> =
      [];

    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
        const url = new URL(input.toString(), "https://api.example");
        const method = init?.method ?? "GET";
        requests.push({
          method,
          path: url.pathname,
          ...(init?.body !== undefined ? { body: init.body } : {}),
        });
        if (method === "GET" && url.pathname.startsWith("/v1/comma/me/avatar/")) {
          return new Response("existing-avatar", {
            headers: { "content-type": "image/png" },
            status: 200,
          });
        }
        return new Response(
          JSON.stringify({
            avatar_id: method === "PUT" ? "avt_ada" : "avt_existing",
            email: "ada@example.com",
            id: "usr_ada",
            name: "Ada",
          }),
          { headers: { "content-type": "application/json" }, status: 200 }
        );
      })
    );

    renderProfileSettings({ ...defaultAuth(), publishProfile });

    await userEvent.click(screen.getByRole("button", { name: "Profile" }));
    const avatarButton = await screen.findByRole("button", {
      name: "Choose image",
    });
    expect(avatarButton.querySelector(".comma-user-avatar")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Remove" })).not.toBeInTheDocument();
    await userEvent.click(avatarButton);
    expect(inputClick).toHaveBeenCalledOnce();

    const fileInput = await screen.findByLabelText("Choose image", {
      selector: 'input[type="file"]',
    });
    const avatar = new File(["avatar"], "avatar.png", { type: "image/png" });
    prepareProfileAvatar.mockResolvedValueOnce(preparedAvatar);
    await userEvent.upload(fileInput, avatar);

    await waitFor(() =>
      expect(requests).toEqual(
        expect.arrayContaining([
          expect.objectContaining({ method: "PUT", path: "/v1/comma/me/avatar" }),
        ])
      )
    );
    const upload = requests.find(({ method }) => method === "PUT");
    if (!(upload?.body instanceof FormData)) {
      throw new Error("Expected avatar upload multipart form data");
    }
    expect(prepareProfileAvatar).toHaveBeenCalledWith(avatar);
    expect(upload.body.get("avatar")).toBe(preparedAvatar);
    expect(publishProfile).toHaveBeenCalledWith({
      avatar_id: "avt_ada",
      email: "ada@example.com",
      id: "usr_ada",
      name: "Ada",
    });
    expect(screen.queryByRole("dialog", { name: "Name" })).not.toBeInTheDocument();
  });

  it("signs out from the Profile account section", async () => {
    const signOut = vi.fn();
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(
            JSON.stringify({
              avatar_id: null,
              email: "ada@example.com",
              id: "usr_ada",
              name: "Ada",
            }),
            { headers: { "content-type": "application/json" }, status: 200 }
          )
      )
    );

    renderProfileSettings({ ...defaultAuth(), signOut });

    await userEvent.click(screen.getByRole("button", { name: "Profile" }));

    expect(
      await screen.findByText("Sign out of Comma on this device.")
    ).toBeInTheDocument();
    // Settings lives inside the shell now: there is no "Back to app" link.
    expect(screen.queryByRole("link", { name: "Back to app" })).not.toBeInTheDocument();
    expect(signOut).not.toHaveBeenCalled();

    await userEvent.click(screen.getByRole("button", { name: "Sign out" }));

    expect(signOut).toHaveBeenCalledOnce();
  });

  it("uses SettingsPanel to switch and persist the display language", async () => {
    renderSettings();

    expect(
      screen.getByRole("heading", { level: 1, name: "General" })
    ).toBeInTheDocument();
    expect(screen.getByText("Language for the app UI")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /Select language/ })).toHaveTextContent(
      "Auto detect"
    );

    await userEvent.click(screen.getByRole("button", { name: /Select language/ }));
    await userEvent.click(screen.getByRole("option", { name: "Simplified Chinese" }));

    expect(screen.getByRole("heading", { level: 1, name: "通用" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /选择语言/ })).toHaveTextContent(
      "简体中文"
    );
    expect(readStoredClientSettings().localePreference).toBe("zh-CN");
    expect(document.documentElement.lang).toBe("zh-CN");
  });

  it("applies and persists every Appearance control", async () => {
    // Main lists the installed families; Appearance reads them on entry.
    installNativeBridgeMock({
      appearance: {
        fontFamilies: vi.fn(async () => ({ families: ["Avenir Next", "Georgia"] })),
      },
      platform: "electron",
    });
    const firstRender = renderSettings();

    await userEvent.click(screen.getByRole("button", { name: "Appearance" }));
    const themeTrigger = screen.getByRole("button", { name: /Select theme/ });
    expect(themeTrigger).toHaveTextContent("Default");
    expect(themeTrigger.querySelector('[data-slot="theme-swatch"]')).not.toBeNull();
    await userEvent.click(themeTrigger);
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
    expect(screen.getByRole("option", { name: "Default" })).toBeInTheDocument();
    expect(screen.getByRole("option", { name: "Soft Light" })).toBeInTheDocument();
    expect(screen.getByRole("option", { name: "Signal Light" })).toBeInTheDocument();
    expect(screen.queryByRole("option", { name: /^Light$/ })).not.toBeInTheDocument();
    expect(screen.queryByRole("option", { name: "Paper" })).not.toBeInTheDocument();
    expect(screen.queryByRole("option", { name: "Auto" })).not.toBeInTheDocument();
    expect(screen.queryByRole("option", { name: "Twilight" })).not.toBeInTheDocument();
    expect(screen.queryByRole("option", { name: "Ink" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Edit" })).not.toBeInTheDocument();
    await userEvent.click(screen.getByRole("option", { name: "Dark" }));
    expect(document.documentElement.dataset.theme).toBe("Dark mode");

    const fontTrigger = screen.getByRole("button", { name: /Select font$/ });
    expect(fontTrigger).toHaveTextContent("Default");
    await userEvent.click(fontTrigger);
    // Each family previews its own face.
    expect(
      (await screen.findAllByRole("option")).map((option) => option.textContent)
    ).toEqual(["Default", "Avenir Next", "Georgia"]);
    expect(
      screen
        .getByRole("option", { name: "Georgia" })
        .querySelector<HTMLElement>('[data-slot="dropdown-option-label"]')?.style
        .fontFamily
    ).toMatch(/^"Georgia", /);
    await userEvent.click(screen.getByRole("option", { name: "Georgia" }));
    expect(document.documentElement.dataset.commaFontFamily).toBe("Georgia");
    expect(document.documentElement.style.getPropertyValue("--font-sans")).toMatch(
      /^"Georgia", 'Inter Variable'/
    );
    await userEvent.click(fontTrigger);
    await userEvent.click(screen.getByRole("option", { name: "Default" }));
    expect(document.documentElement.dataset.commaFontFamily).toBeUndefined();
    expect(document.documentElement.style.getPropertyValue("--font-sans")).toBe("");
    await userEvent.click(fontTrigger);
    await userEvent.click(screen.getByRole("option", { name: "Avenir Next" }));

    await userEvent.click(screen.getByRole("button", { name: /Select font size/ }));
    await userEvent.click(screen.getByRole("option", { name: "Large" }));
    expect(document.documentElement.dataset.commaFontSize).toBe("large");

    const pointerCursors = screen.getByRole("switch", {
      name: "Use pointer cursors",
    });
    await userEvent.click(pointerCursors);
    expect(pointerCursors).toBeChecked();
    expect(document.documentElement.dataset.commaPointerCursors).toBe("true");
    const reduceMotion = screen.getByRole("switch", { name: "Reduce motion" });
    await userEvent.click(reduceMotion);
    expect(reduceMotion).toBeChecked();
    expect(document.documentElement.dataset.commaReducedMotion).toBe("true");
    expect(readStoredClientSettings().appearance).toEqual({
      theme: "dark",
      customHue: 263,
      customChroma: defaultCommaAppearancePreferences.customChroma,
      customLightness: defaultCommaAppearancePreferences.customLightness,
      customScheme: "system",
      fontFamily: "Avenir Next",
      fontSize: "large",
      pointerCursors: true,
      reducedMotion: true,
    });

    firstRender.unmount();
    renderSettings();
    await userEvent.click(screen.getByRole("button", { name: "Appearance" }));

    expect(screen.getByRole("button", { name: /Select theme/ })).toHaveTextContent(
      "Dark"
    );
    expect(screen.getByRole("button", { name: /Select font$/ })).toHaveTextContent(
      "Avenir Next"
    );
    expect(screen.getByRole("button", { name: /Select font size/ })).toHaveTextContent(
      "Large"
    );
    expect(screen.getByRole("switch", { name: "Use pointer cursors" })).toBeChecked();
    expect(screen.getByRole("switch", { name: "Reduce motion" })).toBeChecked();
  });

  it("applies Signal Dark from the theme dropdown", async () => {
    renderSettings();

    await userEvent.click(screen.getByRole("button", { name: "Appearance" }));
    await userEvent.click(screen.getByRole("button", { name: /Select theme/ }));
    const darkSwatch = screen
      .getByRole("option", { name: "Dark" })
      .querySelector('[data-slot="theme-swatch"]');
    const signalSwatch = screen
      .getByRole("option", { name: "Signal Dark" })
      .querySelector('[data-slot="theme-swatch"]');
    expect(darkSwatch).not.toBeNull();
    expect(signalSwatch).not.toBeNull();
    expect(signalSwatch).toHaveClass("comma-theme-swatch");
    expect(
      (signalSwatch as HTMLElement).style.getPropertyValue("--comma-theme-h")
    ).not.toBe((darkSwatch as HTMLElement).style.getPropertyValue("--comma-theme-h"));
    await userEvent.click(screen.getByRole("option", { name: "Signal Dark" }));

    const triggerSwatch = screen
      .getByRole("button", { name: /Select theme/ })
      .querySelector('[data-slot="theme-swatch"]');
    expect(
      (triggerSwatch as HTMLElement).style.getPropertyValue("--comma-theme-h")
    ).toBe((signalSwatch as HTMLElement).style.getPropertyValue("--comma-theme-h"));

    expect(document.documentElement.dataset.theme).toBe("Dark mode");
    expect(document.documentElement.dataset.commaTheme).toBe("signal-dark");
    expect(readStoredClientSettings().appearance).toMatchObject({
      theme: "signal-dark",
      customHue: 263,
      customChroma: defaultCommaAppearancePreferences.customChroma,
      customLightness: defaultCommaAppearancePreferences.customLightness,
      customScheme: "system",
    });
  });

  it("persists Soft Light across remount", async () => {
    const firstRender = renderSettings();

    await userEvent.click(screen.getByRole("button", { name: "Appearance" }));
    await userEvent.click(screen.getByRole("button", { name: /Select theme/ }));
    await userEvent.click(screen.getByRole("option", { name: "Soft Light" }));

    expect(document.documentElement.dataset.theme).toBe("Light mode");
    expect(document.documentElement.dataset.commaTheme).toBe("light");
    expect(readStoredClientSettings().appearance).toMatchObject({
      theme: "light",
    });

    firstRender.unmount();
    renderSettings();
    await userEvent.click(screen.getByRole("button", { name: "Appearance" }));
    expect(screen.getByRole("button", { name: /Select theme/ })).toHaveTextContent(
      "Soft Light"
    );
    expect(document.documentElement.dataset.commaTheme).toBe("light");
  });

  it("opens a custom theme menu popover with a pad and presets, not a centered dialog", async () => {
    renderSettings();

    await userEvent.click(screen.getByRole("button", { name: "Appearance" }));
    await userEvent.click(screen.getByRole("button", { name: /Select theme/ }));
    await userEvent.click(screen.getByRole("option", { name: "Custom" }));

    expect(screen.getByRole("dialog", { name: "Custom" })).toBeInTheDocument();
    expect(document.querySelector('[data-slot="menu-popover"]')).not.toBeNull();
    expect(document.querySelector('[data-slot="menu-popover"]')).not.toHaveAttribute(
      "data-positioning",
      "selection-aligned"
    );
    expect(screen.getByRole("button", { name: /Select theme/ })).not.toHaveClass(
      "opacity-0"
    );
    expect(
      screen.queryByRole("button", { name: "Close dialog" })
    ).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Edit" })).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Back to themes" })).toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: "Custom" })).not.toBeInTheDocument();
    expect(
      screen.getByText(
        "Drag any indicator to move the color. The other two follow on their own planes."
      )
    ).toBeInTheDocument();
    const pad = screen.getByRole("group", { name: "Hue, chroma, and lightness pad" });
    expect(pad).toHaveClass("comma-custom-theme-studio__canvas");
    expect(screen.getByRole("slider", { name: "Hue" })).toBeInTheDocument();
    expect(screen.getByRole("slider", { name: "Chroma" })).toBeInTheDocument();
    expect(screen.getByRole("slider", { name: "Lightness" })).toBeInTheDocument();
    expect(document.querySelector(".comma-custom-theme-studio__dial")).toBeNull();
    expect(document.querySelector(".comma-custom-theme-studio__wave")).toBeNull();
    expect(screen.queryByRole("option", { name: "Auto" })).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Auto" })).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: "Auto" }).querySelector("[data-comma-icon]")
    ).toBeNull();
    expect(
      screen
        .getByRole("button", { name: /Select theme/ })
        .querySelector('[data-slot="theme-swatch"]')
    ).not.toBeNull();

    screen.getByRole("slider", { name: "Lightness" }).focus();
    await userEvent.keyboard("{ArrowUp}");
    expect(
      Number.parseFloat(
        document.documentElement.style.getPropertyValue("--comma-theme-l")
      )
    ).toBeGreaterThan(defaultCommaAppearancePreferences.customLightness);
    expect(screen.getByRole("slider", { name: "Lightness" })).toHaveAttribute(
      "aria-valuenow",
      String(
        Math.round(
          (Number.parseFloat(
            document.documentElement.style.getPropertyValue("--comma-theme-l")
          ) || 0) * 100
        )
      )
    );

    await userEvent.click(screen.getByRole("button", { name: "Hue 263°" }));
    expect(document.documentElement.style.getPropertyValue("--comma-theme-h")).toBe(
      "263deg"
    );
    expect(
      (
        screen
          .getByRole("button", { name: /Select theme/ })
          .querySelector('[data-slot="theme-swatch"]') as HTMLElement | null
      )?.style.getPropertyValue("--comma-theme-h")
    ).toBe("263deg");

    const studio = pad.closest("[data-slot='custom-theme-studio']");
    expect(studio).not.toBeNull();
    expect(screen.getByRole("button", { name: "Auto" })).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Dark", pressed: false }));
    expect(document.documentElement.dataset.theme).toBe("Dark mode");
    expect(document.documentElement.dataset.commaTheme).toBe("custom");
    await userEvent.click(screen.getByRole("button", { name: "Auto" }));
    expect(readStoredClientSettings().appearance).toMatchObject({
      theme: "custom",
      customScheme: "system",
    });

    await userEvent.keyboard("{Escape}");
    expect(screen.queryByRole("dialog", { name: "Custom" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Edit" })).not.toBeInTheDocument();
    expect(document.querySelector("[data-slot='dropdown-popover']")).toBeNull();
    await userEvent.click(screen.getByRole("button", { name: /Select theme/ }));
    expect(screen.getByRole("dialog", { name: "Custom" })).toBeInTheDocument();
    expect(
      screen.getByRole("group", { name: "Hue, chroma, and lightness pad" })
    ).toBeInTheDocument();
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

    await userEvent.click(screen.getByRole("button", { name: "Appearance" }));
    await userEvent.click(screen.getByRole("button", { name: /Select theme/ }));

    const popover = document.querySelector("[data-slot='menu-popover']");
    expect(popover).toHaveClass("z-50", "[-webkit-app-region:no-drag]");
    expect(screen.getByRole("dialog", { name: "Custom" })).toBeInTheDocument();
    expect(screen.queryByRole("option", { name: "Auto" })).not.toBeInTheDocument();
    const backButton = screen.getByRole("button", { name: "Back to themes" });
    expect(backButton).toHaveFocus();
    await userEvent.keyboard("{Enter}");
    await waitFor(() => {
      expect(screen.queryByRole("dialog", { name: "Custom" })).not.toBeInTheDocument();
      expect(document.querySelector("[data-slot='menu-popover']")).toBeNull();
    });
    expect(document.querySelector("[data-slot='dropdown-popover']")).not.toBeNull();
    const customOption = screen.getByRole("option", { name: "Custom" });
    expect(customOption).toHaveFocus();
    const defaultOption = screen.getByRole("option", { name: "Default" });
    expect(defaultOption).toBeInTheDocument();
    expect(screen.queryByRole("option", { name: "Twilight" })).not.toBeInTheDocument();
    expect(screen.queryByRole("option", { name: "Ink" })).not.toBeInTheDocument();
    await userEvent.click(defaultOption);

    expect(document.documentElement.dataset.commaTheme).toBe("default");
    expect(screen.getByRole("button", { name: /Select theme/ })).toHaveTextContent(
      "Default"
    );
    expect(readStoredClientSettings().appearance).toEqual(
      defaultCommaAppearancePreferences
    );
  });

  it("records and persists the global Side Chat shortcut", async () => {
    const firstRender = renderSettings();

    await userEvent.click(screen.getByRole("button", { name: "Keyboard shortcuts" }));
    const shortcut = await screen.findByRole("button", {
      name: "Open Side Chat: Ctrl + Z",
    });
    expect(shortcut).toBeEnabled();
    await userEvent.click(shortcut);
    await userEvent.keyboard("{Control>}l{/Control}");

    expect(
      screen.getByRole("button", { name: "Open Side Chat: Ctrl + L" })
    ).toBeInTheDocument();
    expect(readStoredClientSettings().sideChatShortcut).toEqual({
      key: "l",
      modifiers: {
        alt: false,
        control: true,
        meta: false,
        shift: false,
      },
    });

    firstRender.unmount();
    renderSettings();
    await userEvent.click(screen.getByRole("button", { name: "Keyboard shortcuts" }));
    expect(
      screen.getByRole("button", { name: "Open Side Chat: Ctrl + L" })
    ).toBeInTheDocument();
  });

  it("customizes general shortcuts and can reset them to defaults", async () => {
    const firstRender = renderSettings();

    await userEvent.click(screen.getByRole("button", { name: "Keyboard shortcuts" }));
    expect(
      screen.getByRole("heading", { level: 2, name: "Navigation" })
    ).toBeInTheDocument();
    const inboxShortcut = await screen.findByRole("button", {
      name: "Go to Inbox: G then I",
    });
    await waitFor(() => expect(inboxShortcut).toBeEnabled());
    await userEvent.click(inboxShortcut);
    await userEvent.keyboard("gx");

    expect(
      await screen.findByRole(
        "button",
        { name: "Go to Inbox: G then X" },
        { timeout: 2_000 }
      )
    ).toBeInTheDocument();
    expect(readStoredClientSettings().appShortcutOverrides).toEqual({
      "go-inbox": { kind: "sequence", codes: ["KeyG", "KeyX"] },
    });

    const reset = screen.getByRole("button", { name: "Reset all to defaults" });
    expect(reset).toBeEnabled();
    await userEvent.click(reset);
    expect(readStoredClientSettings().appShortcutOverrides).toEqual({});
    expect(
      screen.getByRole("button", { name: "Go to Inbox: G then I" })
    ).toBeInTheDocument();
    expect(reset).toBeDisabled();

    firstRender.unmount();
    renderSettings();
    await userEvent.click(screen.getByRole("button", { name: "Keyboard shortcuts" }));
    expect(
      screen.getByRole("button", { name: "Go to Inbox: G then I" })
    ).toBeInTheDocument();
  });

  it("clears one app shortcut instead of restoring its default", async () => {
    const firstRender = renderSettings();

    await userEvent.click(screen.getByRole("button", { name: "Keyboard shortcuts" }));
    const toggleSidebar = await screen.findByRole("button", {
      name: /Toggle left sidebar: (?:Command|Control) \+ B/,
    });
    await waitFor(() => expect(toggleSidebar).toBeEnabled());
    await userEvent.click(toggleSidebar);
    await userEvent.click(screen.getByRole("button", { name: "Clear shortcut" }));

    expect(
      screen.getByRole("button", { name: "Toggle left sidebar: Not set" })
    ).toBeInTheDocument();
    expect(readStoredClientSettings().appShortcutOverrides).toEqual({
      "toggle-left-sidebar": null,
    });

    firstRender.unmount();
    renderSettings();
    await userEvent.click(screen.getByRole("button", { name: "Keyboard shortcuts" }));
    expect(
      screen.getByRole("button", { name: "Toggle left sidebar: Not set" })
    ).toBeInTheDocument();
  });

  it("rejects app and Side Chat collisions in both editing directions", async () => {
    const updateShortcut = vi.fn(async (shortcut) => shortcut);
    installNativeBridgeMock({
      platform: "electron",
      sideChat: { updateShortcut },
    });
    renderSettings();

    await userEvent.click(screen.getByRole("button", { name: "Keyboard shortcuts" }));
    const appShortcut = await screen.findByRole("button", {
      name: /Toggle left sidebar: (?:Command|Control) \+ B/,
    });
    const appUsesCommand = appShortcut.getAttribute("aria-label")?.includes("Command");
    await waitFor(() => expect(appShortcut).toBeEnabled());
    await userEvent.click(appShortcut);
    await userEvent.keyboard("{Control>}z{/Control}");

    expect(
      screen.getByRole("button", {
        name: /Toggle left sidebar: (?:Command|Control) \+ B/,
      })
    ).toBeInTheDocument();
    expect(
      await screen.findByText("This shortcut is already used by another command.")
    ).toHaveAttribute("role", "alert");

    const sideChatShortcut = screen.getByRole("button", {
      name: "Open Side Chat: Ctrl + Z",
    });
    await userEvent.click(sideChatShortcut);
    await userEvent.keyboard(
      appUsesCommand ? "{Meta>}b{/Meta}" : "{Control>}b{/Control}"
    );

    expect(
      screen.getByRole("button", { name: "Open Side Chat: Ctrl + Z" })
    ).toBeInTheDocument();
    expect(updateShortcut).toHaveBeenCalledOnce();
    expect(
      screen.getAllByText("This shortcut is already used by another command.")
    ).toHaveLength(2);
  });

  it("clears a stale app conflict after the conflicting binding is removed", async () => {
    renderSettings();

    await userEvent.click(screen.getByRole("button", { name: "Keyboard shortcuts" }));
    const inboxShortcut = await screen.findByRole("button", {
      name: "Go to Inbox: G then I",
    });
    await waitFor(() => expect(inboxShortcut).toBeEnabled());
    await userEvent.click(inboxShortcut);
    await userEvent.keyboard("gx");
    const customizedInbox = await screen.findByRole(
      "button",
      { name: "Go to Inbox: G then X" },
      { timeout: 2_000 }
    );
    await waitFor(() =>
      expect(readStoredClientSettings().appShortcutOverrides).toEqual({
        "go-inbox": { kind: "sequence", codes: ["KeyG", "KeyX"] },
      })
    );

    const pluginsShortcut = await screen.findByRole("button", {
      name: "Go to Plugin: G then P",
    });
    await userEvent.click(pluginsShortcut);
    await userEvent.keyboard("gxx");
    expect(
      await screen.findByText("This shortcut is already used by another command.")
    ).toHaveAttribute("role", "alert");

    await userEvent.click(customizedInbox);
    await userEvent.click(screen.getByRole("button", { name: "Clear shortcut" }));

    expect(
      screen.queryByText("This shortcut is already used by another command.")
    ).not.toBeInTheDocument();
  });

  it("blocks app binding edits while a Side Chat shortcut is registering", async () => {
    let resolveShortcut!: (shortcut: SideChatShortcut) => void;
    const updateShortcut = vi
      .fn()
      .mockResolvedValueOnce({
        key: "z",
        modifiers: {
          alt: false,
          control: true,
          meta: false,
          shift: false,
        },
      })
      .mockImplementationOnce(
        () =>
          new Promise<SideChatShortcut>((resolve) => {
            resolveShortcut = resolve;
          })
      );
    installNativeBridgeMock({
      platform: "electron",
      sideChat: { updateShortcut },
    });
    renderSettings();

    await userEvent.click(screen.getByRole("button", { name: "Keyboard shortcuts" }));
    const sideChatShortcut = await screen.findByRole("button", {
      name: "Open Side Chat: Ctrl + Z",
    });
    await waitFor(() => expect(sideChatShortcut).toBeEnabled());
    await userEvent.click(sideChatShortcut);
    await userEvent.keyboard("{Control>}x{/Control}");

    const appShortcut = screen.getByRole("button", {
      name: /Toggle left sidebar: (?:Command|Control) \+ B/,
    });
    await waitFor(() => expect(appShortcut).toBeDisabled());

    resolveShortcut({
      key: "x",
      modifiers: {
        alt: false,
        control: true,
        meta: false,
        shift: false,
      },
    });
    await waitFor(() => expect(appShortcut).toBeEnabled());
    expect(
      screen.getByRole("button", { name: "Open Side Chat: Ctrl + X" })
    ).toBeInTheDocument();
  });

  it("preserves a pre-existing Side Chat shortcut and disables its colliding app default", async () => {
    localStorage.setItem(
      legacyCommaSideChatShortcutStorageKey,
      JSON.stringify({
        key: "b",
        modifiers: {
          alt: false,
          control: false,
          meta: true,
          shift: false,
        },
      })
    );

    renderSettings(defaultAuth(), "macos");
    await userEvent.click(screen.getByRole("button", { name: "Keyboard shortcuts" }));

    const sideChatShortcut = await screen.findByRole("button", {
      name: "Open Side Chat: Cmd + B",
    });
    await waitFor(() => expect(sideChatShortcut).toBeEnabled());
    expect(
      await screen.findByRole("button", {
        name: "Toggle left sidebar: Not set",
      })
    ).toBeInTheDocument();
    expect(readStoredClientSettings().appShortcutOverrides).toEqual({
      "toggle-left-sidebar": null,
    });
    expect(readStoredClientSettings().sideChatShortcut).toEqual({
      key: "b",
      modifiers: {
        alt: false,
        control: false,
        meta: true,
        shift: false,
      },
    });
  });

  it("keeps an app binding when a colliding stored Side Chat shortcut is rejected", async () => {
    localStorage.setItem(
      legacyCommaSideChatShortcutStorageKey,
      JSON.stringify({
        key: "b",
        modifiers: {
          alt: false,
          control: false,
          meta: true,
          shift: false,
        },
      })
    );
    installNativeBridgeMock({
      platform: "electron",
      sideChat: {
        updateShortcut: vi.fn().mockRejectedValueOnce(new Error("Unavailable")),
      },
    });

    renderSettings(defaultAuth(), "macos");
    await userEvent.click(screen.getByRole("button", { name: "Keyboard shortcuts" }));

    expect(
      await screen.findByRole("button", { name: "Open Side Chat: Ctrl + Z" })
    ).toBeEnabled();
    expect(
      screen.getByRole("button", {
        name: /Toggle left sidebar: (?:Command|Windows|Super) \+ B/,
      })
    ).toBeEnabled();
    expect(readStoredClientSettings().appShortcutOverrides).toEqual({});
    expect(readStoredClientSettings().sideChatShortcut).toEqual(
      defaultCommaClientSettings.sideChatShortcut
    );
  });

  it("keeps unavailable settings controls disabled", async () => {
    renderSettings();

    await userEvent.click(screen.getByRole("button", { name: "Computer use" }));
    expect(screen.getByRole("button", { name: "Manage permissions" })).toBeDisabled();
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
    await userEvent.click(screen.getByRole("button", { name: "Computer use" }));
    await waitFor(() => expect(screen.getAllByText("Not granted")).toHaveLength(2));
    getPermissions.mockResolvedValue({
      ok: true,
      permissions: { accessibility: true, screenRecording: true },
    });
    await userEvent.click(screen.getByRole("button", { name: "Manage permissions" }));
    await waitFor(() => expect(screen.getAllByText("Granted")).toHaveLength(2));
    expect(openPermissionFlow).toHaveBeenCalledOnce();
    getPermissions.mockResolvedValue({ ok: false, error: "Helper unavailable" });
    await userEvent.click(screen.getByRole("button", { name: "Refresh status" }));
    await screen.findByText("Helper unavailable");
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
    await userEvent.click(screen.getByRole("button", { name: "Computer use" }));
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
    await userEvent.click(screen.getByRole("button", { name: "General" }));
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
    await waitFor(() => expect(launchAtLogin).toBeEnabled());
    expect(launchAtLogin).not.toBeChecked();
    expect(showInMenuBar).toBeChecked();
    expect(showInDock).toBeChecked();
    // Existing preference files predate AirDrop; Comma stays visible by default.
    expect(showInAirDrop).toBeChecked();

    await userEvent.click(launchAtLogin);
    await waitFor(() => expect(launchAtLogin).toBeChecked());
    await userEvent.click(showInMenuBar);
    await waitFor(() => expect(showInMenuBar).not.toBeChecked());
    await userEvent.click(showInDock);
    await waitFor(() => expect(showInDock).not.toBeChecked());
    await userEvent.click(showInAirDrop);
    await waitFor(() => expect(showInAirDrop).not.toBeChecked());

    expect(update.mock.calls.map(([patch]) => patch)).toEqual([
      { launchAtLogin: true },
      { showInMenuBar: false },
      { showInDock: false },
      { showInAirDrop: false },
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
    const edit = await screen.findByRole("button", {
      name: "Edit AirDrop name: Ada’s Comma",
    });
    await waitFor(() => expect(edit).toBeEnabled());
    await userEvent.click(edit);
    const field = screen.getByRole("textbox", { name: "AirDrop name" });
    expect(field).toHaveValue("Ada’s Comma");
    await userEvent.clear(field);
    await userEvent.type(field, "Studio Mac{Enter}");
    const renamed = await screen.findByRole("button", {
      name: "Edit AirDrop name: Studio Mac",
    });

    await waitFor(() => expect(renamed).toBeEnabled());
    await userEvent.click(renamed);
    await userEvent.clear(screen.getByRole("textbox", { name: "AirDrop name" }));
    await userEvent.click(screen.getByRole("button", { name: "Save" }));
    await screen.findByRole("button", { name: "Edit AirDrop name: Ada’s Comma" });

    // Hidden from AirDrop, Comma has no name to edit.
    const showInAirDrop = screen.getByRole("switch", { name: "Show Comma in AirDrop" });
    await waitFor(() => expect(showInAirDrop).toBeEnabled());
    await userEvent.click(showInAirDrop);
    await waitFor(() =>
      expect(screen.queryByRole("button", { name: /^Edit AirDrop name/ })).toBeNull()
    );
    expect(update.mock.calls.map(([patch]) => patch)).toEqual([
      { airDropName: "Studio Mac" },
      { airDropName: null },
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
    await waitFor(() => expect(showInNotch).toBeChecked());
    const width = screen.getByRole("slider", { name: "Notch width" });
    expect(width).toHaveAttribute("aria-valuenow", "156");

    // The preview follows each key at once; Main hears only where it stops.
    width.focus();
    await userEvent.keyboard("{ArrowRight}{ArrowRight}");
    expect(width).toHaveAttribute("aria-valuenow", "164");
    expect(update).not.toHaveBeenCalled();
    await waitFor(() => expect(update).toHaveBeenCalledWith({ notchSideWidth: 164 }));
    expect(screen.getByRole("button", { name: "Reset" })).toBeEnabled();

    // The real Notch shows that width once, with the preview's sample Task.
    await userEvent.click(screen.getByRole("button", { name: "Preview on notch" }));
    expect(bridge.notch.preview).toHaveBeenCalledWith({
      sideWidth: 164,
      title: "Summarize this week’s meetings",
    });

    await waitFor(() => expect(showInNotch).toBeEnabled());
    await userEvent.click(showInNotch);
    await waitFor(() => expect(showInNotch).not.toBeChecked());
    await waitFor(() =>
      expect(screen.queryByRole("slider", { name: "Notch width" })).toBeNull()
    );
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
    await userEvent.click(screen.getByRole("button", { name: "Notifications" }));

    const routerMessages = screen.getByRole("switch", {
      name: "Router message notifications",
    });
    const sound = screen.getByRole("switch", { name: "Notification sound" });
    await waitFor(() => expect(routerMessages).toBeEnabled());
    expect(routerMessages).toBeChecked();
    expect(sound).toBeChecked();

    await userEvent.click(sound);
    await waitFor(() => expect(sound).not.toBeChecked());

    // Turning Router notifications off leaves no notification to sound.
    await userEvent.click(routerMessages);
    await waitFor(() => expect(sound).toBeDisabled());

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
    await userEvent.click(screen.getByRole("button", { name: "Notifications" }));

    const system = screen.getByRole("switch", { name: "System notifications" });
    const routerMessages = screen.getByRole("switch", {
      name: "Router message notifications",
    });
    const sound = screen.getByRole("switch", { name: "Notification sound" });
    await waitFor(() => expect(system).toBeEnabled());
    expect(system).toBeChecked();
    expect(
      screen.getByText("Comma sends system notifications to remind you.")
    ).toBeInTheDocument();

    // The master switch is the only one that stays interactive once it is
    // off; the Router choices keep their stored values for when it returns.
    await userEvent.click(system);
    await waitFor(() => expect(system).not.toBeChecked());
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
    await userEvent.click(screen.getByRole("button", { name: "Notifications" }));

    const system = screen.getByRole("switch", { name: "System notifications" });
    await waitFor(() =>
      expect(
        screen.getByText(
          "Notifications for Comma are turned off in System Settings. Allow them there to turn this on."
        )
      ).toBeInTheDocument()
    );
    // Stored as on, but the OS has the final say: nothing can be delivered,
    // so the switch shows off until the user turns it on and allows Comma.
    expect(system).toBeEnabled();
    expect(system).not.toBeChecked();
    expect(
      screen.getByRole("switch", { name: "Router message notifications" })
    ).toBeDisabled();
    expect(screen.getByRole("switch", { name: "Notification sound" })).toBeDisabled();

    await userEvent.click(system);
    const dialog = await screen.findByRole("dialog", {
      name: "Allow notifications in System Settings",
    });
    expect(system).toBeChecked();
    expect(
      screen.getByText(
        "Notifications for Comma are turned off in System Settings. Open System Settings, then allow notifications for Comma."
      )
    ).toBeInTheDocument();

    await userEvent.click(screen.getByRole("button", { name: "Open System Settings" }));
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
    await userEvent.click(screen.getByRole("button", { name: "Notifications" }));

    const system = screen.getByRole("switch", { name: "System notifications" });
    await waitFor(() => expect(system).toBeEnabled());
    await userEvent.click(system);
    await screen.findByRole("dialog", {
      name: "Allow notifications in System Settings",
    });
    expect(update.mock.calls.map(([patch]) => patch)).toEqual([
      { systemNotifications: true },
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
    await userEvent.click(screen.getByRole("button", { name: "Notifications" }));

    const preview = screen.getByRole("button", { name: "Play sample" });
    await waitFor(() =>
      expect(screen.getByRole("switch", { name: "Notification sound" })).toBeDisabled()
    );

    // The sample is how you decide whether to turn the sound on, so it stays
    // reachable while the toggle it belongs to is disabled.
    expect(preview).toBeEnabled();
    await userEvent.click(preview);
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
    await waitFor(() => expect(launchAtLogin).toBeEnabled());

    await userEvent.click(showInMenuBar);

    // A native write in flight gates all three, not just the one clicked. The
    // pending flag covers writes from any Main window, which is how concurrent
    // preference updates are serialised across windows.
    await waitFor(() => expect(showInMenuBar).toBeDisabled());
    expect(launchAtLogin).toBeDisabled();
    expect(showInDock).toBeDisabled();

    release?.();
    await waitFor(() => expect(showInMenuBar).toBeEnabled());
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
    await waitFor(() => expect(launchAtLogin).toBeDisabled());
    expect(launchAtLogin).not.toBeChecked();
    expect(
      screen.getByText(
        "Approval is required in System Settings > General > Login Items."
      )
    ).toBeInTheDocument();

    await userEvent.click(launchAtLogin);
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

    await waitFor(() => expect(launchAtLogin).toBeChecked());
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

    expect(
      await screen.findByRole("switch", { name: "Launch Comma at login" })
    ).toBeDisabled();
    expect(screen.getByRole("switch", { name: "Show in system tray" })).toBeEnabled();
    expect(screen.getByRole("switch", { name: "Show in dock" })).toBeDisabled();
    // AirDrop reception exists only on macOS, so there is nothing to disable.
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
    await waitFor(() => expect(launchAtLogin).toBeEnabled());
    expect(launchAtLogin).toBeChecked();
    expect(screen.getByRole("switch", { name: "Show in system tray" })).toBeEnabled();
    expect(screen.getByRole("switch", { name: "Show in dock" })).toBeDisabled();

    preferences = appPreferencesSchema.parse({
      launchAtLogin: false,
      revision: 1,
      showInDock: true,
      showInMenuBar: true,
    });
    window.dispatchEvent(new Event("focus"));
    await waitFor(() => expect(launchAtLogin).not.toBeChecked());
  });

  it("does not let a delayed update acknowledgement roll back a newer event", async () => {
    const initial = appPreferencesSchema.parse({
      launchAtLogin: false,
      revision: 0,
      showInDock: true,
      showInMenuBar: true,
    });
    let publish: ((snapshot: AppPreferences) => void) | undefined;
    const get = vi.fn(async () => initial);
    const state = Object.assign(get, {
      get,
      subscribe: vi.fn((listener: (snapshot: AppPreferences) => void) => {
        publish = listener;
        void get().then(listener);
        return () => {};
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

    const showInDock = await screen.findByRole("switch", { name: "Show in dock" });
    const showInMenuBar = screen.getByRole("switch", { name: "Show in menu bar" });
    await waitFor(() => expect(showInDock).toBeEnabled());
    await userEvent.click(showInDock);

    publish!(
      appPreferencesSchema.parse({
        launchAtLogin: false,
        revision: 2,
        showInDock: false,
        showInMenuBar: false,
      })
    );
    await waitFor(() => expect(showInMenuBar).not.toBeChecked());

    resolveUpdate(
      appPreferencesSchema.parse({
        launchAtLogin: false,
        revision: 1,
        showInDock: false,
        showInMenuBar: true,
      })
    );

    await waitFor(() => expect(showInDock).toBeEnabled());
    expect(showInDock).not.toBeChecked();
    expect(showInMenuBar).not.toBeChecked();
  });

  it("shows Open Comma's default and clears Side Chat from its active editor", async () => {
    const updateShortcut = vi.fn(async (shortcut) => shortcut);
    installNativeBridgeMock({ platform: "electron", sideChat: { updateShortcut } });
    renderSettings();
    await userEvent.click(screen.getByRole("button", { name: "Keyboard shortcuts" }));
    expect(
      await screen.findByRole("button", { name: "Open Comma: Alt + Space" })
    ).toBeEnabled();
    const shortcut = await screen.findByRole("button", {
      name: "Open Side Chat: Ctrl + Z",
    });
    await waitFor(() => expect(shortcut).toBeEnabled());
    await userEvent.click(shortcut);
    const clear = screen.getByRole("button", { name: "Clear shortcut" });
    expect(clear).toBeVisible();
    await userEvent.click(clear);
    await waitFor(() => expect(updateShortcut).toHaveBeenLastCalledWith(null));
    await waitFor(() => expect(readStoredClientSettings().sideChatShortcut).toBeNull());
    expect(
      screen.getByRole("button", { name: "Open Side Chat: Not set" })
    ).toBeEnabled();
  });

  it("persists only acknowledged shortcuts and reports native rejection", async () => {
    const updateShortcut = vi
      .fn()
      .mockResolvedValueOnce({
        key: "z",
        modifiers: {
          alt: false,
          control: true,
          meta: false,
          shift: false,
        },
      })
      .mockRejectedValueOnce(new Error("Shortcut unavailable"));
    installNativeBridgeMock({
      platform: "electron",
      sideChat: { updateShortcut },
    });
    renderSettings();

    await userEvent.click(screen.getByRole("button", { name: "Keyboard shortcuts" }));
    const shortcut = await screen.findByRole("button", {
      name: "Open Side Chat: Ctrl + Z",
    });
    expect(shortcut).toBeEnabled();
    await userEvent.click(shortcut);
    await userEvent.keyboard("{Control>}l{/Control}");

    expect(
      await screen.findByText(
        "Couldn’t register this shortcut. The previous shortcut is still active."
      )
    ).toHaveAttribute("role", "alert");
    expect(
      screen.getByRole("button", { name: "Open Side Chat: Ctrl + Z" })
    ).toBeEnabled();
    expect(readStoredClientSettings().sideChatShortcut).toEqual(
      defaultCommaClientSettings.sideChatShortcut
    );
  });

  it("does not expose the native Side Chat shortcut on the web", async () => {
    installNativeBridgeMock({ platform: "web" });
    renderSettings();

    await userEvent.click(screen.getByRole("button", { name: "Keyboard shortcuts" }));
    expect(
      screen.queryByRole("button", { name: /Open Side Chat:/ })
    ).not.toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "General" }));
    expect(
      screen.getByRole("switch", { name: "Launch Comma at login" })
    ).toBeDisabled();
    expect(screen.getByRole("switch", { name: "Show in menu bar" })).toBeDisabled();
    expect(screen.getByRole("switch", { name: "Show in dock" })).toBeDisabled();
  });

  it("does not reserve the native Side Chat shortcut on the web", async () => {
    installNativeBridgeMock({ platform: "web" });
    renderSettings();

    await userEvent.click(screen.getByRole("button", { name: "Keyboard shortcuts" }));
    const appShortcut = await screen.findByRole("button", {
      name: /Toggle left sidebar: (?:Command|Control) \+ B/,
    });
    await userEvent.click(appShortcut);
    await userEvent.keyboard("{Control>}z{/Control}");

    expect(
      screen.getByRole("button", { name: "Toggle left sidebar: Control + Z" })
    ).toBeInTheDocument();
    expect(
      screen.queryByText("This shortcut is already used by another command.")
    ).not.toBeInTheDocument();
  });
});
