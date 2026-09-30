import userEvent from "@testing-library/user-event";
import { CommaI18nProvider } from "@comma/i18n/react";
import { render, screen, waitFor } from "@comma/test-utils/render";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createCommaApi, type CommaApiSessionTransport } from "../api";
import {
  CommaAuthContext,
  type CommaAuthContextValue,
} from "../components/auth-context";
import { CommaAppearanceProvider } from "../components/commaAppearance";
import { CommaWebClientSettingsProvider } from "../components/commaClientSettings";
import { CommaSideChatShortcutProvider } from "../components/commaSideChatShortcut";
import { CommaAppShortcutsProvider } from "../components/shortcuts/commaAppShortcuts";
import { RecommendationMockDebugSettingsRoute } from "../devtools/recommendation-mock/RecommendationMockDebugSettingsRoute";

const auth = (audience = "http://127.0.0.1:4200"): CommaAuthContextValue => {
  const sessionController = new AbortController();
  const sessionTransport: CommaApiSessionTransport = {
    applyHeaders: (headers) => {
      headers["x-comma-session"] = "test-session";
    },
    credentials: "include",
    reportSessionRejection: vi.fn(),
    signal: sessionController.signal,
  };
  return {
    api: createCommaApi({
      baseUrl: "https://api.example",
      sessionTransport,
      token: "",
    }),
    apiBaseUrl: "https://api.example",
    authenticated: true,
    productLease: {
      audience,
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

const renderRoute = (audience?: string) =>
  render(
    <CommaWebClientSettingsProvider>
      <CommaAuthContext.Provider value={auth(audience)}>
        <CommaAppearanceProvider>
          <CommaSideChatShortcutProvider>
            <CommaAppShortcutsProvider>
              <CommaI18nProvider>
                <RecommendationMockDebugSettingsRoute />
              </CommaI18nProvider>
            </CommaAppShortcutsProvider>
          </CommaSideChatShortcutProvider>
        </CommaAppearanceProvider>
      </CommaAuthContext.Provider>
    </CommaWebClientSettingsProvider>
  );

describe("RecommendationMockDebugSettingsRoute", () => {
  beforeEach(() => {
    installNativeBridgeMock({
      platform: "electron",
      sideChat: { updateShortcut: vi.fn(async (shortcut) => shortcut) },
    });
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("keeps remote-backend settings usable without probing the local mock endpoint", async () => {
    const fetch = vi.fn(async () => new Response("unauthorized", { status: 401 }));
    vi.stubGlobal("fetch", fetch);

    renderRoute("https://salix-staging.comma.surf");
    await userEvent.click(screen.getByRole("button", { name: "Debug" }));
    expect(
      screen.getByRole("switch", { name: "Show Session history" })
    ).toBeInTheDocument();
    expect(
      screen.queryByRole("switch", { name: "Use local routine mock" })
    ).not.toBeInTheDocument();
    expect(fetch).not.toHaveBeenCalled();
  });

  it("adds the dev-only mock controls to the shared Debug category and toggles the backend mock live", async () => {
    const requests: Array<{ body?: unknown; method: string; url: string }> = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL, init: RequestInit = {}) => {
        const url = String(input);
        const body = typeof init.body === "string" ? JSON.parse(init.body) : undefined;
        requests.push({ body, method: init.method ?? "GET", url });

        if (url.endsWith("/v1/comma/workspaces")) {
          return new Response(
            JSON.stringify({
              data: [{ group_id: "grp-1", id: "wsp-1", name: "Comma" }],
            }),
            {
              headers: { "content-type": "application/json" },
              status: 200,
            }
          );
        }

        return new Response(
          JSON.stringify({ available: true, enabled: body?.enabled ?? false }),
          { headers: { "content-type": "application/json" }, status: 200 }
        );
      })
    );

    renderRoute();
    expect(screen.getAllByRole("button", { name: "Debug" })).toHaveLength(1);
    await userEvent.click(screen.getByRole("button", { name: "Debug" }));
    expect(
      screen.getByRole("switch", { name: "Show Session history" })
    ).not.toBeChecked();

    const toggle = await screen.findByRole("switch", {
      name: "Use local routine mock",
    });
    await waitFor(() => expect(toggle).toBeEnabled());
    await userEvent.click(toggle);

    await waitFor(() =>
      expect(requests).toEqual([
        {
          body: undefined,
          method: "GET",
          url: "https://api.example/v1/debug/recommendation-mock",
        },
        {
          body: undefined,
          method: "GET",
          url: "https://api.example/v1/comma/workspaces",
        },
        {
          body: { enabled: true, workspaceId: "wsp-1" },
          method: "PATCH",
          url: "https://api.example/v1/debug/recommendation-mock",
        },
      ])
    );
    expect(toggle).toBeChecked();
  });
});
