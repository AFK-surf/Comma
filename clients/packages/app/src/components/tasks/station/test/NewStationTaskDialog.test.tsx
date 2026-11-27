import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { advance, flush } from "@comma/test-utils/fake-clock";
import { render, screen } from "@comma/test-utils/render";
import {
  RouterProvider,
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
} from "@tanstack/react-router";
import userEvent from "@testing-library/user-event";
import type { ReactNode } from "react";
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
      if (name === "stations.newTask")
        return {
          session: "s_codex_100",
          thread: 100,
          groupId: "g1",
          conversationId: "station:st_studio:100",
        };
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
    path: "/tasks/$workspaceId/$groupId/$conversationId",
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
  // It opens as any Task does, at its conversation.
  expect(decodeURIComponent(router.state.location.pathname)).toBe(
    "/tasks/w1/g1/station:st_studio:100"
  );
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

it("makes the Task in Comma's cloud when no machine is reached, with a model of the workspace's catalog, on ⌘↵", async () => {
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "stations"
        ? { workspace: "w1", loading: false, stations: [] }
        : topic.topic === "models"
          ? {
              workspace: "w1",
              catalog: { sources: {}, models: [] },
              presets: [],
              profiles: [],
              moreProfiles: false,
              models: [
                {
                  id: "gpt-5.5",
                  name: "GPT 5.5",
                  vendor: "openai",
                  efforts: [],
                  serving: ["p1"],
                },
                {
                  id: "unserved",
                  name: "Unserved",
                  vendor: "openai",
                  efforts: [],
                  serving: [],
                },
                {
                  id: "claude-opus-5-5",
                  name: "Claude Opus 5.5",
                  vendor: "anthropic",
                  efforts: [],
                  serving: ["p2"],
                },
              ],
              agents: {
                workspace_id: "w1",
                agents: { router: {} },
                task_model: {
                  selection: {
                    kind: "catalog",
                    model: "claude-opus-5-5",
                    reasoning_effort: null,
                    allow_paid: true,
                    profile_id: null,
                  },
                },
                task_place: { place: { kind: "salix" } },
              },
              error: false,
            }
          : undefined,
    calls: (name) => (name === "chat.startTask" ? cloudTask : null),
  });
  const onClose = vi.fn();
  const rootRoute = createRootRoute({
    component: () =>
      core.wrap(<NewStationTaskDialog onClose={onClose} workspace="w1" />),
  });
  const task = createRoute({
    getParentRoute: () => rootRoute,
    path: "/tasks/$workspaceId/$groupId/$conversationId",
    component: () => null,
  });
  const router = createRouter({
    routeTree: rootRoute.addChildren([task]),
    history: createMemoryHistory({ initialEntries: ["/"] }),
  });
  render(<RouterProvider router={router} />);
  await flush();

  await user().type(
    screen.getByRole("textbox", { name: "What should it do?" }),
    "fix the build"
  );
  // ⌘↵ from the message makes it, as the button does.
  await user().keyboard("{Meta>}{Enter}{/Meta}");
  await flush();
  // The workspace's default Task model, among those a profile serves.
  expect(core.sentTo("chat.startTask")).toEqual([
    {
      workspaceId: "w1",
      key: expect.any(String),
      model: { id: "claude-opus-5-5", name: "Claude Opus 5.5" },
      text: "fix the build",
    },
  ]);
  expect(core.sentTo("stations.profiles")).toEqual([]);

  // The Task opens as soon as it is made.
  await advance(50);
  expect(router.state.location.pathname).toBe("/tasks/w1/g1/c_task");
  expect(onClose).toHaveBeenCalled();
});

it("makes a cloud Task with Comma's built-in model, sent as no model, where no profile serves one", async () => {
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "stations"
        ? { workspace: "w1", loading: false, stations: [] }
        : topic.topic === "models"
          ? {
              ...workspaceModels,
              models: [],
              agents: {
                workspace_id: "w1",
                agents: { router: {} },
                task_model: { selection: { kind: "builtin" } },
                task_place: { place: { kind: "salix" } },
              },
            }
          : undefined,
    calls: (name) => (name === "chat.startTask" ? cloudTask : null),
  });
  renderDialog(core);
  await flush();

  const modelButton = screen.getByRole("button", { name: "Model" });
  expect(modelButton).toHaveTextContent("Comma built-in");
  expect(modelButton.querySelector('[data-slot="comma-mark"]')).toBeInTheDocument();
  expect(modelButton.querySelector("[data-comma-icon]")).toBeNull();
  await user().type(
    screen.getByRole("textbox", { name: "What should it do?" }),
    "plan the offsite"
  );
  await user().keyboard("{Meta>}{Enter}{/Meta}");
  await flush();
  expect(core.sentTo("chat.startTask")).toEqual([
    { workspaceId: "w1", key: expect.any(String), text: "plan the offsite" },
  ]);
});

it('sends a catalog model whose id is "default" as that model, not as the built-in one', async () => {
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "stations"
        ? { workspace: "w1", loading: false, stations: [] }
        : topic.topic === "models"
          ? {
              ...workspaceModels,
              models: [
                {
                  id: "default",
                  name: "My endpoint",
                  vendor: "openai",
                  efforts: [],
                  serving: ["p1"],
                },
              ],
              agents: {
                workspace_id: "w1",
                agents: { router: {} },
                task_model: { selection: { kind: "builtin" } },
                task_place: { place: { kind: "salix" } },
              },
            }
          : undefined,
    calls: (name) => (name === "chat.startTask" ? cloudTask : null),
  });
  renderDialog(core);
  await flush();

  await user().click(screen.getByRole("button", { name: "Model" }));
  await user().click(screen.getByRole("menuitemradio", { name: "My endpoint" }));
  await user().type(
    screen.getByRole("textbox", { name: "What should it do?" }),
    "plan the offsite"
  );
  await user().keyboard("{Meta>}{Enter}{/Meta}");
  await flush();
  expect(core.sentTo("chat.startTask")).toEqual([
    {
      workspaceId: "w1",
      key: expect.any(String),
      model: { id: "default", name: "My endpoint" },
      text: "plan the offsite",
    },
  ]);
});

