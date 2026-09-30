import userEvent from "@testing-library/user-event";
import { initializeCommaI18n, type CommaLocale } from "@comma/i18n";
import { CommaI18nProvider } from "@comma/i18n/react";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { act, render, screen } from "@comma/test-utils/render";
import {
  Outlet,
  RouterProvider,
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
  useRouterState,
} from "@tanstack/react-router";
import { useLayoutEffect, useState } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  CommaAuthenticatedLayout,
  CommaProductLayout,
  settingsRouteComponentForBuildFlavor,
} from "../components/AppLayout";
import { useCommaAuth } from "../components/AuthGate";
import {
  isHomePath,
  isSettingsPath,
  showsProductRouteOutlet,
} from "../components/productShellPaths";
import { COMMA_SURFACE_PAUSED_ATTRIBUTE } from "../components/commaSurfacePause";
import { AppSettingsRoute } from "../components/AppSettingsRoute";
import { writeActiveWorkspaceId } from "../components/activeWorkspace";
import {
  ChatConsumerBoundary,
  useChatRegistry,
  useHomeConversationTarget,
} from "../components/chat/ChatProvider";
import { useConversation } from "../components/chat/conversation/useConversation";
import { useComposerDraft } from "../components/chat/composer/conversationDraft";
import { ChatSidebarProvider } from "../components/chat-sidebar/ChatSidebarContext";
import { CommaAppearanceProvider } from "../components/commaAppearance";
import { CommaWebClientSettingsProvider } from "../components/commaClientSettings";
import { CommaSideChatShortcutProvider } from "../components/commaSideChatShortcut";
import { RecommendationMockDebugSettingsRoute } from "../devtools/recommendation-mock/RecommendationMockDebugSettingsRoute";
import { CommaAppShortcutsProvider } from "../components/shortcuts/commaAppShortcuts";
import { CommaSessionHostProvider } from "../session/react";
import {
  createTestSessionHostController,
  publishTestSessionSnapshot,
  signedInSessionSnapshot,
} from "./sessionHostHarness";

const historyText = "Kept through Settings";
let listedDevices: {
  device_id: string;
  name: string;
  status: "connected";
  allows_operations: boolean;
  device_runtimes: {
    provider: string;
    device_runtime_id: string;
    status: string;
    message?: string;
    readiness_valid_until?: number;
  }[];
}[] = [];

function renderSessionApp(
  controller: ReturnType<typeof createTestSessionHostController>,
  router: ReturnType<typeof createSessionRouter>,
  locale?: CommaLocale
) {
  return render(
    <CommaWebClientSettingsProvider>
      <CommaSessionHostProvider controller={controller}>
        <CommaAppearanceProvider>
          <CommaSideChatShortcutProvider>
            <CommaAppShortcutsProvider>
              <CommaI18nProvider {...(locale ? { locale } : {})}>
                <RouterProvider router={router} />
              </CommaI18nProvider>
            </CommaAppShortcutsProvider>
          </CommaSideChatShortcutProvider>
        </CommaAppearanceProvider>
      </CommaSessionHostProvider>
    </CommaWebClientSettingsProvider>
  );
}

