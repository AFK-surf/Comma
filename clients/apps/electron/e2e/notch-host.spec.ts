import { expect, test } from "@playwright/test";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { existsSync } from "node:fs";
import { resolve } from "node:path";
import { createInterface, type Interface } from "node:readline";

const hostPath = resolve(process.cwd(), "apps/electron/dist/native/macos/NotchHost");
const canRunNotchHost = process.platform === "darwin" && existsSync(hostPath);

test.skip(!canRunNotchHost, "The native NotchHost binary is available only on macOS.");

test("native NotchHost appears for an in-progress Task and hides for an empty projection", async () => {
  const host = spawn(hostPath, [], {
    env: {
      LANG: process.env.LANG ?? "en_US.UTF-8",
      PATH: process.env.PATH ?? "/usr/bin:/bin",
    },
    stdio: ["pipe", "pipe", "pipe"],
  });
  const lines = createInterface({ input: host.stdout });
  const harness = new NotchHostHarness(host, lines);

  try {
    await expect(harness.nextEvent()).resolves.toMatchObject({
      payload: { hasActivity: false, running: true },
      type: "ready",
    });

    await expect(
      harness.command("update", {
        listSubtitle: "Open a conversation to inspect its latest state.",
        listTitle: "Conversation activity",
        openChatLabel: "Open chat",
        tasks: [
          {
            conversationId: "conversation-1",
            groupId: "group-1",
            id: "task-1",
            status: "in_progress",
            subtitle: "In progress",
            title: "Ship the Notch",
            updatedAt: 1_787_563_200,
            workspaceId: "workspace-1",
          },
        ],
      })
    ).resolves.toMatchObject({
      payload: { hasActivity: true, method: "update", running: true },
      type: "ack",
    });

    await expect(harness.command("update", { tasks: [] })).resolves.toMatchObject({
      payload: { hasActivity: false, method: "update", running: true },
      type: "ack",
    });
  } finally {
    await harness.close();
  }
});

class NotchHostHarness {
  private readonly iterator: AsyncIterator<string>;
  private nextID = 0;

  constructor(
    private readonly host: ChildProcessWithoutNullStreams,
    private readonly lines: Interface
  ) {
    this.iterator = lines[Symbol.asyncIterator]();
  }

  async nextEvent(): Promise<Record<string, unknown>> {
    const next = await this.iterator.next();
    if (next.done) {
      throw new Error("NotchHost closed before returning an event.");
    }
    return JSON.parse(next.value) as Record<string, unknown>;
  }

  async command(method: string, payload?: Record<string, unknown>) {
    const id = `e2e-${++this.nextID}`;
    this.host.stdin.write(`${JSON.stringify({ id, method, payload })}\n`);

    for (;;) {
      const event = await this.nextEvent();
      if (event.id === id) return event;
    }
  }

  async close() {
    this.lines.close();
    if (this.host.exitCode !== null || this.host.killed) return;

    const exited = new Promise<void>((resolveExit) => {
      this.host.once("exit", () => resolveExit());
    });
    this.host.kill();
    await exited;
  }
}