/** The cloud Task `chat.startTask` made. */
const cloudTask = { groupId: "g1", conversationId: "c_task" };

/** The workspace's models as the core shows them: Claude Opus 5.5 served, and its default Task model. */
const workspaceModels = {
  workspace: "w1",
  catalog: { sources: {}, models: [] },
  presets: [],
  profiles: [],
  moreProfiles: false,
  models: [
    {
      id: "claude-opus-5-5",
      name: "Claude Opus 5.5",
      vendor: "anthropic",
      efforts: [],
      serving: ["p1"],
    },
  ],
  agents: null,
  error: false,
};

/** The window's hidden file input, as the composer's. */
const fileInput = () =>
  screen
    .getByTestId("new-station-task")
    .querySelector<HTMLInputElement>("input[type=file]")!;

function renderDialog(core: ReturnType<typeof createScriptedCore>) {
  const rootRoute = createRootRoute({
    component: () =>
      core.wrap(<NewStationTaskDialog onClose={() => {}} workspace="w1" />),
  });
  const page = createRoute({
    getParentRoute: () => rootRoute,
    path: "/tasks/$workspaceId/$groupId/$conversationId",
    component: () => null,
  });
  const router = createRouter({
    routeTree: rootRoute.addChildren([page]),
    history: createMemoryHistory({ initialEntries: ["/"] }),
  });
  render(<RouterProvider router={router} />);
  return router;
}

const spec = () => new File(["%PDF"], "spec.pdf", { type: "application/pdf" });

it("uploads a file to the cloud as it is added, and makes a cloud Task of the files alone", async () => {
  const path = `/uploads/${"f".repeat(22)}-spec.pdf`;
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "stations"
        ? { workspace: "w1", loading: false, stations: [] }
        : topic.topic === "models"
          ? workspaceModels
          : undefined,
    calls: (name) =>
      name === "chat.uploadTaskFile"
        ? { name: "spec.pdf", path, size: 4 }
        : name === "chat.startTask"
          ? cloudTask
          : null,
  });
  renderDialog(core);
  await flush();
  expect(screen.getByRole("button", { name: "Create task" })).toBeDisabled();

  await user().upload(fileInput(), spec());
  await flush();
  expect(core.sentTo("chat.uploadTaskFile")).toEqual([
    { workspaceId: "w1", name: "spec.pdf", bytes: expect.any(Uint8Array) },
  ]);
  expect(screen.getByText("spec.pdf")).toBeVisible();

  // The file alone is something to make the Task of.
  await user().click(screen.getByRole("button", { name: "Create task" }));
  await flush();
  expect(core.sentTo("chat.startTask")).toEqual([
    {
      workspaceId: "w1",
      key: expect.any(String),
      model: { id: "claude-opus-5-5", name: "Claude Opus 5.5" },
      text: "",
      uploads: [{ name: "spec.pdf", path }],
    },
  ]);
});

it("holds the Task while a file failed to reach its station, and uploads it again where another place is chosen", async () => {
  const path = `/uploads/${"f".repeat(22)}-spec.pdf`;
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "stations"
        ? {
            workspace: "w1",
            loading: false,
            stations: [station("st_mac", "MacBook", "online")],
          }
        : topic.topic === "models"
          ? workspaceModels
          : undefined,
    calls: (name) => {
      if (name === "stations.upload") throw new Error("The file is larger than 8 MB.");
      if (name === "chat.uploadTaskFile") return { name: "spec.pdf", path, size: 4 };
      if (name === "stations.profiles")
        return [
          {
            id: "work",
            name: "Work",
            runtimes: ["codex"],
            model: "gpt-5.5",
            models: [],
          },
        ];
      return null;
    },
  });
  renderDialog(core);
  await flush();
  await user().type(
    screen.getByRole("textbox", { name: "What should it do?" }),
    "read the spec"
  );
  await user().upload(fileInput(), spec());
  // jsdom reads the file for its base64 on a timer.
  await advance(50);
  expect(core.sentTo("stations.upload")).toEqual([
    { workspace: "w1", station: "st_mac", name: "spec.pdf", bytes: "JVBERg==" },
  ]);
  expect(screen.getByText("Upload failed")).toBeVisible();
  expect(screen.getByRole("button", { name: "Create task" })).toBeDisabled();

  // In the cloud the same file goes up again, there.
  await user().click(screen.getByRole("button", { name: "Machine" }));
  await user().click(screen.getByRole("menuitemradio", { name: "Comma cloud" }));
  await flush();
  expect(core.sentTo("chat.uploadTaskFile")).toHaveLength(1);
  expect(screen.queryByText("Upload failed")).toBeNull();
  await user().click(screen.getByRole("button", { name: "Create task" }));
  await flush();
  expect(core.sentTo("chat.startTask")).toEqual([
    {
      workspaceId: "w1",
      key: expect.any(String),
      model: { id: "claude-opus-5-5", name: "Claude Opus 5.5" },
      text: "read the spec",
      uploads: [{ name: "spec.pdf", path }],
    },
  ]);
});

