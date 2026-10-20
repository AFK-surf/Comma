import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { EventEmitter } from "node:events";
import { fileURLToPath } from "node:url";
import { PassThrough } from "node:stream";
import { afterEach, describe, expect, it, vi } from "vitest";
import { NotchService } from "../notch";

const replacementFixturePath = fileURLToPath(
  new URL("../../../test/fixtures/notch-host-replacement.cjs", import.meta.url)
);

vi.mock("electron", () => ({
  app: {
    getAppPath: vi.fn(() => "/comma"),
    isPackaged: false,
  },
  BrowserWindow: {
    getAllWindows: vi.fn(() => []),
    getFocusedWindow: vi.fn(() => null),
  },
}));

vi.mock("electron-log/main", () => ({
  default: { warn: vi.fn() },
}));

describe("NotchService host boundary", () => {
  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it("spawns the native partner with locale/path only and no Main secrets", async () => {
    vi.stubEnv("PATH", "/usr/bin:/bin");
    vi.stubEnv("LANG", "en_US.UTF-8");
    vi.stubEnv("COMMA_ELECTRON_STARTUP_SESSION_TOKEN", "fixture-bearer-secret");
    vi.stubEnv("COMMA_SESSION_TOKEN", "main-bearer-secret");
    vi.stubEnv("COMMA_API_BASE_URL", "https://api.comma.test");
    vi.stubEnv("NOTCH_ARBITRARY_SENTINEL", "must-not-cross");

    const host = new FakeNotchHost();
    const spawnHost = vi.fn((_path: string, environment: NodeJS.ProcessEnv) => {
      host.environment = environment;
      return host as unknown as ChildProcessWithoutNullStreams;
    });
    const service = new NotchService({
      isSupportedPlatform: () => true,
      pathExists: () => true,
      resolveHostPath: () => "/comma/NotchHost",
      spawnHost,
    });

    const start = service.start();
    const configure = await host.nextRequest();
    expect(configure).toMatchObject({
      method: "configure",
      payload: { compactSideWidth: 156 },
    });
    const request = await host.nextRequest();
    expect(request.method).toBe("start");
    host.respond({
      id: request.id,
      payload: { running: true },
      type: "result",
    });

    await expect(start).resolves.toMatchObject({
      payload: { running: true },
      type: "result",
    });
    expect(spawnHost).toHaveBeenCalledOnce();
    expect(host.environment).toMatchObject({
      LANG: "en_US.UTF-8",
      PATH: "/usr/bin:/bin",
    });
    expect(
      Object.keys(host.environment).every((key) =>
        ["LANG", "LC_ALL", "LC_CTYPE", "PATH"].includes(key)
      )
    ).toBe(true);
    expect(host.environment.COMMA_ELECTRON_STARTUP_SESSION_TOKEN).toBeUndefined();
    expect(host.environment.COMMA_SESSION_TOKEN).toBeUndefined();
    expect(host.environment.COMMA_API_BASE_URL).toBeUndefined();
    expect(host.environment.NOTCH_ARBITRARY_SENTINEL).toBeUndefined();
    expect(JSON.stringify([configure, request])).not.toContain("secret");

    service.dispose();
  });

  it("keeps a real replacement host alive when the stopped child reports late output, error, and exit", async () => {
    const children: ChildProcessWithoutNullStreams[] = [];
    const spawnHost = vi.fn((_path: string, environment: NodeJS.ProcessEnv) => {
      const child = spawn(
        process.execPath,
        [replacementFixturePath, String(children.length + 1)],
        {
          env: environment,
          stdio: ["pipe", "pipe", "pipe"],
        }
      );
      children.push(child);
      return child;
    });
    const service = new NotchService({
      isSupportedPlatform: () => true,
      pathExists: () => true,
      resolveHostPath: () => replacementFixturePath,
      spawnHost,
    });
    const events: Array<{ type: string; value?: string | undefined }> = [];
    service.onEvent((event) => {
      events.push({ type: event.type, value: event.payload?.value });
    });

    try {
      const firstStart = service.start();
      await expect(firstStart).resolves.toMatchObject({
        payload: { method: "start", value: "host-a" },
        type: "result",
      });
      const firstChild = children[0];
      if (!firstChild) {
        throw new Error("Expected the fixture to spawn host A.");
      }
      const firstChildClosed = new Promise<void>((resolve) => {
        firstChild.once("close", () => resolve());
      });

      await expect(service.stop()).resolves.toMatchObject({
        payload: { method: "stop", value: "host-a" },
        type: "result",
      });

      const replacementPending = waitForHostValue(service, "host-b-command-pending");
      const replacementStart = service.start();
      await replacementPending;

      expect(() => {
        firstChild.emit("error", new Error("late injected host A error"));
      }).not.toThrow();
      // Host A's late output and exit come now, while host B starts.
      process.kill(firstChild.pid!, "SIGUSR2");
      await firstChildClosed;
      const replacementChild = children[1];
      if (!replacementChild) {
        throw new Error("Expected the fixture to spawn host B.");
      }

      expect(replacementChild.exitCode).toBeNull();
      // process.kill, not child.kill: the latter marks the host as killed.
      process.kill(replacementChild.pid!, "SIGUSR1");
      await expect(replacementStart).resolves.toMatchObject({
        payload: { method: "start", value: "host-b" },
        type: "result",
      });
      await expect(service.update({ title: "after-race" })).resolves.toMatchObject({
        payload: { method: "update", value: "host-b" },
        type: "result",
      });
      expect(spawnHost).toHaveBeenCalledTimes(2);
      expect(events).not.toContainEqual({
        type: "action",
        value: "host-a-late-stdout",
      });
      expect(events.filter((event) => event.type === "exit")).toEqual([]);
    } finally {
      service.dispose();
      // Host A ignores SIGTERM until it has had its SIGUSR2.
      for (const child of children) {
        if (child.exitCode === null && child.signalCode === null) {
          child.kill("SIGKILL");
        }
      }
    }
  });
});

