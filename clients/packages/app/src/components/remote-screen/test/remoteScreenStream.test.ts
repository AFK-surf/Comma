import { installUiClock } from "@comma/ui/clock";
import { createVirtualUiClock } from "@comma/ui/clock/virtual";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  holdScreenStream,
  setScreenAudioMuted,
  type HeldScreenStreamView,
} from "../remoteScreenStream";
import { createScreenAudioPlayer, screenOpusDecodes } from "../screenAudio";
import { openMeshScreenStream } from "../meshScreenStream";
import type { ScreenStreamSource } from "../ScreenStreamStage";

vi.mock("../meshScreenStream", () => ({ openMeshScreenStream: vi.fn() }));
vi.mock("../screenAudio", () => ({
  createScreenAudioPlayer: vi.fn(),
  screenOpusDecodes: vi.fn(() => Promise.resolve(false)),
}));

type Opened = Parameters<typeof openMeshScreenStream>[0];

describe("holdScreenStream", () => {
  let clock: ReturnType<typeof createVirtualUiClock>;
  let restore: () => void;
  let opened: { options: Opened; close: ReturnType<typeof vi.fn> }[];
  let source: ScreenStreamSource;

  const options = { target: "app", control: false, background: undefined } as const;

  beforeEach(() => {
    clock = createVirtualUiClock({ start: 1_000, frameMs: 16 });
    restore = installUiClock(clock);
    opened = [];
    source = {
      key: "workspace\ndevice\n",
      view: { open: () => new Promise(() => undefined), send: () => undefined },
    };
    vi.mocked(openMeshScreenStream).mockImplementation((peer) => {
      const close = vi.fn();
      opened.push({ options: peer, close });
      return { send: vi.fn(), close };
    });
  });

  afterEach(() => {
    clock.advance(10_000);
    restore();
  });

  it("gives a second holder the stream the first one has", () => {
    const first = holdScreenStream({ source, ...options }, () => undefined);
    opened[0]!.options.onState("live");
    const views: HeldScreenStreamView[] = [];
    const second = holdScreenStream({ source, ...options }, (view) => views.push(view));

    expect(opened).toHaveLength(1);
    expect(views.at(-1)?.state).toBe("live");
    first.release();
    second.release();
  });

  it("keeps the stream for a holder that takes it right after another let it go", () => {
    holdScreenStream({ source, ...options }, () => undefined).release();
    clock.advance(500);
    const next = holdScreenStream({ source, ...options }, () => undefined);
    clock.advance(5_000);

    expect(opened).toHaveLength(1);
    expect(opened[0]!.close).not.toHaveBeenCalled();
    next.release();
  });

  it("closes the stream when nobody takes it", () => {
    const held = holdScreenStream({ source, ...options }, () => undefined);
    held.release();
    clock.advance(1_000);

    expect(opened[0]!.close).toHaveBeenCalledOnce();
  });

  it("keeps a controlled stream through a holder that only watches and back", () => {
    const panel = holdScreenStream(
      { source, ...options, control: true },
      () => undefined
    );
    opened[0]!.options.onState("live");
    panel.release();
    const views: HeldScreenStreamView[] = [];
    const card = holdScreenStream({ source, ...options }, (view) => views.push(view));
    expect(views.at(-1)?.state).toBe("live");
    card.release();
    clock.advance(999);
    const again = holdScreenStream(
      { source, ...options, control: true },
      () => undefined
    );

    expect(opened).toHaveLength(1);
    expect(opened[0]!.close).not.toHaveBeenCalled();
    again.release();
  });

  it("a watcher does not take a failed controlled stream nobody holds", () => {
    holdScreenStream({ source, ...options, control: true }, () => undefined).release();
    opened[0]!.options.onState("failed");
    const watching = holdScreenStream({ source, ...options }, () => undefined);
    expect(opened).toHaveLength(2);
    expect(opened[0]!.close).toHaveBeenCalledOnce();
    watching.release();
  });

  it("opens a failed stream anew for all who hold it, on one's retry", () => {
    const seen: HeldScreenStreamView[][] = [[], []];
    const held = seen.map((views) =>
      holdScreenStream({ source, ...options }, (view) => views.push(view))
    );
    held[0]!.retry();
    expect(opened).toHaveLength(1);
    opened[0]!.options.onFailure?.("it went");
    opened[0]!.options.onState("failed");
    expect(seen[1]!.at(-1)).toMatchObject({ state: "failed", failure: "it went" });
    held[0]!.retry();
    expect(opened).toHaveLength(2);
    expect(opened[0]!.close).toHaveBeenCalledOnce();
    for (const views of seen)
      expect(views.at(-1)).toMatchObject({ state: "connecting", failure: undefined });
    for (const one of held) one.release();
  });

  it("on a station that cannot switch the open view, opens anew to drive, and a stream that drives serves who then only watches", () => {
    const view = holdScreenStream({ source, ...options }, () => undefined);
    view.control(true);
    expect(opened).toHaveLength(2);
    expect(opened[0]!.close).toHaveBeenCalledOnce();
    view.control(false);
    expect(opened).toHaveLength(2);
    view.release();
  });

  it("opens anew for a holder after the stream failed", () => {
    holdScreenStream({ source, ...options }, () => undefined).release();
    opened[0]!.options.onState("failed");
    const views: HeldScreenStreamView[] = [];
    const next = holdScreenStream({ source, ...options }, (view) => views.push(view));

    expect(opened).toHaveLength(2);
    expect(opened[0]!.close).toHaveBeenCalledOnce();
    expect(views.at(-1)?.state).toBe("connecting");
    next.release();
  });

  describe("with a way over the mesh", () => {
    let mesh: Parameters<typeof openMeshScreenStream>[0][];
    const meshSource = () => ({
      ...source,
      key: "workspace\ndevice\nmesh",
      view: { open: vi.fn(), send: vi.fn() },
    });

    beforeEach(() => {
      mesh = [];
      vi.mocked(openMeshScreenStream).mockImplementation((peer) => {
        mesh.push(peer);
        return {
          send: vi.fn(),
          close: vi.fn(),
          sound: (on: boolean) => sounds.push(on),
        };
      });
    });
    const sounds: boolean[] = [];

    it("asks a computer's sound, plays it once for all who hold it, and stops it while muted here", async () => {
      const player = { play: vi.fn(), stop: vi.fn(), close: vi.fn() };
      vi.mocked(createScreenAudioPlayer).mockReturnValue(player);
      const shared = meshSource();
      const views: HeldScreenStreamView[] = [];
      const held = [
        holdScreenStream({ source: shared, ...options }, (view) => views.push(view)),
        holdScreenStream({ source: shared, ...options }, () => undefined),
      ];
      await mesh[0]!.open(
        () => undefined,
        new AbortController().signal,
        ["h264"],
        false
      );
      expect(vi.mocked(shared.view.open).mock.calls[0]![0]).toMatchObject({
        audio: true,
      });
      // Opus where the page decodes it.
      vi.mocked(screenOpusDecodes).mockReturnValueOnce(Promise.resolve(true));
      await mesh[0]!.open(
        () => undefined,
        new AbortController().signal,
        ["h264"],
        false
      );
      expect(vi.mocked(shared.view.open).mock.calls[1]![0]).toMatchObject({
        audio: "opus",
      });
      expect(mesh[0]!.sound?.()).toBe(true);
      const packet = new Uint8Array(3840);
      mesh[0]!.onAudio!(packet);
      expect(views.at(-1)?.audio).toBe(true);
      expect(player.play).toHaveBeenCalledOnce();
      sounds.length = 0;
      setScreenAudioMuted(shared.key, true);
      expect(player.stop).toHaveBeenCalled();
      // The computer is told to send none, and the next view opens told so.
      expect(sounds).toEqual([false]);
      expect(mesh[0]!.sound?.()).toBe(false);
      mesh[0]!.onAudio!(packet);
      expect(player.play).toHaveBeenCalledOnce();
      setScreenAudioMuted(shared.key, false);
      expect(sounds).toEqual([false, true]);
      // The view went: what plays stops, and the bar's switch goes.
      mesh[0]!.onAudio!(null);
      expect(views.at(-1)?.audio).toBe(false);
      for (const h of held) h.release();
      clock.advance(1_000);
      expect(player.close).toHaveBeenCalled();
    });

    it("asks no sound of this app's own computer, and plays none that comes", async () => {
      vi.mocked(createScreenAudioPlayer).mockClear();
      const own = { ...meshSource(), self: () => true };
      const views: HeldScreenStreamView[] = [];
      const held = holdScreenStream({ source: own, ...options }, (view) =>
        views.push(view)
      );
      await mesh[0]!.open(
        () => undefined,
        new AbortController().signal,
        ["h264"],
        false
      );
      expect(vi.mocked(own.view.open).mock.calls[0]![0]).not.toHaveProperty("audio");
      mesh[0]!.onAudio!(new Uint8Array(3840));
      expect(createScreenAudioPlayer).not.toHaveBeenCalled();
      expect(views.at(-1)?.audio).toBeUndefined();
      held.release();
    });

    it("hands a copy made on the screen to one holder, and only while the stream drives", () => {
      // A station that switches Watch and Control on the open view.
      vi.mocked(openMeshScreenStream).mockImplementation((peer) => {
        mesh.push(peer);
        return { send: vi.fn(), close: vi.fn(), control: () => true };
      });
      const shared = meshSource();
      const heard: string[][] = [[], []];
      const held = heard.map((got) => {
        const h = holdScreenStream(
          { source: shared, ...options, control: true },
          () => undefined
        );
        h.onCopied((clip) => got.push(clip.type === "text" ? clip.text : "png"));
        return h;
      });
      mesh[0]!.onClipboard!({ type: "text", text: "复制的" });
      expect(heard).toEqual([["复制的"], []]);
      for (const h of held) h.control(false);
      mesh[0]!.onClipboard!({ type: "text", text: "later" });
      expect(heard).toEqual([["复制的"], []]);
      for (const h of held) h.release();
    });

    it("asks the 画质 chosen and its bounds; another 画质 opens a view of its own, 自动 asks none", async () => {
      const shared = meshSource();
      const asked = async (
        quality: "smooth" | "hd" | "original" | undefined,
        side?: number
      ) => {
        const held = holdScreenStream(
          {
            source: shared,
            ...options,
            ...(quality ? { quality } : {}),
            ...(side ? { side } : {}),
          },
          () => undefined
        );
        await mesh
          .at(-1)!
          .open(() => undefined, new AbortController().signal, ["h264"], false);
        held.release();
        return vi.mocked(shared.view.open).mock.calls.at(-1)![0];
      };
      expect(await asked("smooth")).toMatchObject({
        quality: "smooth",
        maxWidth: 1280,
        maxHeight: 720,
      });
      expect(mesh).toHaveLength(1);
      // Another 画质, while the one before still lingers: a stream of its own.
      expect(await asked("original")).toMatchObject({
        quality: "original",
        maxWidth: 7680,
        maxHeight: 4320,
      });
      expect(mesh).toHaveLength(2);
      const auto = await asked(undefined);
      expect(auto).not.toHaveProperty("quality");
      expect(auto).not.toHaveProperty("maxWidth");
      // A device's picture: 高清 within the side it shows at, 自动 at that side.
      expect(await asked("hd", 1080)).toMatchObject({
        maxWidth: 1080,
        maxHeight: 1080,
      });
      expect(await asked("smooth", 1440)).toMatchObject({
        maxWidth: 1280,
        maxHeight: 1280,
      });
      expect(await asked(undefined, 720)).toMatchObject({
        maxWidth: 720,
        maxHeight: 720,
      });
    });

    it("switches 画质 with three views open: the old view, held by none, goes before the new one opens, and its sound with it", () => {
      // The station: three views a member at once; one more is refused (503) until one closes.
      let live = 0;
      const refused: number[] = [];
      vi.mocked(openMeshScreenStream).mockImplementation((peer) => {
        mesh.push(peer);
        if (live >= 3) refused.push(mesh.length - 1);
        else live++;
        let closed = false;
        return {
          send: vi.fn(),
          close: () => {
            if (!closed && !refused.includes(mesh.indexOf(peer))) live--;
            closed = true;
          },
        };
      });
      const players = [0, 1].map(() => ({
        play: vi.fn(),
        stop: vi.fn(),
        close: vi.fn(),
      }));
      vi.mocked(createScreenAudioPlayer)
        .mockReturnValueOnce(players[0]!)
        .mockReturnValueOnce(players[1]!);
      const others = ["a", "b"].map((name) =>
        holdScreenStream(
          { source: { ...meshSource(), key: `workspace\n${name}\nmesh` }, ...options },
          () => undefined
        )
      );
      const shared = meshSource();
      const views: HeldScreenStreamView[] = [];
      let held = holdScreenStream(
        { source: shared, ...options, quality: "hd" },
        (view) => views.push(view)
      );
      const packet = new Uint8Array(3840);
      mesh[2]!.onAudio!(packet);
      expect(players[0]!.play).toHaveBeenCalledOnce();
      // The stage lets the old stream go and holds the new 画质's.
      held.release();
      held = holdScreenStream(
        { source: shared, ...options, quality: "original" },
        (view) => views.push(view)
      );
      expect(mesh).toHaveLength(4);
      expect(refused).toEqual([]);
      expect(live).toBe(3);
      // The old stream's sound stopped with it; the new one's plays.
      expect(players[0]!.close).toHaveBeenCalled();
      mesh[3]!.onAudio!(packet);
      expect(players[1]!.play).toHaveBeenCalledOnce();
      // A holder that takes the same stream back within the linger still shares it.
      held.release();
      held = holdScreenStream(
        { source: shared, ...options, quality: "original" },
        () => undefined
      );
      expect(mesh).toHaveLength(4);
      held.release();
      for (const other of others) other.release();
    });

    it("says the computer is out of reach where the mesh does not reach it, and tries again by itself", () => {
      const views: HeldScreenStreamView[] = [];
      const held = holdScreenStream({ source: meshSource(), ...options }, (view) =>
        views.push(view)
      );
      mesh[0]!.onUnavailable();
      expect(views.at(-1)).toMatchObject({ state: "failed", failure: "unreachable" });
      clock.advance(30_000);
      expect(mesh).toHaveLength(2);
      mesh[1]!.onState("live");
      expect(views.at(-1)?.state).toBe("live");
      held.release();
    });

    it("opens a failed stream anew for all who hold it, on one's retry", () => {
      const seen: HeldScreenStreamView[][] = [[], []];
      const shared = meshSource();
      const held = seen.map((views) =>
        holdScreenStream({ source: shared, ...options }, (view) => views.push(view))
      );
      held[0]!.retry();
      expect(mesh).toHaveLength(1);
      mesh[0]!.onFailure("it went");
      mesh[0]!.onState("failed");
      held[0]!.retry();
      expect(mesh).toHaveLength(2);
      for (const views of seen)
        expect(views.at(-1)).toMatchObject({ state: "connecting", failure: undefined });
      mesh[1]!.onState("live");
      for (const views of seen) expect(views.at(-1)?.state).toBe("live");
      for (const one of held) one.release();
    });

    it("switches Watch and Control on the open stream: no stream opened anew", () => {
      const control = vi.fn(() => true);
      vi.mocked(openMeshScreenStream).mockImplementation((peer) => {
        mesh.push(peer);
        return { send: vi.fn(), close: vi.fn(), control };
      });
      const shared = meshSource();
      const panel = holdScreenStream({ source: shared, ...options }, () => undefined);
      const card = holdScreenStream({ source: shared, ...options }, () => undefined);
      expect(mesh[0]!.control).toBe(false);
      panel.control(true);
      // It drives while any holder does.
      card.control(false);
      panel.control(false);
      panel.control(true);
      panel.release();
      expect(control.mock.calls).toEqual([[true], [false], [true], [false]]);
      expect(mesh).toHaveLength(1);
      card.release();
    });

    it("opens anew to drive where a switch asked while it opened was lost on a station from before", () => {
      vi.mocked(openMeshScreenStream).mockImplementation((peer) => {
        mesh.push(peer);
        return { send: vi.fn(), close: vi.fn(), control: () => true };
      });
      const held = holdScreenStream(
        { source: meshSource(), ...options },
        () => undefined
      );
      held.control(true);
      expect(mesh).toHaveLength(1);
      mesh[0]!.onSwitchLost?.();
      expect(mesh).toHaveLength(2);
      expect(mesh[1]!.control).toBe(true);
      held.release();
    });

    it("tells its holders when the computer does not let it drive", () => {
      const views: HeldScreenStreamView[] = [];
      const held = holdScreenStream(
        { source: meshSource(), ...options, control: true },
        (view) => views.push(view)
      );
      mesh[0]!.onRefused?.("this view only looks");
      expect(views.at(-1)?.refused).toBe("this view only looks");
      held.release();
    });

    it("says why it failed to whoever holds it", () => {
      const views: HeldScreenStreamView[] = [];
      const held = holdScreenStream({ source: meshSource(), ...options }, (view) =>
        views.push(view)
      );
      mesh[0]!.onFailure("its access is not Full");
      mesh[0]!.onState("failed");
      expect(views.at(-1)).toMatchObject({
        state: "failed",
        failure: "its access is not Full",
      });
      expect(opened).toHaveLength(0);
      held.release();
    });
  });
});
