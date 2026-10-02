import {
  RouterProvider,
  createHashHistory,
  createRootRoute,
  createRoute,
  createRouter,
} from "@tanstack/react-router";
import { Suspense, lazy, useEffect, useMemo } from "react";
import { captureCommaPageView } from "./analytics/client";
import {
  CommaAuthenticatedLayout,
  CommaProductLayout,
  CommaRootLayout,
  CommaWorkbenchHost,
} from "./components/AppLayout";
import {
  CommaAppearanceProvider,
  CommaReducedMotionRootSync,
} from "./components/commaAppearance";
import { CommaSideChatShortcutProvider } from "./components/commaSideChatShortcut";
import { CommaAppShortcutsProvider } from "./components/shortcuts/commaAppShortcuts";
import { ConversationRoute } from "./components/chat/conversation/ConversationRoute";
import { DriveRoute } from "./components/drive/DriveRoute";
import { InboxWorkspace } from "./components/inbox/InboxRoute";
import { PluginsRoute } from "./components/plugins/PluginsRoute";
import {
  commaDefaultPrimaryContentMinWidth,
  commaDriveSpaceRailWidth,
  commaHomeContentMinWidth,
  commaInboxConversationRailWidth,
} from "./components/shellGeometry";
import { TasksRoute } from "./components/tasks/TasksRoute";

export { CommaAnalyticsLifecycle } from "./analytics/CommaAnalyticsLifecycle";
export { startCommaAnalytics, reportCommaClientError } from "./analytics/client";

declare module "@tanstack/router-core" {
  interface StaticDataRouteOption {
    commaPrimaryContentMinWidth?: number;
  }
}

export {
  apiBaseUrlStorageKey,
  CommaApiError,
  createCommaApi,
  defaultApiBaseUrl,
  storeCommaApiBaseUrl,
  type CommaApiClient,
  type CommaApiSessionTransport,
  type CommaConnectorToken,
  type CommaConversation,
  type CommaConversationEvent,
  type SalixMessage,
  type CommaPlugin,
  type CommaPluginResource,
  type CommaWorkspace,
} from "./api";
export {
  commaLogoUrl,
  getActiveCommaConfig,
  getCommaConfig,
  parseCommaChannel,
  parseCommaChannelStrict,
  type CommaChannel,
  type CommaConfig,
} from "@comma/config";
export { CommaSidebarPanel } from "./components/sidebar/SidebarPanel";
export {
  CommaSidebarProvider,
  useCommaSidebar,
  type CommaSidebarContextValue,
} from "./components/sidebar/SidebarContext";
export {
  CommaAuthGate,
  useCommaAuth,
  type CommaAuthContextValue,
} from "./components/AuthGate";
export {
  CommaSessionHostProvider,
  useSessionHostController,
  useSessionLifecycleSnapshot,
  type SessionAuthenticatorController,
  type SessionHostController,
  type SessionLifecycleController,
  type SessionLoginChallenge,
  type WebSessionHostPorts,
} from "./session/react";
export {
  CommaClientSettingsI18nProvider,
  CommaElectronClientSettingsProvider,
  CommaWebClientSettingsProvider,
  commaClientSettingsStorageKey,
  readWebCommaClientSettings,
  useCommaClientSettings,
  useCommaClientSettingsPending,
} from "./components/commaClientSettings";
export { readLegacyCommaClientSettings } from "./components/readLegacyCommaClientSettings";
export { createBrowserSessionHostPorts } from "./session/web/browser-session-host";
export { createWebSessionHostController } from "./session/web/web-session-host-controller";
export { createElectronSessionHostController } from "./session/electron/electron-session-host-controller";
export {
  WebCookieSessionAdapter,
  type WebCookieSessionProductLease,
} from "./session/web/web-cookie-session-adapter";
export {
  createProductInboxProjectionController,
  createElectronProductInboxProjectionController,
  productInboxErrorMessage,
  productInboxUnavailableResult,
  type ProductInboxProjectionBridge,
  type ProductInboxProjectionController,
  type ProductInboxProjectionEnvelope,
  type ProductInboxRefresh,
  type ProductInboxRetention,
} from "./product-inbox/controller";
export {
  ProductInboxProjectionProvider,
  useProductInboxProjection,
  useProductInboxSnapshot,
} from "./product-inbox/react";
export { SideChatApp } from "./components/chat/side-chat/SideChatApp";
export { SideChatTestWindow } from "./components/chat/side-chat/SideChatTestWindow";
export { BrowserInspectionComposer } from "./components/chat-sidebar/BrowserInspectionComposer";
export { OnboardingWindowApp } from "./components/onboarding/window/OnboardingWindowApp";
// Re-exported so an Electron renderer can declare, at its entry point, whether
// its window has a toast surface at all. Only CommaApp and OnboardingWindowApp
// mount a <Toaster />.
export { setToastsEnabled } from "@comma/ui";
export { CommaAppearanceProvider, CommaReducedMotionRootSync };