it("says why no cloud Task was made, and tries again as another Task", async () => {
  let refuse = true;
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "stations"
        ? { workspace: "w1", loading: false, stations: [] }
        : topic.topic === "models"
          ? workspaceModels
          : undefined,
    calls: (name) => {
      if (name !== "chat.startTask") return null;
      if (!refuse) return cloudTask;
      refuse = false;
      throw Object.assign(new Error("no plan serves claude-opus-5-5"), {
        code: "refused",
      });
    },
  });
  renderDialog(core);
  await flush();
  await user().type(
    screen.getByRole("textbox", { name: "What should it do?" }),
    "fix the build"
  );
  await user().click(screen.getByRole("button", { name: "Create task" }));
  await flush();
  await advance(50);
  expect(screen.getByRole("alert")).toHaveTextContent("no plan serves claude-opus-5-5");

  await user().click(screen.getByRole("button", { name: "Create task" }));
  await flush();
  const [first, again] = core.sentTo("chat.startTask") as { key: string }[];
  expect(again?.key).toBeDefined();
  expect(again?.key).not.toBe(first?.key);
});

it("localizes 402 billing denials with a fresh retry key and never leaks raw selection error codes", async () => {
  let attempt = 0;
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "stations"
        ? { workspace: "w1", loading: false, stations: [] }
        : topic.topic === "models"
          ? workspaceModels
          : undefined,
    calls: (name) => {
      if (name !== "chat.startTask") return null;
      attempt += 1;
      if (attempt === 1) {
        throw Object.assign(new Error("billing_unavailable"), {
          code: "billing_unavailable",
          status: 402,
          detail: { error: "billing_unavailable", reason: "insufficient_credits" },
        });
      }
      if (attempt === 2) {
        throw Object.assign(new Error("task_model_selection_failed"), {
          code: "task_model_selection_failed",
          status: 503,
        });
      }
      return cloudTask;
    },
  });
  renderDialog(core);
  await flush();
  await user().type(
    screen.getByRole("textbox", { name: "What should it do?" }),
    "fix the build"
  );
  await user().click(screen.getByRole("button", { name: "Create task" }));
  await flush();
  await advance(50);
  expect(screen.getByRole("alert")).toHaveTextContent(
    "Unable to create task: out of Comma credits. Add credits, then retry."
  );

  // Billing refusal rotates the key; a non-refusal selection outage stays localized and keeps the key.
  await user().click(screen.getByRole("button", { name: "Create task" }));
  await flush();
  await advance(50);
  expect(screen.getByRole("alert")).not.toHaveTextContent(
    "task_model_selection_failed"
  );
  expect(screen.getByRole("alert")).toHaveTextContent("Could not create the task.");

  await user().click(screen.getByRole("button", { name: "Create task" }));
  await flush();
  const [first, second, third] = core.sentTo("chat.startTask") as { key: string }[];
  expect(second?.key).not.toBe(first?.key);
  expect(third?.key).toBe(second?.key);
});

it("tries a cloud Task that failed without a refusal again as the same Task", async () => {
  let fail = true;
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "stations"
        ? { workspace: "w1", loading: false, stations: [] }
        : topic.topic === "models"
          ? workspaceModels
          : undefined,
    calls: (name) => {
      if (name !== "chat.startTask") return null;
      if (!fail) return cloudTask;
      fail = false;
      throw Object.assign(new Error("task_unavailable"), { code: "task_unavailable" });
    },
  });
  renderDialog(core);
  await flush();
  await user().type(
    screen.getByRole("textbox", { name: "What should it do?" }),
    "fix the build"
  );
  await user().click(screen.getByRole("button", { name: "Create task" }));
  await flush();
  await advance(50);
  expect(screen.getByRole("alert")).toHaveTextContent("Could not create the task.");

  await user().click(screen.getByRole("button", { name: "Create task" }));
  await flush();
  const [first, again] = core.sentTo("chat.startTask") as { key: string }[];
  expect(again?.key).toBe(first?.key);
});

it("holds the files until the machines are known, then sends them to the one reached", async () => {
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "stations"
        ? { workspace: "w1", loading: true, stations: [] }
        : topic.topic === "models"
          ? workspaceModels
          : undefined,
    calls: (name) =>
      name === "stations.upload"
        ? { name: "spec.pdf", path: "/uploads/spec.pdf", size: 4 }
        : name === "stations.profiles"
          ? []
          : null,
  });
  renderDialog(core);
  await flush();
  await user().upload(fileInput(), spec());
  await advance(50);
  expect(core.sentTo("chat.uploadTaskFile")).toEqual([]);
  expect(core.sentTo("stations.upload")).toEqual([]);

  core.emit("stations", {
    workspace: "w1",
    loading: false,
    stations: [station("st_mac", "MacBook", "online")],
  });
  // The machine is chosen, then the file is read for its base64 on a timer.
  await flush();
  await advance(50);
  expect(core.sentTo("chat.uploadTaskFile")).toEqual([]);
  expect(core.sentTo("stations.upload")).toEqual([
    { workspace: "w1", station: "st_mac", name: "spec.pdf", bytes: "JVBERg==" },
  ]);
});

it("turns away a file over a station's 8 MB before reading it, and takes it in the cloud", async () => {
  const path = `/uploads/${"f".repeat(22)}-big.pdf`;
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "stations"
        ? {
            workspace: "w1",
            loading: false,
            stations: [station("st_mac", "MacBook", "online")],
          }
        : topic.topic === "models"
          ? workspaceModels
          : undefined,
    calls: (name) =>
      name === "chat.uploadTaskFile"
        ? { name: "big.pdf", path, size: 8 * 1024 * 1024 + 1 }
        : name === "stations.profiles"
          ? []
          : null,
  });
  renderDialog(core);
  await flush();
  await user().upload(
    fileInput(),
    new File([new Uint8Array(8 * 1024 * 1024 + 1)], "big.pdf", {
      type: "application/pdf",
    })
  );
  await advance(50);
  expect(core.sentTo("stations.upload")).toEqual([]);
  expect(screen.getByText("Upload failed")).toBeVisible();

  await user().click(screen.getByRole("button", { name: "Machine" }));
  await user().click(screen.getByRole("menuitemradio", { name: "Comma cloud" }));
  await flush();
  expect(core.sentTo("chat.uploadTaskFile")).toHaveLength(1);
  expect(screen.queryByText("Upload failed")).toBeNull();
});

