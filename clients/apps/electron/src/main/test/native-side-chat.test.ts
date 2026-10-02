import type { ChildProcessWithoutNullStreams } from "node:child_process";
import { EventEmitter } from "node:events";
import { readFile } from "node:fs/promises";
import { PassThrough } from "node:stream";
import { fileURLToPath } from "node:url";

import {
  chatProtocolVersion,
  sideChatClientFrameSchema,
  sideChatGeometrySettingsSchema,
  sideChatHostFrameSchema,
  type SideChatClientFrame,
  type SideChatDebugSettingsValues,
  type SideChatHostFrame,
  type SideChatPresentation,
} from "@comma/chat-contract";
import {
  defaultSideChatDebugSettings,
  defaultSideChatShortcut,
  type SideChatDebugSettings,
  type SideChatShortcut,
} from "@comma/native-bridge";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  NativeSideChatService,
  type SideChatBackdropGeometry,
} from "../native-side-chat";

vi.mock("electron-log/main", () => ({
  default: { warn: vi.fn() },
}));

describe("NativeSideChatService", () => {
  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllEnvs();
  });

  it("keeps native helper fixtures on the canonical chat protocol version", async () => {
    const fixtureNames = [
      "side-chat-shortcut-overlap-host.cjs",
      "side-chat-shortcut-rejection-host.cjs",
      "side-chat-shortcut-replay-host.cjs",
      "side-chat-slow-close-host.cjs",
    ];

    await Promise.all(
      fixtureNames.map(async (fixtureName) => {
        const fixturePath = fileURLToPath(
          new URL(`../../../test/fixtures/${fixtureName}`, import.meta.url)
        );
        const fixture = await readFile(fixturePath, "utf8");

        expect(fixture).toContain(`const protocolVersion = ${chatProtocolVersion};`);
      })
    );
  });

  it("keeps the gesture helper credential-free and sends only presentation controls", async () => {
    vi.stubEnv("PATH", "/usr/bin:/bin");
    vi.stubEnv("LANG", "en_US.UTF-8");
    vi.stubEnv("COMMA_ELECTRON_STARTUP_SESSION_TOKEN", "renderer-bearer-secret");
    vi.stubEnv("COMMA_SESSION_TOKEN", "main-bearer-secret");
    vi.stubEnv("COMMA_API_BASE_URL", "https://comma.test");
    vi.stubEnv("SIDE_CHAT_ARBITRARY_SENTINEL", "must-not-cross");
    const hosts: FakeHost[] = [];
    const closeTestWindow = vi.fn();
    const openSettings = vi.fn();
    const openTestWindow = vi.fn();
    const service = createService(hosts, {
      onCloseTestWindow: closeTestWindow,
      onOpenSettings: openSettings,
      onOpenTestWindow: openTestWindow,
    });

    service.start();
    service.setContentSize({ height: 285.2, width: 363.1 });
    service.setInteractiveProgress({ progress: 0.42 });
    service.finishInteractiveProgress({ shouldOpen: true });
    service.open();
    service.toggle();
    service.close();
    await service.openSettings();
    await service.openTestWindow({
      sourceFrame: { height: 30, width: 30, x: 42, y: 84 },
    });
    service.closeTestWindow();

    expect(hosts).toHaveLength(1);
    expect(hosts[0]?.environment).toMatchObject({
      LANG: "en_US.UTF-8",
      PATH: "/usr/bin:/bin",
    });
    expect(hosts[0]?.environment.COMMA_ELECTRON_STARTUP_SESSION_TOKEN).toBeUndefined();
    expect(hosts[0]?.environment.COMMA_SESSION_TOKEN).toBeUndefined();
    expect(hosts[0]?.environment.COMMA_API_BASE_URL).toBeUndefined();
    expect(hosts[0]?.environment.SIDE_CHAT_ARBITRARY_SENTINEL).toBeUndefined();
    expect(hosts[0]?.hostFrames().map(({ kind }) => kind)).toEqual([
      "side-chat.layout",
      "side-chat.shortcut",
      "side-chat.layout",
      "side-chat.interactive-progress",
      "side-chat.interactive-complete",
      "side-chat.open",
      "side-chat.toggle",
      "side-chat.close",
    ]);
    expect(hosts[0]?.hostFrames()[0]).toMatchObject({
      debugSettings: sideChatGeometrySettingsSchema.parse(defaultSideChatDebugSettings),
      height: 254,
      kind: "side-chat.layout",
      width: 400,
    });
    expect(hosts[0]?.hostFrames()[1]).toMatchObject({
      keyCode: 6,
      kind: "side-chat.shortcut",
      modifiers: 4_096,
    });
    expect(hosts[0]?.hostFrames()[2]).toMatchObject({
      height: 286,
      kind: "side-chat.layout",
      width: 364,
    });
    expect(hosts[0]?.hostFrames()[3]).toMatchObject({
      kind: "side-chat.interactive-progress",
      progress: 0.42,
    });
    expect(hosts[0]?.hostFrames()[4]).toMatchObject({
      kind: "side-chat.interactive-complete",
      shouldOpen: true,
    });
    expect(openSettings).toHaveBeenCalledOnce();
    expect(openTestWindow).toHaveBeenCalledWith({
      sourceFrame: { height: 30, width: 30, x: 42, y: 84 },
    });
    expect(closeTestWindow).toHaveBeenCalledOnce();
    expect(JSON.stringify(hosts[0]?.hostFrames())).not.toContain("secret");
    expect(JSON.stringify(hosts[0]?.hostFrames())).not.toContain("chat.snapshot");

    hosts[0]?.emitClientFrame({
      kind: "side-chat.ready",
      protocolVersion: chatProtocolVersion,
      requestId: "helper-ready",
    });
    expect(hosts[0]?.hostFrames().at(-1)).toEqual({
      kind: "command.result",
      ok: true,
      protocolVersion: chatProtocolVersion,
      requestId: "helper-ready",
    });

    service.dispose();
    expect(hosts[0]?.hostFrames().at(-1)?.kind).toBe("side-chat.stop");
  });

  it("clears the binding and replays the cleared state after helper restart", async () => {
    vi.useFakeTimers();
    const hosts: FakeHost[] = [];
    const service = createService(hosts);
    service.start();
    hosts[0]?.acknowledgeLastShortcut();
    const clearing = service.updateShortcut(null);
    expect(hosts[0]?.hostFrames().at(-1)).toMatchObject({
      kind: "side-chat.shortcut",
      modifiers: 0,
    });
    expect(hosts[0]?.hostFrames().at(-1)).not.toHaveProperty("keyCode");
    hosts[0]?.acknowledgeLastShortcut();
    await expect(clearing).resolves.toBeNull();
    hosts[0]?.emit("exit", 1, null);
    await vi.advanceTimersByTimeAsync(1_000);
    expect(
      hosts[1]?.hostFrames().find((frame) => frame.kind === "side-chat.shortcut")
    ).toMatchObject({ kind: "side-chat.shortcut", modifiers: 0 });
    expect(
      hosts[1]?.hostFrames().find((frame) => frame.kind === "side-chat.shortcut")
    ).not.toHaveProperty("keyCode");
    service.dispose();
  });

  it("draws the menu-bar menu in the helper it starts, reports the chosen row, and gives the menu up with the helper", async () => {
    vi.useFakeTimers();
    const hosts: FakeHost[] = [];
    const service = createService(hosts);
    const onSelect = vi.fn();
    const onLost = vi.fn();
    const menu = {
      iconPath: "/resources/CommaTemplate.png",
      rows: [
        { id: "open-comma", kind: "item" as const, shortcut: "⌥ Space", title: "Open" },
        { kind: "separator" as const },
        { id: "quit", kind: "item" as const, shortcut: "⌘ Q", title: "Quit Comma" },
      ],
      toolTip: "Comma is running",
      width: 300,
    };

    // A menu set before the helper runs reaches it when it starts.
    service.showStatusMenu(menu, onSelect, onLost);
    expect(hosts).toHaveLength(0);
    service.start();
    expect(statusMenuShows(hosts[0])).toEqual([
      expect.objectContaining({ ...menu, kind: "status-menu.show" }),
    ]);
    hosts[0]?.emitClientFrame({
      id: "quit",
      kind: "status-menu.select",
      protocolVersion: chatProtocolVersion,
      requestId: "select-1",
    });
    expect(onSelect).toHaveBeenCalledWith("quit");

    // A lost helper takes the menu with it: Main draws it from then on, and
    // the restarted helper does not.
    hosts[0]?.exit(1);
    expect(onLost).toHaveBeenCalledOnce();
    await vi.advanceTimersByTimeAsync(1_000);
    expect(statusMenuShows(hosts[1])).toEqual([]);
    hosts[1]?.exit(1);
    expect(onLost).toHaveBeenCalledOnce();

    // A hidden menu stays hidden in the next helper.
    service.showStatusMenu(menu, onSelect, onLost);
    await vi.advanceTimersByTimeAsync(1_000);
    expect(statusMenuShows(hosts[2])).toHaveLength(1);
    service.hideStatusMenu();
    expect(hosts[2]?.hostFrames().at(-1)?.kind).toBe("status-menu.hide");
    service.dispose();
    expect(onLost).toHaveBeenCalledOnce();
  });

  it("gives the menu-bar menu up when the helper rejects the replayed shortcut", () => {
    const hosts: FakeHost[] = [];
    const service = createService(hosts);
    const onLost = vi.fn();
    service.showStatusMenu(
      {
        iconPath: "/resources/CommaTemplate.png",
        rows: [],
        toolTip: "Comma",
        width: 300,
      },
      vi.fn(),
      onLost
    );
    service.start();
    const replay = hosts[0]
      ?.hostFrames()
      .find((frame) => frame.kind === "side-chat.shortcut");
    hosts[0]?.emitClientFrame({
      error: "The global shortcut is unavailable.",
      kind: "command.result",
      ok: false,
      protocolVersion: chatProtocolVersion,
      requestId: replay!.requestId,
    });
    expect(onLost).toHaveBeenCalledOnce();
    service.dispose();
  });

  it("keeps Side Chat shut while turned off, also in a restarted helper", async () => {
    vi.useFakeTimers();
    const hosts: FakeHost[] = [];
    const onEnabledChanged = vi.fn();
    const service = createService(hosts, { onEnabledChanged });
    service.start();
    hosts[0]?.acknowledgeLastShortcut();

    service.setEnabled(false);
    expect(onEnabledChanged).toHaveBeenLastCalledWith(false);
    expect(hosts[0]?.hostFrames().at(-1)).toMatchObject({
      enabled: false,
      kind: "side-chat.enabled",
    });
    const sentWhileOff = kinds(hosts[0]).length;
    service.open();
    service.toggle();
    service.setInteractiveProgress({ progress: 0.5 });
    service.finishInteractiveProgress({ shouldOpen: true });
    // Only closing frames reach the helper.
    expect(
      hosts[0]
        ?.hostFrames()
        .slice(sentWhileOff)
        .filter(
          (frame) =>
            frame.kind !== "side-chat.close" &&
            !(frame.kind === "side-chat.interactive-complete" && !frame.shouldOpen)
        )
    ).toEqual([]);

    // A restarted helper hears it is off before it registers the chord.
    hosts[0]?.emit("exit", 1, null);
    await vi.advanceTimersByTimeAsync(1_000);
    const restarted = kinds(hosts[1]);
    expect(restarted.indexOf("side-chat.enabled")).toBeGreaterThanOrEqual(0);
    expect(restarted.indexOf("side-chat.enabled")).toBeLessThan(
      restarted.indexOf("side-chat.shortcut")
    );

    service.setEnabled(true);
    expect(hosts[1]?.hostFrames().at(-1)).toMatchObject({
      enabled: true,
      kind: "side-chat.enabled",
    });
    service.open();
    expect(kinds(hosts[1]).at(-1)).toBe("side-chat.open");
    service.dispose();
  });

  it("turned off before start launches no helper and replays the saved binding", () => {
    const hosts: FakeHost[] = [];
    const service = createService(hosts);

    // Main applies the stored preference before it starts the helper.
    service.setEnabled(false);
    expect(hosts).toHaveLength(0);

    service.start(null);
    expect(hosts).toHaveLength(1);
    const frames = hosts[0]?.hostFrames() ?? [];
    expect(frames.filter((frame) => frame.kind === "side-chat.shortcut")).toEqual([
      expect.not.objectContaining({ keyCode: expect.anything() }),
    ]);
    expect(kinds(hosts[0]).indexOf("side-chat.enabled")).toBeLessThan(
      kinds(hosts[0]).indexOf("side-chat.shortcut")
    );
    service.dispose();
  });

  it("starts with a saved cleared binding instead of registering the default", () => {
    const hosts: FakeHost[] = [];
    const service = createService(hosts);
    service.start(null);
    expect(
      hosts[0]?.hostFrames().find((frame) => frame.kind === "side-chat.shortcut")
    ).toMatchObject({ kind: "side-chat.shortcut", modifiers: 0 });
    expect(
      hosts[0]?.hostFrames().find((frame) => frame.kind === "side-chat.shortcut")
    ).not.toHaveProperty("keyCode");
    service.dispose();
  });

  it("updates the native global shortcut and reapplies it after helper restart", async () => {
    vi.useFakeTimers();
    const hosts: FakeHost[] = [];
    const service = createService(hosts);

    service.start();
    hosts[0]?.acknowledgeLastShortcut();
    const update = service.updateShortcut({
      key: "k",
      modifiers: {
        alt: false,
        control: true,
        meta: false,
        shift: true,
      },
    });
    expect(hosts[0]?.hostFrames().at(-1)).toMatchObject({
      keyCode: 40,
      kind: "side-chat.shortcut",
      modifiers: 4_608,
    });
    const shortcutFrame = hosts[0]?.hostFrames().at(-1);
    if (!shortcutFrame || shortcutFrame.kind !== "side-chat.shortcut") {
      throw new Error("The shortcut update frame was not emitted.");
    }
    hosts[0]?.emitCommandResult(shortcutFrame.requestId);
    await expect(update).resolves.toEqual({
      key: "k",
      modifiers: {
        alt: false,
        control: true,
        meta: false,
        shift: true,
      },
    });

    hosts[0]?.exit(1);
    await vi.advanceTimersByTimeAsync(1_000);

    expect(hosts[1]?.hostFrames()[1]).toMatchObject({
      keyCode: 40,
      kind: "side-chat.shortcut",
      modifiers: 4_608,
    });
    service.dispose();
  });

  it("propagates an asynchronous Settings window failure", async () => {
    const service = createService([], {
      onOpenSettings: async () => {
        throw new Error("Settings window failed");
      },
    });

    await expect(service.openSettings()).rejects.toThrow("Settings window failed");
  });

  it("terminates and retries a restarted helper that rejects shortcut replay", async () => {
    vi.useFakeTimers();
    const hosts: FakeHost[] = [];
    const service = createService(hosts);

    service.start();
    hosts[0]?.acknowledgeLastShortcut();
    const update = service.updateShortcut({
      key: "k",
      modifiers: {
        alt: false,
        control: true,
        meta: false,
        shift: true,
      },
    });
    const updateFrame = hosts[0]?.hostFrames().at(-1);
    if (!updateFrame || updateFrame.kind !== "side-chat.shortcut") {
      throw new Error("The shortcut update frame was not emitted.");
    }
    hosts[0]?.emitCommandResult(updateFrame.requestId);
    await expect(update).resolves.toMatchObject({ key: "k" });

    hosts[0]?.exit(1);
    await vi.advanceTimersByTimeAsync(1_000);

    const rejectedReplay = hosts[1]?.hostFrames()[1];
    if (!rejectedReplay || rejectedReplay.kind !== "side-chat.shortcut") {
      throw new Error("The restarted helper did not receive shortcut replay.");
    }
    expect(rejectedReplay).toMatchObject({
      keyCode: 40,
      modifiers: 4_608,
    });
    hosts[1]?.emitClientFrame({
      error: "The replayed global shortcut is unavailable.",
      kind: "command.result",
      ok: false,
      protocolVersion: chatProtocolVersion,
      requestId: rejectedReplay.requestId,
    });

    expect(hosts[1]?.kill).toHaveBeenCalledOnce();
    await vi.advanceTimersByTimeAsync(1_000);

    const reconciledReplay = hosts[2]?.hostFrames()[1];
    expect(reconciledReplay).toMatchObject({
      keyCode: 40,
      kind: "side-chat.shortcut",
      modifiers: 4_608,
    });
    if (!reconciledReplay || reconciledReplay.kind !== "side-chat.shortcut") {
      throw new Error("The replacement helper did not receive shortcut replay.");
    }
    hosts[2]?.emitCommandResult(reconciledReplay.requestId);
    await vi.advanceTimersByTimeAsync(5_000);
    expect(hosts[2]?.kill).not.toHaveBeenCalled();

    service.dispose();
  });

  it("keeps a queued update behind replay when an unrelated result arrives", async () => {
    const hosts: FakeHost[] = [];
    const service = createService(hosts);

    service.start();
    const replay = hosts[0]?.hostFrames()[1];
    if (!replay || replay.kind !== "side-chat.shortcut") {
      throw new Error("The helper did not receive initial shortcut replay.");
    }
    const queuedUpdate = service.updateShortcut({
      key: "k",
      modifiers: {
        alt: false,
        control: true,
        meta: false,
        shift: false,
      },
    });

    hosts[0]?.emitCommandResult("stale-shortcut-registration");
    expect(
      hosts[0]?.hostFrames().filter((frame) => frame.kind === "side-chat.shortcut")
    ).toEqual([replay]);

    hosts[0]?.emitCommandResult(replay.requestId);
    const updateFrame = hosts[0]?.hostFrames().at(-1);
    if (!updateFrame || updateFrame.kind !== "side-chat.shortcut") {
      throw new Error("The queued shortcut update was not emitted.");
    }
    hosts[0]?.emitCommandResult(updateFrame.requestId);
    await expect(queuedUpdate).resolves.toMatchObject({ key: "k" });

    service.dispose();
  });

  it("returns Main's committed shortcut without overlapping restart replay", async () => {
    vi.useFakeTimers();
    const hosts: FakeHost[] = [];
    const service = createService(hosts);
    const committedShortcut = {
      key: "k" as const,
      modifiers: {
        alt: false,
        control: true,
        meta: false,
        shift: false,
      },
    };

    service.start();
    hosts[0]?.acknowledgeLastShortcut();
    const update = service.updateShortcut(committedShortcut);
    hosts[0]?.acknowledgeLastShortcut();
    await expect(update).resolves.toEqual(committedShortcut);

    hosts[0]?.exit(1);
    await vi.advanceTimersByTimeAsync(1_000);
    const replay = hosts[1]?.hostFrames()[1];
    if (!replay || replay.kind !== "side-chat.shortcut") {
      throw new Error("The replacement helper did not receive committed replay.");
    }

    let synchronized: SideChatShortcut | null | undefined;
    const synchronization = service.updateShortcut(committedShortcut).then((value) => {
      synchronized = value;
    });
    await vi.advanceTimersByTimeAsync(0);
    expect(synchronized).toEqual(committedShortcut);
    expect(
      hosts[1]?.hostFrames().filter((frame) => frame.kind === "side-chat.shortcut")
    ).toEqual([replay]);

    hosts[1]?.emitClientFrame({
      error: "The replayed global shortcut is unavailable.",
      kind: "command.result",
      ok: false,
      protocolVersion: chatProtocolVersion,
      requestId: replay.requestId,
    });
    expect(hosts[1]?.kill).toHaveBeenCalledOnce();
    await synchronization;

    await vi.advanceTimersByTimeAsync(1_000);
    expect(hosts[2]?.hostFrames()[1]).toMatchObject({
      keyCode: 40,
      kind: "side-chat.shortcut",
      modifiers: 4_096,
    });

    service.dispose();
  });

  it("orders a request for the committed value behind an active user update", async () => {
    vi.useFakeTimers();
    const hosts: FakeHost[] = [];
    const service = createService(hosts);

    service.start();
    hosts[0]?.acknowledgeLastShortcut();
    const firstUpdate = service.updateShortcut({
      key: "k",
      modifiers: {
        alt: false,
        control: true,
        meta: false,
        shift: false,
      },
    });
    const firstFrame = hosts[0]?.hostFrames().at(-1);
    if (!firstFrame || firstFrame.kind !== "side-chat.shortcut") {
      throw new Error("The first shortcut update frame was not emitted.");
    }

    let resetResult: SideChatShortcut | null | undefined;
    const reset = service.updateShortcut(defaultSideChatShortcut).then((value) => {
      resetResult = value;
    });
    await vi.advanceTimersByTimeAsync(0);
    expect(resetResult).toBeUndefined();
    expect(
      hosts[0]?.hostFrames().filter((frame) => frame.kind === "side-chat.shortcut")
    ).toHaveLength(2);

    hosts[0]?.emitCommandResult(firstFrame.requestId);
    await expect(firstUpdate).resolves.toMatchObject({ key: "k" });
    const resetFrame = hosts[0]?.hostFrames().at(-1);
    if (!resetFrame || resetFrame.kind !== "side-chat.shortcut") {
      throw new Error("The queued reset shortcut frame was not emitted.");
    }
    expect(resetFrame).toMatchObject({ keyCode: 6, modifiers: 4_096 });
    hosts[0]?.emitCommandResult(resetFrame.requestId);
    await reset;
    expect(resetResult).toEqual(defaultSideChatShortcut);

    hosts[0]?.exit(1);
    await vi.advanceTimersByTimeAsync(1_000);
    expect(hosts[1]?.hostFrames()[1]).toMatchObject({
      keyCode: 6,
      kind: "side-chat.shortcut",
      modifiers: 4_096,
    });

    service.dispose();
  });

  it("lets the committed value replace a queued update behind restart replay", async () => {
    vi.useFakeTimers();
    const hosts: FakeHost[] = [];
    const service = createService(hosts);
    const committedShortcut = {
      key: "k" as const,
      modifiers: {
        alt: false,
        control: true,
        meta: false,
        shift: false,
      },
    };

    service.start();
    hosts[0]?.acknowledgeLastShortcut();
    const committedUpdate = service.updateShortcut(committedShortcut);
    hosts[0]?.acknowledgeLastShortcut();
    await expect(committedUpdate).resolves.toEqual(committedShortcut);

    hosts[0]?.exit(1);
    await vi.advanceTimersByTimeAsync(1_000);
    const replay = hosts[1]?.hostFrames()[1];
    if (!replay || replay.kind !== "side-chat.shortcut") {
      throw new Error("The replacement helper did not receive committed replay.");
    }

    let supersededError: Error | undefined;
    void service
      .updateShortcut({
        key: "l",
        modifiers: {
          alt: false,
          control: true,
          meta: false,
          shift: false,
        },
      })
      .catch((error: Error) => {
        supersededError = error;
      });
    let resyncResult: SideChatShortcut | null | undefined;
    const resync = service.updateShortcut(committedShortcut).then((value) => {
      resyncResult = value;
    });
    await vi.advanceTimersByTimeAsync(0);

    expect(supersededError?.message).toBe(
      "The Side Chat shortcut update was superseded."
    );
    expect(resyncResult).toBeUndefined();
    expect(
      hosts[1]?.hostFrames().filter((frame) => frame.kind === "side-chat.shortcut")
    ).toEqual([replay]);

    hosts[1]?.emitClientFrame({
      error: "The replayed global shortcut is unavailable.",
      kind: "command.result",
      ok: false,
      protocolVersion: chatProtocolVersion,
      requestId: replay.requestId,
    });
    const recoveryFrame = hosts[1]?.hostFrames().at(-1);
    if (!recoveryFrame || recoveryFrame.kind !== "side-chat.shortcut") {
      throw new Error("The committed recovery shortcut frame was not emitted.");
    }
    expect(recoveryFrame).toMatchObject({ keyCode: 40, modifiers: 4_096 });
    hosts[1]?.emitCommandResult(recoveryFrame.requestId);
    await resync;
    expect(resyncResult).toEqual(committedShortcut);
    expect(hosts[1]?.kill).not.toHaveBeenCalled();

    service.dispose();
  });

  it("serializes a user update behind restart replay reconciliation", async () => {
    vi.useFakeTimers();
    const hosts: FakeHost[] = [];
    const service = createService(hosts);

    service.start();
    hosts[0]?.acknowledgeLastShortcut();
    const confirmedUpdate = service.updateShortcut({
      key: "k",
      modifiers: {
        alt: false,
        control: true,
        meta: false,
        shift: false,
      },
    });
    const confirmedFrame = hosts[0]?.hostFrames().at(-1);
    if (!confirmedFrame || confirmedFrame.kind !== "side-chat.shortcut") {
      throw new Error("The confirmed shortcut update frame was not emitted.");
    }
    hosts[0]?.emitCommandResult(confirmedFrame.requestId);
    await expect(confirmedUpdate).resolves.toMatchObject({ key: "k" });

    hosts[0]?.exit(1);
    await vi.advanceTimersByTimeAsync(1_000);
    const rejectedReplay = hosts[1]?.hostFrames()[1];
    if (!rejectedReplay || rejectedReplay.kind !== "side-chat.shortcut") {
      throw new Error("The replacement helper did not receive committed replay.");
    }

    const queuedUpdate = service.updateShortcut({
      key: "l",
      modifiers: {
        alt: false,
        control: true,
        meta: false,
        shift: false,
      },
    });
    expect(
      hosts[1]?.hostFrames().filter((frame) => frame.kind === "side-chat.shortcut")
    ).toEqual([rejectedReplay]);

    hosts[1]?.emitClientFrame({
      error: "The replayed global shortcut is unavailable.",
      kind: "command.result",
      ok: false,
      protocolVersion: chatProtocolVersion,
      requestId: rejectedReplay.requestId,
    });
    expect(hosts[1]?.kill).not.toHaveBeenCalled();
    const rejectedUpdate = hosts[1]?.hostFrames().at(-1);
    if (!rejectedUpdate || rejectedUpdate.kind !== "side-chat.shortcut") {
      throw new Error("The queued recovery update was not sent after replay settled.");
    }
    expect(rejectedUpdate).toMatchObject({ keyCode: 37, modifiers: 4_096 });
    hosts[1]?.emitClientFrame({
      error: "The queued global shortcut is unavailable.",
      kind: "command.result",
      ok: false,
      protocolVersion: chatProtocolVersion,
      requestId: rejectedUpdate.requestId,
    });
    await expect(queuedUpdate).rejects.toThrow(
      "The queued global shortcut is unavailable."
    );
    expect(hosts[1]?.kill).toHaveBeenCalledOnce();

    await vi.advanceTimersByTimeAsync(1_000);
    const reconciledReplay = hosts[2]?.hostFrames()[1];
    expect(reconciledReplay).toMatchObject({
      keyCode: 40,
      kind: "side-chat.shortcut",
      modifiers: 4_096,
    });
    if (!reconciledReplay || reconciledReplay.kind !== "side-chat.shortcut") {
      throw new Error("The replacement helper did not retry committed replay.");
    }
    hosts[2]?.emitCommandResult(reconciledReplay.requestId);
    await vi.advanceTimersByTimeAsync(5_000);
    expect(hosts[2]?.kill).not.toHaveBeenCalled();

    service.dispose();
  });

  it("lets a serialized user update recover a rejected restart replay", async () => {
    vi.useFakeTimers();
    const hosts: FakeHost[] = [];
    const service = createService(hosts);

    service.start();
    hosts[0]?.acknowledgeLastShortcut();
    const confirmedUpdate = service.updateShortcut({
      key: "k",
      modifiers: {
        alt: false,
        control: true,
        meta: false,
        shift: false,
      },
    });
    const confirmedFrame = hosts[0]?.hostFrames().at(-1);
    if (!confirmedFrame || confirmedFrame.kind !== "side-chat.shortcut") {
      throw new Error("The confirmed shortcut update frame was not emitted.");
    }
    hosts[0]?.emitCommandResult(confirmedFrame.requestId);
    await expect(confirmedUpdate).resolves.toMatchObject({ key: "k" });

    hosts[0]?.exit(1);
    await vi.advanceTimersByTimeAsync(1_000);
    const rejectedReplay = hosts[1]?.hostFrames()[1];
    if (!rejectedReplay || rejectedReplay.kind !== "side-chat.shortcut") {
      throw new Error("The replacement helper did not receive committed replay.");
    }

    const recoveryUpdate = service.updateShortcut({
      key: "l",
      modifiers: {
        alt: false,
        control: true,
        meta: false,
        shift: false,
      },
    });
    expect(
      hosts[1]?.hostFrames().filter((frame) => frame.kind === "side-chat.shortcut")
    ).toEqual([rejectedReplay]);
    hosts[1]?.emitClientFrame({
      error: "The replayed global shortcut is unavailable.",
      kind: "command.result",
      ok: false,
      protocolVersion: chatProtocolVersion,
      requestId: rejectedReplay.requestId,
    });

    const recoveryFrame = hosts[1]?.hostFrames().at(-1);
    if (!recoveryFrame || recoveryFrame.kind !== "side-chat.shortcut") {
      throw new Error("The queued recovery shortcut frame was not emitted.");
    }
    expect(recoveryFrame).toMatchObject({ keyCode: 37, modifiers: 4_096 });
    hosts[1]?.emitCommandResult(recoveryFrame.requestId);
    await expect(recoveryUpdate).resolves.toMatchObject({ key: "l" });
    expect(hosts[1]?.kill).not.toHaveBeenCalled();

    hosts[1]?.exit(1);
    await vi.advanceTimersByTimeAsync(1_000);
    expect(hosts[2]?.hostFrames()[1]).toMatchObject({
      keyCode: 37,
      kind: "side-chat.shortcut",
      modifiers: 4_096,
    });

    service.dispose();
  });

  it("serializes consecutive user updates without forgetting the active request", async () => {
    vi.useFakeTimers();
    const hosts: FakeHost[] = [];
    const service = createService(hosts);

    service.start();
    hosts[0]?.acknowledgeLastShortcut();
    const firstUpdate = service.updateShortcut({
      key: "k",
      modifiers: {
        alt: false,
        control: true,
        meta: false,
        shift: false,
      },
    });
    const firstFrame = hosts[0]?.hostFrames().at(-1);
    if (!firstFrame || firstFrame.kind !== "side-chat.shortcut") {
      throw new Error("The first shortcut update frame was not emitted.");
    }

    const secondUpdate = service.updateShortcut({
      key: "l",
      modifiers: {
        alt: false,
        control: true,
        meta: false,
        shift: false,
      },
    });
    expect(
      hosts[0]?.hostFrames().filter((frame) => frame.kind === "side-chat.shortcut")
    ).toHaveLength(2);

    hosts[0]?.emitCommandResult(firstFrame.requestId);
    await expect(firstUpdate).resolves.toMatchObject({ key: "k" });
    const secondFrame = hosts[0]?.hostFrames().at(-1);
    if (!secondFrame || secondFrame.kind !== "side-chat.shortcut") {
      throw new Error("The queued shortcut update frame was not emitted.");
    }
    expect(secondFrame).toMatchObject({ keyCode: 37, modifiers: 4_096 });
    hosts[0]?.emitClientFrame({
      error: "The second global shortcut is unavailable.",
      kind: "command.result",
      ok: false,
      protocolVersion: chatProtocolVersion,
      requestId: secondFrame.requestId,
    });
    await expect(secondUpdate).rejects.toThrow(
      "The second global shortcut is unavailable."
    );
    expect(hosts[0]?.kill).not.toHaveBeenCalled();

    hosts[0]?.exit(1);
    await vi.advanceTimersByTimeAsync(1_000);
    expect(hosts[1]?.hostFrames()[1]).toMatchObject({
      keyCode: 40,
      kind: "side-chat.shortcut",
      modifiers: 4_096,
    });

    service.dispose();
  });

  it("rejects a queued update and restarts when committed replay times out", async () => {
    vi.useFakeTimers();
    const hosts: FakeHost[] = [];
    const service = createService(hosts);

    service.start();
    hosts[0]?.acknowledgeLastShortcut();
    hosts[0]?.exit(1);
    await vi.advanceTimersByTimeAsync(1_000);
    const replay = hosts[1]?.hostFrames()[1];
    if (!replay || replay.kind !== "side-chat.shortcut") {
      throw new Error("The replacement helper did not receive committed replay.");
    }

    const queuedUpdate = service.updateShortcut({
      key: "l",
      modifiers: {
        alt: false,
        control: true,
        meta: false,
        shift: false,
      },
    });
    expect(
      hosts[1]?.hostFrames().filter((frame) => frame.kind === "side-chat.shortcut")
    ).toEqual([replay]);

    const rejection = expect(queuedUpdate).rejects.toThrow(
      "Timed out while replaying the Side Chat shortcut."
    );
    await vi.advanceTimersByTimeAsync(5_000);
    await rejection;
    expect(hosts[1]?.kill).toHaveBeenCalledOnce();

    await vi.advanceTimersByTimeAsync(1_000);
    expect(hosts[2]?.hostFrames()[1]).toMatchObject({
      keyCode: 6,
      kind: "side-chat.shortcut",
      modifiers: 4_096,
    });

    service.dispose();
  });

  it("rejects an active update and replays the committed value after timeout", async () => {
    vi.useFakeTimers();
    const hosts: FakeHost[] = [];
    const service = createService(hosts);

    service.start();
    hosts[0]?.acknowledgeLastShortcut();
    const update = service.updateShortcut({
      key: "l",
      modifiers: {
        alt: false,
        control: true,
        meta: false,
        shift: false,
      },
    });

    const rejection = expect(update).rejects.toThrow(
      "Timed out while registering the Side Chat shortcut."
    );
    await vi.advanceTimersByTimeAsync(5_000);
    await rejection;
    expect(hosts[0]?.kill).toHaveBeenCalledOnce();

    await vi.advanceTimersByTimeAsync(1_000);
    expect(hosts[1]?.hostFrames()[1]).toMatchObject({
      keyCode: 6,
      kind: "side-chat.shortcut",
      modifiers: 4_096,
    });

    service.dispose();
  });

  it("rejects a queued update when its replay helper exits", async () => {
    vi.useFakeTimers();
    const hosts: FakeHost[] = [];
    const service = createService(hosts);

    service.start();
    hosts[0]?.acknowledgeLastShortcut();
    hosts[0]?.exit(1);
    await vi.advanceTimersByTimeAsync(1_000);
    const replay = hosts[1]?.hostFrames()[1];
    if (!replay || replay.kind !== "side-chat.shortcut") {
      throw new Error("The replacement helper did not receive committed replay.");
    }
    const queuedUpdate = service.updateShortcut({
      key: "l",
      modifiers: {
        alt: false,
        control: true,
        meta: false,
        shift: false,
      },
    });

    const rejection = expect(queuedUpdate).rejects.toThrow(
      "The Side Chat helper exited before registering the shortcut."
    );
    hosts[1]?.exit(1);
    await rejection;
    await vi.advanceTimersByTimeAsync(1_000);
    expect(hosts[2]?.hostFrames()[1]).toMatchObject({
      keyCode: 6,
      kind: "side-chat.shortcut",
      modifiers: 4_096,
    });

    service.dispose();
  });

  it("keeps the last acknowledged shortcut when the helper rejects an update", async () => {
    vi.useFakeTimers();
    const hosts: FakeHost[] = [];
    const service = createService(hosts);

    service.start();
    hosts[0]?.acknowledgeLastShortcut();
    const rejectedUpdate = service.updateShortcut({
      key: "k",
      modifiers: {
        alt: false,
        control: true,
        meta: false,
        shift: false,
      },
    });
    const rejectedFrame = hosts[0]?.hostFrames().at(-1);
    if (!rejectedFrame || rejectedFrame.kind !== "side-chat.shortcut") {
      throw new Error("The rejected shortcut frame was not emitted.");
    }
    expect(rejectedFrame).toMatchObject({
      keyCode: 40,
      kind: "side-chat.shortcut",
      modifiers: 4_096,
    });
    hosts[0]?.emitClientFrame({
      error: "The global shortcut is unavailable.",
      kind: "command.result",
      ok: false,
      protocolVersion: chatProtocolVersion,
      requestId: rejectedFrame.requestId,
    });

    await expect(rejectedUpdate).rejects.toThrow("The global shortcut is unavailable.");

    hosts[0]?.exit(1);
    await vi.advanceTimersByTimeAsync(1_000);
    expect(hosts[1]?.hostFrames()[1]).toMatchObject({
      keyCode: 6,
      kind: "side-chat.shortcut",
      modifiers: 4_096,
    });

    service.dispose();
  });

  it("keeps Debug settings in Main memory and applies them live to the addon and helper", () => {
    const hosts: FakeHost[] = [];
    const published: SideChatDebugSettings[] = [];
    const service = createService(hosts, {
      onDebugSettingsChanged: (settings) => published.push(settings),
    });
    const attachment = createAttachment();

    expect(service.debugSettings()).toEqual(defaultSideChatDebugSettings);
    service.attachWindow(attachment.value);
    attachment.emit("ready-to-show");
    service.start();
    attachment.backdrop.updateSettings.mockClear();

    const updated = service.updateDebugSettings({
      blurRadius: 18,
      contentOffsetX: -12,
      contentWidth: 420,
      leftFeather: 48,
      openXOffset: 12,
    });

    expect(updated).toMatchObject({
      blurRadius: 18,
      contentOffsetX: -12,
      contentWidth: 420,
      leftFeather: 48,
      openXOffset: 12,
      revision: 1,
    });
    expect(attachment.backdrop.updateSettings).toHaveBeenCalledOnce();
    expect(attachment.backdrop.updateSettings).toHaveBeenCalledWith(
      expect.objectContaining({
        blurRadius: 18,
        contentOffsetX: -12,
        contentWidth: 420,
        leftFeather: 48,
        openXOffset: 12,
      })
    );
    expect(attachment.backdrop.updateSettings.mock.calls[0]?.[0]).not.toHaveProperty(
      "revision"
    );
    expect(hosts[0]?.hostFrames().at(-1)).toMatchObject({
      debugSettings: {
        contentOffsetX: -12,
        contentWidth: 420,
        leftFeather: 48,
        openXOffset: 12,
      },
      kind: "side-chat.layout",
    });
    expect(published).toEqual([updated]);

    expect(service.updateDebugSettings({ blurRadius: 18 })).toEqual(updated);
    expect(attachment.backdrop.updateSettings).toHaveBeenCalledOnce();
    expect(published).toHaveLength(1);

    const reset = service.resetDebugSettings();
    expect(reset).toEqual({ ...defaultSideChatDebugSettings, revision: 2 });
    expect(attachment.backdrop.updateSettings).toHaveBeenCalledTimes(2);
    expect(hosts[0]?.hostFrames().at(-1)).toMatchObject({
      debugSettings: sideChatGeometrySettingsSchema.parse(defaultSideChatDebugSettings),
      kind: "side-chat.layout",
    });
    expect(published).toEqual([updated, reset]);

    service.dispose();
  });

  it("fails closed when a live addon settings apply reports native blur failure", () => {
    const hosts: FakeHost[] = [];
    const service = createService(hosts);
    const attachment = createAttachment();

    service.attachWindow(attachment.value);
    attachment.emit("ready-to-show");
    service.start();
    hosts[0]?.emitPresentation(
      presentationFrame({ offsetX: 0, phase: "open", progress: 1, revision: 1 })
    );
    attachment.resetPresentationSpies();
    attachment.backdrop.updateSettings.mockReturnValueOnce(false);

    service.updateDebugSettings({
      contentWidth: defaultSideChatDebugSettings.contentWidth + 36,
    });

    expect(attachment.window.hide.mock.calls.length).toBeGreaterThanOrEqual(1);
    expect(service.presentation()).toMatchObject({
      phase: "closed",
      progress: 0,
    });
    expect(hosts[0]?.hostFrames().at(-2)).toMatchObject({
      kind: "side-chat.close",
    });
    expect(hosts[0]?.hostFrames().at(-1)).toMatchObject({
      debugSettings: { contentWidth: defaultSideChatDebugSettings.contentWidth + 36 },
      kind: "side-chat.layout",
    });

    service.dispose();
  });

  it.each([
    ["geometry update", "updateGeometry"],
    ["reveal update", "setRevealOffset"],
    ["native health query", "isAvailable"],
  ] as const)(
    "fails closed when a presentation %s reports native blur failure",
    (_failure, method) => {
      const hosts: FakeHost[] = [];
      const service = createService(hosts);
      const attachment = createAttachment();

      service.attachWindow(attachment.value);
      attachment.emit("ready-to-show");
      service.start();
      attachment.resetPresentationSpies();
      attachment.backdrop[method].mockReturnValueOnce(false);

      hosts[0]?.emitPresentation(
        presentationFrame({ offsetX: 0, phase: "open", progress: 1, revision: 1 })
      );

      expect(attachment.backdrop[method]).toHaveBeenCalled();
      expect(attachment.window.showInactive).not.toHaveBeenCalled();
      expect(attachment.window.show).not.toHaveBeenCalled();
      expect(attachment.window.focus).not.toHaveBeenCalled();
      expectFailedClosed(service, hosts, attachment);

      service.dispose();
    }
  );

  it("fails closed when an explicit backdrop rebuild fails", () => {
    const hosts: FakeHost[] = [];
    const service = createService(hosts);
    const attachment = createAttachment();

    service.attachWindow(attachment.value);
    attachment.emit("ready-to-show");
    service.start();
    hosts[0]?.emitPresentation(
      presentationFrame({ offsetX: 0, phase: "open", progress: 1, revision: 1 })
    );
    attachment.resetPresentationSpies();
    attachment.backdrop.rebuild.mockReturnValueOnce(false);

    expect(service.rebuildBackdrop()).toBe(false);

    expect(attachment.backdrop.rebuild).toHaveBeenCalledOnce();
    expect(attachment.backdrop.isAvailable).not.toHaveBeenCalled();
    expectFailedClosed(service, hosts, attachment);

    service.dispose();
  });

  it("fails closed and detaches the native backdrop when the renderer window fails", () => {
    const hosts: FakeHost[] = [];
    const service = createService(hosts);
    const attachment = createAttachment();

    service.attachWindow(attachment.value);
    attachment.emit("ready-to-show");
    service.start();
    hosts[0]?.emitPresentation(
      presentationFrame({ offsetX: 0, phase: "open", progress: 1, revision: 1 })
    );
    attachment.resetPresentationSpies();
    attachment.backdrop.detach.mockClear();

    service.handleWindowFailure(attachment.value.browserWindow, "renderer crashed");

    expect(attachment.backdrop.detach).toHaveBeenCalledOnce();
    expectFailedClosed(service, hosts, attachment);

    service.dispose();
  });

  it("fail-closes an in-flight open before the helper publishes its first positive presentation", () => {
    const hosts: FakeHost[] = [];
    const service = createService(hosts);
    const failedWindow = createAttachment();
    const replacement = createAttachment();

    service.attachWindow(failedWindow.value);
    failedWindow.emit("ready-to-show");
    service.start();
    service.open();

    expect(service.presentation()).toMatchObject({ phase: "closed", progress: 0 });
    expect(hosts[0]?.hostFrames().at(-1)).toMatchObject({ kind: "side-chat.open" });

    service.handleWindowFailure(failedWindow.value.browserWindow, "renderer crashed");
    service.attachWindow(replacement.value);
    replacement.emit("ready-to-show");
    replacement.resetPresentationSpies();

    expect(hosts[0]?.hostFrames().at(-1)).toMatchObject({ kind: "side-chat.close" });
    hosts[0]?.emitPresentation(
      presentationFrame({
        offsetX: -80,
        phase: "opening",
        progress: 0.8,
        revision: 1,
      })
    );
    hosts[0]?.emitPresentation(
      presentationFrame({ offsetX: 0, phase: "open", progress: 1, revision: 2 })
    );

    expect(service.presentation()).toMatchObject({ phase: "closed", progress: 0 });
    expect(replacement.backdrop.attach).not.toHaveBeenCalled();
    expect(replacement.window.showInactive).not.toHaveBeenCalled();
    expect(replacement.window.show).not.toHaveBeenCalled();
    expect(replacement.window.focus).not.toHaveBeenCalled();

    hosts[0]?.acknowledgeLastClose();
    hosts[0]?.emitPresentation(
      presentationFrame({
        offsetX: -120,
        phase: "closing",
        progress: 0.6,
        revision: 3,
      })
    );
    expect(replacement.backdrop.attach).not.toHaveBeenCalled();

    hosts[0]?.emitPresentation(
      presentationFrame({ phase: "closed", progress: 0, revision: 4 })
    );
    expect(replacement.backdrop.attach).toHaveBeenCalledOnce();
    expect(replacement.window.showInactive).not.toHaveBeenCalled();
    expect(replacement.window.show).not.toHaveBeenCalled();

    service.dispose();
  });

  it("requires the exact close acknowledgement before a subsequent closed frame releases the barrier", () => {
    const hosts: FakeHost[] = [];
    const service = createService(hosts);
    const failedWindow = createAttachment();
    const replacement = createAttachment();

    service.attachWindow(failedWindow.value);
    failedWindow.emit("ready-to-show");
    service.start();
    hosts[0]?.emitPresentation(
      presentationFrame({ offsetX: 0, phase: "open", progress: 1, revision: 1 })
    );

    service.handleWindowFailure(failedWindow.value.browserWindow, "renderer crashed");
    service.attachWindow(replacement.value);
    replacement.emit("ready-to-show");

    expect(replacement.backdrop.attach).not.toHaveBeenCalled();
    expect(replacement.window.hide).toHaveBeenCalled();
    expect(replacement.window.showInactive).not.toHaveBeenCalled();
    expect(replacement.window.show).not.toHaveBeenCalled();

    replacement.resetPresentationSpies();
    hosts[0]?.emitPresentation(
      presentationFrame({
        phase: "closed",
        progress: 0,
        revision: 2,
      })
    );
    hosts[0]?.emitCommandResult("unrelated-close-result");
    hosts[0]?.emitPresentation(
      presentationFrame({
        phase: "closed",
        progress: 0,
        revision: 3,
      })
    );

    expect(service.presentation()).toMatchObject({ phase: "closed", progress: 0 });
    expect(replacement.backdrop.attach).not.toHaveBeenCalled();
    expect(replacement.window.hide).not.toHaveBeenCalled();
    expect(replacement.window.showInactive).not.toHaveBeenCalled();
    expect(replacement.window.show).not.toHaveBeenCalled();
    expect(replacement.window.focus).not.toHaveBeenCalled();

    hosts[0]?.acknowledgeLastClose();
    expect(replacement.backdrop.attach).not.toHaveBeenCalled();
    hosts[0]?.emitPresentation(
      presentationFrame({
        offsetX: -120,
        phase: "closing",
        progress: 0.7,
        revision: 4,
      })
    );
    expect(replacement.backdrop.attach).not.toHaveBeenCalled();
    hosts[0]?.emitPresentation(
      presentationFrame({ phase: "closed", progress: 0, revision: 5 })
    );

    expect(replacement.backdrop.attach).toHaveBeenCalledOnce();
    expect(replacement.window.showInactive).not.toHaveBeenCalled();
    expect(replacement.window.show).not.toHaveBeenCalled();
    expect(replacement.window.focus).not.toHaveBeenCalled();

    service.dispose();
  });

  it("drops every renderer interactive frame while a fail-close barrier is active", () => {
    const hosts: FakeHost[] = [];
    const service = createService(hosts);
    const failedWindow = createAttachment();
    const replacement = createAttachment();

    service.attachWindow(failedWindow.value);
    failedWindow.emit("ready-to-show");
    service.start();
    hosts[0]?.emitPresentation(
      presentationFrame({ offsetX: 0, phase: "open", progress: 1, revision: 1 })
    );
    service.handleWindowFailure(failedWindow.value.browserWindow, "renderer crashed");
    service.attachWindow(replacement.value);
    replacement.emit("ready-to-show");

    const hostFramesBeforeInteractiveInput = hosts[0]?.hostFrames() ?? [];
    expect(hostFramesBeforeInteractiveInput.at(-1)).toMatchObject({
      kind: "side-chat.close",
    });

    service.setInteractiveProgress({ progress: 0 });
    service.setInteractiveProgress({ progress: 0.75 });
    expect(hosts[0]?.hostFrames()).toEqual(hostFramesBeforeInteractiveInput);
    expect(service.presentation()).toMatchObject({ phase: "closed", progress: 0 });
    expect(replacement.window.showInactive).not.toHaveBeenCalled();
    expect(replacement.window.show).not.toHaveBeenCalled();

    service.finishInteractiveProgress({ shouldOpen: false });
    expect(hosts[0]?.hostFrames()).toEqual(hostFramesBeforeInteractiveInput);
    hosts[0]?.acknowledgeLastClose();
    hosts[0]?.emitPresentation(
      presentationFrame({ phase: "closed", progress: 0, revision: 2 })
    );

    expect(hosts[0]?.hostFrames()).toEqual(hostFramesBeforeInteractiveInput);
    expect(replacement.backdrop.attach).toHaveBeenCalledOnce();
    expect(replacement.window.showInactive).not.toHaveBeenCalled();
    expect(replacement.window.show).not.toHaveBeenCalled();

    service.dispose();
  });

  it("ignores stale helper frames and keeps a queued reopen behind the active fail-close epoch", async () => {
    vi.useFakeTimers();
    const hosts: FakeHost[] = [];
    const service = createService(hosts);
    const failedWindow = createAttachment();
    const replacement = createAttachment();

    service.start();
    service.open();
    hosts[0]?.emitPresentation(
      presentationFrame({ offsetX: 0, phase: "open", progress: 1, revision: 80 })
    );
    hosts[0]?.exit(1);
    await vi.advanceTimersByTimeAsync(1_000);
    expect(hosts).toHaveLength(2);

    service.attachWindow(failedWindow.value);
    failedWindow.emit("ready-to-show");
    hosts[1]?.emitPresentation(
      presentationFrame({ offsetX: 0, phase: "open", progress: 1, revision: 1 })
    );
    service.handleWindowFailure(failedWindow.value.browserWindow, "renderer crashed");
    service.attachWindow(replacement.value);
    replacement.emit("ready-to-show");

    const openCountBeforeQueue = hosts[1]
      ?.hostFrames()
      .filter(({ kind }) => kind === "side-chat.open").length;
    service.open();
    expect(
      hosts[1]?.hostFrames().filter(({ kind }) => kind === "side-chat.open")
    ).toHaveLength(openCountBeforeQueue ?? 0);

    hosts[0]?.emitPresentation(
      presentationFrame({ phase: "closed", progress: 0, revision: 81 })
    );
    hosts[1]?.emitPresentation(
      presentationFrame({
        offsetX: -120,
        phase: "closing",
        progress: 0.5,
        revision: 2,
      })
    );

    expect(replacement.backdrop.attach).not.toHaveBeenCalled();
    expect(replacement.window.showInactive).not.toHaveBeenCalled();
    expect(replacement.window.show).not.toHaveBeenCalled();
    expect(
      hosts[1]?.hostFrames().filter(({ kind }) => kind === "side-chat.open")
    ).toHaveLength(openCountBeforeQueue ?? 0);

    hosts[1]?.acknowledgeLastClose();
    hosts[1]?.emitPresentation(
      presentationFrame({ phase: "closing", progress: 0.4, revision: 3 })
    );
    hosts[1]?.emitPresentation(
      presentationFrame({ phase: "interactive", progress: 0.7, revision: 4 })
    );
    hosts[1]?.emitPresentation(
      presentationFrame({ offsetX: 0, phase: "open", progress: 1, revision: 5 })
    );

    expect(replacement.backdrop.attach).not.toHaveBeenCalled();
    expect(replacement.window.showInactive).not.toHaveBeenCalled();
    expect(replacement.window.show).not.toHaveBeenCalled();
    expect(
      hosts[1]?.hostFrames().filter(({ kind }) => kind === "side-chat.open")
    ).toHaveLength(openCountBeforeQueue ?? 0);

    hosts[1]?.emitPresentation(
      presentationFrame({ phase: "closed", progress: 0, revision: 6 })
    );

    expect(replacement.backdrop.attach).toHaveBeenCalledOnce();
    expect(
      hosts[1]?.hostFrames().filter(({ kind }) => kind === "side-chat.open")
    ).toHaveLength((openCountBeforeQueue ?? 0) + 1);
    expect(replacement.window.showInactive).not.toHaveBeenCalled();
    expect(replacement.window.show).not.toHaveBeenCalled();

    service.dispose();
  });

  it("releases a queued reopen when the matching helper generation is lost", async () => {
    vi.useFakeTimers();
    const hosts: FakeHost[] = [];
    const service = createService(hosts);
    const failedWindow = createAttachment();
    const replacement = createAttachment();

    service.attachWindow(failedWindow.value);
    failedWindow.emit("ready-to-show");
    service.start();
    hosts[0]?.emitPresentation(
      presentationFrame({ offsetX: 0, phase: "open", progress: 1, revision: 1 })
    );
    service.handleWindowFailure(failedWindow.value.browserWindow, "renderer crashed");
    service.attachWindow(replacement.value);
    replacement.emit("ready-to-show");
    service.open();

    expect(replacement.backdrop.attach).not.toHaveBeenCalled();
    hosts[0]?.exit(1);

    expect(replacement.backdrop.attach).toHaveBeenCalledOnce();
    expect(replacement.window.showInactive).not.toHaveBeenCalled();
    expect(replacement.window.show).not.toHaveBeenCalled();

    await vi.advanceTimersByTimeAsync(1_000);
    expect(hosts).toHaveLength(2);
    expect(hosts[1]?.hostFrames().map(({ kind }) => kind)).toEqual([
      "side-chat.layout",
      "side-chat.shortcut",
      "side-chat.open",
    ]);

    service.dispose();
  });

  it("restarts the matching helper when it rejects the fail-close command", async () => {
    vi.useFakeTimers();
    const hosts: FakeHost[] = [];
    const service = createService(hosts);
    const failedWindow = createAttachment();
    const replacement = createAttachment();

    service.attachWindow(failedWindow.value);
    failedWindow.emit("ready-to-show");
    service.start();
    hosts[0]?.emitPresentation(
      presentationFrame({ offsetX: 0, phase: "open", progress: 1, revision: 1 })
    );
    service.handleWindowFailure(failedWindow.value.browserWindow, "renderer crashed");
    service.attachWindow(replacement.value);
    replacement.emit("ready-to-show");
    service.open();

    hosts[0]?.acknowledgeLastClose(false);

    expect(hosts[0]?.kill).toHaveBeenCalledOnce();
    expect(replacement.backdrop.attach).toHaveBeenCalledOnce();
    expect(replacement.window.showInactive).not.toHaveBeenCalled();
    expect(replacement.window.show).not.toHaveBeenCalled();

    await vi.advanceTimersByTimeAsync(1_000);
    expect(hosts).toHaveLength(2);
    expect(hosts[1]?.hostFrames().map(({ kind }) => kind)).toEqual([
      "side-chat.layout",
      "side-chat.shortcut",
      "side-chat.open",
    ]);

    service.dispose();
  });

  it("keeps Electron bounds, the same-window backdrop, and renderer state in lockstep", () => {
    const hosts: FakeHost[] = [];
    const published: SideChatPresentation[] = [];
    const service = createService(hosts, {
      onPresentationChanged: (presentation) => published.push(presentation),
    });
    const attachment = createAttachment();

    service.attachWindow(attachment.value);
    expect(attachment.backdrop.attach).not.toHaveBeenCalled();

    attachment.emit("ready-to-show");
    expect(attachment.backdrop.attach).toHaveBeenCalledWith(
      Buffer.from("native-window")
    );
    attachment.resetPresentationSpies();

    service.start();
    hosts[0]?.emitPresentation(
      presentationFrame({
        offsetX: -280,
        phase: "opening",
        progress: 0.45,
        revision: 8,
      })
    );

    expect(service.presentation()).toMatchObject({
      offsetX: -280,
      phase: "opening",
      progress: 0.45,
      revision: 1,
    });
    expect(published).toHaveLength(1);
    expect(attachment.window.setBounds).toHaveBeenCalledWith(
      { height: 412, width: 523, x: 20, y: 40 },
      false
    );
    expect(attachment.backdrop.updateGeometry).toHaveBeenCalledWith({
      contentHeight: 286,
      contentWidth: 364,
      contentX: 5,
      contentY: -9,
      visualHeight: 286,
      visualWidth: 364,
      windowHeight: 412,
      windowWidth: 523,
    } satisfies SideChatBackdropGeometry);
    expect(attachment.backdrop.rebuild).not.toHaveBeenCalled();
    expect(attachment.backdrop.setRevealOffset).toHaveBeenCalledWith(-280);
    expect(attachment.window.showInactive).toHaveBeenCalledOnce();
    expect(attachment.window.show).not.toHaveBeenCalled();

    hosts[0]?.emitPresentation(
      presentationFrame({ offsetX: 0, phase: "open", progress: 1, revision: 9 })
    );
    expect(service.presentation().revision).toBe(2);
    expect(attachment.window.show).toHaveBeenCalledOnce();
    expect(attachment.window.focus).toHaveBeenCalledOnce();
    expect(attachment.window.setBounds).toHaveBeenCalledTimes(1);

    hosts[0]?.emitPresentation(
      presentationFrame({ offsetX: -400, phase: "closing", progress: 0.2, revision: 9 })
    );
    hosts[0]?.emitRawClientFrame({
      ...presentationFrame({ revision: 10 }),
      progress: 2,
    });
    expect(service.presentation()).toMatchObject({ phase: "open", revision: 2 });
    expect(published).toHaveLength(2);

    hosts[0]?.emitPresentation(
      presentationFrame({ offsetX: -539, phase: "closed", progress: 0, revision: 10 })
    );
    expect(service.presentation()).toMatchObject({ phase: "closed", revision: 3 });
    expect(attachment.window.hide).toHaveBeenCalledOnce();

    attachment.emit("closed");
    expect(attachment.backdrop.detach).toHaveBeenCalledOnce();
    service.dispose();
  });

  it("keeps an automated open transition visible without native activation", () => {
    const hosts: FakeHost[] = [];
    const service = createService(hosts, { activateOpenWindow: false });
    const attachment = createAttachment();

    service.attachWindow(attachment.value);
    attachment.emit("ready-to-show");
    service.start();
    hosts[0]?.emitPresentation(
      presentationFrame({ offsetX: 0, phase: "open", progress: 1, revision: 1 })
    );

    expect(attachment.window.showInactive).toHaveBeenCalled();
    expect(attachment.window.show).not.toHaveBeenCalled();
    expect(attachment.window.focus).not.toHaveBeenCalled();
  });

  it("replays identical bounds and backdrop geometry to a replacement window", () => {
    const hosts: FakeHost[] = [];
    const service = createService(hosts);
    const first = createAttachment();
    const replacement = createAttachment();

    service.attachWindow(first.value);
    first.emit("ready-to-show");
    service.start();
    hosts[0]?.emitPresentation(
      presentationFrame({ offsetX: 0, phase: "open", progress: 1, revision: 1 })
    );
    expect(first.window.setBounds).toHaveBeenCalledWith(
      { height: 412, width: 523, x: 20, y: 40 },
      false
    );
    expect(first.backdrop.updateGeometry).toHaveBeenCalled();

    service.attachWindow(replacement.value);
    replacement.emit("ready-to-show");

    expect(first.backdrop.detach).toHaveBeenCalledOnce();
    expect(replacement.window.setBounds).toHaveBeenCalledWith(
      { height: 412, width: 523, x: 20, y: 40 },
      false
    );
    expect(replacement.backdrop.updateGeometry).toHaveBeenCalledWith({
      contentHeight: 286,
      contentWidth: 364,
      contentX: 5,
      contentY: -9,
      visualHeight: 286,
      visualWidth: 364,
      windowHeight: 412,
      windowWidth: 523,
    } satisfies SideChatBackdropGeometry);

    service.dispose();
  });

  it("fails closed instead of showing a Side Chat window without the native blur floor", () => {
    const hosts: FakeHost[] = [];
    const service = createService(hosts);
    const attachment = createAttachment();
    attachment.backdrop.attach.mockReturnValue(false);

    service.attachWindow(attachment.value);
    attachment.emit("ready-to-show");
    attachment.resetPresentationSpies();
    service.start();

    hosts[0]?.emitPresentation(
      presentationFrame({ offsetX: 0, phase: "open", progress: 1, revision: 1 })
    );

    expect(attachment.window.hide.mock.calls.length).toBeGreaterThanOrEqual(1);
    expect(attachment.window.showInactive).not.toHaveBeenCalled();
    expect(attachment.window.show).not.toHaveBeenCalled();
    expect(attachment.window.focus).not.toHaveBeenCalled();
    expect(attachment.backdrop.updateGeometry).not.toHaveBeenCalled();
    expect(attachment.backdrop.setRevealOffset).not.toHaveBeenCalled();
    expect(hosts[0]?.hostFrames().at(-1)?.kind).toBe("side-chat.close");
    expect(service.presentation()).toMatchObject({
      phase: "closed",
      progress: 0,
    });

    service.dispose();
  });

  it("updates the backdrop inside a fixed window reserve without a helper round trip", () => {
    const hosts: FakeHost[] = [];
    const service = createService(hosts);
    const attachment = createAttachment();
    service.attachWindow(attachment.value);
    attachment.emit("ready-to-show");
    service.start();
    hosts[0]?.acknowledgeLastShortcut();
    hosts[0]?.emitPresentation(
      presentationFrame({ offsetX: 0, phase: "open", progress: 1, revision: 1 })
    );
    const reservedHeight = service.presentation().contentFrame.height;
    for (const visualHeight of [180, 240, 180]) {
      service.setContentSize({ height: reservedHeight, visualHeight, width: 364 });
      expect(attachment.backdrop.updateGeometry).toHaveBeenLastCalledWith(
        expect.objectContaining({ contentHeight: reservedHeight, visualHeight })
      );
    }
    // A delayed helper presentation cannot restore the larger mask.
    hosts[0]?.emitPresentation(
      presentationFrame({ offsetX: 0, phase: "open", progress: 1, revision: 2 })
    );
    expect(attachment.backdrop.updateGeometry).toHaveBeenLastCalledWith(
      expect.objectContaining({ visualHeight: 180 })
    );
    service.dispose();
  });

  it("bounds asynchronous native health polling to the visible window and rebuilds on reopen", async () => {
    vi.useFakeTimers();
    const hosts: FakeHost[] = [];
    const service = createService(hosts);
    const attachment = createAttachment();

    service.attachWindow(attachment.value);
    attachment.emit("ready-to-show");
    service.start();
    hosts[0]?.acknowledgeLastShortcut();
    hosts[0]?.emitPresentation(
      presentationFrame({ offsetX: 0, phase: "open", progress: 1, revision: 1 })
    );
    attachment.resetPresentationSpies();
    attachment.backdrop.isAvailable.mockReturnValue(false);

    await vi.advanceTimersByTimeAsync(100);

    expect(attachment.window.hide).toHaveBeenCalled();
    expect(service.presentation()).toMatchObject({ phase: "closed", progress: 0 });
    expect(hosts[0]?.hostFrames().at(-1)).toMatchObject({ kind: "side-chat.close" });
    expect(vi.getTimerCount()).toBe(0);

    attachment.backdrop.isAvailable.mockReturnValue(true);
    service.open();
    expect(attachment.backdrop.rebuild).not.toHaveBeenCalled();
    expect(hosts[0]?.hostFrames().at(-1)).toMatchObject({ kind: "side-chat.close" });
    hosts[0]?.emitPresentation(
      presentationFrame({
        offsetX: -120,
        phase: "closing",
        progress: 0.3,
        revision: 2,
      })
    );
    expect(service.presentation()).toMatchObject({ phase: "closed", progress: 0 });
    expect(attachment.backdrop.rebuild).not.toHaveBeenCalled();
    hosts[0]?.acknowledgeLastClose();
    hosts[0]?.emitPresentation(presentationFrame({ phase: "closed", revision: 3 }));
    expect(attachment.backdrop.rebuild).toHaveBeenCalledOnce();
    expect(hosts[0]?.hostFrames().at(-1)).toMatchObject({ kind: "side-chat.open" });
    hosts[0]?.emitPresentation(
      presentationFrame({ offsetX: 0, phase: "open", progress: 1, revision: 4 })
    );
    expect(service.presentation()).toMatchObject({ phase: "open", progress: 1 });

    const availabilityCallsAfterRecovery =
      attachment.backdrop.isAvailable.mock.calls.length;
    service.dispose();
    await vi.advanceTimersByTimeAsync(500);
    expect(attachment.backdrop.isAvailable).toHaveBeenCalledTimes(
      availabilityCallsAfterRecovery
    );
  });

  it("rejects stale hosts, resets the helper revision gate on restart, and keeps renderer revisions monotonic", async () => {
    vi.useFakeTimers();
    const hosts: FakeHost[] = [];
    const published: SideChatPresentation[] = [];
    const service = createService(hosts, {
      onPresentationChanged: (presentation) => published.push(presentation),
    });

    service.start();
    service.open();
    hosts[0]?.emitPresentation(
      presentationFrame({ offsetX: 0, phase: "open", progress: 1, revision: 80 })
    );
    hosts[0]?.exit(1);

    expect(published.map(({ phase, revision }) => ({ phase, revision }))).toEqual([
      { phase: "open", revision: 1 },
      { phase: "closed", revision: 2 },
    ]);

    await vi.advanceTimersByTimeAsync(1_000);
    expect(hosts).toHaveLength(2);
    expect(hosts[1]?.hostFrames().map(({ kind }) => kind)).toEqual([
      "side-chat.layout",
      "side-chat.shortcut",
      "side-chat.open",
    ]);

    hosts[0]?.emitPresentation(
      presentationFrame({ phase: "closing", progress: 0.5, revision: 81 })
    );
    hosts[1]?.emitPresentation(
      presentationFrame({ phase: "opening", progress: 0.4, revision: 1 })
    );

    expect(published.map(({ phase, revision }) => ({ phase, revision }))).toEqual([
      { phase: "open", revision: 1 },
      { phase: "closed", revision: 2 },
      { phase: "opening", revision: 3 },
    ]);
    expect(service.presentation().revision).toBe(3);

    service.dispose();
  });

  it("falls back to deterministic interactive progress and completion when the helper is unavailable", () => {
    const published: SideChatPresentation[] = [];
    const service = new NativeSideChatService({
      onPresentationChanged: (presentation) => published.push(presentation),
      resolveExecutablePath: () => "/definitely/missing/CommaSideChatHost",
    });

    expect(service.setInteractiveProgress({ progress: 0.4 })).toEqual({
      revision: 1,
    });
    expect(service.presentation()).toMatchObject({
      phase: "interactive",
      progress: 0.4,
      revision: 1,
    });
    expect(service.finishInteractiveProgress({ shouldOpen: true })).toEqual({
      revision: 2,
    });
    expect(service.presentation()).toMatchObject({
      offsetX: 0,
      phase: "open",
      progress: 1,
      revision: 2,
    });
    expect(service.setInteractiveProgress({ progress: 0.25 })).toEqual({
      revision: 3,
    });
    expect(service.finishInteractiveProgress({ shouldOpen: false })).toEqual({
      revision: 4,
    });
    expect(service.presentation()).toMatchObject({
      phase: "closed",
      progress: 0,
      revision: 4,
    });
    expect(published.map(({ phase }) => phase)).toEqual([
      "interactive",
      "open",
      "interactive",
      "closed",
    ]);

    service.dispose();
  });
});