describe("NotchService presentation settings", () => {
  const task = {
    conversationId: "conversation-1",
    groupId: "group-1",
    id: "task-1",
    status: "in_progress" as const,
    subtitle: "In progress",
    title: "Ship the Notch",
    updatedAt: 1_787_563_200,
    workspaceId: "workspace-1",
  };

  function createService() {
    const hosts: FakeNotchHost[] = [];
    const service = new NotchService({
      isSupportedPlatform: () => true,
      pathExists: () => true,
      resolveHostPath: () => "/comma/NotchHost",
      spawnHost: () => {
        const host = new FakeNotchHost();
        hosts.push(host);
        return host as unknown as ChildProcessWithoutNullStreams;
      },
    });
    return { hosts, service };
  }

  it("never starts a turned-off Notch and shows the latest scene once it is turned on", async () => {
    const { hosts, service } = createService();
    try {
      service.setPresentation({ sideWidth: 156, visible: false });

      await expect(
        service.update({ hasActivity: true, notify: true, tasks: [task] })
      ).resolves.toMatchObject({ payload: { running: false }, type: "ack" });
      await service.update({
        airDrop: {
          transfer: { phase: "receiving", requestId: "drop-1", title: "Photo" },
        },
      });
      await expect(service.status()).resolves.toEqual({
        available: true,
        running: false,
      });
      expect(hosts).toHaveLength(0);

      service.setPresentation({ sideWidth: 200, visible: true });

      expect(hosts).toHaveLength(1);
      const host = hosts[0]!;
      await expect(host.nextRequest()).resolves.toMatchObject({
        method: "configure",
        payload: { compactSideWidth: 200 },
      });
      // Both writers' scenes come back, without replaying the arrival comma.
      await expect(host.nextRequest()).resolves.toMatchObject({
        method: "update",
        payload: {
          airDrop: { transfer: { requestId: "drop-1" } },
          hasActivity: true,
          tasks: [{ id: "task-1" }],
        },
      });
    } finally {
      service.dispose();
    }
  });

  it("forgets the scene and its host on reset, as a launch finds it", async () => {
    const { hosts, service } = createService();
    try {
      service.setPresentation({ sideWidth: 200, visible: false });
      await service.update({ hasActivity: true, notify: true, tasks: [task] });

      service.reset();
      // The preferences turn it off and on again after a reset, as at a launch: no scene comes back.
      service.setPresentation({ sideWidth: 156, visible: false });
      service.setPresentation({ sideWidth: 156, visible: true });
      expect(hosts).toHaveLength(0);
    } finally {
      service.dispose();
    }
  });

  it("previews a width on the real Notch once without keeping it as a scene", async () => {
    const { hosts, service } = createService();
    try {
      const preview = service.preview({ sideWidth: 64, title: "Ship the Notch" });
      const host = hosts[0]!;
      await expect(host.nextRequest()).resolves.toMatchObject({ method: "configure" });
      const request = await host.nextRequest();
      expect(request).toMatchObject({
        method: "preview",
        payload: { compactSideWidth: 64, title: "Ship the Notch" },
      });
      host.respond({ id: request.id, payload: { running: true }, type: "ack" });
      await preview;

      // Turning the Notch off and on again restores scenes, never a preview.
      service.setPresentation({ sideWidth: 156, visible: false });
      service.setPresentation({ sideWidth: 156, visible: true });
      expect(hosts).toHaveLength(1);
    } finally {
      service.dispose();
    }
  });

  it("brings the kept scene back once when the host ends on its own", async () => {
    const { hosts, service } = createService();
    try {
      const update = service.update({ hasActivity: true, notify: true, tasks: [task] });
      const first = hosts[0]!;
      await expect(first.nextRequest()).resolves.toMatchObject({ method: "configure" });
      const request = await first.nextRequest();
      first.respond({ id: request.id, payload: { running: true }, type: "ack" });
      await update;

      first.emit("exit", null);
      expect(hosts).toHaveLength(2);
      const second = hosts[1]!;
      await expect(second.nextRequest()).resolves.toMatchObject({
        method: "configure",
        payload: { compactSideWidth: 156 },
      });
      const restore = await second.nextRequest();
      expect(restore).toMatchObject({
        method: "update",
        payload: { hasActivity: true, tasks: [{ id: "task-1" }] },
      });
      expect(restore.payload).not.toHaveProperty("notify");

      // A host that ends again right away waits for the next change.
      second.emit("exit", 1);
      expect(hosts).toHaveLength(2);
    } finally {
      service.dispose();
    }
  });

  it("resizes a running Notch in place and ends its host when it is turned off", async () => {
    const { hosts, service } = createService();
    try {
      const update = service.update({ hasActivity: true, tasks: [task] });
      const host = hosts[0]!;
      await expect(host.nextRequest()).resolves.toMatchObject({ method: "configure" });
      const request = await host.nextRequest();
      host.respond({ id: request.id, payload: { running: true }, type: "ack" });
      await update;

      service.setPresentation({ sideWidth: 96, visible: true });
      await expect(host.nextRequest()).resolves.toMatchObject({
        method: "configure",
        payload: { compactSideWidth: 96 },
      });
      expect(hosts).toHaveLength(1);

      service.setPresentation({ sideWidth: 96, visible: false });
      expect(host.killed).toBe(true);
      await service.update({ hasActivity: true, tasks: [task] });
      expect(hosts).toHaveLength(1);
    } finally {
      service.dispose();
    }
  });
});