describe("authenticated session layout", () => {
  beforeEach(() => {
    listedDevices = [];
    installNativeBridgeMock({ platform: "web" });
    installFetchStub();
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
    initializeCommaI18n(["en"]);
  });

  it("selects the recommendation Debug wrapper only for dev builds", () => {
    expect(settingsRouteComponentForBuildFlavor("dev")).toBe(
      RecommendationMockDebugSettingsRoute
    );
    expect(settingsRouteComponentForBuildFlavor("staging")).toBe(AppSettingsRoute);
    expect(settingsRouteComponentForBuildFlavor("prod")).toBe(AppSettingsRoute);
    expect(settingsRouteComponentForBuildFlavor(undefined)).toBe(AppSettingsRoute);
  });

  it("refreshes newly connected devices and delayed agent readiness while devices is visible", async () => {
    vi.useFakeTimers({ toFake: ["setInterval", "clearInterval", "Date"] });
    writeActiveWorkspaceId("wsp_home");
    listedDevices = [
      {
        device_id: "dev_first",
        name: "First device",
        status: "connected",
        allows_operations: false,
        device_runtimes: [
          {
            provider: "codex",
            device_runtime_id: "runtime_1",
            status: "unavailable",
            message: "Allow operations",
          },
        ],
      },
    ];
    const controller = createTestSessionHostController({
      apiBaseUrl: "https://api.example",
      initial: signedInSessionSnapshot,
    });
    const router = createSessionRouter(() => {});
    renderSessionApp(controller, router);
    await screen.findByText(historyText);
    await act(() => router.navigate({ to: "/settings" }));
    await userEvent.click(screen.getByRole("button", { name: "Devices" }));
    await screen.findByText("First device");
    listedDevices = [
      {
        ...listedDevices[0]!,
        allows_operations: true,
        device_runtimes: [
          {
            provider: "codex",
            device_runtime_id: "runtime_1",
            status: "ready",
            readiness_valid_until: Date.now() / 1000 + 300,
          },
        ],
      },
      {
        device_id: "dev_new",
        name: "New device",
        status: "connected",
        allows_operations: false,
        device_runtimes: [],
      },
    ];
    await act(async () => {
      await vi.advanceTimersByTimeAsync(15_000);
    });
    expect(await screen.findByText("New device")).toBeVisible();
    expect((await screen.findAllByText("Check passed"))[0]).toBeVisible();
    // The browser retires a ready observation even while subsequent requests hang.
    vi.mocked(fetch).mockImplementation(() => new Promise(() => {}));
    await act(async () => {
      await vi.advanceTimersByTimeAsync(300_001);
    });
    expect((await screen.findAllByText("Check expired"))[0]).toBeVisible();
    expect(screen.queryByText("Check passed")).toBeNull();
    await userEvent.click(screen.getByRole("button", { name: "General" }));
    const fetchMock = vi.mocked(fetch);
    const countDeviceReads = () =>
      fetchMock.mock.calls.filter(([url]) => String(url).includes("/devices")).length;
    const requests = countDeviceReads();
    await act(async () => {
      await vi.advanceTimersByTimeAsync(30_000);
    });
    expect(countDeviceReads()).toBe(requests);
  });

  it("leads with this computer in the desktop app, before its Connector reports", async () => {
    writeActiveWorkspaceId("wsp_home");
    installNativeBridgeMock({ platform: "electron" });
    listedDevices = [
      {
        device_id: "dev_first",
        name: "First device",
        status: "connected",
        allows_operations: false,
        device_runtimes: [],
      },
    ];
    const controller = createTestSessionHostController({
      apiBaseUrl: "https://api.example",
      initial: signedInSessionSnapshot,
    });
    const router = createSessionRouter(() => {});
    renderSessionApp(controller, router);
    await act(() => router.navigate({ to: "/settings" }));
    await userEvent.click(await screen.findByRole("button", { name: "Devices" }));

    await screen.findByText("First device");
    const identities = Array.from(
      document.querySelectorAll('[data-slot="device-card"]')
    );
    expect(identities.map((row) => row.querySelector("h3")?.textContent)).toEqual([
      "This device",
      "First device",
    ]);
    // A Connector that has not reported yet is connecting, not offline, and
    // its permission is not a switch to throw in the meantime.
    expect(screen.getByRole("status", { name: "Connecting…" })).toHaveAttribute(
      "aria-busy",
      "true"
    );
    await userEvent.click(
      screen.getAllByRole("button", { name: "Permissions & details" })[0]!
    );
    expect(screen.getByRole("switch", { name: /^Allow operations/ })).toBeDisabled();
  });

  it.each([
    {
      locale: "en" as const,
      devices: "Devices",
      manual: "Connect manually",
      add: "Add device",
      guided: "Ask Router",
      draft: "I want to connect another computer. Please guide me in English.",
    },
    {
      locale: "zh-CN" as const,
      devices: "设备",
      manual: "手动接入",
      add: "添加设备",
      guided: "让 Router 帮忙",
      draft: "我要连接另一台电脑，请用简体中文引导我。",
    },
  ])(
    "opens Router with the $locale device draft from settings",
    async ({ locale, devices, manual, add, draft, guided }) => {
      writeActiveWorkspaceId("wsp_home");
      const controller = createTestSessionHostController({
        apiBaseUrl: "https://api.example",
        initial: signedInSessionSnapshot,
      });
      const errors: string[] = [];
      const router = createSessionRouter((error) => errors.push(error.message));
      renderSessionApp(controller, router, locale);
      await screen.findByText(historyText);
      await act(() => router.navigate({ to: "/settings" }));
      await userEvent.click(screen.getByRole("button", { name: devices }));
      await userEvent.click(screen.getByRole("button", { name: add }));
      expect(screen.getByText(manual)).toBeVisible();
      await userEvent.click(screen.getByRole("button", { name: guided }));
      await vi.waitFor(() => expect(router.state.location.pathname).toBe("/"));
      expect((screen.getByLabelText("Router draft") as HTMLTextAreaElement).value).toBe(
        draft
      );
      expect(errors).toEqual([]);
      expect(
        vi
          .mocked(fetch)
          .mock.calls.some(
            ([input, init]) =>
              String(input).endsWith("/messages") && init?.method === "POST"
          )
      ).toBe(false);
    }
  );

  it("keeps the Home instance mounted while Settings is the surface", async () => {
    const routeErrors: string[] = [];
    const controller = createTestSessionHostController({
      apiBaseUrl: "https://api.example",
      initial: signedInSessionSnapshot,
    });
    const router = createSessionRouter((error) => routeErrors.push(error.message));

    renderSessionApp(controller, router);

    expect(await screen.findByText(historyText)).toBeVisible();

    await act(() => router.navigate({ to: "/settings" }));
    expect(screen.getByRole("heading", { level: 1, name: "General" })).toBeVisible();
    // Settings is a live modal beside the retained Home, never an inert
    // overlay that takes the shell down with it.
    const settingsDialog = screen.getByRole("dialog", { name: "Settings sections" });
    expect(settingsDialog).toContainElement(
      screen.getByRole("heading", { level: 1, name: "General" })
    );
    expect(settingsDialog.closest("[inert]")).toBeNull();
    expect(screen.getByText(historyText)).not.toBeVisible();
    const hiddenHome = screen.getByTestId("home-responsive-layout");
    const keepAliveHost = hiddenHome.closest("[inert]");
    expect(hiddenHome).not.toBeVisible();
    expect(keepAliveHost).not.toBeNull();
    expect(keepAliveHost).toHaveStyle({ visibility: "hidden" });
    expect(keepAliveHost).not.toHaveAttribute("hidden");
    expect(keepAliveHost).toHaveAttribute(COMMA_SURFACE_PAUSED_ATTRIBUTE, "true");
    expect(screen.queryByTestId("chat-empty")).toBeNull();
    expect(screen.queryByRole("button", { name: "Do anything" })).toBeNull();
    expect(routeErrors).toEqual([]);

    await act(() => router.navigate({ to: "/" }));

    expect(screen.getByText(historyText)).toBeVisible();
    expect(screen.queryByTestId("chat-empty")).toBeNull();
    expect(screen.queryByRole("button", { name: "Do anything" })).toBeNull();
    expect(routeErrors).toEqual([]);
  });

  it("keeps the Home instance mounted while Tasks is showing", async () => {
    const routeErrors: string[] = [];
    const controller = createTestSessionHostController({
      apiBaseUrl: "https://api.example",
      initial: signedInSessionSnapshot,
    });
    const router = createSessionRouter((error) => routeErrors.push(error.message));

    renderSessionApp(controller, router);

    expect(await screen.findByText(historyText)).toBeVisible();
    const home = screen.getByTestId("home-responsive-layout");

    await act(() => router.navigate({ to: "/tasks" }));
    expect(screen.getByTestId("tasks-route")).toBeVisible();
    expect(home).toBe(screen.getByTestId("home-responsive-layout"));
    expect(home).not.toBeVisible();
    const pausedHome = home.closest("[inert]");
    expect(pausedHome).not.toBeNull();
    expect(pausedHome).toHaveStyle({ visibility: "hidden" });
    expect(pausedHome).toHaveAttribute(COMMA_SURFACE_PAUSED_ATTRIBUTE, "true");
    expect(screen.queryByTestId("chat-empty")).toBeNull();
    expect(screen.queryByRole("button", { name: "Do anything" })).toBeNull();
    expect(routeErrors).toEqual([]);

    await act(() => router.navigate({ to: "/" }));

    expect(screen.getByTestId("home-responsive-layout")).toBe(home);
    expect(screen.getByText(historyText)).toBeVisible();
    expect(screen.queryByTestId("chat-empty")).toBeNull();
    expect(screen.queryByRole("button", { name: "Do anything" })).toBeNull();
    expect(routeErrors).toEqual([]);
  });

  it("keeps the Profile name draft across a same-session reconcile and paints Home history immediately", async () => {
    const routeErrors: string[] = [];
    const controller = createTestSessionHostController({
      apiBaseUrl: "https://api.example",
      bumpGenerationOnReconcile: true,
      initial: signedInSessionSnapshot,
    });
    const router = createSessionRouter((error) => routeErrors.push(error.message));

    renderSessionApp(controller, router);

    expect(await screen.findByText(historyText)).toBeVisible();

    await act(() => router.navigate({ to: "/settings" }));
    expect(routeErrors).toEqual([]);
    await userEvent.click(await screen.findByRole("button", { name: "Profile" }));
    expect(screen.getByRole("heading", { level: 1, name: "Profile" })).toBeVisible();
    expect(screen.getByRole("button", { name: "Profile" })).toHaveAttribute(
      "data-selected",
      "true"
    );
    await userEvent.click(
      await screen.findByRole("button", { name: "Edit name: Ada" })
    );
    const name = screen.getByRole("textbox", { name: "Name" });
    await userEvent.clear(name);
    await userEvent.type(name, "Ada Lovelace");
    expect(screen.getByRole("dialog", { name: "Name" })).toBeVisible();
    expect(name).toHaveValue("Ada Lovelace");

    await act(() => controller.lifecycle.reconcile({ reason: "manual_retry" }));

    expect(screen.getByRole("dialog", { name: "Name" })).toBeVisible();
    expect(screen.getByRole("textbox", { name: "Name" })).toHaveValue("Ada Lovelace");
    expect(
      screen.getByRole("button", { hidden: true, name: "Profile" })
    ).toHaveAttribute("data-selected", "true");
    expect(
      screen.getByRole("heading", { hidden: true, level: 1, name: "Profile" })
    ).toBeInTheDocument();
    expect(controller.lifecycle.getSnapshotSync().generation).toBe(
      signedInSessionSnapshot.generation + 1
    );
    expect(routeErrors).toEqual([]);

    await act(() => router.navigate({ to: "/" }));

    expect(screen.getByText(historyText)).toBeVisible();
    expect(screen.queryByTestId("chat-empty")).toBeNull();
    expect(screen.queryByRole("button", { name: "Do anything" })).toBeNull();
    expect(routeErrors).toEqual([]);
  });

  it("keeps Home rail folding live after a same-session lease remount", async () => {
    const observers = new Set<ResizeObserverProbe>();
    class ResizeObserverProbe {
      targets = new Set<Element>();
      constructor(readonly callback: ResizeObserverCallback) {
        observers.add(this);
      }
      observe(target: Element) {
        this.targets.add(target);
      }
      unobserve(target: Element) {
        this.targets.delete(target);
      }
      disconnect() {
        this.targets.clear();
        observers.delete(this);
      }
    }
    vi.stubGlobal("ResizeObserver", ResizeObserverProbe);
    const deliverResize = (target: Element) => {
      for (const observer of observers) {
        if (observer.targets.has(target)) {
          observer.callback(
            [{ target } as ResizeObserverEntry],
            observer as unknown as ResizeObserver
          );
        }
      }
    };
    const routeErrors: string[] = [];
    const controller = createTestSessionHostController({
      apiBaseUrl: "https://api.example",
      bumpGenerationOnReconcile: true,
      initial: signedInSessionSnapshot,
    });
    const router = createSessionRouter(
      (error) => routeErrors.push(error.message),
      "/",
      CommaProductLayout
    );
    renderSessionApp(controller, router);
    const original = await screen.findByTestId("home-responsive-layout");
    const route = original.closest(".comma-chat-route")!.parentElement!;
    Object.defineProperty(route, "clientWidth", { value: 961 });
    act(() => deliverResize(route));
    expect(screen.getByTestId("home-tasks-rail")).toHaveAttribute(
      "data-folded",
      "true"
    );

    await act(() => controller.lifecycle.reconcile({ reason: "manual_retry" }));
    const replacement = screen.getByTestId("home-responsive-layout");
    expect(replacement).not.toBe(original);
    const replacementRoute = replacement.closest(".comma-chat-route")!.parentElement!;
    Object.defineProperty(replacementRoute, "clientWidth", { value: 961 });
    act(() => deliverResize(replacementRoute));
    const greeting = screen.getByTestId("home-greet-rail");

    // A preview does not commit the preference to React until pointer release.
    // Its live geometry must reach the observer attached to the new Home tree.
    act(() => {
      replacement.style.setProperty("--comma-home-greet-preferred", "260px");
      deliverResize(greeting);
    });
    expect(screen.getByTestId("home-tasks-rail")).toHaveAttribute(
      "data-folded",
      "false"
    );
    act(() => {
      replacement.style.setProperty("--comma-home-greet-preferred", "320px");
      deliverResize(greeting);
    });
    expect(screen.getByTestId("home-tasks-rail")).toHaveAttribute(
      "data-folded",
      "true"
    );

    // A paused Home can remount while Settings is open. The first measurement
    // on return must replace the retained folds even when both rails now fit.
    await act(() => router.navigate({ to: "/settings" }));
    await act(() => controller.lifecycle.reconcile({ reason: "manual_retry" }));
    const pausedHome = screen.getByTestId("home-responsive-layout");
    const pausedRoute = pausedHome.closest(".comma-chat-route")!.parentElement!;
    Object.defineProperty(pausedRoute, "clientWidth", { value: 1400 });
    await act(() => router.navigate({ to: "/" }));
    expect(screen.getByTestId("home-tasks-rail")).toHaveAttribute(
      "data-folded",
      "false"
    );
    expect(routeErrors).toEqual([]);
  });

  it("remounts Settings local state when the signed-in session changes", async () => {
    const routeErrors: string[] = [];
    const controller = createTestSessionHostController({
      apiBaseUrl: "https://api.example",
      initial: signedInSessionSnapshot,
    });
    const router = createSessionRouter((error) => routeErrors.push(error.message));

    renderSessionApp(controller, router);

    expect(await screen.findByText(historyText)).toBeVisible();
    await act(() => router.navigate({ to: "/settings" }));
    await userEvent.click(await screen.findByRole("button", { name: "Profile" }));
    await userEvent.click(
      await screen.findByRole("button", { name: "Edit name: Ada" })
    );
    const name = screen.getByRole("textbox", { name: "Name" });
    await userEvent.clear(name);
    await userEvent.type(name, "Account A draft");

    act(() => {
      publishTestSessionSnapshot(controller, {
        ...signedInSessionSnapshot,
        generation: signedInSessionSnapshot.generation + 1,
        principal: {
          email: "other@example.com",
          userId: "usr_2",
        },
        revision: signedInSessionSnapshot.revision + 1,
        session: {
          ...signedInSessionSnapshot.session,
          sessionId: "22222222-2222-4222-8222-222222222222",
        },
      });
    });

    expect(screen.queryByRole("dialog", { name: "Name" })).toBeNull();
    expect(screen.getByRole("button", { name: "General" })).toHaveAttribute(
      "data-selected",
      "true"
    );
    expect(screen.queryByTestId("home-responsive-layout")).not.toBeInTheDocument();
    expect(routeErrors).toEqual([]);
  });

  it("does not retain a product route when Settings is entered from non-Home", async () => {
    const routeErrors: string[] = [];
    const controller = createTestSessionHostController({
      apiBaseUrl: "https://api.example",
      initial: signedInSessionSnapshot,
    });
    const router = createSessionRouter(
      (error) => routeErrors.push(error.message),
      "/inbox"
    );

    renderSessionApp(controller, router);

    expect(await screen.findByTestId("non-home-route")).toHaveTextContent("Inbox");

    await act(() => router.navigate({ to: "/settings" }));

    expect(screen.getByRole("heading", { level: 1, name: "General" })).toBeVisible();
    expect(screen.queryByTestId("non-home-route")).not.toBeInTheDocument();
    expect(screen.queryByTestId("home-responsive-layout")).not.toBeInTheDocument();
    expect(routeErrors).toEqual([]);
  });
});