const rootRoute = createRootRoute({
  component: CommaRootLayout,
});

// Pathless authenticated session: AuthGate and the stable chat-session owner
// stay mounted. The only child is the product shell — Settings is a location
// inside that shell's content panel, not a sibling match that unmounts Home.
// It renders beside the keyed chat-consumer boundary so a generation bump
// cannot wipe its local state.
const authedRoute = createRoute({
  getParentRoute: () => rootRoute,
  id: "_authed",
  component: CommaAuthenticatedLayout,
});

// Pathless product session: the window bar, icon rail and content panel.
// Home is retained (hidden) underneath every later location once it has been
// mounted; a direct Settings entry does not fabricate a hidden Home.
const shellRoute = createRoute({
  getParentRoute: () => authedRoute,
  id: "_shell",
  component: CommaProductLayout,
});

const indexRoute = createRoute({
  getParentRoute: () => shellRoute,
  path: "/",
  component: () => null,
  validateSearch: (
    search: Record<string, unknown>
  ): { meetingTask?: string | undefined; meetingGroup?: string | undefined } => ({
    meetingTask:
      typeof search.meetingTask === "string" ? search.meetingTask : undefined,
    meetingGroup:
      typeof search.meetingGroup === "string" ? search.meetingGroup : undefined,
  }),
  staticData: {
    commaPrimaryContentMinWidth: commaHomeContentMinWidth,
  },
});

const inboxRoute = createRoute({
  getParentRoute: () => shellRoute,
  path: "inbox",
  component: InboxWorkspace,
  staticData: {
    commaPrimaryContentMinWidth: commaInboxConversationRailWidth,
  },
});

const conversationRoute = createRoute({
  getParentRoute: () => inboxRoute,
  path: "$workspaceId/$groupId/$conversationId",
  component: ConversationRoute,
  staticData: {
    commaPrimaryContentMinWidth:
      commaInboxConversationRailWidth + commaDefaultPrimaryContentMinWidth,
  },
});

const inboxRouteTree = inboxRoute.addChildren({ conversationRoute });

const driveRoute = createRoute({
  getParentRoute: () => shellRoute,
  path: "drive",
  component: DriveRoute,
  validateSearch: (
    search: Record<string, unknown>
  ): { space?: string; path?: string; reveal?: string } => ({
    ...(typeof search["space"] === "string" && search["space"]
      ? { space: search["space"] }
      : {}),
    ...(typeof search["path"] === "string" && search["path"]
      ? { path: search["path"] }
      : {}),
    ...(typeof search["reveal"] === "string" && search["reveal"]
      ? { reveal: search["reveal"] }
      : {}),
  }),
  staticData: {
    // The space rail is fixed, so the file list beside it is what a widening
    // sidebar would otherwise eat into.
    commaPrimaryContentMinWidth:
      commaDriveSpaceRailWidth + commaDefaultPrimaryContentMinWidth,
  },
});