describe("NotchService with Main's own Tasks", () => {
  const rendererTask = {
    conversationId: "conversation-1",
    groupId: "group-1",
    id: "group-1:conversation-1",
    status: "in_progress" as const,
    subtitle: "In progress",
    title: "Ship the Notch",
    updatedAt: 1_787_563_200_000,
    workspaceId: "workspace-1",
  };
  const sent = {
    ...rendererTask,
    conversationId: "quick-chat:request-1",
    groupId: "quick-chat:request-1",
    id: "quick-chat:request-1",
    subtitle: "进行中",
    title: "Plan the review",
    updatedAt: 1_787_563_260_000,
  };
  const created = {
    ...sent,
    conversationId: "conversation-2",
    groupId: "group-1",
    id: "group-1:conversation-2",
    title: "Design review plan",
    workspaceId: "workspace-1",
  };

  function createService() {
    const hosts: FakeNotchHost[] = [];
    const service = new NotchService({
      isSupportedPlatform: () => true,
      locale: "zh-CN",
      pathExists: () => true,
      resolveHostPath: () => "/comma/NotchHost",
      spawnHost: () => {
        const host = new FakeNotchHost();
        hosts.push(host);
        return host as unknown as ChildProcessWithoutNullStreams;
      },
    });
    return { hosts, service };
  }

  it("shows Main's Tasks after the renderer's, and the renderer's copy of a Task wins", async () => {
    const { hosts, service } = createService();
    try {
      // Without a window, Main labels the list in its own language.
      service.setMainTasks([sent], { notify: true });
      const host = hosts[0]!;
      await expect(answered(host)).resolves.toMatchObject({ method: "configure" });
      await expect(answered(host)).resolves.toMatchObject({
        method: "update",
        payload: {
          hasActivity: true,
          listTitle: "任务动态",
          notify: true,
          openChatLabel: "打开聊天",
          tasks: [{ id: sent.id, title: "Plan the review" }],
        },
      });

      // A renderer write replaces NotchHost's whole list, so Main's Task rides along, the newest first.
      await Promise.all([
        service.update({
          hasActivity: true,
          listTitle: "Conversation activity",
          tasks: [rendererTask],
        }),
        expect(answered(host)).resolves.toMatchObject({
          payload: {
            listTitle: "Conversation activity",
            tasks: [{ id: sent.id }, { id: rendererTask.id }],
          },
        }),
      ]);

      // The Task the server made replaces the one shown on sending, without a bounce.
      service.setMainTasks([created]);
      const replaced = await answered(host);
      expect(replaced.payload).not.toHaveProperty("notify");
      expect(replaced.payload).toMatchObject({
        listTitle: "Conversation activity",
        tasks: [
          { id: created.id, title: "Design review plan" },
          { id: rendererTask.id },
        ],
      });
      expect(service.showsMainTask(created.id)).toBe(true);

      // Once the renderer has the Task too, its copy (with the Worker's step) is the one shown.
      const followed = { ...created, subtitle: "Reading the calendar" };
      await Promise.all([
        service.update({ tasks: [followed, rendererTask] }),
        expect(answered(host)).resolves.toMatchObject({
          payload: {
            tasks: [
              { id: created.id, subtitle: "Reading the calendar" },
              { id: rendererTask.id },
            ],
          },
        }),
      ]);
      expect(service.showsMainTask(created.id)).toBe(false);
    } finally {
      service.dispose();
    }
  });

  it("shows a renderer Task in the row of the message it came from, once", async () => {
    const { hosts, service } = createService();
    try {
      service.setMainTasks([{ ...sent, status: "sent", subtitle: "已发送" }], {
        notify: true,
      });
      const host = hosts[0]!;
      await answered(host);
      await answered(host);

      // Main's row now stands for the Task the Router made; the renderer lists it too.
      const running = {
        ...created,
        subtitle: "Reading the calendar",
        updatedAt: sent.updatedAt + 1,
      };
      service.setMainTasks([
        { ...sent, title: created.title, subtitle: "进行中", standsFor: created.id },
      ]);
      await answered(host);
      await Promise.all([
        service.update({ tasks: [running, rendererTask] }),
        expect(answered(host)).resolves.toMatchObject({
          payload: {
            tasks: [
              {
                id: sent.id,
                conversationId: created.conversationId,
                subtitle: "Reading the calendar",
                title: created.title,
              },
              { id: rendererTask.id },
            ],
          },
        }),
      ]);
      // The row is Main's, so Main answers its click.
      expect(service.showsMainTask(sent.id)).toBe(true);

      // The renderer stops listing the Task: Main's row shows what Main last said.
      await Promise.all([
        service.update({ tasks: [rendererTask] }),
        expect(answered(host)).resolves.toMatchObject({
          payload: {
            tasks: [
              { id: sent.id, title: created.title, subtitle: "进行中" },
              { id: rendererTask.id },
            ],
          },
        }),
      ]);
    } finally {
      service.dispose();
    }
  });

  it("lists the newest twenty of the renderer's and Main's Tasks together", async () => {
    const { hosts, service } = createService();
    try {
      const rendererTasks = Array.from({ length: 25 }, (_, n) => ({
        ...rendererTask,
        conversationId: `conversation-${n + 1}`,
        id: `group-1:conversation-${n + 1}`,
        updatedAt: rendererTask.updatedAt + n * 1_000,
      }));
      service.setMainTasks([sent], { notify: true });
      const host = hosts[0]!;
      await answered(host);
      await answered(host);

      await Promise.all([
        service.update({ hasActivity: true, tasks: rendererTasks }),
        expect(answered(host)).resolves.toMatchObject({
          payload: {
            tasks: [
              { id: sent.id },
              { id: "group-1:conversation-25" },
              ...Array.from({ length: 18 }, (_, n) => ({
                id: `group-1:conversation-${24 - n}`,
              })),
            ],
          },
        }),
      ]);
      // Main's send is newer than every renderer Task here; the six oldest are left out.
      await Promise.all([
        service.update({ tasks: rendererTasks }),
        expect(answered(host)).resolves.toMatchObject({
          payload: {
            tasks: expect.toSatisfy((tasks: unknown[]) => tasks.length === 20),
          },
        }),
      ]);
    } finally {
      service.dispose();
    }
  });

  it("keeps Main's Tasks when the renderer hides its scene, and on a restarted host", async () => {
    const { hosts, service } = createService();
    try {
      const update = service.update({ hasActivity: true, tasks: [rendererTask] });
      const first = hosts[0]!;
      await answered(first);
      await answered(first);
      await update;
      service.setMainTasks([sent], { notify: true });
      await answered(first);

      const hide = service.hide();
      const hidden = await answered(first);
      await hide;
      expect(hidden).toMatchObject({
        method: "update",
        payload: { airDrop: {}, hasActivity: true, tasks: [{ id: sent.id }] },
      });
      expect(hidden.payload?.tasks).toHaveLength(1);

      first.emit("exit", null);
      const second = hosts[1]!;
      await answered(second);
      const restore = await answered(second);
      expect(restore).toMatchObject({
        method: "update",
        payload: { listTitle: "任务动态", tasks: [{ id: sent.id }] },
      });
      expect(restore.payload).not.toHaveProperty("notify");

      // Without Main's Tasks, hiding is NotchHost's own `hide` again.
      service.setMainTasks([]);
      await expect(answered(second)).resolves.toMatchObject({
        payload: { hasActivity: false, tasks: [] },
      });
      const lastHide = service.hide();
      await expect(answered(second)).resolves.toMatchObject({ method: "hide" });
      await lastHide;
    } finally {
      service.dispose();
    }
  });

  it("keeps Main's Tasks while the Notch is turned off and shows them once it is on", async () => {
    const { hosts, service } = createService();
    try {
      service.setPresentation({ sideWidth: 156, visible: false });
      service.setMainTasks([sent], { notify: true });
      expect(hosts).toHaveLength(0);

      service.setPresentation({ sideWidth: 156, visible: true });
      const host = hosts[0]!;
      await answered(host);
      const shown = await answered(host);
      expect(shown).toMatchObject({
        method: "update",
        payload: { hasActivity: true, tasks: [{ id: sent.id }] },
      });
      expect(shown.payload).not.toHaveProperty("notify");
    } finally {
      service.dispose();
    }
  });
});