it("starts a coding session in a cloud sandbox with a repository, its base branch and a runtime, and opens its Task", async () => {
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "stations"
        ? { workspace: "w1", loading: false, stations: [] }
        : undefined,
    calls: (name) => {
      if (name === "coding.repos")
        return [
          { owner: "acme", name: "web", defaultBranch: "main", private: false },
          { owner: "acme", name: "api", defaultBranch: "trunk", private: true },
        ];
      if (name === "coding.branches") return ["trunk", "release/2.1"];
      if (name === "coding.start") return { taskId: "cnv_code", groupId: "grp_1" };
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
    path: "/tasks/$workspaceId/$groupId/$conversationId",
    component: () => null,
  });
  const router = createRouter({
    routeTree: rootRoute.addChildren([page]),
    history: createMemoryHistory({ initialEntries: ["/"] }),
  });
  render(<RouterProvider router={router} />);
  await flush();

  await user().click(screen.getByRole("button", { name: "Machine" }));
  // Where sandboxes are not set up, no plain sandbox is offered.
  expect(screen.queryByRole("menuitemradio", { name: "Sandbox" })).toBeNull();
  await user().click(screen.getByRole("menuitemradio", { name: "Code" }));
  await flush();
  // The account's repositories, recently pushed first; another is chosen, and its branches read.
  await user().click(screen.getByRole("button", { name: "Repository" }));
  await user().click(screen.getByRole("menuitemradio", { name: "acme/api" }));
  await flush();
  expect(core.sentTo("coding.branches")).toContainEqual({
    workspaceId: "w1",
    owner: "acme",
    name: "api",
  });
  await user().click(screen.getByRole("button", { name: "Base branch" }));
  await user().click(screen.getByRole("menuitemradio", { name: "from release/2.1" }));
  await user().click(screen.getByRole("button", { name: "Model" }));
  await user().click(screen.getByRole("menuitemradio", { name: "Claude Code" }));
  await user().type(
    screen.getByRole("textbox", { name: "What should it do?" }),
    "fix the flaky test"
  );
  await user().click(screen.getByRole("button", { name: "Create task" }));
  await flush();
  expect(core.sentTo("coding.start")).toEqual([
    {
      workspaceId: "w1",
      key: expect.any(String),
      text: "fix the flaky test",
      repo: { owner: "acme", name: "api", baseRef: "release/2.1" },
      model: { provider: "claude" },
    },
  ]);
  expect(router.state.location.pathname).toBe("/tasks/w1/grp_1/cnv_code");
  expect(onClose).toHaveBeenCalled();
});

it("starts a plain sandbox Task, with nothing checked out and no files, where sandboxes are set up", async () => {
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "stations"
        ? { workspace: "w1", loading: false, stations: [] }
        : topic.topic === "models"
          ? {
              ...workspaceModels,
              agents: {
                workspace_id: "w1",
                agents: {},
                task_model: { selection: { kind: "builtin" } },
                task_place: { place: { kind: "salix" }, sandboxes: true },
              },
            }
          : undefined,
    calls: (name) =>
      name === "coding.start" ? { taskId: "cnv_box", groupId: "grp_1" } : null,
  });
  const router = renderDialog(core);
  await flush();

  await user().click(screen.getByRole("button", { name: "Machine" }));
  await user().click(screen.getByRole("menuitemradio", { name: "Sandbox" }));
  await flush();
  // No repository to choose: the sandbox starts empty.
  expect(screen.queryByRole("button", { name: "Repository" })).toBeNull();
  expect(core.sentTo("coding.repos")).toEqual([]);

  await user().type(
    screen.getByRole("textbox", { name: "What should it do?" }),
    "convert the videos to mp4"
  );
  await user().click(screen.getByRole("button", { name: "Create task" }));
  await flush();
  expect(core.sentTo("coding.start")).toEqual([
    {
      workspaceId: "w1",
      key: expect.any(String),
      text: "convert the videos to mp4",
      model: { provider: "codex" },
    },
  ]);
  expect(router.state.location.pathname).toBe("/tasks/w1/grp_1/cnv_box");
});

it("uploads a coding session's image as a cloud Task's, and starts the session with it alone", async () => {
  const path = `/uploads/${"f".repeat(22)}-shot.png`;
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "stations"
        ? { workspace: "w1", loading: false, stations: [] }
        : undefined,
    calls: (name) => {
      if (name === "chat.uploadTaskFile") return { name: "shot.png", path, size: 3 };
      if (name === "coding.repos")
        return [{ owner: "acme", name: "web", defaultBranch: "main", private: false }];
      if (name === "coding.branches") return ["main"];
      if (name === "coding.start") return { taskId: "cnv_code", groupId: "grp_1" };
      return null;
    },
  });
  renderDialog(core);
  await flush();
  await user().click(screen.getByRole("button", { name: "Machine" }));
  await user().click(screen.getByRole("menuitemradio", { name: "Code" }));
  await flush();

  await user().upload(
    fileInput(),
    new File(["png"], "shot.png", { type: "image/png" })
  );
  // jsdom reads the file's bytes on a timer.
  await advance(50);
  expect(core.sentTo("chat.uploadTaskFile")).toEqual([
    { workspaceId: "w1", name: "shot.png", bytes: expect.any(Uint8Array) },
  ]);
  expect(
    screen.getByTestId("new-station-task").querySelector('[data-state="loading"]')
  ).toBeNull();

  // The image alone is something to start the session from.
  await user().click(screen.getByRole("button", { name: "Create task" }));
  await flush();
  expect(core.sentTo("coding.start")).toEqual([
    {
      workspaceId: "w1",
      key: expect.any(String),
      text: "",
      uploads: [{ name: "shot.png", path }],
      repo: { owner: "acme", name: "web", baseRef: "main" },
      model: { provider: "codex" },
    },
  ]);
});

