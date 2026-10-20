import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { flush } from "@comma/test-utils/fake-clock";
import { render, screen } from "@comma/test-utils/render";
import {
  RouterProvider,
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
} from "@tanstack/react-router";
import userEvent from "@testing-library/user-event";
import { expect, it, vi } from "vitest";

/** A user whose waits run on the fake clock. */
const user = () => userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
import { NewStationTaskDialog } from "../NewStationTaskDialog";

const station = (id: string, name: string, state: "online" | "offline") => ({
  id,
  name,
  version: "1",
  present: state === "online",
  enrolledAt: null,
  enrolledBy: null,
  link: { state },
});

it("makes a Task on the chosen machine with a model of its profiles, and opens it", async () => {
  const sent: [string, unknown][] = [];
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "stations"
        ? {
            workspace: "w1",
            loading: false,
            stations: [
              station("st_mini", "Mac mini", "offline"),
              station("st_studio", "Studio", "online"),
            ],
          }
        : undefined,
    calls: (name, params) => {
      sent.push([name, params]);
      if (name === "stations.profiles")
        return [
          {
            id: "work",
            name: "Work",
            runtimes: ["codex"],
            model: "gpt-5.5",
            models: ["gpt-5.5", "gpt-5.4"],
          },
        ];
      if (name === "stations.newTask") return { session: "s_codex_100", thread: 100 };
      return null;
    },
  });
  const onClose = vi.fn();
  const rootRoute = createRootRoute({
    component: () =>
      core.wrap(<NewStationTaskDialog onClose={onClose} workspace="w1" />),
  });
  const page = createRoute({
    getParentRoute: () => rootRoute,
    path: "/tasks/$workspaceId/station/$station/$thread",
    component: () => null,
  });
  const router = createRouter({
    routeTree: rootRoute.addChildren([page]),
    history: createMemoryHistory({ initialEntries: ["/"] }),
  });
  render(<RouterProvider router={router} />);

  // The machine reached is chosen; its profiles' models are offered.
  await flush();
  expect(sent).toContainEqual([
    "stations.profiles",
    { station: "st_studio", workspace: "w1" },
  ]);
  await user().type(
    screen.getByRole("textbox", { name: "What should it do?" }),
    "fix the build"
  );
  await user().click(screen.getByRole("button", { name: "Create task" }));
  await flush();
  expect(router.state.location.pathname).toBe("/tasks/w1/station/st_studio/100");
  expect(sent.find(([name]) => name === "stations.newTask")?.[1]).toMatchObject({
    station: "st_studio",
    workspace: "w1",
    runtime: "codex",
    profile: "work",
    model: "gpt-5.5",
    text: "fix the build",
  });
  expect(onClose).toHaveBeenCalled();
});
