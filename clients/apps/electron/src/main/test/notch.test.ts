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

      await firstChildClosed;
      const replacementChild = children[1];
      if (!replacementChild) {
        throw new Error("Expected the fixture to spawn host B.");
      }

      expect(replacementChild.exitCode).toBeNull();
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
      for (const child of children) {
        if (child.exitCode === null && !child.killed) {
          child.kill();
        }
      }
    }
  }, 10_000);
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

function waitForHostValue(service: NotchService, expectedValue: string) {
  return new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => {
      unsubscribe();
      reject(new Error(`Timed out waiting for NotchHost value: ${expectedValue}`));
    }, 2_000);
    const unsubscribe = service.onEvent((event) => {
      if (event.payload?.value !== expectedValue) {
        return;
      }

      clearTimeout(timer);
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