/** A signed-in subscription as the core shows it. */
const subscription = (id: string, source: string, name: string) => ({
  id,
  credential_kind: "subscription_oauth" as const,
  source,
  name,
  disabled: false,
  status: "ok",
  version: "1",
  subscription: true,
  usable: true,
  preset: null,
  tokenDance: false,
  meters: [],
  servable: [],
});

it("runs a coding session on the subscription and model chosen, or the runtime's default", async () => {
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "stations"
        ? { workspace: "w1", loading: false, stations: [] }
        : topic.topic === "models"
          ? {
              ...workspaceModels,
              profiles: [
                subscription("acct_work", "codex", "Work ChatGPT"),
                subscription("acct_home", "codex", "Home ChatGPT"),
              ],
              models: [
                {
                  id: "gpt-5.6-sol",
                  name: "GPT-5.6 Sol",
                  vendor: "openai",
                  efforts: [],
                  serving: ["acct_work", "acct_home"],
                },
                {
                  id: "gpt-6-sol",
                  name: "GPT-6 Sol",
                  vendor: "openai",
                  efforts: [],
                  serving: ["acct_work"],
                },
              ],
            }
          : undefined,
    calls: (name) => {
      if (name === "coding.repos")
        return [{ owner: "acme", name: "api", defaultBranch: "trunk", private: true }];
      if (name === "coding.branches") return ["trunk"];
      if (name === "coding.start") return { taskId: "cnv_code", groupId: "grp_1" };
      return null;
    },
  });
  const rootRoute = createRootRoute({
    component: () =>
      core.wrap(<NewStationTaskDialog onClose={vi.fn()} workspace="w1" />),
  });
  const page = createRoute({
    getParentRoute: () => rootRoute,
    path: "/tasks/$workspaceId/$groupId/$conversationId",
    component: () => null,
  });
  render(
    <RouterProvider
      router={createRouter({
        routeTree: rootRoute.addChildren([page]),
        history: createMemoryHistory({ initialEntries: ["/"] }),
      })}
    />
  );
  await flush();
  await user().click(screen.getByRole("button", { name: "Machine" }));
  await user().click(screen.getByRole("menuitemradio", { name: "Code" }));
  await flush();

  // Each subscription's default and the models it serves; Claude Code, with no subscription, on its default.
  await user().click(screen.getByRole("button", { name: "Model" }));
  const offered = screen.getAllByRole("menuitemradio").map((item) => item.textContent);
  expect(offered).toEqual([
    "CodexWork ChatGPT",
    "GPT-5.6 SolWork ChatGPT",
    "GPT-6 SolWork ChatGPT",
    "CodexHome ChatGPT",
    "GPT-5.6 SolHome ChatGPT",
    "Claude Code",
  ]);
  await user().click(
    screen.getAllByRole("menuitemradio", { name: /GPT-5\.6 Sol/ })[1]!
  );

  await user().type(
    screen.getByRole("textbox", { name: "What should it do?" }),
    "fix it"
  );
  await user().click(screen.getByRole("button", { name: "Create task" }));
  await flush();
  expect(core.sentTo("coding.start")).toEqual([
    expect.objectContaining({
      model: { provider: "codex", model: "gpt-5.6-sol" },
      accountId: "acct_home",
    }),
  ]);
});

it("offers a sandbox a runtime without its own subscription only where the accounts Salix lends it run that runtime", async () => {
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "stations"
        ? { workspace: "w1", loading: false, stations: [] }
        : topic.topic === "models"
          ? {
              ...workspaceModels,
              models: [],
              agents: {
                workspace_id: "w1",
                agents: {},
                task_model: { selection: { kind: "builtin" } },
                task_place: {
                  place: { kind: "salix" },
                  sandboxes: true,
                  sandbox_runtimes: ["codex"],
                },
              },
            }
          : undefined,
    calls: (name) =>
      name === "coding.start" ? { taskId: "cnv_box", groupId: "grp_1" } : null,
  });
  renderDialog(core);
  await flush();
  await user().click(screen.getByRole("button", { name: "Machine" }));
  await user().click(screen.getByRole("menuitemradio", { name: "Sandbox" }));
  await flush();

  // Claude Code has no subscription here, and Salix lends the sandbox nothing that runs it: it is not offered.
  // Codex runs on the platform's model.
  await user().click(screen.getByRole("button", { name: "Model" }));
  expect(screen.getAllByRole("menuitemradio").map((item) => item.textContent)).toEqual([
    "Codex",
  ]);
  await user().click(screen.getByRole("menuitemradio", { name: "Codex" }));
  await user().type(
    screen.getByRole("textbox", { name: "What should it do?" }),
    "convert the videos to mp4"
  );
  await user().click(screen.getByRole("button", { name: "Create task" }));
  await flush();
  expect(core.sentTo("coding.start")).toEqual([
    expect.objectContaining({ model: { provider: "codex" } }),
  ]);
});