/** The host's next command, answered. */
async function answered(host: FakeNotchHost) {
  const request = await host.nextRequest();
  host.respond({ id: request.id, payload: { running: true }, type: "ack" });
  return request;
}

function waitForHostValue(service: NotchService, expectedValue: string) {
  return new Promise<void>((resolve) => {
    const unsubscribe = service.onEvent((event) => {
      if (event.payload?.value !== expectedValue) {
        return;
      }

      unsubscribe();
      resolve();
    });
  });
}

interface HostRequest {
  id: string;
  method: string;
  payload?: Record<string, unknown>;
}

class FakeNotchHost extends EventEmitter {
  readonly stdin = new PassThrough();
  readonly stdout = new PassThrough();
  readonly stderr = new PassThrough();
  environment: NodeJS.ProcessEnv = {};
  killed = false;
  readonly #requests: HostRequest[] = [];
  readonly #waiting: Array<(request: HostRequest) => void> = [];
  #buffer = "";

  constructor() {
    super();
    // Main writes one JSON line per command, and a new host gets two at once.
    this.stdin.on("data", (chunk) => {
      this.#buffer += chunk.toString();
      for (;;) {
        const newline = this.#buffer.indexOf("\n");
        if (newline < 0) return;
        const request = JSON.parse(this.#buffer.slice(0, newline)) as HostRequest;
        this.#buffer = this.#buffer.slice(newline + 1);
        const waiting = this.#waiting.shift();
        if (waiting) waiting(request);
        else this.#requests.push(request);
      }
    });
  }

  nextRequest(): Promise<HostRequest> {
    const request = this.#requests.shift();
    if (request) return Promise.resolve(request);
    return new Promise((resolve) => this.#waiting.push(resolve));
  }

  respond(response: unknown) {
    this.stdout.write(`${JSON.stringify(response)}\n`);
  }

  kill() {
    this.killed = true;
    this.emit("exit", 0);
    return true;
  }
}
