import userEvent from "@testing-library/user-event";
import {
  commaClientAppShortcutOverridesSchema,
  defaultCommaClientSettings,
} from "@comma/native-bridge";
import {
  Outlet,
  RouterProvider,
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
} from "@tanstack/react-router";
import { act } from "react";
import { render, screen, waitFor, within } from "@comma/test-utils/render";
import { sequenceKeybinding } from "@comma/ui";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { WindowBar } from "../components/WindowBar";
import { ChatSidebarProvider } from "../components/chat-sidebar/ChatSidebarContext";
import {
  CommaWebClientSettingsProvider,
  commaClientSettingsStorageKey,
} from "../components/commaClientSettings";
import { CommaSidebarProvider } from "../components/sidebar/SidebarContext";
import { CommaAppShortcutsProvider } from "../components/shortcuts/commaAppShortcuts";
import type { TaskViewModel } from "../components/tasks/useWorkspaceTasks";

const mocks = vi.hoisted(() => ({
  openCommandPalette: vi.fn(),
  workspace: {
    activeGroupId: "grp_1" as string | undefined,
    activeWorkspaceId: "wsp_1" as string | undefined,
    tasks: [] as TaskViewModel[],
  },
}));

vi.mock("../components/tasks/useWorkspaceTasks", () => ({
  useWorkspaceTasks: () => mocks.workspace,
}));

// The palette itself is the search product surface's concern; the bar only
// has to hand the press to it.
vi.mock("../components/search/CommandPaletteContext", () => ({
  useCommandPalette: () => ({
    close: vi.fn(),
    isOpen: false,
    open: mocks.openCommandPalette,
    toggle: vi.fn(),
  }),
}));