it("reads the models again as it opens, and holds a sandbox Task that nothing lent can run, saying why", async () => {
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "stations"
        ? { workspace: "w1", loading: false, stations: [] }
        : topic.topic === "models"
          ? {
              ...workspaceModels,
              models: [],
              agents: {
                workspace_id: "w1",
                agents: {},
                task_model: { selection: { kind: "builtin" } },
                task_place: {
                  place: { kind: "salix" },
                  sandboxes: true,
                  sandbox_runtimes: [],
                },
              },
            }
          : undefined,
    calls: () => null,
  });
  renderDialog(core);
  await flush();
  expect(core.sentTo("models.refresh")).toEqual([{}]);
  await user().click(screen.getByRole("button", { name: "Machine" }));
  await user().click(screen.getByRole("menuitemradio", { name: "Sandbox" }));
  await flush();
  await user().type(
    screen.getByRole("textbox", { name: "What should it do?" }),
    "convert the videos to mp4"
  );
  expect(screen.getByRole("alert")).toHaveTextContent(
    "No account here can run a sandbox. Add one in Settings › Model & API."
  );
  expect(screen.getByRole("button", { name: "Create task" })).toBeDisabled();
  await user().keyboard("{Meta>}{Enter}{/Meta}");
  await flush();
  expect(core.sentTo("coding.start")).toEqual([]);
});

it("as a request's card, declines it or accepts it with the chosen model", async () => {
  const sent: [string, unknown][] = [];
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "stations"
        ? { workspace: "w1", loading: false, stations: [] }
        : topic.topic === "models"
          ? {
              workspace: "w1",
              catalog: { sources: {}, models: [] },
              presets: [],
              profiles: [],
              moreProfiles: false,
              models: [
                {
                  id: "gpt-5.5",
                  name: "GPT 5.5",
                  vendor: "openai",
                  efforts: [],
                  serving: ["p1"],
                },
              ],
            }
          : undefined,
    calls: (name, params) => {
      sent.push([name, params]);
      if (name === "taskRequests.accept") return { task: { group_id: "g1", id: "c9" } };
      return null;
    },
  });
  const onClose = vi.fn();
  const request = { id: "trq_1", title: "From Sam", content: "Summarize Q3" };
  const rootRoute = createRootRoute({
    component: () =>
      core.wrap(
        <NewStationTaskDialog onClose={onClose} request={request} workspace="w1" />
      ),
  });
  const page = createRoute({
    getParentRoute: () => rootRoute,
    path: "/tasks/$workspaceId/$groupId/$conversationId",
    component: () => null,
  });
  const router = createRouter({
    routeTree: rootRoute.addChildren([page]),
    history: createMemoryHistory({ initialEntries: ["/"] }),
  });
  render(<RouterProvider router={router} />);
  await flush();

  // A card, not a dialog, opening with the request's words; no files can be added.
  expect(screen.getByTestId("task-request-card")).toBeTruthy();
  expect(screen.queryByRole("dialog")).toBeNull();
  expect(screen.getByRole("textbox", { name: "What should it do?" })).toHaveProperty(
    "value",
    "Summarize Q3"
  );
  expect(screen.queryByTestId("new-station-task-attach")).toBeNull();

  await user().click(screen.getByRole("button", { name: "Decline" }));
  await flush();
  expect(sent.find(([name]) => name === "taskRequests.decline")?.[1]).toEqual({
    workspace: "w1",
    request: "trq_1",
  });
  expect(onClose).toHaveBeenCalledTimes(1);

  sent.length = 0;
  await user().click(screen.getByRole("button", { name: "Create task" }));
  await flush();
  expect(sent.find(([name]) => name === "taskRequests.accept")?.[1]).toEqual({
    workspace: "w1",
    request: "trq_1",
    content: "Summarize Q3",
    run: { kind: "cloud", model: "gpt-5.5" },
  });
  expect(decodeURIComponent(router.state.location.pathname)).toBe("/tasks/w1/g1/c9");
});

it("as a request's card, accepts into Comma's cloud with the built-in Task model where no profile serves one", async () => {
  const sent: [string, unknown][] = [];
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "stations"
        ? { workspace: "w1", loading: false, stations: [] }
        : topic.topic === "models"
          ? {
              ...workspaceModels,
              models: [],
              agents: {
                workspace_id: "w1",
                agents: { router: {} },
                task_model: { selection: { kind: "builtin" } },
                task_place: { place: { kind: "salix" } },
              },
            }
          : undefined,
    calls: (name, params) => {
      sent.push([name, params]);
      if (name === "taskRequests.accept") return { task: { group_id: "g1", id: "c9" } };
      return null;
    },
  });
  const onClose = vi.fn();
  const request = { id: "trq_1", title: "From Sam", content: "Summarize Q3" };
  const rootRoute = createRootRoute({
    component: () =>
      core.wrap(
        <NewStationTaskDialog onClose={onClose} request={request} workspace="w1" />
      ),
  });
  const page = createRoute({
    getParentRoute: () => rootRoute,
    path: "/tasks/$workspaceId/$groupId/$conversationId",
    component: () => null,
  });
  const router = createRouter({
    routeTree: rootRoute.addChildren([page]),
    history: createMemoryHistory({ initialEntries: ["/"] }),
  });
  render(<RouterProvider router={router} />);
  await flush();

  expect(screen.getByRole("button", { name: "Model" })).toHaveTextContent(
    "Comma built-in"
  );
  expect(screen.getByRole("button", { name: "Model" })).toBeEnabled();
  expect(screen.getByRole("button", { name: "Create task" })).toBeEnabled();

  await user().click(screen.getByRole("button", { name: "Create task" }));
  await flush();
  expect(sent.find(([name]) => name === "taskRequests.accept")?.[1]).toEqual({
    workspace: "w1",
    request: "trq_1",
    content: "Summarize Q3",
    run: { kind: "cloud" },
  });
  expect(decodeURIComponent(router.state.location.pathname)).toBe("/tasks/w1/g1/c9");
});

