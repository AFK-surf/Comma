import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import type { ChildProcessWithoutNullStreams } from "node:child_process";
import { describe, expect, it, vi } from "vitest";
import { NotchService } from "../notch";

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

describe("NotchService dismissed Tasks", () => {
  const ship = {
    conversationId: "conversation-1",
    groupId: "group-1",
    id: "group-1:conversation-1",
    status: "in_progress" as const,
    subtitle: "In progress",
    title: "Ship the Notch",
    updatedAt: 1_787_563_200_000,
    workspaceId: "workspace-1",
  };
  const review = {
    ...ship,
    conversationId: "conversation-2",
    id: "group-1:conversation-2",
    runStartedAt: 1_787_563_100_000,
    title: "Review the plan",
    updatedAt: 1_787_563_260_000,
  };
  const sent = {
    ...ship,
    conversationId: "quick-chat:request-1",
    groupId: "quick-chat:request-1",
    id: "quick-chat:request-1",
    status: "sent" as const,
    subtitle: "已发送",
    title: "Plan the review",
    updatedAt: 1_787_563_320_000,
  };

  function createService() {
    const hosts: FakeNotchHost[] = [];
    const service = new NotchService({
      // Every command is answered, so the command deadline never has to run.
      clock: { now: () => 1_787_563_200_000, setTimer: () => () => undefined },
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

  it("takes a dismissed Task out of every write until it runs anew", async () => {
    const { hosts, service } = createService();
    try {
      await Promise.all([
        service.update({ dismissTaskLabel: "Dismiss", tasks: [ship, review] }),
        (async () => {
          const host = hosts[0]!;
          await expect(answered(host)).resolves.toMatchObject({ method: "configure" });
          await expect(answered(host)).resolves.toMatchObject({
            method: "update",
            payload: {
              dismissTaskLabel: "Dismiss",
              tasks: [{ id: review.id }, { id: ship.id }],
            },
          });
        })(),
      ]);
      const host = hosts[0]!;

      // The × on the row: Main writes the list without it at once.
      host.dismiss(review.id);
      await expect(answered(host)).resolves.toMatchObject({
        method: "update",
        payload: {
          dismissTaskLabel: "Dismiss",
          hasActivity: true,
          tasks: [{ id: ship.id }],
        },
      });

      // The renderer keeps listing the Task (a Worker step changed); it stays out.
      const stepped = { ...review, subtitle: "Reading the calendar" };
      await Promise.all([
        service.update({ tasks: [ship, stepped] }),
        expect(answered(host)).resolves.toMatchObject({
          payload: { tasks: [{ id: ship.id }] },
        }),
      ]);

      // A write without it (a renderer still loading after a reload, another
      // workspace, the newest-first cap) does not end the dismissal.
      await Promise.all([
        service.update({ tasks: [] }),
        expect(answered(host)).resolves.toMatchObject({
          payload: { hasActivity: false, tasks: [] },
        }),
      ]);
      await Promise.all([
        service.update({ tasks: [ship] }),
        expect(answered(host)).resolves.toMatchObject({
          payload: { tasks: [{ id: ship.id }] },
        }),
      ]);
      await Promise.all([
        service.update({ tasks: [ship, review] }),
        expect(answered(host)).resolves.toMatchObject({
          payload: { tasks: [{ id: ship.id }] },
        }),
      ]);

      // The Task running anew shows.
      await Promise.all([
        service.update({
          tasks: [ship, { ...review, runStartedAt: 1_787_563_250_000 }],
        }),
        expect(answered(host)).resolves.toMatchObject({
          payload: { tasks: [{ id: review.id }, { id: ship.id }] },
        }),
      ]);

      // Dismissing the last row leaves an empty list, and a reset forgets it all.
      host.dismiss(review.id);
      await expect(answered(host)).resolves.toMatchObject({
        payload: { hasActivity: true, tasks: [{ id: ship.id }] },
      });
      host.dismiss(ship.id);
      await expect(answered(host)).resolves.toMatchObject({
        payload: { hasActivity: false, tasks: [] },
      });
      service.reset();
      await Promise.all([
        service.update({ tasks: [ship, review] }),
        (async () => {
          const next = hosts[1]!;
          await answered(next);
          await expect(answered(next)).resolves.toMatchObject({
            payload: { tasks: [{ id: review.id }, { id: ship.id }] },
          });
        })(),
      ]);
    } finally {
      service.dispose();
    }
  });

  it("keeps a dismissed row of Main's out as the Task it stands for, and ignores rows it does not show", async () => {
    const { hosts, service } = createService();
    try {
      service.setMainTasks([{ ...sent, standsFor: review.id }], { notify: true });
      const host = hosts[0]!;
      await answered(host);
      await expect(answered(host)).resolves.toMatchObject({
        method: "update",
        payload: {
          dismissTaskLabel: "隐藏",
          tasks: [{ id: sent.id, title: "Plan the review" }],
        },
      });

      // A × on a row the Notch does not show changes nothing: the next write is the renderer's.
      host.dismiss(ship.id);
      await Promise.all([
        service.update({ tasks: [review, ship] }),
        expect(answered(host)).resolves.toMatchObject({
          payload: {
            tasks: [{ id: sent.id, title: "Review the plan" }, { id: ship.id }],
          },
        }),
      ]);

      // The row shows the renderer's Task; dismissed, neither comes back.
      host.dismiss(sent.id);
      await expect(answered(host)).resolves.toMatchObject({
        payload: { tasks: [{ id: ship.id }] },
      });
      service.setMainTasks([]);
      await expect(answered(host)).resolves.toMatchObject({
        payload: { tasks: [{ id: ship.id }] },
      });
      await Promise.all([
        service.update({ tasks: [review, ship] }),
        expect(answered(host)).resolves.toMatchObject({
          payload: { tasks: [{ id: ship.id }] },
        }),
      ]);
    } finally {
      service.dispose();
    }
  });

  it("keeps the Task a dismissed row of Main's comes to stand for out after the row goes", async () => {
    const { hosts, service } = createService();
    try {
      service.setMainTasks([sent], { notify: true });
      const host = hosts[0]!;
      await answered(host);
      await expect(answered(host)).resolves.toMatchObject({
        payload: { tasks: [{ id: sent.id }] },
      });

      // Dismissed before the Router made its Task.
      host.dismiss(sent.id);
      await expect(answered(host)).resolves.toMatchObject({
        payload: { hasActivity: false, tasks: [] },
      });
      service.setMainTasks([{ ...sent, standsFor: review.id }]);
      await expect(answered(host)).resolves.toMatchObject({
        payload: { tasks: [] },
      });
      await Promise.all([
        service.update({ tasks: [review, ship] }),
        expect(answered(host)).resolves.toMatchObject({
          payload: { tasks: [{ id: ship.id }] },
        }),
      ]);

      // Newer sends push the row out; its Task stays out until it runs anew.
      service.setMainTasks([]);
      await expect(answered(host)).resolves.toMatchObject({
        payload: { tasks: [{ id: ship.id }] },
      });
      await Promise.all([
        service.update({
          tasks: [{ ...review, runStartedAt: 1_787_563_250_000 }, ship],
        }),
        expect(answered(host)).resolves.toMatchObject({
          payload: { tasks: [{ id: review.id }, { id: ship.id }] },
        }),
      ]);
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

interface HostRequest {
  id: string;
  method: string;
  payload?: Record<string, unknown>;
}

class FakeNotchHost extends EventEmitter {
  readonly stdin = new PassThrough();
  readonly stdout = new PassThrough();
  readonly stderr = new PassThrough();
  killed = false;
  readonly #requests: HostRequest[] = [];
  readonly #waiting: Array<(request: HostRequest) => void> = [];
  #buffer = "";

  constructor() {
    super();
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

  /** The reader's × on a row, as NotchHost reports it. */
  dismiss(taskId: string) {
    this.respond({
      payload: { action: "task:dismiss", value: taskId },
      type: "action",
    });
  }

  kill() {
    this.killed = true;
    this.emit("exit", 0);
    return true;
  }
}