const tasksRoute = createRoute({
  getParentRoute: () => shellRoute,
  path: "tasks",
  component: TasksRoute,
  // Task properties and chips link to a label, origin, status, or client platform.
  // Drop unsupported query fields and unknown status/platform values.
  validateSearch: (
    search: Record<string, unknown>
  ): {
    label?: string;
    platform?: string;
    status?: string;
    clientPlatform?: string;
  } => {
    const label = search["label"];
    const platform = search["platform"];
    return {
      ...(typeof label === "string" && label ? { label } : {}),
      ...(typeof platform === "string" && platform ? { platform } : {}),
      ...(typeof search["status"] === "string" &&
      ["backlog", "in_progress", "needs_review", "done", "cancelled"].includes(
        search["status"]
      )
        ? { status: search["status"] }
        : {}),
      ...(typeof search["clientPlatform"] === "string" &&
      ["macos", "windows", "linux", "ios", "android", "web", "unknown"].includes(
        search["clientPlatform"]
      )
        ? { clientPlatform: search["clientPlatform"] }
        : {}),
    };
  },
});

const taskDetailRoute = createRoute({
  getParentRoute: () => shellRoute,
  path: "tasks/$workspaceId/$groupId/$conversationId",
  component: ConversationRoute,
});

const pluginsRoute = createRoute({
  getParentRoute: () => shellRoute,
  path: "plugins",
  component: PluginsRoute,
});

// URL for Settings. The product layout renders the Settings surface itself
// (outside the chat-consumer boundary), so this match stays empty.
const settingsRoute = createRoute({
  getParentRoute: () => shellRoute,
  path: "settings",
  component: () => null,
});

const shellRouteTree = shellRoute.addChildren({
  indexRoute,
  inboxRouteTree,
  driveRoute,
  pluginsRoute,
  settingsRoute,
  taskDetailRoute,
  tasksRoute,
});

const authedRouteTree = authedRoute.addChildren({
  shellRouteTree,
});

const routeTree = (() => {
  if (import.meta.env.DEV) {
    const RuntimeWorkbenchRoute = lazy(() =>
      import("./devtools/runtime-workbench/RuntimeWorkbenchRoute").then((module) => ({
        default: module.RuntimeWorkbenchRoute,
      }))
    );

    // Dev-only: a sibling of the authenticated tree (not a child), so it
    // renders bare — no auth gate, no product chrome — via CommaWorkbenchHost.
    const runtimeWorkbenchRoute = createRoute({
      getParentRoute: () => rootRoute,
      path: "dev/workbench",
      component: () => (
        <CommaWorkbenchHost>
          <Suspense fallback={null}>
            <RuntimeWorkbenchRoute />
          </Suspense>
        </CommaWorkbenchHost>
      ),
    });

    return rootRoute.addChildren({
      authedRouteTree,
      runtimeWorkbenchRoute,
    });
  }

  return rootRoute.addChildren({
    authedRouteTree,
  });
})();

function createCommaRouter() {
  return createRouter({
    routeTree,
    history: createHashHistory(),
    defaultPreload: "intent",
  });
}

type CommaRouter = ReturnType<typeof createCommaRouter>;

declare module "@tanstack/react-router" {
  interface Register {
    router: CommaRouter;
  }
}

export function CommaApp() {
  const router = useMemo(() => createCommaRouter(), []);
  useEffect(() => router.subscribe("onResolved", captureCommaPageView), [router]);

  return (
    <CommaAppearanceProvider>
      <CommaSideChatShortcutProvider>
        <CommaAppShortcutsProvider>
          <RouterProvider router={router} />
        </CommaAppShortcutsProvider>
      </CommaSideChatShortcutProvider>
    </CommaAppearanceProvider>
  );
}

export { SessionHistoryBridgeProvider } from "./runtime-chat/sessionHistoryBridge";

export { MeetingRecorderWindowApp } from "./components/MeetingRecorderWindowApp";

export { SitePermissionMenuApp } from "./components/SitePermissionMenuApp";
export { TaskPanelApp } from "./components/tasks/TaskPanelApp";
