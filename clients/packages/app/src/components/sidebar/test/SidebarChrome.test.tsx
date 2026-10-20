import { initializeCommaI18n } from "@comma/i18n";
import { act, render, screen } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { useSyncExternalStore, type ReactNode } from "react";
import {
  Outlet,
  RouterProvider,
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
} from "@tanstack/react-router";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { createTestCommaAuthValue } from "../../../test/productInboxProjectionHarness";
import { CommaAuthContext } from "../../auth-context";
import { CommaWebClientSettingsProvider } from "../../commaClientSettings";
import { CommaAppShortcutsProvider } from "../../shortcuts/commaAppShortcuts";
import { SidebarChrome } from "../SidebarChrome";
import {
  CommaCenterStatusProvider,
  usePublishCommaCenterStatus,
} from "../CommaCenterStatusContext";
import {
  CommaSettingsOverlayProvider,
  useCommaSettingsOverlay,
} from "../../settingsOverlay";

// Each rail item's render, by item id ("/inbox", "settings", ...).
const railRenders = vi.hoisted(() => [] as string[]);

vi.mock("@comma/ui/components/left-rail", async (importOriginal) => {
  const [actual, React] = await Promise.all([
    importOriginal<typeof import("@comma/ui/components/left-rail")>(),
    import("react"),
  ]);
  return {
    ...actual,
    LeftRailItemControl: (props: Parameters<typeof actual.LeftRailItemControl>[0]) => {
      railRenders.push(props.item.id);
      return React.createElement(actual.LeftRailItemControl, props);
    },
  };
});

function renderRail({
  children,
  initialEntry = "/",
}: { children?: ReactNode; initialEntry?: string } = {}) {
  const auth = createTestCommaAuthValue();
  const rail = (
    <>
      {children}
      <SidebarChrome />
      <Outlet />
    </>
  );
  const rootRoute = createRootRoute({
    component: () => (
      <CommaWebClientSettingsProvider>
        <CommaAuthContext.Provider value={auth}>
          <CommaAppShortcutsProvider>
            <CommaCenterStatusProvider>
              {children ? (
                <CommaSettingsOverlayProvider>{rail}</CommaSettingsOverlayProvider>
              ) : (
                rail
              )}
            </CommaCenterStatusProvider>
          </CommaAppShortcutsProvider>
        </CommaAuthContext.Provider>
      </CommaWebClientSettingsProvider>
    ),
  });
  const pages = ["/", "/inbox", "/drive", "/tasks", "/plugins"].map((path) =>
    createRoute({ getParentRoute: () => rootRoute, path, component: () => null })
  );
  const router = createRouter({
    routeTree: rootRoute.addChildren(pages),
    history: createMemoryHistory({ initialEntries: [initialEntry] }),
  });
  render(<RouterProvider router={router} />);
  return router;
}

