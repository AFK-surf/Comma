import type { SurfaceList } from "@comma/native-bridge";
import { act, render as baseRender, screen } from "@comma/test-utils/render";
import {
  createNativeBridgeMock,
  createNativeStateBridgeMock,
  installNativeBridgeMock,
} from "@comma/test-utils/native-bridge";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import userEvent from "@testing-library/user-event";
import {
  createMemoryHistory,
  createRootRoute,
  createRouter,
  RouterProvider,
} from "@tanstack/react-router";
import type { ReactNode } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ChatSidebarAppPage } from "../../chat-sidebar/ChatSidebarContext";
import { miniAppWindowRoute, useMiniAppWindows } from "../miniAppOpen";
import { SidebarMiniApp } from "../SidebarMiniApp";

const page: ChatSidebarAppPage = {
  id: "p1",
  appId: "a1",
  workspaceId: "wsp",
  name: "Habit tracker",
};

const info = {
  session: "mas-1",
  app: {
    id: "a1",
    name: "Habit tracker",
    author: { name: "Ada" },
    status: "active",
    capabilities: [],
    egress: [],
    grants: [],
  },
  version: 2,
  digest: "d",
  guest: false,
  viewer: { id: "v", name: "Ada", avatarUrl: null, guest: false },
  capabilities: [],
  grants: [],
  storage: [],
};

/** The app's window, as the shell lists it from the moment it is created (before it shows). */
const appWindow: SurfaceList["windows"][number] = {
  id: "win_dynamic_1",
  surfaceId: "win_dynamic_1",
  owner: { id: "app", kind: "app" },
  role: "main-window",
  lifecycle: "ready",
  route: miniAppWindowRoute(page),
  bounds: { x: 0, y: 0, width: 440, height: 760 },
  focused: true,
  visible: true,
  state: "normal",
};

/** The shell's windows, which a test opens and closes. */
let setWindows: (windows: SurfaceList["windows"]) => void;
let bridge: ReturnType<typeof installNativeBridgeMock>;

beforeEach(async () => {
  let list: SurfaceList = {
    ...(await createNativeBridgeMock().surfaces.state()),
    windows: [],
  };
  const listeners = new Set<(list: SurfaceList) => void>();
  const state = createNativeStateBridgeMock(() => list);
  state.subscribe = vi.fn((listener: (list: SurfaceList) => void) => {
    listeners.add(listener);
    listener(list);
    return () => listeners.delete(listener);
  }) as typeof state.subscribe;
  setWindows = (windows) => {
    list = { ...list, windows };
    act(() => listeners.forEach((listener) => listener(list)));
  };
  bridge = installNativeBridgeMock({
    platform: "electron",
    os: "macos",
    surfaces: { state },
  });
});

/** The panel's app as the right panel shows it: told which window, if any, the app runs in. */
function Panel() {
  const windows = useMiniAppWindows();
  return (
    <SidebarMiniApp
      host={undefined}
      page={page}
      windowId={windows.get(miniAppWindowRoute(page))}
    />
  );
}

function render() {
  const core = createScriptedCore({
    calls: (name) => (name === "miniApps.session.open" ? info : null),
  });
  const router = createRouter({
    routeTree: createRootRoute({ component: Panel }),
    history: createMemoryHistory(),
  });
  baseRender(<RouterProvider router={router} />, {
    wrapper: ({ children }: { children: ReactNode }) => core.wrap(children),
  });
}

describe("a panel's app in a window of its own", () => {
  it("keeps its tab and shows its window in its place, then runs again once the window closes", async () => {
    render();
    await screen.findByTestId("mini-app-frame");

    // Opened from anywhere (the Apps page, a chat card): the app runs in one place at a time.
    setWindows([appWindow]);
    expect(screen.getByTestId("mini-app-notice-in-window")).toBeTruthy();
    expect(screen.queryByTestId("mini-app-frame")).toBeNull();

    await userEvent.click(screen.getByRole("button", { name: "Show window" }));
    expect(bridge.windows.focus).toHaveBeenCalledWith({ windowId: "win_dynamic_1" });
    await userEvent.click(screen.getByRole("button", { name: "Move back to panel" }));
    expect(bridge.windows.close).toHaveBeenCalledWith({ windowId: "win_dynamic_1" });

    setWindows([]);
    expect(await screen.findByTestId("mini-app-frame")).toBeTruthy();
    expect(screen.queryByTestId("mini-app-notice-in-window")).toBeNull();
  });

  it("keeps the app on screen until the window it moves to shows", async () => {
    let shown!: () => void;
    vi.mocked(bridge.windows.create).mockImplementation(
      () =>
        new Promise((resolve) => {
          shown = () => resolve({} as SurfaceList);
        })
    );
    render();
    await screen.findByTestId("mini-app-frame");
    await userEvent.click(screen.getByRole("button", { name: "App actions" }));
    await userEvent.click(
      await screen.findByRole("menuitem", { name: "Open in window" })
    );
    expect(bridge.windows.create).toHaveBeenCalledWith({
      route: "/apps/wsp/a1/window",
      bounds: expect.objectContaining({ width: expect.any(Number) }),
    });

    // The shell lists the window while it still loads, before it shows over the panel.
    setWindows([appWindow]);
    expect(screen.getByTestId("mini-app-frame")).toBeTruthy();

    await act(async () => shown());
    expect(screen.getByTestId("mini-app-notice-in-window")).toBeTruthy();
    expect(screen.queryByTestId("mini-app-frame")).toBeNull();
  });
});
