import { installMiniAppRunLinkClicks, openMiniAppRunLink } from "./miniAppRunLink";
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
import { AppsRoute } from "./components/apps/AppsRoute";
import { AppLinkRoute } from "./components/apps/AppLinkRoute";
import { AppWindowRoute } from "./components/apps/AppWindowRoute";
import { adoptMiniAppLinkLocation } from "./miniAppLink";

export { CommaAnalyticsLifecycle } from "./analytics/CommaAnalyticsLifecycle";
export { miniAppLinkTokenFromLocation } from "./miniAppLink";
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
    workspace?: string | undefined;
  } => ({
    workspace: typeof search.workspace === "string" ? search.workspace : undefined,
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

const pluginsRoute = createRoute({
  getParentRoute: () => shellRoute,
  path: "plugins",
  component: PluginsRoute,
});

// Mini Apps: the Apps gallery, an app's settings over it, an app beside it, and an app link.
const appsRoute = createRoute({
  getParentRoute: () => shellRoute,
  path: "apps",
  component: AppsRoute,
});

const appLinkRoute = createRoute({
  getParentRoute: () => shellRoute,
  path: "apps/link/$token",
  component: function AppLinkRouteView() {
    const { token } = appLinkRoute.useParams();
    return <AppLinkRoute key={token} token={token} />;
  },
});

// An app's settings are a dialog over the Apps gallery; this address opens them there.
const appSettingsRoute = createRoute({
  getParentRoute: () => shellRoute,
  path: "apps/$workspaceId/$appId",
  component: function AppSettingsRouteView() {
    const { workspaceId, appId } = appSettingsRoute.useParams();
    return <AppsRoute settingsFor={{ workspaceId, appId }} />;
  },
});

// A Task card's preview Version of an app; the live Version where absent.
function validateAppVersionSearch(search: Record<string, unknown>): {
  version?: number;
} {
  const version = Number(search["version"]);
  return Number.isSafeInteger(version) && version > 0 ? { version } : {};
}

// An app's address (the link the Router gives): the gallery, with the app opened in the right panel beside it.
const appRunRoute = createRoute({
  getParentRoute: () => shellRoute,
  path: "apps/$workspaceId/$appId/run",
  validateSearch: validateAppVersionSearch,
  component: function AppRunRouteView() {
    const { workspaceId, appId } = appRunRoute.useParams();
    const { version } = appRunRoute.useSearch();
    return <AppsRoute openFor={{ workspaceId, appId, version }} />;
  },
});

// An app in its own window (Mac "Open in window"): inside the signed-in session, outside the product shell, so the
// window shows the app alone rather than another Comma.
const appWindowRoute = createRoute({
  getParentRoute: () => authedRoute,
  path: "apps/$workspaceId/$appId/window",
  validateSearch: validateAppVersionSearch,
  component: function AppWindowRouteView() {
    const { workspaceId, appId } = appWindowRoute.useParams();
    const { version } = appWindowRoute.useSearch();
    return (
      <AppWindowRoute
        appId={appId}
        key={`${appId}:${version ?? ""}`}
        version={version}
        workspaceId={workspaceId}
      />
    );
  },
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
  appsRoute,
  appLinkRoute,
  appSettingsRoute,
  appRunRoute,
  inboxRouteTree,
  driveRoute,
  pluginsRoute,
  settingsRoute,
  taskDetailRoute,
  tasksRoute,
});

const authedRouteTree = authedRoute.addChildren({
  appWindowRoute,
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
  // The current document owns its hash route, including when served from a preview path.
  const initialUrl = useMemo(
    () => new URL(`/${window.location.hash}`, window.location.href).href,
    []
  );
  const router = useMemo(() => {
    // A page opened at an app link continues at its hash route.
    adoptMiniAppLinkLocation(window.location, window.history);
    return createCommaRouter();
  }, []);
  useEffect(() => installMiniAppRunLinkClicks(document), []);
  useEffect(() => {
    openMiniAppRunLink(initialUrl);
  }, [initialUrl]);
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
