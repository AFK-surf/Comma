import { initializeCommaI18n } from "@comma/i18n";
import { CommaI18nProvider } from "@comma/i18n/react";
import {
  defaultAppPreferences,
  defaultCommaClientSettings,
  type AppPreferences,
  type ApplicationMenuCommand,
  type NativeStateBridge,
  type OnboardingWindowState,
} from "@comma/native-bridge";
import type { SessionProductLease } from "@comma/session-contract";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { act, render, screen, waitFor, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import type { ReactNode } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { CommaApiClient } from "../../../api";
import type { AgentModels } from "../../../api/modelCatalog";
import { writeActiveWorkspaceId } from "../../activeWorkspace";
import { useApplicationMenu } from "../../application-menu/useApplicationMenu";
import { CommaAuthContext, type CommaAuthContextValue } from "../../auth-context";
import {
  CommaElectronClientSettingsProvider,
  CommaWebClientSettingsProvider,
  readWebCommaClientSettings,
} from "../../commaClientSettings";
import {
  RouterIdentityProvider,
  useRouterDisplayName,
} from "../../router-identity/RouterIdentityProvider";
import type { OnboardingExperienceProps } from "../OnboardingExperience";
import { OnboardingHost } from "../OnboardingHost";
import { useOnboardingHandoff } from "../onboardingHandoff";

vi.mock("../OnboardingExperience", () => ({
  OnboardingExperience: ({
    onComplete,
    onExited,
    presentation,
  }: OnboardingExperienceProps) => (
    <section aria-label={`Onboarding, ${presentation} presentation`}>
      <button onClick={onComplete} type="button">
        Start chatting
      </button>
      <button onClick={onExited} type="button">
        Exit reveal finished
      </button>
    </section>
  ),
}));

const userId = "usr_1";
const productLease: SessionProductLease = {
  audience: "https://api.comma.test",
  authorityInstanceId: "electron-main",
  generation: 1,
  sessionId: "11111111-1111-4111-8111-111111111111",
};

describe("OnboardingHost", () => {
  beforeEach(() => {
    initializeCommaI18n(["en"]);
    writeActiveWorkspaceId("wsp_home");
  });

  afterEach(() => {
    localStorage.clear();
  });

  it("presents the onboarding window on Electron and stands the product down while it is open", async () => {
    const onboardingWindow = controlledState<OnboardingWindowState>({ open: false });
    const preferences = controlledState<AppPreferences>(appPreferences(1, []));
    const presentWindow = vi.fn(async () => ({ presented: true }));
    const menu = applicationMenuMock();
    const handoff = mainEvent();
    installNativeBridgeMock({
      os: "macos",
      platform: "electron",
      appPreferences: { state: preferences.state },
      applicationMenu: menu.bridge,
      onboarding: {
        onHandoff: handoff.subscribe,
        presentWindow,
        window: onboardingWindow.state,
      },
    });
    let routerName = "Default workspace Router";
    const getAgentModels = vi.fn(async () => agentModels(routerName));

    render(
      <ProductWindow api={{ getAgentModels }}>
        <CommaElectronClientSettingsProvider
          initialPreferences={preferences.state.current()}
        >
          <OnboardingHost userId={userId} />
        </CommaElectronClientSettingsProvider>
      </ProductWindow>
    );

    await waitFor(() => expect(presentWindow).toHaveBeenCalledOnce());
    expect(presentWindow).toHaveBeenCalledWith({ session: productLease });
    await waitFor(() => expect(screen.getByRole("status")).toHaveTextContent("Comma"));
    expect(screen.queryByRole("region", { name: /Onboarding/ })).toBeNull();

    // Main opened the window: the menu commands stand down under it.
    onboardingWindow.publish({ open: true });
    await waitFor(() => expect(menu.lastItems()).toEqual([menu.item(false)]));
    await act(async () => menu.invoke("go-search"));
    expect(menu.openSearch).not.toHaveBeenCalled();

    // The window named the Router, recorded completion, and closed.
    routerName = "Atlas";
    preferences.publish(appPreferences(2, [userId]));
    onboardingWindow.publish({ open: false });

    await waitFor(() => expect(menu.lastItems()).toEqual([menu.item(true)]));
    await act(async () => menu.invoke("go-search"));
    expect(menu.openSearch).toHaveBeenCalledOnce();
    await waitFor(() => expect(screen.getByRole("status")).toHaveTextContent("Atlas"));
    expect(getAgentModels).toHaveBeenCalledTimes(2);
    expect(presentWindow).toHaveBeenCalledOnce();

    // It ended with Start chatting: Main hands the user to Home's composer.
    expect(homeComposer()).not.toHaveFocus();
    handoff.publish();
    expect(homeComposer()).toHaveFocus();

    // The Debug replay forgets the account's completion: the window again.
    preferences.publish(appPreferences(3, []));
    await waitFor(() => expect(presentWindow).toHaveBeenCalledTimes(2));
    expect(screen.queryByRole("region", { name: /Onboarding/ })).toBeNull();
  });

  it("does not present the window again after it closed without recording completion", async () => {
    const onboardingWindow = controlledState<OnboardingWindowState>({ open: false });
    const presentWindow = vi.fn(async () => ({ presented: true }));
    installNativeBridgeMock({
      os: "macos",
      platform: "electron",
      onboarding: { presentWindow, window: onboardingWindow.state },
    });

    render(
      <ProductWindow>
        <CommaWebClientSettingsProvider initialSettings={clientSettings([])}>
          <OnboardingHost userId={userId} />
        </CommaWebClientSettingsProvider>
      </ProductWindow>
    );
    await waitFor(() => expect(presentWindow).toHaveBeenCalledOnce());

    // Its renderer crashed: Main closed it, and nothing recorded completion.
    onboardingWindow.publish({ open: true });
    onboardingWindow.publish({ open: false });
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(presentWindow).toHaveBeenCalledOnce();
    expect(screen.queryByRole("region", { name: /Onboarding/ })).toBeNull();
  });

  it("covers the product with the overlay where Main presents no window", async () => {
    const user = userEvent.setup();
    // The web bridge answers that no window was presented.
    installNativeBridgeMock();

    render(
      <ProductWindow>
        <CommaWebClientSettingsProvider
          initialSettings={clientSettings(["usr_earlier"])}
        >
          <OnboardingHost userId={userId} />
        </CommaWebClientSettingsProvider>
      </ProductWindow>
    );

    const overlay = await screen.findByRole("region", {
      name: "Onboarding, overlay presentation",
    });
    await user.click(within(overlay).getByRole("button", { name: "Start chatting" }));
    await waitFor(() =>
      expect(readWebCommaClientSettings().onboardingCompletedUserIds).toEqual([
        "usr_earlier",
        userId,
      ])
    );
    // It stays through its exit reveal, then leaves for good and hands the
    // user to Home's composer.
    expect(overlay).toBeInTheDocument();
    await user.click(
      within(overlay).getByRole("button", { name: "Exit reveal finished" })
    );
    expect(screen.queryByRole("region", { name: /Onboarding/ })).toBeNull();
    expect(homeComposer()).toHaveFocus();
  });

  it("asks again with the new product lease after Main refused the replaced one", async () => {
    const presentWindow = vi.fn(
      async ({ session }: { session: SessionProductLease }) => {
        if (session.generation === 1) throw new Error("stale product lease");
        return { presented: false };
      }
    );
    installNativeBridgeMock({
      os: "macos",
      platform: "electron",
      onboarding: { presentWindow },
    });
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const view = (lease: SessionProductLease) => (
      <ProductWindow lease={lease}>
        <CommaWebClientSettingsProvider initialSettings={clientSettings([])}>
          <OnboardingHost userId={userId} />
        </CommaWebClientSettingsProvider>
      </ProductWindow>
    );
    const { rerender } = render(view(productLease));
    await waitFor(() => expect(presentWindow).toHaveBeenCalledOnce());

    // The credential settled again: a new generation, the same account.
    rerender(view({ ...productLease, generation: 2 }));

    expect(
      await screen.findByRole("region", { name: "Onboarding, overlay presentation" })
    ).toBeInTheDocument();
    expect(presentWindow).toHaveBeenCalledTimes(2);
    consoleError.mockRestore();
  });
});

/**
 * The main window's signed-in product around the host, with a Router label, a
 * menu command, and Home's composer.
 */
function ProductWindow({
  api = { getAgentModels: async () => agentModels("Default workspace Router") },
  children,
  lease = productLease,
}: {
  api?: Partial<CommaApiClient>;
  children: ReactNode;
  lease?: SessionProductLease;
}) {
  const auth = {
    api,
    productLease: lease,
    userId,
  } as unknown as CommaAuthContextValue;
  return (
    <CommaI18nProvider locale="en">
      <CommaAuthContext.Provider value={auth}>
        <RouterIdentityProvider>
          <RouterLabel />
          <SearchMenuCommand />
          <HomeComposer />
          {children}
        </RouterIdentityProvider>
      </CommaAuthContext.Provider>
    </CommaI18nProvider>
  );
}

function RouterLabel() {
  return <output>{useRouterDisplayName()}</output>;
}

/** Home's composer as far as the hand-off goes: it takes the focus. */
function HomeComposer() {
  useOnboardingHandoff(() => homeComposer().focus());
  return <textarea aria-label="AI prompt" />;
}

const homeComposer = () => screen.getByRole("textbox", { name: "AI prompt" });

/** An event Main sends the main window. */
function mainEvent() {
  const listeners = new Set<(payload: Record<string, never>) => void>();
  return {
    subscribe: (listener: (payload: Record<string, never>) => void) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    publish: () => {
      act(() => {
        for (const listener of listeners) listener({});
      });
    },
  };
}

const openSearch = vi.fn();

function SearchMenuCommand() {
  useApplicationMenu([
    { id: "go-search", enabled: true, accelerator: "Super+K", run: openSearch },
  ]);
  return null;
}

function applicationMenuMock() {
  openSearch.mockClear();
  let listener: ((id: ApplicationMenuCommand) => void) | undefined;
  const update = vi.fn(async (_input: { items: unknown[]; locale: string }) => {});
  return {
    bridge: {
      update,
      onCommand: (next: (id: ApplicationMenuCommand) => void) => {
        listener = next;
        return () => {
          listener = undefined;
        };
      },
    },
    invoke: (id: ApplicationMenuCommand) => listener?.(id),
    item: (enabled: boolean) => ({ id: "go-search", enabled, accelerator: "Super+K" }),
    lastItems: () => update.mock.lastCall?.[0].items,
    openSearch,
  };
}

/** A Main-owned state the test publishes, replayed to each new subscriber. */
function controlledState<Snapshot>(initial: Snapshot) {
  let current = initial;
  const listeners = new Set<(snapshot: Snapshot) => void>();
  const get = vi.fn(async () => current);
  const state = Object.assign(get, {
    current: () => current,
    get,
    subscribe: (listener: (snapshot: Snapshot) => void) => {
      listeners.add(listener);
      void get().then(listener);
      return () => {
        listeners.delete(listener);
      };
    },
  });
  return {
    state: state as typeof state & NativeStateBridge<Snapshot>,
    publish: (next: Snapshot) => {
      current = next;
      act(() => {
        for (const listener of listeners) listener(next);
      });
    },
  };
}

function clientSettings(onboardingCompletedUserIds: string[]) {
  return { ...defaultCommaClientSettings, onboardingCompletedUserIds };
}

function appPreferences(
  revision: number,
  onboardingCompletedUserIds: string[]
): AppPreferences {
  return {
    ...defaultAppPreferences,
    clientSettings: clientSettings(onboardingCompletedUserIds),
    revision,
  };
}

const routerModel = (name: string) => ({
  agent_id: "agent_router",
  name,
  role: "router" as const,
});

const agentModels = (routerName: string): AgentModels => ({
  workspace_id: "wsp_home",
  agents: { router: routerModel(routerName) },
  workers: { items: [], next_cursor: null },
});
