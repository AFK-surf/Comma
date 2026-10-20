import userEvent from "@testing-library/user-event";
import { CommaI18nProvider } from "@comma/i18n/react";
import { render, screen, waitFor } from "@comma/test-utils/render";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { CommaApiSessionTransport } from "../session/controller";
import {
  CommaAuthContext,
  type CommaAuthContextValue,
} from "../components/auth-context";
import { CommaAppearanceProvider } from "../components/commaAppearance";
import { CommaWebClientSettingsProvider } from "../components/commaClientSettings";
import { RouterIdentityProvider } from "../components/router-identity/RouterIdentityProvider";
import { CommaAppShortcutsProvider } from "../components/shortcuts/commaAppShortcuts";
import { RecommendationMockDebugSettingsRoute } from "../devtools/recommendation-mock/RecommendationMockDebugSettingsRoute";

const auth = (audience = "http://127.0.0.1"): CommaAuthContextValue => {
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

const renderRoute = (core: ReturnType<typeof createScriptedCore>, audience?: string) =>
  render(
    core.wrap(
      <CommaWebClientSettingsProvider>
        <CommaAuthContext.Provider value={auth(audience)}>
          <RouterIdentityProvider>
            <CommaAppearanceProvider>
              <CommaAppShortcutsProvider>
                <CommaI18nProvider>
                  <RecommendationMockDebugSettingsRoute />
                </CommaI18nProvider>
              </CommaAppShortcutsProvider>
            </CommaAppearanceProvider>
          </RouterIdentityProvider>
        </CommaAuthContext.Provider>
      </CommaWebClientSettingsProvider>
    )
  );

describe("RecommendationMockDebugSettingsRoute", () => {
  beforeEach(() => {
    installNativeBridgeMock({ platform: "electron" });
  });

  it("keeps remote-backend settings usable without probing the local mock endpoint", async () => {
    const subscribed: unknown[] = [];
    const core = createScriptedCore({
      owns: (name) => name.startsWith("recommendationMock"),
      onSubscribe: (topic) => subscribed.push(topic.topic),
    });

    renderRoute(core, "https://salix-staging.comma.surf");
    await userEvent.click(screen.getByRole("button", { name: "Debug" }));
    expect(
      screen.getByRole("switch", { name: "Show Session history" })
    ).toBeInTheDocument();
    expect(
      screen.queryByRole("switch", { name: "Use local routine mock" })
    ).not.toBeInTheDocument();
    expect(subscribed).not.toContain("recommendationMock");
    expect(core.sentTo("recommendationMock.set")).toEqual([]);
  });

  it("adds the dev-only mock controls to the shared Debug category and toggles the backend mock live", async () => {
    let status = { available: true, enabled: false };
    const core = createScriptedCore({
      owns: (name) => name.startsWith("recommendationMock"),
      values: (topic) =>
        topic.topic === "recommendationMock"
          ? { status: "ready", ...status }
          : undefined,
      calls: (name, params) => {
        if (name !== "recommendationMock.set") return null;
        status = { available: true, enabled: (params as { enabled: boolean }).enabled };
        core.changed("recommendationMock");
        return status;
      },
    });

    renderRoute(core);
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
      expect(core.sentTo("recommendationMock.set")).toEqual([{ enabled: true }])
    );
    expect(await screen.findByText(/^Local mock enabled\./)).toBeInTheDocument();
    await waitFor(() => expect(toggle).toBeChecked());
  });
});