describe("SidebarChrome", () => {
  beforeAll(() => {
    initializeCommaI18n(["en"]);
  });
  afterEach(() => vi.restoreAllMocks());

  it("re-renders only the two links a page switch moves between", async () => {
    const router = renderRail();
    const home = await screen.findByRole("link", { name: "Home" });
    const inbox = screen.getByRole("link", { name: "Inbox" });
    expect(home).toHaveAttribute("aria-current", "page");

    railRenders.length = 0;
    await act(() => router.navigate({ to: "/inbox" }));

    expect(inbox).toHaveAttribute("aria-current", "page");
    expect(home).not.toHaveAttribute("aria-current");
    expect(new Set(railRenders)).toEqual(new Set(["/", "/inbox"]));
  });

  it("navigates on a press unless the link is already the current page", async () => {
    const router = renderRail();
    await act(() => router.navigate({ to: "/inbox" }));
    const navigate = vi.spyOn(router, "navigate");

    await userEvent.click(screen.getByRole("link", { name: "Inbox" }));
    expect(navigate).not.toHaveBeenCalled();

    await userEvent.click(screen.getByRole("link", { name: "Tasks" }));
    expect(navigate).toHaveBeenCalledWith(expect.objectContaining({ to: "/tasks" }));
    expect(router.state.location.pathname).toBe("/tasks");
  });

  it("badges a new Router reply away from Home and clears it when Home is viewed", async () => {
    vi.spyOn(document, "hasFocus").mockReturnValue(true);
    const { router, publish } = renderReplyRail("/inbox");
    const home = await screen.findByRole("link", { name: "Home" });
    const badge = () => home.querySelector('[data-slot="left-rail-item-badge"]');
    expect(badge()).toBeNull();
    // Initial history is the baseline, even when Home has not been opened.
    act(() => publish("old-reply"));
    expect(badge()).toBeNull();
    act(() => publish("new-reply"));
    expect(badge()).not.toBeNull();
    await userEvent.click(home);
    expect(router.state.location.pathname).toBe("/");
    expect(badge()).toBeNull();
    act(() => publish("reply-while-reading"));
    await act(() => router.navigate({ to: "/inbox" }));
    expect(badge()).toBeNull();
  });

  it("keeps a first reply unread under Settings and while the Home window is away", async () => {
    const focused = vi.spyOn(document, "hasFocus").mockReturnValue(true);
    const { publish } = renderReplyRail("/");
    const home = await screen.findByRole("link", { name: "Home" });
    const badge = () => home.querySelector('[data-slot="left-rail-item-badge"]');
    act(() => publish(null));
    await userEvent.click(screen.getByRole("button", { name: "Settings" }));
    act(() => publish("first-reply"));
    expect(badge()).not.toBeNull();
    await userEvent.click(screen.getByRole("button", { name: "Close settings" }));
    expect(badge()).toBeNull();
    focused.mockReturnValue(false);
    act(() => window.dispatchEvent(new Event("blur")));
    act(() => publish("background-reply"));
    expect(badge()).not.toBeNull();
    focused.mockReturnValue(true);
    act(() => window.dispatchEvent(new Event("focus")));
    expect(badge()).toBeNull();
  });

  it("keeps unread through a reconnect and drops it with the conversation owner", async () => {
    vi.spyOn(document, "hasFocus").mockReturnValue(true);
    const { publish, replaceOwner } = renderReplyRail("/inbox");
    const home = await screen.findByRole("link", { name: "Home" });
    const badge = () => home.querySelector('[data-slot="left-rail-item-badge"]');
    act(() => publish(null));
    act(() => publish("new-reply"));
    expect(badge()).not.toBeNull();
    act(() => publish(undefined));
    expect(badge()).not.toBeNull();
    act(() => publish("new-reply"));
    expect(badge()).not.toBeNull();
    act(() => replaceOwner());
    expect(badge()).toBeNull();
    act(() => publish("other-account-history"));
    expect(badge()).toBeNull();
  });
});

function renderReplyRail(initialEntry: string) {
  let snapshot = {
    owner: Symbol("home"),
    replyId: undefined as string | null | undefined,
  };
  const listeners = new Set<() => void>();
  const subscribe = (listener: () => void) => {
    listeners.add(listener);
    return () => {
      listeners.delete(listener);
    };
  };
  const getSnapshot = () => snapshot;
  function ReplyPublisher() {
    const { owner, replyId } = useSyncExternalStore(subscribe, getSnapshot);
    usePublishCommaCenterStatus(owner, { kind: "idle" }, replyId);
    const { open, closeSettings } = useCommaSettingsOverlay();
    return open ? <button onClick={closeSettings}>Close settings</button> : null;
  }
  return {
    router: renderRail({ children: <ReplyPublisher />, initialEntry }),
    publish(replyId: string | null | undefined) {
      snapshot = { ...snapshot, replyId };
      listeners.forEach((listener) => listener());
    },
    replaceOwner() {
      snapshot = { owner: Symbol("other-home"), replyId: undefined };
      listeners.forEach((listener) => listener());
    },
  };
}
