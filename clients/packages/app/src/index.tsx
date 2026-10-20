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
import { CommaAppShortcutsProvider } from "./components/shortcuts/commaAppShortcuts";
import { ConversationRoute } from "./components/chat/conversation/ConversationRoute";
import { DriveRoute } from "./components/drive/DriveRoute";
import { StationTaskRoute } from "./components/tasks/station/StationTaskPage";
import { InboxWorkspace } from "./components/inbox/InboxRoute";
import { PluginsRoute } from "./components/plugins/PluginsRoute";
import {
  commaDefaultPrimaryContentMinWidth,
  commaDriveSpaceRailWidth,
  commaHomeContentMinWidth,
  commaInboxConversationRailWidth,
} from "./components/shellGeometry";
import { TasksRoute } from "./components/tasks/TasksRoute";
import { validateTasksSearch } from "./components/tasks/tasksSearch";

export { CommaAnalyticsLifecycle } from "./analytics/CommaAnalyticsLifecycle";
export { startCommaAnalytics, reportCommaClientError } from "./analytics/client";

declare module "@tanstack/router-core" {
  interface StaticDataRouteOption {
    commaPrimaryContentMinWidth?: number;
  }
}

export {
  apiBaseUrlStorageKey,
  defaultApiBaseUrl,
  storeCommaApiBaseUrl,
} from "./apiBaseUrl";
export type { CommaApiSessionTransport } from "./session/controller";
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
export { createCoreSessionHostController } from "./session/core-session-host-controller";
export {
  productInboxErrorMessage,
  productInboxUnavailableResult,
} from "./product-inbox/messages";
export {
  useProductInboxProjection,
  useProductInboxSnapshot,
  type ProductInboxRefresh,
} from "./product-inbox/react";
export { BrowserInspectionComposer } from "./components/chat-sidebar/BrowserInspectionComposer";
export { OnboardingWindowApp } from "./components/onboarding/window/OnboardingWindowApp";
// Re-exported so an Electron renderer can declare, at its entry point, whether
// its window has a toast surface at all. Only CommaApp and OnboardingWindowApp
// mount a <Toaster />.
export { setToastsEnabled } from "@comma/ui/components/toast";
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
  ): {
    meetingTask?: string | undefined;
    meetingGroup?: string | undefined;
    workspace?: string | undefined;
  } => ({
    workspace: typeof search.workspace === "string" ? search.workspace : undefined,
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
  validateSearch: validateTasksSearch,
});

const taskDetailRoute = createRoute({
  getParentRoute: () => shellRoute,
  path: "tasks/$workspaceId/$groupId/$conversationId",
  component: ConversationRoute,
});

// A Task a station hosts: read and written on the station, over this device's link to it.
const stationTaskRoute = createRoute({
  getParentRoute: () => shellRoute,
  path: "tasks/$workspaceId/station/$station/$thread",
  component: function StationTaskRouteView() {
    const { station, thread, workspaceId } = stationTaskRoute.useParams();
    return (
      <StationTaskRoute station={station} thread={thread} workspace={workspaceId} />
    );
  },
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
  stationTaskRoute,
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
      <CommaAppShortcutsProvider>
        <RouterProvider router={router} />
      </CommaAppShortcutsProvider>
    </CommaAppearanceProvider>
  );
}

export { MeetingRecorderWindowApp } from "./components/MeetingRecorderWindowApp";

export { SitePermissionMenuApp } from "./components/SitePermissionMenuApp";
export { TaskPanelApp } from "./components/tasks/TaskPanelApp";