function createSessionRouter(
  onCatch: (error: Error) => void,
  initialEntry = "/",
  productLayout = TestProductLayout
) {
  const rootRoute = createRootRoute({
    component: CommaAuthenticatedLayout,
  });
  const shellRoute = createRoute({
    getParentRoute: () => rootRoute,
    id: "_shell",
    component: productLayout,
  });
  const indexRoute = createRoute({
    getParentRoute: () => shellRoute,
    path: "/",
    component: () => null,
  });
  const settingsRoute = createRoute({
    getParentRoute: () => shellRoute,
    path: "settings",
    component: () => null,
  });
  const inboxRoute = createRoute({
    getParentRoute: () => shellRoute,
    path: "inbox",
    component: () => <div data-testid="non-home-route">Inbox</div>,
  });
  const tasksRoute = createRoute({
    getParentRoute: () => shellRoute,
    path: "tasks",
    component: () => <div data-testid="tasks-route">Tasks page</div>,
  });

  return createRouter({
    defaultOnCatch: onCatch,
    routeTree: rootRoute.addChildren([
      shellRoute.addChildren([indexRoute, settingsRoute, inboxRoute, tasksRoute]),
    ]),
    history: createMemoryHistory({ initialEntries: [initialEntry] }),
  });
}

// Mirrors `CommaContent` in AppLayout.tsx with a history probe in Home's slot:
// one keyed chat-consumer boundary holds the retained Home surface and the
// product Outlet, and the Settings surface renders beside that boundary —
// never inert, keyed by the signed-in account — so a same-session generation
// bump remounts the chat consumers but not Settings, while an account change
// remounts Settings alone.
function TestProductLayout() {
  const pathname = useRouterState({
    select: (state) => state.location.pathname,
  });
  const accountKey = useProductAccountKey();
  const homeVisible = isHomePath(pathname);
  const settingsActive = isSettingsPath(pathname);
  const showProductRoute = showsProductRouteOutlet(pathname);
  // Home is retained for the account that mounted it; a signed-in session
  // change drops the previous account's surface.
  const [homeSurface, setHomeSurface] = useState(() => ({
    accountKey,
    mounted: homeVisible,
  }));

  if (homeSurface.accountKey !== accountKey || (homeVisible && !homeSurface.mounted)) {
    setHomeSurface({ accountKey, mounted: homeVisible });
  }
  const homeMounted = homeSurface.mounted;

  return (
    <ChatSidebarProvider>
      <div
        className="relative flex min-h-0 min-w-0 flex-1"
        data-testid="comma-route-outlet"
      >
        <ChatConsumerBoundary>
          {homeMounted ? (
            <div
              aria-hidden={homeVisible ? undefined : true}
              className="absolute inset-0"
              data-comma-surface-paused={homeVisible ? undefined : "true"}
              inert={homeVisible ? undefined : true}
              style={
                homeVisible
                  ? undefined
                  : { pointerEvents: "none", visibility: "hidden" }
              }
            >
              <HomeHistoryProbe />
            </div>
          ) : null}
          {showProductRoute ? <Outlet /> : null}
        </ChatConsumerBoundary>
        {settingsActive ? <TestSettingsSurface /> : null}
      </div>
    </ChatSidebarProvider>
  );
}

