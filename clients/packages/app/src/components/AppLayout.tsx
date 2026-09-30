import { PluginInstallProvider } from "./plugins/PluginInstallProvider";
import { useCommaMessages } from "@comma/i18n/react";
import {
  Outlet,
  useMatches,
  useNavigate,
  useRouterState,
} from "@tanstack/react-router";
import { getNativeBridge, type NativeInfo } from "@comma/native-bridge";
import {
  ChatPanelVideoPictureInPictureProvider,
  ChatPanelVideoSurfaceProvider,
  OverlayPortalProvider,
  Toaster,
} from "@comma/ui";
import {
  Suspense,
  useCallback,
  createContext,
  lazy,
  useContext,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { scrubLegacyRendererAuthMetadata } from "../api/config";
import { AutomaticUpdates } from "./AutomaticUpdates";
import { AppSettingsRoute } from "./AppSettingsRoute";
import { CommaAuthGate, useCommaAuth } from "./AuthGate";
import { WindowBar } from "./WindowBar";
import { ChatConsumerBoundary, ChatSessionProvider } from "./chat/ChatProvider";
import { HomeConversationTargetBootstrap } from "./chat/HomeConversationTargetBootstrap";
import { HomeRoute } from "./RouteScreens";
import { RecommendationMockDebugSettingsRoute } from "../devtools/recommendation-mock/RecommendationMockDebugSettingsRoute";
import { ChatSidebar } from "./chat-sidebar/ChatSidebar";
import { ChatSidebarProvider, useChatSidebar } from "./chat-sidebar/ChatSidebarContext";
import { CommaSidebarPanel } from "./sidebar/SidebarPanel";
import { CommaSidebarProvider, useCommaSidebar } from "./sidebar/SidebarContext";
import {
  CommaSettingsOverlayProvider,
  useCommaSettingsOverlay,
} from "./settingsOverlay";
import {
  chatSidebarMaxWidthForFrame,
  commaDefaultPrimaryContentMinWidth,
  commaHomeGreetPreferredMinWidth,
  commaHomeRailFoldsOpen,
  commaHomeTasksPreferredWidth,
  commaSidebarRailWidth,
  railFitsFrame,
} from "./shellGeometry";
import { isHomePath, showsProductRouteOutlet } from "./productShellPaths";
import { HomeRailFoldProvider, HomeRailFolds } from "./home/HomeRailFolds";
import {
  toggleCollapsedHomeRail,
  useCollapsedHomeRails,
} from "./home/homeRailCollapse";
import {
  isWindowResizing,
  subscribeWindowResizing,
  useWindowResizingFlag,
} from "./shellResizeSettle";
import { SidebarChrome } from "./sidebar/SidebarChrome";
import { CommandPaletteProvider } from "./search/CommandPaletteContext";
import {
  CommaCenterStatusOwner,
  CommaCenterStatusProvider,
} from "./sidebar/CommaCenterStatusContext";
import { AppProductShortcutListener } from "./shortcuts/useAppShortcutListener";
import { MeetingRecorderHost } from "./MeetingRecorderHost";
import { NotchTaskSync } from "./tasks/NotchTaskSync";
import { MessageNotificationSync } from "./notifications/MessageNotificationSync";
import { AirDropToasts } from "./airdrop/AirDropToasts";
import { CommaConnectorRuntimeOwner } from "./useCommaConnectorScope";

declare const COMMA_DEFINED_BUILD_FLAVOR: string | undefined;

export function settingsRouteComponentForBuildFlavor(buildFlavor: string | undefined) {
  return buildFlavor === "dev"
    ? RecommendationMockDebugSettingsRoute
    : AppSettingsRoute;
}

// Vite replaces this value at build time. Prod/staging builds therefore drop
// the Debug wrapper and its mock-only API/UI dependency graph.
const SettingsRouteComponent =
  typeof COMMA_DEFINED_BUILD_FLAVOR !== "undefined" &&
  COMMA_DEFINED_BUILD_FLAVOR === "dev"
    ? RecommendationMockDebugSettingsRoute
    : AppSettingsRoute;

const CommaNavTraceRoot = import.meta.env.DEV
  ? lazy(() =>
      import("../devtools/CommaNavTraceRoot").then((module) => ({
        default: module.CommaNavTraceRoot,
      }))
    )
  : null;

const NativeInfoContext = createContext<NativeInfo>({
  appVersion: "unknown",
  os: "unknown",
  platform: "web",
});

const DevLayoutInspector = import.meta.env.DEV
  ? lazy(() =>
      import("@comma/layout-inspector").then((module) => ({
        default: module.LayoutInspector,
      }))
    )
  : null;

// Root layout: resolve native info once and expose it. The route hierarchy
// decides workbench vs the authenticated product session. Settings is a
// location of that session, not a competing layout.
export function CommaRootLayout() {
  const nativeInfo = useNativeInfo();

  useEffect(() => {
    scrubLegacyRendererAuthMetadata();
  }, []);

  return (
    <NativeInfoContext.Provider value={nativeInfo}>
      <AutomaticUpdates />
      <Outlet />
      {/* Toasts are renderer-local: one stack per window, anchored to this
          window's own bottom-right corner. A sibling of the shell rather than a
          child of it, so `position: fixed` resolves against the viewport and no
          `overflow: hidden` ancestor can clip the card or its shadow. */}
      <Toaster />
      {CommaNavTraceRoot ? (
        <Suspense fallback={null}>
          <CommaNavTraceRoot />
        </Suspense>
      ) : null}
      {DevLayoutInspector ? (
        <Suspense fallback={null}>
          <DevLayoutInspector />
        </Suspense>
      ) : null}
    </NativeInfoContext.Provider>
  );
}

// Pathless authenticated session: one AuthGate, one chat-session owner, one
// Outlet. The Outlet always renders the product route host; Settings is a
// location inside that host, never a sibling match that tears an
// already-committed Home down (that remounts Home and flashes the empty
// "Do anything" starter).
export function CommaAuthenticatedLayout() {
  return (
    <CommaAuthGate>
      <CommaAuthenticatedSession />
    </CommaAuthGate>
  );
}

function CommaAuthenticatedSession() {
  const { api, productLease, sessionSignal } = useCommaAuth();

  return (
    <ChatSessionProvider
      api={api}
      productLease={productLease}
      sessionSignal={sessionSignal}
    >
      <PluginInstallProvider api={api} sessionSignal={sessionSignal}>
        <CommandPaletteProvider>
          <CommaConnectorRuntimeOwner api={api} />
          <CommaCenterStatusProvider>
            <ChatConsumerBoundary>
              <NotchTaskSync />
              <MessageNotificationSync />
              <AirDropToasts />
              <HomeConversationTargetBootstrap />
              <CommaCenterStatusOwner />
            </ChatConsumerBoundary>
            <Outlet />
          </CommaCenterStatusProvider>
        </CommandPaletteProvider>
      </PluginInstallProvider>
    </ChatSessionProvider>
  );
}

// Product session host: the window bar, the icon rail and the content panel.
// Every product location — Settings included — is a surface inside that
// panel. Once Home has been mounted it stays in one React slot and in layout
// (`visibility: hidden`, not `display: none`) while another location shows, so
// its container queries and scroll do not collapse; the paused marker tells
// chat image observers not to drop preview leases. Hidden Home stays live: an
// arrival animation in flight still finishes there, so Home is not hidden
// with `content-visibility`, which freezes the animations it skips. Product
// portals render into the host below, outside every chat-consumer boundary.
export function CommaProductLayout() {
  const productPortalHost = useRef<HTMLDivElement>(null);
  const getProductPortalHost = useCallback(() => productPortalHost.current, []);

  return (
    <OverlayPortalProvider getContainer={getProductPortalHost}>
      <div className="h-screen min-h-0 w-full">
        <div data-comma-product-portal-host="" ref={productPortalHost} />
        <CommaProductSessionLayout />
      </div>
    </OverlayPortalProvider>
  );
}

function CommaProductSessionLayout() {
  const nativeInfo = useContext(NativeInfoContext);

  return (
    <ChatSidebarProvider>
      <CommaProductLayoutFrame nativeInfo={nativeInfo} />
    </ChatSidebarProvider>
  );
}

// The widest content minimum any matched route declares. Only the rail's fit
// and the Chat Sidebar's ceiling depend on it, so each reads it where it is
// used: a page switch that changes it re-renders those two and restyles the
// sidebar, not the whole frame and every element under the shell root.
function usePrimaryContentMinWidth() {
  return useMatches({
    select: (matches) =>
      matches.reduce(
        (minimum, match) =>
          Math.max(
            minimum,
            match.staticData.commaPrimaryContentMinWidth ??
              commaDefaultPrimaryContentMinWidth
          ),
        commaDefaultPrimaryContentMinWidth
      ),
  });
}

function CommaProductLayoutFrame({ nativeInfo }: { nativeInfo: NativeInfo }) {
  // Held as state so the rail-fit observer attaches once the shell exists.
  const [shellElement, setShellElement] = useState<HTMLElement | null>(null);

  return (
    <main
      className="comma-app-shell flex h-screen min-h-0 w-full min-w-0 bg-window pb-md pr-md text-primary"
      data-os={nativeInfo.os}
      data-platform={nativeInfo.platform}
      ref={setShellElement}
    >
      <CommaSettingsOverlayProvider>
        <CommaRailFitProvider shellElement={shellElement}>
          <CommaProductFrame />
        </CommaRailFitProvider>
      </CommaSettingsOverlayProvider>
    </main>
  );
}

// Feeds the rail its geometry veto. Lives between the shell and the frame so
// the Chat Sidebar and route subscriptions re-render only this wrapper and the
// rail provider; the frame below is the same element and is not re-rendered.
function CommaRailFitProvider({
  children,
  shellElement,
}: {
  children: ReactNode;
  shellElement: HTMLElement | null;
}) {
  const { isOpen: chatSidebarOpen } = useChatSidebar();
  const primaryContentMinWidth = usePrimaryContentMinWidth();
  const railFits = useRailFits({
    chatSidebarOpen,
    primaryContentMinWidth,
    shellElement,
  });

  return (
    <CommaSidebarProvider chatSidebarOpen={chatSidebarOpen} railFits={railFits}>
      {children}
    </CommaSidebarProvider>
  );
}

// Whether the shell's content box (the window frame) holds the rail beside the
// route and an open Chat Sidebar. Observed per frame like the sidebar ceiling,
// but only the boolean reaches React: a resize within one answer re-renders
// nothing.
function useRailFits({
  chatSidebarOpen,
  primaryContentMinWidth,
  shellElement,
}: {
  chatSidebarOpen: boolean;
  primaryContentMinWidth: number;
  shellElement: HTMLElement | null;
}) {
  const [fits, setFits] = useState(true);
  useLayoutEffect(() => {
    if (!shellElement) return undefined;
    const observer = new ResizeObserver(([entry]) => {
      setFits(
        railFitsFrame({
          chatSidebarOpen,
          frameWidth: entry?.contentRect.width ?? 0,
          primaryContentMinWidth,
        })
      );
    });
    observer.observe(shellElement);
    return () => observer.disconnect();
  }, [chatSidebarOpen, primaryContentMinWidth, shellElement]);
  return fits;
}

// The window frame stacks the window bar over a row of the icon rail and the
// content panel. The bar spans the whole frame, so the traffic lights, history
// and search hint never move with anything the row does. Chat consumers sit
// inside keyed boundaries, so a product-lease generation bump remounts them
// without touching the shell chrome around them.
function CommaProductFrame() {
  // Held as state, not a ref: the Chat Sidebar's slot measures this element in
  // a layout effect, and React attaches an ancestor's ref only after its
  // descendants' layout effects have run.
  const [frameElement, setFrameElement] = useState<HTMLDivElement | null>(null);
  useWindowResizingFlag();

  return (
    <div
      className="comma-window-frame relative flex min-h-0 w-full min-w-0 flex-col bg-window"
      ref={setFrameElement}
    >
      <AppProductShortcutListener />
      <ChatConsumerBoundary>
        <WindowBar />
      </ChatConsumerBoundary>
      <div className="comma-window-body flex min-h-0 min-w-0 flex-1">
        <CommaSidebarPanel>
          <SidebarChrome />
        </CommaSidebarPanel>
        <CommaContent frameElement={frameElement} />
      </div>
    </div>
  );
}

function CommaContent({ frameElement }: { frameElement: HTMLElement | null }) {
  const messages = useCommaMessages();
  const [recorderArea, setRecorderArea] = useState<HTMLDivElement | null>(null);
  const { chatSidebarOpen, collapsed } = useCommaSidebar();
  const navigate = useNavigate();
  const handleConnectApps = useCallback(() => {
    void navigate({ to: "/plugins" });
  }, [navigate]);
  const revealHome = useCallback(() => {
    void navigate({ to: "/" });
  }, [navigate]);
  const pathname = useRouterState({
    select: (state) => state.location.pathname,
  });
  const accountKey = useProductAccountKey();
  const homeVisible = isHomePath(pathname);
  const { open: settingsOpen } = useCommaSettingsOverlay();
  const showProductRoute = showsProductRouteOutlet(pathname);
  // Home is retained once mounted — for the account that mounted it. A
  // signed-in session change drops the previous account's surface, so the
  // next account mounts Home only when it visits it.
  const [homeSurface, setHomeSurface] = useState(() => ({
    accountKey,
    mounted: homeVisible,
  }));
  const homeSurfaceRef = useRef<HTMLDivElement | null>(null);
  const [railFolds, setRailFolds] = useState(commaHomeRailFoldsOpen);
  // Collapsing a rail is a reading choice, not a geometry one: it survives
  // every window width the route can hold the rail at, route changes, and
  // the app's next launch (homeRailCollapse.ts).
  const railCollapsed = useCollapsedHomeRails();
  const [railWidths, setRailWidths] = useState({
    greet: commaHomeGreetPreferredMinWidth,
    tasks: commaHomeTasksPreferredWidth,
  });
  const setRailWidth = useCallback((rail: "greet" | "tasks", width: number) => {
    setRailWidths((current) =>
      current[rail] === width ? current : { ...current, [rail]: width }
    );
  }, []);
  const railState = useMemo(
    () => ({
      widths: railWidths,
      setWidth: setRailWidth,
      collapsed: railCollapsed,
      folds: railFolds,
      toggleCollapsed: toggleCollapsedHomeRail,
    }),
    [railCollapsed, railFolds, railWidths, setRailWidth]
  );

  if (homeSurface.accountKey !== accountKey || (homeVisible && !homeSurface.mounted)) {
    setHomeSurface({ accountKey, mounted: homeVisible });
  }
  const homeMounted = homeSurface.mounted;

  return (
    <section
      aria-label={messages.shell_content()}
      className="comma-content relative flex min-h-0 min-w-0 flex-1 overflow-clip bg-main-panel-bg"
      data-chat-sidebar-open={chatSidebarOpen ? "true" : "false"}
      data-sidebar-collapsed={collapsed ? "true" : "false"}
    >
      {/* A playing video keeps playing in a floating window, held in the route
          area like the recorder: native browser views paint above the DOM. */}
      <ChatPanelVideoPictureInPictureProvider containment={recorderArea}>
        <div
          className="comma-route-outlet relative flex min-h-0 min-w-0 flex-1"
          ref={setRecorderArea}
          data-testid="comma-route-outlet"
        >
          <ChatConsumerBoundary>
            {homeMounted ? (
              <div
                aria-hidden={homeVisible ? undefined : true}
                className="absolute inset-0 flex min-h-0 min-w-0"
                data-comma-surface-paused={homeVisible ? undefined : "true"}
                inert={homeVisible ? undefined : true}
                ref={homeSurfaceRef}
                style={
                  homeVisible
                    ? undefined
                    : { pointerEvents: "none", visibility: "hidden" }
                }
              >
                <ChatPanelVideoSurfaceProvider
                  reveal={revealHome}
                  visible={homeVisible}
                >
                  <HomeRailFoldProvider state={railState}>
                    <HomeRoute
                      onConnectApps={handleConnectApps}
                      surfaceActive={homeVisible}
                    />
                  </HomeRailFoldProvider>
                </ChatPanelVideoSurfaceProvider>
              </div>
            ) : null}
            {homeMounted ? (
              <HomeRailFolds
                active={homeVisible}
                greetWidth={railWidths.greet}
                greetCollapsed={railCollapsed.greet}
                onStateChange={setRailFolds}
                routeRef={homeSurfaceRef}
              />
            ) : null}
            {showProductRoute ? (
              <div className="relative z-[1] flex min-h-0 min-w-0 flex-1">
                <Outlet />
              </div>
            ) : null}
          </ChatConsumerBoundary>
          {settingsOpen ? <CommaSettingsSurface /> : null}
        </div>
        {/* Native browser views paint above DOM. Keep client controls in the route
          area; Main still owns capture across projection remounts. */}
        <MeetingRecorderHost containment={recorderArea} />
        <ChatConsumerBoundary>
          <ChatSidebarSlot
            appSidebarFloor={collapsed ? 0 : commaSidebarRailWidth}
            frameElement={frameElement}
          />
        </ChatConsumerBoundary>
      </ChatPanelVideoPictureInPictureProvider>
    </section>
  );
}

// The signed-in account without the product-lease generation: a same-session
// reconcile bumps the generation and remounts every chat consumer, but
// nothing that is keyed by the account.
function useProductAccountKey() {
  const { productLease } = useCommaAuth();
  return JSON.stringify([
    productLease.audience,
    productLease.authorityInstanceId,
    productLease.sessionId,
  ]);
}

// The settings modal renders beside the keyed chat-consumer boundary, so a
// product-lease generation bump cannot wipe its local state; it re-keys only
// when the signed-in session itself changes.
function CommaSettingsSurface() {
  const accountKey = useProductAccountKey();

  return <SettingsRouteComponent key={accountKey} />;
}

// The Chat Sidebar's ceiling is a pure function of the window frame and the
// route's content minimum. It bounds the sidebar's drag and keyboard resizing,
// which cannot happen while the window itself is being dragged; the rendered
// width follows the frame live in CSS (styles.css pins the sidebar to 100cqw
// minus the route minimum). So the frame width commits once the window
// settles, not once per resized frame: a per-frame commit re-rendered the
// whole sidebar — and the conversation in it — on every frame of every window
// drag. It lives here rather than in `CommaContent` so a page switch that moves
// the minimum does not re-render Home and its conversation.
function ChatSidebarSlot({
  appSidebarFloor,
  frameElement,
}: {
  appSidebarFloor: number;
  frameElement: HTMLElement | null;
}) {
  const frameWidth = useSettledElementWidth(frameElement);
  const primaryContentMinWidth = usePrimaryContentMinWidth();

  return (
    <ChatSidebar
      maxWidth={chatSidebarMaxWidthForFrame({
        appSidebarFloor,
        frameWidth,
        primaryContentMinWidth,
      })}
      primaryContentMinWidth={primaryContentMinWidth}
    />
  );
}

// Border-box width of an element as of the last settled window size (0 until
// measured or where ResizeObserver is unavailable). Resizes outside a window
// drag commit as they happen; a window drag commits once, when it settles —
// before any sidebar drag can anchor on the value.
function useSettledElementWidth(element: HTMLElement | null) {
  const [width, setWidth] = useState(0);
  useLayoutEffect(() => {
    if (!element || typeof ResizeObserver === "undefined") return undefined;
    const read = () => {
      if (!isWindowResizing()) setWidth(element.getBoundingClientRect().width);
    };
    read();
    const observer = new ResizeObserver(read);
    observer.observe(element);
    const unsubscribe = subscribeWindowResizing(read);
    return () => {
      observer.disconnect();
      unsubscribe();
    };
  }, [element]);
  return width;
}

// Bare host for the dev-only runtime workbench: no auth gate, no shell chrome.
export function CommaWorkbenchHost({ children }: { children: ReactNode }) {
  const nativeInfo = useContext(NativeInfoContext);

  return (
    <main
      className="comma-runtime-workbench-host h-screen min-h-0 w-full min-w-0"
      data-os={nativeInfo.os}
      data-platform={nativeInfo.platform}
    >
      {children}
    </main>
  );
}

function useNativeInfo() {
  const [nativeInfo, setNativeInfo] = useState<NativeInfo>(() => {
    const bridge = getNativeBridge();
    return {
      appVersion: "unknown",
      os: bridge.os,
      platform: bridge.platform,
    };
  });

  useEffect(() => {
    let active = true;

    void getNativeBridge()
      .native.info()
      .then((info) => {
        if (active) {
          setNativeInfo(info);
        }
      });

    return () => {
      active = false;
    };
  }, []);

  return nativeInfo;
}
