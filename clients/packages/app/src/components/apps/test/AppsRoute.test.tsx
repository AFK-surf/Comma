import type { MiniApp } from "@comma/core-client";
import {
  render as baseRender,
  screen,
  waitFor,
  within,
} from "@comma/test-utils/render";
import type { SurfaceList } from "@comma/native-bridge";
import {
  createNativeStateBridgeMock,
  installNativeBridgeMock,
} from "@comma/test-utils/native-bridge";
import { createScriptedCore, resolvedWorkspace } from "@comma/test-utils/scripted-core";
import userEvent from "@testing-library/user-event";
import {
  createMemoryHistory,
  createRootRoute,
  createRouter,
  RouterProvider,
} from "@tanstack/react-router";
import type { ReactNode } from "react";
import { describe, expect, it } from "vitest";
import { ChatSidebarProvider } from "../../chat-sidebar/ChatSidebarContext";
import { AppsRoute } from "../AppsRoute";

/** An app deployed as preview Version 2 and never published. */
const unpublished = (app: Partial<MiniApp>): MiniApp => ({
  id: "a1",
  slug: "habits",
  workspace_id: "wsp",
  name: "Habit tracker",
  description: "",
  icon_url: null,
  cover_url: null,
  repo: null,
  visibility: "workspace",
  status: "active",
  live_version: null,
  latest_version: 2,
  author: { name: "Ada" },
  capabilities: [],
  egress: [],
  secrets: [],
  grants: [],
  installed: false,
  install: null,
  storage: [],
  has_backend: false,
  created_at: "2026-10-26T00:00:00Z",
  updated_at: "2026-10-26T00:00:00Z",
  ...app,
});

/** The Apps page of Workspace `wsp`, listing `app`, on Mac (so it offers Open in window), with these windows open. */
function render(app: MiniApp, windows: SurfaceList["windows"] = []) {
  const bridge = installNativeBridgeMock({ platform: "electron", os: "macos" });
  const shown = bridge.surfaces.state;
  bridge.surfaces.state = createNativeStateBridgeMock(async () => ({
    ...(await shown()),
    windows,
  }));
  const core = createScriptedCore({
    values: (topic) => {
      if (topic.topic === "workspace") return resolvedWorkspace("wsp");
      if (topic.topic === "miniApps")
        return { status: "ready", apps: [app], error: null };
      return undefined;
    },
  });
  const router = createRouter({
    routeTree: createRootRoute({
      component: () => (
        <ChatSidebarProvider>
          <AppsRoute />
        </ChatSidebarProvider>
      ),
    }),
    history: createMemoryHistory(),
  });
  baseRender(<RouterProvider router={router} />, {
    wrapper: ({ children }: { children: ReactNode }) => core.wrap(children),
  });
  return bridge;
}

async function openActions() {
  const card = await screen.findByTestId("apps-card");
  await userEvent.click(within(card).getByRole("button", { name: "App actions" }));
  return screen.findByRole("menu");
}

describe("an unpublished app on the Apps page", () => {
  // The server runs the owner's latest ready preview until publication, without the page naming a Version; the page
  // opened nothing before it.
  it("opens its latest preview for its own Workspace", async () => {
    const bridge = render(unpublished({}));
    expect(await screen.findByText(/^Not published yet · /)).toBeTruthy();
    const menu = await openActions();
    const open = within(menu).getByRole("menuitem", { name: "Open" });
    expect(open.getAttribute("aria-disabled")).toBeNull();
    await userEvent.click(
      within(menu).getByRole("menuitem", { name: "Open in window" })
    );
    expect(bridge.windows.create).toHaveBeenCalledWith({
      route: "/apps/wsp/a1/window",
      bounds: expect.objectContaining({ width: expect.any(Number) }),
    });
  });

  // Another Workspace runs only the live Version, which an unpublished app does not have.
  it("stays closed to another Workspace", async () => {
    render(unpublished({ workspace_id: "other", installed: true }));
    const menu = await openActions();
    for (const name of ["Open", "Open in window"])
      expect(
        within(menu).getByRole("menuitem", { name }).getAttribute("aria-disabled")
      ).toBe("true");
  });
});

describe("an app in a window of its own", () => {
  it("comes to the front instead of opening in another", async () => {
    const bridge = render(unpublished({}), [
      {
        id: "win_dynamic_1",
        surfaceId: "win_dynamic_1",
        owner: { id: "app", kind: "app" },
        role: "main-window",
        lifecycle: "ready",
        route: "/apps/wsp/a1/window",
        bounds: { x: 0, y: 0, width: 440, height: 760 },
        focused: false,
        visible: true,
        state: "normal",
      },
    ]);
    const menu = await openActions();
    await userEvent.click(
      within(menu).getByRole("menuitem", { name: "Open in window" })
    );
    await waitFor(() =>
      expect(bridge.windows.focus).toHaveBeenCalledWith({ windowId: "win_dynamic_1" })
    );
    expect(bridge.windows.create).not.toHaveBeenCalled();
  });
});