// The signed-in account without the product-lease generation, as AppLayout
// keys it.
function useProductAccountKey() {
  const { productLease } = useCommaAuth();
  return JSON.stringify([
    productLease.audience,
    productLease.authorityInstanceId,
    productLease.sessionId,
  ]);
}

function TestSettingsSurface() {
  const accountKey = useProductAccountKey();

  return <AppSettingsRoute key={accountKey} />;
}

function HomeHistoryProbe() {
  const registry = useChatRegistry();
  const remembered = useHomeConversationTarget();

  useLayoutEffect(() => {
    registry.rememberHomeConversationTarget("wsp_home", "grp_home", "cnv_home");
  }, [registry]);

  const conversation = useConversation(
    remembered?.workspaceId ?? "wsp_home",
    remembered?.groupId ?? "grp_home",
    remembered?.conversationId ?? "cnv_home"
  );
  const draft = useComposerDraft(conversation.draftSource);
  const history = conversation.state.messages
    .map((message) => message.text)
    .filter(Boolean)
    .join(" ");

  return (
    <div data-testid="home-responsive-layout">
      <textarea aria-label="Router draft" value={draft} readOnly />
      {history ? (
        <p>{history}</p>
      ) : (
        <div data-testid="chat-empty">
          <button type="button" data-placeholder="Do anything">
            Do anything
          </button>
        </div>
      )}
    </div>
  );
}

