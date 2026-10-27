import userEvent from "@testing-library/user-event";
import type { DevicesValue, TopicValues } from "@comma/core/contract";
import { initializeCommaI18n, type CommaLocale } from "@comma/i18n";
import { CommaI18nProvider } from "@comma/i18n/react";
import { flush } from "@comma/test-utils/fake-clock";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { act, render, screen } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { projectionToChannelState } from "@comma/core/chat";
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
import { RecommendationMockDebugSettingsRoute } from "../devtools/recommendation-mock/RecommendationMockDebugSettingsRoute";
import { CommaAppShortcutsProvider } from "../components/shortcuts/commaAppShortcuts";
import { CommaSessionHostProvider } from "../session/react";
import {
  createTestSessionHostController,
  publishTestSessionSnapshot,
  signedInSessionSnapshot,
} from "./sessionHostHarness";

const historyText = "Kept through Settings";
let listedDevices: DevicesValue["devices"] = [];

/** The login the window is signed in to: the core labels the window chat with it. */
const chatSession = {
  sessionId: signedInSessionSnapshot.session.sessionId,
  audience: signedInSessionSnapshot.session.audience,
};
const homeTarget = {
  conversationId: "cnv_home",
  groupId: "grp_home",
  workspaceId: "wsp_home",
};
type ChatMessage =
  TopicValues["chat"]["snapshot"]["sessions"][number]["state"]["messages"][number];

const historyMessage: ChatMessage = {
  attachments: [],
  blocksKey: JSON.stringify([{ type: "text", text: historyText }]),
  createdAt: 1_720_000_002,
  delivery: "sent",
  messageId: "msg-settings-history",
  parts: [{ kind: "markdown", text: historyText }],
  refs: [],
  role: "assistant",
  source: "server",
  status: "committed",
  text: historyText,
};

/**
 * The core the app talks to, scripted: the Home workspace, Ada's profile, the
 * listed devices, and the Home chat with its one history message. A draft the
 * UI sets (`chatView.setDraft`), or the suggestion the core adds to it once the
 * chat is ready (`chatView.prefillDraft`), is the draft the core shows next.
 */
function scriptedSessionCore() {
  let draft = { draft: "", draftEpoch: 0 };
  const chat: TopicValues["chat"] = {
    session: chatSession,
    snapshot: {
      protocolVersion: 3,
      revision: 4,
      sessions: [
        {
          ...homeTarget,
          draftEpoch: 0,
          key: "grp_home/cnv_home",
          refs: 1,
          revision: 3,
          state: {
            awaitingReply: false,
            awaitingTimedOut: false,
            locallyAwaitingReply: false,
            connection: "connecting",
            conversation: {
              id: "cnv_home",
              groupId: "grp_home",
              kind: "user_chat",
              status: "active",
              title: "Chat",
              workspaceId: "wsp_home",
            },
            draft: "",
            draftAttachments: [],
            lastBackoffMs: 0,
            messages: [historyMessage],
            pending: [],
            serverMessages: [historyMessage],
            status: "ready",
          },
        },
      ],
    },
  };
  const values: Partial<{ [N in keyof TopicValues]: () => TopicValues[N] }> = {
    workspace: () => ({
      status: "ready",
      workspace: { id: "wsp_home", groupId: "grp_home", name: "Home" },
      selected: true,
    }),
    profile: () => ({
      status: "ready",
      profile: {
        avatar_id: null,
        email: "person@example.com",
        id: "usr_1",
        name: "Ada",
      },
    }),
    devices: () => ({
      workspace: "wsp_home",
      devices: listedDevices,
      cloud: null,
      hasMore: false,
      loading: false,
      failed: false,
      checks: {},
    }),
    chatView: () => ({
      session: chatSession,
      revision: 4,
      draftEpoch: draft.draftEpoch,
      lease: { leaseId: "lease_home", subscriberId: "web:test:grp_home/cnv_home" },
      state: projectionToChannelState({
        ...chat.snapshot.sessions[0]!.state,
        draft: draft.draft,
      }),
    }),
    marks: () => ({ marks: {} }),
    taskOrder: () => ({ orders: {}, sections: [] }),
    doing: () => ({ doing: [] }),
    pluginNotices: () => ({ notices: [] }),
  };
  const scripted = createScriptedCore({
    values: (topic) => values[topic.topic as keyof TopicValues]?.(),
    calls: (name, params) => {
      switch (name) {
        case "chat.resolveWorkspaceChat":
          return { ...homeTarget, status: "ready" };
        case "chatView.prefillDraft":
        case "chatView.setDraft": {
          const text = (params as { draft: string }).draft;
          draft = {
            draft:
              name === "chatView.setDraft" || !draft.draft.trim()
                ? text
                : `${draft.draft}\n\n${text}`,
            draftEpoch: draft.draftEpoch + 1,
          };
          queueMicrotask(() => scripted.changed("chatView"));
          return { revision: 4, draftEpoch: draft.draftEpoch };
        }
        default:
          return null;
      }
    },
  });
  return scripted;
}

let core = scriptedSessionCore();

function user() {
  return userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
}

