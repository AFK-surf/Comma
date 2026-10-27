import type { ChildProcessWithoutNullStreams } from "node:child_process";
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";

import {
  chatProtocolVersion,
  statusMenuClientFrameSchema,
  statusMenuHostFrameSchema,
  type StatusMenuClientFrame,
  type StatusMenuHostFrame,
} from "@comma/chat-contract";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  NativeStatusMenuService,
  STATUS_MENU_STOP_TIMEOUT_MS,
} from "../native-status-menu";

vi.mock("electron-log/main", () => ({
  default: { warn: vi.fn() },
}));

const menu = {
  iconPath: "/resources/CommaTemplate.png",
  rows: [
    { id: "open-comma", kind: "item" as const, shortcut: "⌥ Space", title: "Open" },
    { kind: "separator" as const },
    { id: "quit", kind: "item" as const, shortcut: "⌘ Q", title: "Quit Comma" },
  ],
  toolTip: "Comma is running",
  width: 260,
};

describe("NativeStatusMenuService", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("draws the menu in the helper it starts, sends each new menu there, and reports the chosen row", () => {
    const { hosts, service } = createService();
    const onSelect = vi.fn();

    expect(hosts).toHaveLength(0);
    service.showStatusMenu(menu, onSelect, vi.fn());
    expect(hosts).toHaveLength(1);
    expect(hosts[0]!.hostFrames()).toEqual([
      expect.objectContaining({ ...menu, kind: "status-menu.show" }),
    ]);

    const changed = { ...menu, rows: menu.rows.slice(2) };
    service.showStatusMenu(changed, onSelect, vi.fn());
    expect(hosts).toHaveLength(1);
    expect(hosts[0]!.hostFrames().at(-1)).toMatchObject({
      kind: "status-menu.show",
      rows: changed.rows,
    });

    hosts[0]!.emitClientFrame({
      id: "quit",
      kind: "status-menu.select",
      protocolVersion: chatProtocolVersion,
      requestId: "select-1",
    });
    expect(onSelect).toHaveBeenCalledExactlyOnceWith("quit");
    service.dispose();
  });

  it("ends the helper when the menu is hidden, without counting that as a loss, and starts another for the next menu", () => {
    const { hosts, service } = createService();
    const onLost = vi.fn();
    service.showStatusMenu(menu, vi.fn(), onLost);

    service.hideStatusMenu();
    expect(hosts[0]!.stdin.writableEnded).toBe(true);
    hosts[0]!.exit(0);
    expect(onLost).not.toHaveBeenCalled();

    service.showStatusMenu(menu, vi.fn(), onLost);
    expect(hosts).toHaveLength(2);
    expect(hosts[1]!.hostFrames()).toHaveLength(1);
    service.dispose();
    expect(hosts[1]!.stdin.writableEnded).toBe(true);
    expect(onLost).not.toHaveBeenCalled();
  });

  it("draws a menu shown again only after the stopped helper ends, and kills one that does not end", async () => {
    const { hosts, service } = createService();
    service.showStatusMenu(menu, vi.fn(), vi.fn());
    service.hideStatusMenu();

    // Two items never show together: the next helper waits for the first to end.
    service.showStatusMenu(menu, vi.fn(), vi.fn());
    const latest = { ...menu, toolTip: "Comma is busy" };
    service.showStatusMenu(latest, vi.fn(), vi.fn());
    expect(hosts).toHaveLength(1);
    hosts[0]!.exit(0);
    expect(hosts).toHaveLength(2);
    expect(hosts[1]!.hostFrames()).toEqual([
      expect.objectContaining({ ...latest, kind: "status-menu.show" }),
    ]);

    // A helper that ignores its closed input is killed.
    service.hideStatusMenu();
    await vi.advanceTimersByTimeAsync(STATUS_MENU_STOP_TIMEOUT_MS);
    expect(hosts[1]!.kill).toHaveBeenCalledExactlyOnceWith("SIGTERM");
    expect(hosts[0]!.kill).not.toHaveBeenCalled();
    hosts[1]!.exit(null);
    service.dispose();
  });

  it("gives the menu up once when the helper ends or cannot run, so Main draws it", () => {
    const { hosts, service } = createService();
    const onLost = vi.fn();
    const onSelect = vi.fn();
    service.showStatusMenu(menu, onSelect, onLost);

    hosts[0]!.exit(1);
    expect(onLost).toHaveBeenCalledOnce();
    // A late row from the lost helper chooses nothing.
    hosts[0]!.emitClientFrame({
      id: "quit",
      kind: "status-menu.select",
      protocolVersion: chatProtocolVersion,
      requestId: "late",
    });
    expect(onSelect).not.toHaveBeenCalled();

    // Shown again, the menu starts a new helper; one that cannot start is lost too.
    const onLostAgain = vi.fn();
    service.showStatusMenu(menu, vi.fn(), onLostAgain);
    hosts[1]!.emit("error", new Error("spawn EACCES"));
    hosts[1]!.exit(null);
    expect(onLostAgain).toHaveBeenCalledOnce();
    expect(onLost).toHaveBeenCalledOnce();
    service.dispose();
  });
});

function createService() {
  const hosts: FakeHost[] = [];
  const service = new NativeStatusMenuService({
    resolveExecutablePath: () => "/helper/CommaMenuBarHost",
    spawnHost: () => {
      const host = new FakeHost();
      hosts.push(host);
      return host as unknown as ChildProcessWithoutNullStreams;
    },
  });
  return { hosts, service };
}

class FakeHost extends EventEmitter {
  readonly stdin = new PassThrough();
  readonly stdout = new PassThrough();
  readonly stderr = new PassThrough();
  readonly kill = vi.fn();
  #input = "";

  constructor() {
    super();
    this.stdin.on("data", (chunk) => {
      this.#input += chunk.toString();
    });
  }

  hostFrames(): StatusMenuHostFrame[] {
    return this.#input
      .trim()
      .split("\n")
      .filter(Boolean)
      .map((line) => statusMenuHostFrameSchema.parse(JSON.parse(line) as unknown));
  }

  emitClientFrame(frame: StatusMenuClientFrame) {
    this.stdout.emit(
      "data",
      Buffer.from(`${JSON.stringify(statusMenuClientFrameSchema.parse(frame))}\n`)
    );
  }

  exit(code: number | null) {
    this.emit("exit", code, null);
  }
}
