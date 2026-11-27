import { flush } from "@comma/test-utils/fake-clock";
import { render, screen } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import {
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
  RouterProvider,
} from "@tanstack/react-router";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { CommaAuthContext, type CommaAuthContextValue } from "../../auth-context";
import { TaskMembers } from "../TaskMembers";

const user = () => userEvent.setup({ advanceTimers: vi.advanceTimersByTime });

const png = new Uint8Array([137, 80, 78, 71]);

const authValue = {
  apiBaseUrl: "https://comma.test",
  authenticated: true,
  avatarRevision: "avt_self",
  userId: "u_me",
  userEmail: "me@example.com",
  userDisplayName: "Me",
  signOut: vi.fn(),
} as unknown as CommaAuthContextValue;

describe("TaskMembers avatars", () => {
  it("loads avatars for the host and People members on both the stack trigger and popover list", async () => {
    const core = createScriptedCore({
      values: (topic) => {
        if (topic.topic === "workspace")
          return {
            status: "ready",
            workspace: { id: "w_me", groupId: "g_me", name: "Mine" },
            selected: true,
          };
        if (topic.topic === "taskMembers")
          return {
            members: [
              {
                person: { id: "u_cat", name: "CatsJuice", avatar_id: "avt_cat" },
                status: "active",
              },
              {
                person: null,
                invited_email: "guest@example.com",
                status: "invited",
              },
              {
                person: { id: "u_dec", name: "Declined User", avatar_id: null },
                status: "declined",
              },
              {
                person: { id: "u_left", name: "Left User", avatar_id: null },
                status: "left",
              },
            ],
          };
        if (topic.topic === "taskRequests")
          return {
            workspace: "w_me",
            incoming: [],
            grants: [],
            targets: [],
            sent: [],
            links: [],
            own: "review",
            people: [
              {
                id: "u_cat",
                name: "CatsJuice",
                email: "cat@example.com",
                avatar: {
                  source: "target-avatar",
                  grant: "trg_1",
                  revision: "avt_cat",
                },
                sends: null,
                receives: [],
                waiting: null,
                lastAt: null,
                lastTitle: null,
              },
            ],
            error: false,
          };
        return undefined;
      },
      calls: (name) =>
        name === "files.read" ? { bytes: png, type: "image/png" } : null,
    });

    const root = createRootRoute({
      component: () => (
        <CommaAuthContext.Provider value={authValue}>
          {core.wrap(
            <TaskMembers
              conversationId="cnv_1"
              groupId="g_me"
              together
              workspaceId="w_me"
            />
          )}
        </CommaAuthContext.Provider>
      ),
    });
    const router = createRouter({
      routeTree: root.addChildren([
        createRoute({ getParentRoute: () => root, path: "/", component: () => null }),
      ]),
      history: createMemoryHistory({ initialEntries: ["/"] }),
    });

    render(<RouterProvider router={router} />);
    await flush();

    // Both host ("avatar") and People member ("target-avatar") are requested.
    expect(core.sentTo("files.read")).toEqual(
      expect.arrayContaining([
        { source: "avatar", revision: "avt_self" },
        { source: "target-avatar", grant: "trg_1", revision: "avt_cat" },
      ])
    );

    const trigger = screen.getByTestId("task-members-trigger");
    expect(trigger.querySelectorAll("img")).toHaveLength(2);
    // The email seat's face is a person, not the letter @.
    expect(trigger).not.toHaveTextContent("@");
    expect(trigger.querySelectorAll("svg").length).toBeGreaterThan(0);

    await user().click(trigger);
    await flush();
    const list = screen.getByTestId("task-members-list");
    expect(list.querySelectorAll("img")).toHaveLength(2);
    expect(list).toHaveTextContent("CatsJuice");
    expect(list).toHaveTextContent("guest@example.com");
    // Who is in it: the host, who joined, and who has not joined yet (said in a word). Who declined or left is not.
    expect(
      screen.getAllByTestId("task-member").map((row) => row.getAttribute("data-status"))
    ).toEqual(["host", "active", "invited"]);
    expect(list).toHaveTextContent("Pending");
    expect(list).not.toHaveTextContent("Declined User");
    expect(list).not.toHaveTextContent("Left User");
  });

  it("exposes Leave task directly in the members popover for a participant without an overflow menu", async () => {
    const core = createScriptedCore({
      values: (topic) => {
        if (topic.topic === "workspace")
          return {
            status: "ready",
            workspace: { id: "w_me", groupId: "g_me", name: "Mine" },
            selected: true,
          };
        if (topic.topic === "collaborations")
          return {
            items: [
              {
                id: "col_1",
                status: "active",
                host: { id: "u_host", name: "Host Person", avatar_id: null },
                task: {
                  id: "cnv_shared",
                  group_id: "g_host",
                  title: "Shared",
                  status: "active",
                },
                members: [
                  {
                    person: { id: "u_me", name: "Me", avatar_id: "avt_self" },
                    status: "active",
                  },
                ],
              },
            ],
          };
        if (topic.topic === "taskRequests")
          return {
            workspace: "w_me",
            incoming: [],
            grants: [],
            targets: [],
            sent: [],
            links: [],
            own: "review",
            people: [],
            error: false,
          };
        return undefined;
      },
      calls: () => null,
    });

    const root = createRootRoute({
      component: () => (
        <CommaAuthContext.Provider value={authValue}>
          {core.wrap(
            <TaskMembers
              conversationId="cnv_shared"
              groupId="g_host"
              together
              workspaceId="w_host"
            />
          )}
        </CommaAuthContext.Provider>
      ),
    });
    const router = createRouter({
      routeTree: root.addChildren([
        createRoute({ getParentRoute: () => root, path: "/", component: () => null }),
      ]),
      history: createMemoryHistory({ initialEntries: ["/"] }),
    });

    render(<RouterProvider router={router} />);
    await flush();

    await user().click(screen.getByTestId("task-members-trigger"));
    await flush();

    const leaveButton = screen.getByTestId("task-members-leave");
    expect(leaveButton).toHaveTextContent("Leave task");
    expect(screen.queryByRole("button", { name: /Actions for/i })).toBeNull();

    await user().click(leaveButton);
    await flush();
    expect(screen.getByText("Leave this task?")).toBeTruthy();
  });
});