function renderSessionApp(
  controller: ReturnType<typeof createTestSessionHostController>,
  router: ReturnType<typeof createSessionRouter>,
  locale?: CommaLocale
) {
  return render(
    core.wrap(
      <CommaWebClientSettingsProvider>
        <CommaSessionHostProvider controller={controller}>
          <CommaAppearanceProvider>
            <CommaAppShortcutsProvider>
              <CommaI18nProvider {...(locale ? { locale } : {})}>
                <RouterProvider router={router} />
              </CommaI18nProvider>
            </CommaAppShortcutsProvider>
          </CommaAppearanceProvider>
        </CommaSessionHostProvider>
      </CommaWebClientSettingsProvider>
    )
  );
}

describe("authenticated session layout", () => {
  beforeEach(() => {
    core = scriptedSessionCore();
    listedDevices = [];
    installNativeBridgeMock({ platform: "web" });
  });

  afterEach(() => {
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

  it("leads with this computer in the desktop app, before its Connector reports", async () => {
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
    await flush();
    await user().click(screen.getByRole("button", { name: "Devices" }));
    await flush();

    screen.getByText("First device");
    const identities = Array.from(
      document.querySelectorAll('[data-slot="device-card"]')
    );
    expect(identities.map((row) => row.querySelector("h3")?.textContent)).toEqual([
      "This device",
      "First device",
    ]);
    // A Connector that has not reported yet is connecting, not offline, and
    // its access cannot be changed in the meantime.
    expect(screen.getByRole("status", { name: "Connecting…" })).toHaveAttribute(
      "aria-busy",
      "true"
    );
    expect(screen.getByRole("button", { name: /This device Access/ })).toBeDisabled();
  });

  it.each([
    {
      locale: "en" as const,
      devices: "Devices",
      add: "Add device",
      guided: "Ask Router",
      draft: "I want to connect another computer. Please guide me in English.",
    },
    {
      locale: "zh-CN" as const,
      devices: "设备",
      add: "添加设备",
      guided: "让 Router 帮忙",
      draft: "我要连接另一台电脑，请用简体中文引导我。",
    },
  ])(
    "opens Router with the $locale device draft from settings",
    async ({ locale, devices, add, draft, guided }) => {
      const controller = createTestSessionHostController({
        apiBaseUrl: "https://api.example",
        initial: signedInSessionSnapshot,
      });
      const errors: string[] = [];
      const router = createSessionRouter((error) => errors.push(error.message));
      renderSessionApp(controller, router, locale);
      await flush();
      expect(screen.getByText(historyText)).toBeVisible();
      await act(() => router.navigate({ to: "/settings" }));
      await user().click(screen.getByRole("button", { name: devices }));
      await user().click(screen.getByRole("button", { name: add }));
      expect(screen.getByRole("dialog", { name: add })).toBeVisible();
      await user().click(screen.getByRole("button", { name: guided }));
      await flush();
      expect(router.state.location.pathname).toBe("/");
      expect((screen.getByLabelText("Router draft") as HTMLTextAreaElement).value).toBe(
        draft
      );
      expect(errors).toEqual([]);
      expect(core.sentTo("chatView.prefillDraft")).toEqual([
        expect.objectContaining({
          workspace: "wsp_home",
          group: "grp_home",
          conversation: "cnv_home",
          draft,
        }),
      ]);
      // The draft is only set: nothing is sent to Router.
      expect(core.sent.filter(([name]) => /send/i.test(name))).toEqual([]);
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

    await flush();
    expect(screen.getByText(historyText)).toBeVisible();

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

    await flush();
    expect(screen.getByText(historyText)).toBeVisible();
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

    await flush();
    expect(screen.getByText(historyText)).toBeVisible();

    await act(() => router.navigate({ to: "/settings" }));
    expect(routeErrors).toEqual([]);
    await flush();
    await user().click(screen.getByRole("button", { name: "Profile" }));
    expect(screen.getByRole("heading", { level: 1, name: "Profile" })).toBeVisible();
    expect(screen.getByRole("button", { name: "Profile" })).toHaveAttribute(
      "data-selected",
      "true"
    );
    await flush();
    await user().click(screen.getByRole("button", { name: "Edit name: Ada" }));
    const name = screen.getByRole("textbox", { name: "Name" });
    await user().clear(name);
    await user().type(name, "Ada Lovelace");
    expect(screen.getByRole("dialog", { name: "Name" })).toBeVisible();
    expect(name).toHaveValue("Ada Lovelace");

    await act(() => controller.lifecycle.reconcile({ reason: "manual_retry" }));
    await flush();

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
    await flush();
    const original = screen.getByTestId("home-responsive-layout");
    const route = original.closest(".comma-chat-route")!.parentElement!;
    Object.defineProperty(route, "clientWidth", { value: 961 });
    act(() => deliverResize(route));
    expect(screen.getByTestId("home-tasks-rail")).toHaveAttribute(
      "data-folded",
      "true"
    );

    await act(() => controller.lifecycle.reconcile({ reason: "manual_retry" }));
    await flush();
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
    await flush();
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

    await flush();
    expect(screen.getByText(historyText)).toBeVisible();
    await act(() => router.navigate({ to: "/settings" }));
    await flush();
    await user().click(screen.getByRole("button", { name: "Profile" }));
    await flush();
    await user().click(screen.getByRole("button", { name: "Edit name: Ada" }));
    const name = screen.getByRole("textbox", { name: "Name" });
    await user().clear(name);
    await user().type(name, "Account A draft");

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

    await flush();
    expect(screen.getByTestId("non-home-route")).toHaveTextContent("Inbox");

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