function installFetchStub() {
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url =
        typeof input === "string"
          ? input
          : input instanceof URL
            ? input.toString()
            : input.url;
      const path = new URL(url, "https://api.example").pathname;
      const method = init?.method ?? "GET";

      if (method === "GET" && path === "/v1/comma/workspaces") {
        return jsonResponse({
          data: [
            { id: "wsp_home", group_id: "grp_home", name: "Home", status: "ready" },
          ],
        });
      }
      if (method === "GET" && path === "/v1/comma/workspaces/wsp_home/devices") {
        return jsonResponse({ devices: listedDevices, next_cursor: null });
      }
      if (method === "POST" && path === "/v1/comma/groups/grp_home/assistant-chat") {
        return jsonResponse({
          id: "cnv_home",
          group_id: "grp_home",
          kind: "user_chat",
          status: "active",
          title: "Chat",
          messages: [],
        });
      }

      if (method === "GET" && path === "/v1/comma/me/profile") {
        return jsonResponse({
          avatar_id: null,
          email: "person@example.com",
          id: "usr_1",
          name: "Ada",
        });
      }

      if (
        method === "GET" &&
        path === "/v1/comma/groups/grp_home/conversations/cnv_home"
      ) {
        return jsonResponse({
          group_id: "grp_home",
          id: "cnv_home",
          kind: "user_chat",
          messages: [
            {
              actor_type: "agent",
              content: [{ text: historyText, type: "text" }],
              created_at: 1_720_000_002,
              kind: "message",
              message_id: "msg-settings-history",
            },
          ],
          status: "active",
          title: "Chat",
        });
      }

      if (method === "GET" && path.endsWith("/skills")) {
        return jsonResponse({ data: [] });
      }

      if (method === "GET" && path.endsWith("/events")) {
        return new Response(
          new ReadableStream({
            start() {},
          }),
          {
            headers: { "content-type": "text/event-stream" },
            status: 200,
          }
        );
      }

      return jsonResponse({ error: `unhandled ${method} ${path}` }, 404);
    })
  );
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    headers: { "content-type": "application/json" },
    status,
  });
}