function kinds(host: FakeHost | undefined) {
  return host?.hostFrames().map((frame) => frame.kind) ?? [];
}

function createService(
  hosts: FakeHost[],
  options: {
    activateOpenWindow?: boolean;
    onCloseTestWindow?: () => void;
    onDebugSettingsChanged?: (settings: SideChatDebugSettings) => void;
    onEnabledChanged?: (enabled: boolean) => void;
    onOpenSettings?: () => Promise<void> | void;
    onOpenTestWindow?: (input: {
      sourceFrame: { height: number; width: number; x: number; y: number };
    }) => void;
    onPresentationChanged?: (presentation: SideChatPresentation) => void;
  } = {}
) {
  return new NativeSideChatService({
    ...options,
    resolveExecutablePath: () => process.execPath,
    spawnHost: (_path, environment) => {
      const host = new FakeHost(environment);
      hosts.push(host);
      return host as unknown as ChildProcessWithoutNullStreams;
    },
  });
}

function expectFailedClosed(
  service: NativeSideChatService,
  hosts: FakeHost[],
  attachment: ReturnType<typeof createAttachment>
) {
  expect(attachment.window.hide.mock.calls.length).toBeGreaterThanOrEqual(1);
  expect(service.presentation()).toMatchObject({
    phase: "closed",
    progress: 0,
  });
  expect(hosts[0]?.hostFrames()).toContainEqual(
    expect.objectContaining({ kind: "side-chat.close" })
  );
}

