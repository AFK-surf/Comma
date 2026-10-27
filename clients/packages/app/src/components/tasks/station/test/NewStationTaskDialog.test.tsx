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
  // A coding session takes no files: its repository is its files.
  expect(screen.queryByRole("button", { name: "Add attachment" })).toBeNull();

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
