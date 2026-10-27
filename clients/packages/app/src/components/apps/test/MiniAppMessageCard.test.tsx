import { CoreError } from "@comma/core-client";
import {
  act,
  render as baseRender,
  screen,
  waitFor,
  within,
} from "@comma/test-utils/render";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import userEvent from "@testing-library/user-event";
import {
  createMemoryHistory,
  createRootRoute,
  createRouter,
  RouterProvider,
} from "@tanstack/react-router";
import type { ReactNode } from "react";
import { describe, expect, it } from "vitest";
import { MiniAppMessageCard, MiniAppTaskContext } from "../MiniAppMessageCard";

const part = {
  kind: "mini-app" as const,
  appId: "a1",
  appVersion: 3,
  name: "Habit tracker",
  summary: "Habit tracker — preview version 3",
  conversationId: "task-1",
  messageId: "m1",
};

/** The card inside a router (its open modes navigate) and a core. */
function render(ui: ReactNode) {
  const core = createScriptedCore({
    // The preview's own host is tested in MiniAppFrame.test.tsx; here it does not open.
    calls: (name) => {
      if (name === "miniApps.session.open")
        throw new CoreError({ code: "unavailable", message: "offline" });
      return null;
    },
  });
  const router = createRouter({
    routeTree: createRootRoute({ component: () => <>{ui}</> }),
    history: createMemoryHistory(),
  });
  return {
    core,
    ...baseRender(<RouterProvider router={router} />, {
      wrapper: ({ children }: { children: ReactNode }) => core.wrap(children),
    }),
  };
}

const inReview = (children: ReactNode) => (
  <MiniAppTaskContext.Provider
    value={{ conversationId: "task-1", status: "ready_for_review", reviewVersion: 4 }}
  >
    {children}
  </MiniAppTaskContext.Provider>
);

describe("a Task's app card", () => {
  it("shows the summary where the app cannot run", async () => {
    render(
      <MiniAppMessageCard groupId="g" live={false} part={part} workspaceId="wsp" />
    );
    expect(await screen.findByText(part.summary)).toBeTruthy();
    expect(screen.getByText("Habit tracker")).toBeTruthy();
    expect(screen.getByText("Preview version 3")).toBeTruthy();
    expect(screen.queryByTestId("mini-app-frame")).toBeNull();
    expect(screen.queryByRole("button", { name: "Open beside chat" })).toBeNull();
  });

  it("offers Publish only while its Task is in review", async () => {
    const { unmount } = render(
      <MiniAppTaskContext.Provider
        value={{
          conversationId: "task-1",
          status: "ready_for_review",
          reviewVersion: 4,
        }}
      >
        <MiniAppMessageCard groupId="g" live part={part} workspaceId="wsp" />
      </MiniAppTaskContext.Provider>
    );
    await userEvent.click(await screen.findByRole("button", { name: "App actions" }));
    expect(await screen.findByRole("menuitem", { name: "Publish" })).toBeTruthy();
    unmount();
    render(
      <MiniAppTaskContext.Provider
        value={{ conversationId: "task-1", status: "active", reviewVersion: 4 }}
      >
        <MiniAppMessageCard groupId="g" live part={part} workspaceId="wsp" />
      </MiniAppTaskContext.Provider>
    );
    await userEvent.click(await screen.findByRole("button", { name: "App actions" }));
    await screen.findByRole("menuitem", { name: "App settings" });
    expect(screen.queryByRole("menuitem", { name: "Publish" })).toBeNull();
  });

  // The app's own window shows the app alone: its route is outside Comma's shell, not the full-width page.
  it("opens the app in a window of its own on Mac", async () => {
    const bridge = installNativeBridgeMock({ platform: "electron", os: "macos" });
    render(<MiniAppMessageCard groupId="g" live part={part} workspaceId="wsp" />);
    // A rarer open mode: it is in the card's actions menu.
    await userEvent.click(await screen.findByRole("button", { name: "App actions" }));
    await userEvent.click(
      await screen.findByRole("menuitem", { name: "Open in window" })
    );
    // The window opens on the card's place (here, with no layout, a panel-sized window).
    expect(bridge.windows.create).toHaveBeenCalledWith({
      route: "/apps/wsp/a1/window?version=3",
      bounds: expect.objectContaining({ width: expect.any(Number) }),
    });
  });

  // The Task's agent opens no pull request, and nothing in the conversation reads one: Publish asks the server to
  // publish the Version the card previews, which opens the pull request itself.
  it("publishes the Version it previews though no pull request is known", async () => {
    const { core } = render(
      inReview(<MiniAppMessageCard groupId="g" live part={part} workspaceId="wsp" />)
    );
    await userEvent.click(await screen.findByRole("button", { name: "App actions" }));
    await userEvent.click(await screen.findByRole("menuitem", { name: "Publish" }));
    const dialog = await screen.findByRole("dialog");
    const confirm = within(dialog).getByRole("button", { name: "Publish" });
    expect(confirm.hasAttribute("disabled")).toBe(false);
    act(() => confirm.click());
    await waitFor(() =>
      expect(core.sentTo("miniApps.publish")).toEqual([
        {
          workspace: "wsp",
          app: "a1",
          group: "g",
          conversation: "task-1",
          reviewVersion: 4,
          version: 3,
          visibility: "workspace",
        },
      ])
    );
  });
});