function presentationFrame({
  offsetX = -539,
  phase = "closed",
  progress = 0,
  revision = 1,
}: {
  offsetX?: number;
  phase?: "closed" | "closing" | "interactive" | "open" | "opening";
  progress?: number;
  revision?: number;
} = {}) {
  return sideChatClientFrameSchema.parse({
    availableContentHeight: 600,
    contentFrame: { height: 286, width: 364, x: 9, y: 3 },
    displayId: 1,
    kind: "side-chat.presentation",
    offsetX,
    phase,
    progress,
    protocolVersion: chatProtocolVersion,
    revision,
    screenFrame: { height: 900, width: 1440, x: 0, y: 0 },
    windowFrame: { height: 412, width: 523, x: 4, y: 12 },
  });
}

function createAttachment() {
  const events = new Map<string, () => void>();
  const backdrop = {
    attach: vi.fn(() => true),
    detach: vi.fn(),
    isAvailable: vi.fn(() => true),
    rebuild: vi.fn(() => true),
    setRevealOffset: vi.fn(() => true),
    updateGeometry: vi.fn(() => true),
    updateSettings: vi.fn((_settings: SideChatDebugSettingsValues) => true),
  };
  const window = {
    focus: vi.fn(),
    getNativeWindowHandle: vi.fn(() => Buffer.from("native-window")),
    hide: vi.fn(),
    isDestroyed: vi.fn(() => false),
    on: vi.fn((event: "closed" | "ready-to-show", listener: () => void) => {
      events.set(event, listener);
    }),
    setBounds: vi.fn(),
    show: vi.fn(),
    showInactive: vi.fn(),
  };
  return {
    backdrop,
    emit(event: "closed" | "ready-to-show") {
      events.get(event)?.();
    },
    resetPresentationSpies() {
      backdrop.rebuild.mockClear();
      backdrop.isAvailable.mockClear();
      backdrop.setRevealOffset.mockClear();
      backdrop.updateGeometry.mockClear();
      backdrop.updateSettings.mockClear();
      window.focus.mockClear();
      window.hide.mockClear();
      window.setBounds.mockClear();
      window.show.mockClear();
      window.showInactive.mockClear();
    },
    value: {
      backdrop,
      browserWindow: window,
      toElectronBounds: (presentation: SideChatPresentation) =>
        presentation.windowFrame.width > 0
          ? { height: 412, width: 523, x: 20, y: 40 }
          : undefined,
    },
    window,
  };
}