/** A workspace whose invite the person accepted, as the core's `taskRequests` topic lists it. */
const requestTarget = (grant: string, owner: string, name: string, sentToday = 0) => ({
  grant_id: grant,
  workspace: {
    id: `w_${grant}`,
    name,
    owner: { id: `u_${grant}`, name: owner, email: null, avatar_id: `avt_${grant}` },
  },
  mode: "review",
  daily_limit: 20,
  pending_limit: 10,
  sent_today: sentToday,
  pending: 0,
});

it("switches to a New request where the person may send them, and sends the words alone to the chosen owner", async () => {
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "stations"
        ? { workspace: "w1", loading: false, stations: [] }
        : topic.topic === "models"
          ? workspaceModels
          : topic.topic === "taskRequests"
            ? {
                workspace: "w1",
                incoming: [],
                grants: [],
                targets: [
                  // Its day's requests are spent: it cannot be chosen.
                  requestTarget("trg_full", "Ann", "Ann's", 20),
                  requestTarget("trg_cat", "CatsJuice", "Cats"),
                  requestTarget("trg_bo", "Bo", "Bo's"),
                ],
                sent: [],
                links: [],
                error: false,
              }
            : undefined,
    calls: (name) => (name === "taskRequests.send" ? { status: "pending" } : null),
  });
  const onClose = vi.fn();
  const rootRoute = createRootRoute({
    component: () =>
      core.wrap(<NewStationTaskDialog onClose={onClose} workspace="w1" />),
  });
  render(
    <RouterProvider
      router={createRouter({
        routeTree: rootRoute,
        history: createMemoryHistory({ initialEntries: ["/"] }),
      })}
    />
  );
  await flush();

  await user().click(screen.getByRole("button", { name: "What to make" }));
  await user().click(screen.getByRole("menuitemradio", { name: "New request" }));
  // Whom it goes to leads the title, the first who can take one chosen; nothing of what runs it, and no files.
  expect(screen.getByRole("button", { name: "Send to" })).toHaveTextContent(
    "CatsJuice"
  );
  // Each person by name and avatar, read through the person's grant.
  expect(core.sentTo("files.read")).toContainEqual({
    source: "target-avatar",
    grant: "trg_cat",
    revision: "avt_trg_cat",
  });
  expect(screen.queryByRole("button", { name: "Model" })).toBeNull();
  expect(screen.queryByTestId("new-station-task-attach")).toBeNull();
  expect(screen.queryByRole("button", { name: "Create task" })).toBeNull();
  expect(screen.getByRole("button", { name: "Send request" })).toBeDisabled();

  await user().click(screen.getByRole("button", { name: "Send to" }));
  expect(screen.getByRole("menuitemradio", { name: /Ann/ })).toHaveAttribute(
    "aria-disabled",
    "true"
  );
  await user().click(screen.getByRole("menuitemradio", { name: /Bo/ }));
  await user().type(
    screen.getByRole("textbox", { name: "What should it do?" }),
    " review the deck "
  );
  await user().click(screen.getByRole("button", { name: "Send request" }));
  await flush();
  expect(core.sentTo("taskRequests.send")).toEqual([
    {
      grant: "trg_bo",
      content: "review the deck",
      key: expect.any(String),
      workspace: "w1",
    },
  ]);
  expect(core.sentTo("chat.startTask")).toEqual([]);
  expect(onClose).toHaveBeenCalled();
});

/** The window in a router, on a core whose person may send requests to `targets`. */
const inRouter = (targets: unknown[], dialog: ReactNode) => {
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "stations"
        ? { workspace: "w1", loading: false, stations: [] }
        : topic.topic === "taskRequests"
          ? { workspace: "w1", targets }
          : undefined,
  });
  return render(
    <RouterProvider
      router={createRouter({
        routeTree: createRootRoute({ component: () => core.wrap(dialog) }),
        history: createMemoryHistory({ initialEntries: ["/"] }),
      })}
    />
  );
};

it("keeps a plain title where the person may send no requests, and opens as a request to the target it is given", async () => {
  const { unmount } = inRouter(
    [],
    <NewStationTaskDialog onClose={() => {}} workspace="w1" />
  );
  await flush();
  expect(screen.queryByRole("button", { name: "What to make" })).toBeNull();
  expect(screen.getByRole("heading", { name: "New task" })).toBeVisible();
  unmount();

  inRouter(
    [
      requestTarget("trg_cat", "CatsJuice", "Cats"),
      requestTarget("trg_bo", "Bo", "Bo's"),
    ],
    <NewStationTaskDialog onClose={() => {}} requestTo="trg_bo" workspace="w1" />
  );
  await flush();
  expect(screen.getByRole("button", { name: "What to make" })).toHaveTextContent(
    "New request"
  );
  expect(screen.getByRole("button", { name: "Send to" })).toHaveTextContent("Bo");
});

it("keeps the recipient it was opened for when they can take no more today, and holds Send", async () => {
  inRouter(
    [
      requestTarget("trg_ann", "Ann", "Ann's", 20),
      requestTarget("trg_bo", "Bo", "Bo's"),
    ],
    <NewStationTaskDialog onClose={() => {}} requestTo="trg_ann" workspace="w1" />
  );
  await flush();
  expect(screen.getByRole("button", { name: "Send to" })).toHaveTextContent("Ann");
  await user().type(
    screen.getByRole("textbox", { name: "What should it do?" }),
    "review the deck"
  );
  expect(screen.getByRole("button", { name: "Send request" })).toBeDisabled();
});

