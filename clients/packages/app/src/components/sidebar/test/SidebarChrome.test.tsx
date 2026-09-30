import { initializeCommaI18n } from "@comma/i18n";
import { act, render, screen } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import {
  Outlet,
  RouterProvider,
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
} from "@tanstack/react-router";
import { beforeAll, describe, expect, it, vi } from "vitest";
import { createTestCommaAuthValue } from "../../../test/productInboxProjectionHarness";
import { CommaAuthContext } from "../../auth-context";
import { CommaWebClientSettingsProvider } from "../../commaClientSettings";
import { CommaAppShortcutsProvider } from "../../shortcuts/commaAppShortcuts";
import { SidebarChrome } from "../SidebarChrome";

// Each rail item's render, by item id ("/inbox", "settings", ...).
const railRenders = vi.hoisted(() => [] as string[]);

vi.mock("@comma/ui", async (importOriginal) => {
  const [actual, React] = await Promise.all([
    importOriginal<typeof import("@comma/ui")>(),
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

function renderRail() {
  const auth = createTestCommaAuthValue();
  const rootRoute = createRootRoute({
    component: () => (
      <CommaWebClientSettingsProvider>
        <CommaAuthContext.Provider value={auth}>
          <CommaAppShortcutsProvider>
            <SidebarChrome />
            <Outlet />
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
    history: createMemoryHistory({ initialEntries: ["/"] }),
  });
  render(<RouterProvider router={router} />);
  return router;
}

describe("SidebarChrome", () => {
  beforeAll(() => {
    initializeCommaI18n(["en"]);
  });

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
});