function statusMenuShows(host: FakeHost | undefined) {
  return host?.hostFrames().filter((frame) => frame.kind === "status-menu.show");
}

class FakeHost extends EventEmitter {
  readonly environment: NodeJS.ProcessEnv;
  readonly stdin = new PassThrough();
  readonly stdout = new PassThrough();
  readonly stderr = new PassThrough();
  readonly kill = vi.fn(() => {
    this.killed = true;
    return true;
  });
  killed = false;
  #input = "";

  constructor(environment: NodeJS.ProcessEnv) {
    super();
    this.environment = environment;
    this.stdin.on("data", (chunk) => {
      this.#input += chunk.toString();
    });
  }

  hostFrames(): SideChatHostFrame[] {
    return this.#input
      .trim()
      .split("\n")
      .filter(Boolean)
      .map((line) => sideChatHostFrameSchema.parse(JSON.parse(line) as unknown));
  }

  emitClientFrame(frame: SideChatClientFrame) {
    this.emitRawClientFrame(sideChatClientFrameSchema.parse(frame));
  }

  emitPresentation(frame: SideChatClientFrame) {
    this.emitClientFrame(frame);
  }

  emitCommandResult(requestId: string, ok = true) {
    this.emitClientFrame({
      kind: "command.result",
      ok,
      protocolVersion: chatProtocolVersion,
      requestId,
    });
  }

  acknowledgeLastClose(ok = true) {
    const close = this.hostFrames().findLast(
      (frame) => frame.kind === "side-chat.close"
    );
    if (!close || close.kind !== "side-chat.close") {
      throw new Error("No Side Chat close command is available to acknowledge.");
    }
    this.emitCommandResult(close.requestId, ok);
  }

  acknowledgeLastShortcut(ok = true) {
    const shortcut = this.hostFrames().findLast(
      (frame) => frame.kind === "side-chat.shortcut"
    );
    if (!shortcut || shortcut.kind !== "side-chat.shortcut") {
      throw new Error("No Side Chat shortcut command is available to acknowledge.");
    }
    this.emitCommandResult(shortcut.requestId, ok);
  }

  emitRawClientFrame(frame: unknown) {
    this.stdout.write(`${JSON.stringify(frame)}\n`);
  }

  exit(code: number | null) {
    this.emit("exit", code, null);
  }
}