it("lists Monoid workspaces in the machine picker, runs on workspace default or a reported runtime model, and opens the Task", async () => {
  const path = `/uploads/${"f".repeat(22)}-spec.pdf`;
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "stations"
        ? { workspace: "w1", loading: false, stations: [] }
        : topic.topic === "models"
          ? workspaceModels
          : topic.topic === "pluginStations" && topic.plugin === "stillfail"
            ? {
                stations: [
                  {
                    id: "dev_monoid_online",
                    name: "Acme · tokyo-mac",
                    connected: true,
                    connectedAt: "2026-11-25T00:00:00.000Z",
                    workspace: "Acme Engineering",
                    emoji: null,
                    station: "tokyo-mac",
                    stationCount: 2,
                    taskModels: {
                      claude: ["claude-opus-5-5", "claude-sonnet-5-5"],
                      codex: [],
                    },
                  },
                  {
                    id: "dev_monoid_offline",
                    name: "Staging · pvg-1",
                    connected: false,
                    connectedAt: "2026-11-24T00:00:00.000Z",
                    workspace: "Staging Lab",
                    emoji: null,
                    station: "pvg-1",
                    stationCount: 1,
                    taskModels: {},
                  },
                  {
                    id: "dev_monoid_waiting",
                    name: null,
                    connected: false,
                    connectedAt: null,
                    workspace: null,
                    emoji: null,
                    station: null,
                    stationCount: null,
                  },
                ],
                notificationLevel: "action_needed",
                notificationPending: false,
                error: null,
                pending: null,
              }
            : undefined,
    calls: (name) =>
      name === "chat.uploadTaskFile"
        ? { name: "spec.pdf", path, size: 4 }
        : name === "chat.startTask"
          ? { groupId: "grp_1", conversationId: "cnv_monoid_1" }
          : null,
  });
  const onClose = vi.fn();
  const rootRoute = createRootRoute({
    component: () =>
      core.wrap(<NewStationTaskDialog onClose={onClose} workspace="w1" />),
  });
  const page = createRoute({
    getParentRoute: () => rootRoute,
    path: "/tasks/$workspaceId/$groupId/$conversationId",
    component: () => null,
  });
  const router = createRouter({
    routeTree: rootRoute.addChildren([page]),
    history: createMemoryHistory({ initialEntries: ["/"] }),
  });
  render(<RouterProvider router={router} />);
  await flush();

  await user().click(screen.getByRole("button", { name: "Machine" }));
  expect(screen.getByRole("menuitemradio", { name: "Staging Lab" })).toHaveAttribute(
    "aria-disabled",
    "true"
  );
  expect(screen.getByRole("menuitemradio", { name: "Monoid" })).toHaveAttribute(
    "aria-disabled",
    "true"
  );
  await user().click(screen.getByRole("menuitemradio", { name: "Acme Engineering" }));
  await flush();

  // No sandbox repo picker is shown; Workspace default is selected first.
  expect(screen.queryByRole("button", { name: "Repository" })).toBeNull();
  expect(screen.getByRole("button", { name: "Model" })).toHaveTextContent(
    "Workspace default"
  );

  // Opening the model picker shows Workspace default and reported runtime models.
  await user().click(screen.getByRole("button", { name: "Model" }));
  expect(
    screen.getByRole("menuitemradio", { name: "Workspace default" })
  ).toBeVisible();
  expect(screen.getByRole("menuitemradio", { name: "Codex" })).toBeVisible();
  await user().click(screen.getByRole("menuitemradio", { name: "claude-opus-5-5" }));
  await flush();

  await user().upload(fileInput(), spec());
  await flush();
  await user().type(
    screen.getByRole("textbox", { name: "What should it do?" }),
    "run smoke tests"
  );
  await user().click(screen.getByRole("button", { name: "Create task" }));
  await flush();

  expect(core.sentTo("chat.startTask")).toEqual([
    {
      workspaceId: "w1",
      key: expect.any(String),
      stillfail: {
        deviceId: "dev_monoid_online",
        provider: "claude",
        model: "claude-opus-5-5",
      },
      text: "run smoke tests",
      uploads: [{ name: "spec.pdf", path }],
    },
  ]);
  expect(router.state.location.pathname).toBe("/tasks/w1/grp_1/cnv_monoid_1");
  expect(onClose).toHaveBeenCalled();
});

it("allows submitting on a Monoid workspace with empty taskModels using Workspace default", async () => {
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "stations"
        ? { workspace: "w1", loading: false, stations: [] }
        : topic.topic === "models"
          ? workspaceModels
          : topic.topic === "pluginStations" && topic.plugin === "stillfail"
            ? {
                stations: [
                  {
                    id: "dev_monoid_empty",
                    name: "Solo",
                    connected: true,
                    connectedAt: "2026-11-25T00:00:00.000Z",
                    workspace: "Solo Workspace",
                    emoji: null,
                    station: null,
                    stationCount: 1,
                    taskModels: {},
                  },
                ],
                notificationLevel: "action_needed",
                notificationPending: false,
                error: null,
                pending: null,
              }
            : undefined,
    calls: (name) =>
      name === "chat.startTask"
        ? { groupId: "grp_1", conversationId: "cnv_monoid_default" }
        : null,
  });
  const router = renderDialog(core);
  await flush();

  await user().click(screen.getByRole("button", { name: "Machine" }));
  await user().click(screen.getByRole("menuitemradio", { name: "Solo Workspace" }));
  await flush();
  await user().type(
    screen.getByRole("textbox", { name: "What should it do?" }),
    "check status"
  );
  await user().click(screen.getByRole("button", { name: "Create task" }));
  await flush();

  expect(core.sentTo("chat.startTask")).toEqual([
    {
      workspaceId: "w1",
      key: expect.any(String),
      stillfail: { deviceId: "dev_monoid_empty" },
      text: "check status",
    },
  ]);
  expect(router.state.location.pathname).toBe("/tasks/w1/grp_1/cnv_monoid_default");
});