describe("WindowBar", () => {
  beforeEach(() => {
    mocks.openCommandPalette.mockClear();
    mocks.workspace.tasks = [];
  });

  it("enables history arrows only when navigation is available", async () => {
    const router = renderWindowBar();
    const back = await screen.findByRole("button", { name: "Back" });
    const forward = screen.getByRole("button", { name: "Forward" });

    expect(back).toBeDisabled();
    expect(forward).toBeDisabled();

    await act(() => router.navigate({ to: "/plugins" }));

    await waitFor(() => expect(back).toBeEnabled());
    expect(forward).toBeDisabled();

    await userEvent.click(back);

    await waitFor(() => expect(back).toBeDisabled());
    expect(forward).toBeEnabled();

    await userEvent.click(forward);

    await waitFor(() => expect(back).toBeEnabled());
    expect(forward).toBeDisabled();
  });

  it.each([
    { expectedHint: "Use ⌘K for search", platform: "MacIntel" },
    { expectedHint: "Use Ctrl+K for search", platform: "Win32" },
  ])(
    "shows the go-search chord for $platform in the search hint and opens the command palette",
    async ({ expectedHint, platform }) => {
      vi.spyOn(window.navigator, "platform", "get").mockReturnValue(platform);
      const router = renderWindowBar();

      const hint = await screen.findByTestId("comma-window-bar-search");
      expect(screen.getByTestId("comma-window-bar")).toContainElement(hint);
      expect(hint).toHaveTextContent(expectedHint);

      await userEvent.click(hint);

      // Search is a palette over the current route, not a location.
      expect(mocks.openCommandPalette).toHaveBeenCalledTimes(1);
      expect(router.state.location.pathname).toBe("/");
    }
  );

  it("formats a customised go-search sequence in the search hint", async () => {
    seedAppShortcutOverrides({
      "go-search": sequenceKeybinding("KeyG", "KeyF"),
    });
    renderWindowBar();

    expect(await screen.findByTestId("comma-window-bar-search")).toHaveTextContent(
      "Use G F for search"
    );
  });

  it("falls back to the plain Search label when go-search is cleared", async () => {
    seedAppShortcutOverrides({ "go-search": null });
    renderWindowBar();

    const hint = await screen.findByTestId("comma-window-bar-search");
    expect(hint).toHaveTextContent("Search");
    expect(hint).not.toHaveTextContent("for search");
  });

  it("opens and closes the Chat Sidebar from the window bar", async () => {
    renderWindowBar();

    const toggle = await screen.findByRole("button", { name: "Toggle chat sidebar" });
    expect(toggle).toHaveClass("comma-chat-sidebar-toggle");
    expect(toggle).toHaveAttribute("aria-expanded", "false");

    await userEvent.click(toggle);

    expect(toggle).toHaveAttribute("aria-expanded", "true");

    await userEvent.click(toggle);

    expect(toggle).toHaveAttribute("aria-expanded", "false");
  });

  it("lists recent tasks newest first and opens the selected one", async () => {
    mocks.workspace.tasks = [
      {
        conversationId: "cnv_older",
        groupId: "grp_1",
        statusBucket: "done",
        title: "Older task",
        updatedAt: 10,
        workspaceId: "wsp_1",
      },
      {
        conversationId: "cnv_newer",
        groupId: "grp_1",
        statusBucket: "in_progress",
        title: "Newer task",
        updatedAt: 20,
        workspaceId: "wsp_1",
      },
    ] as TaskViewModel[];
    const router = renderWindowBar();

    await userEvent.click(await screen.findByRole("button", { name: "Recent tasks" }));

    const menu = await screen.findByRole("menu", { name: "Recent tasks" });
    expect(
      within(menu).getByRole("group", { name: "Recent tasks" })
    ).toBeInTheDocument();
    const items = within(menu).getAllByRole("menuitem");
    expect(items).toHaveLength(2);
    expect(items[0]).toHaveAccessibleName("Newer task");
    expect(items[1]).toHaveAccessibleName("Older task");
    expect(within(menu).queryByTestId("comma-recent-tasks-empty")).toBeNull();

    await userEvent.click(within(menu).getByRole("menuitem", { name: "Newer task" }));

    await waitFor(() =>
      expect(router.state.location.pathname).toBe("/tasks/wsp_1/grp_1/cnv_newer")
    );
    await waitFor(() => expect(screen.queryByRole("menu")).not.toBeInTheDocument());
  });

  it("shows the empty state when the workspace has no recent tasks", async () => {
    renderWindowBar();

    await userEvent.click(await screen.findByRole("button", { name: "Recent tasks" }));

    const menu = await screen.findByRole("menu", { name: "Recent tasks" });
    const emptyState = within(menu).getByTestId("comma-recent-tasks-empty");
    expect(emptyState).toHaveTextContent("No recent tasks");
    // react-aria announces the empty state as the menu's only item; no task
    // row and no "Recent tasks" section render beside it.
    const items = within(menu).getAllByRole("menuitem");
    expect(items).toHaveLength(1);
    expect(items[0]).toContainElement(emptyState);
    expect(within(menu).queryByRole("group")).toBeNull();
  });
});

function seedAppShortcutOverrides(appShortcutOverrides: Record<string, unknown>) {
  localStorage.setItem(
    commaClientSettingsStorageKey,
    JSON.stringify({
      ...structuredClone(defaultCommaClientSettings),
      appShortcutOverrides:
        commaClientAppShortcutOverridesSchema.parse(appShortcutOverrides),
    })
  );
}

function renderWindowBar() {
  const rootRoute = createRootRoute({
    component: () => (
      <>
        <WindowBar />
        <Outlet />
      </>
    ),
  });
  const homeRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "/",
    component: () => null,
  });
  const pluginsRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "/plugins",
    component: () => null,
  });
  const taskRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "/tasks/$workspaceId/$groupId/$conversationId",
    component: () => null,
  });
  const router = createRouter({
    routeTree: rootRoute.addChildren([homeRoute, pluginsRoute, taskRoute]),
    history: createMemoryHistory({ initialEntries: ["/"] }),
  });

  render(
    <CommaWebClientSettingsProvider>
      <CommaAppShortcutsProvider>
        <CommaSidebarProvider>
          <ChatSidebarProvider>
            <RouterProvider router={router} />
          </ChatSidebarProvider>
        </CommaSidebarProvider>
      </CommaAppShortcutsProvider>
    </CommaWebClientSettingsProvider>
  );
  return router;
}
