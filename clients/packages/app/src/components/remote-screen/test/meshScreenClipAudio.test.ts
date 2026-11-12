import type { ScreenClip, ScreenViewEvent } from "@comma/core/contract";
import type { VirtualUiClock } from "@comma/ui/clock/virtual";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import type { ScreenViewMessage } from "../meshScreenStream";

// A view's clipboard and sound as the mesh stream hands them on (meshScreenStream.ts): the clipboard's types each view
// says as it opens (none again once it went), a copy as it comes, sound only after its format was said on the view that
// runs (stopped as that view goes), and a paste sent to the view that runs.

let clock: VirtualUiClock;
let restoreClock: () => void;
let mesh: typeof import("../meshScreenStream");

beforeEach(async () => {
  // What the page decodes and shows (the frames themselves are not this test's).
  const none = function () {} as unknown;
  Object.assign(globalThis, {
    VideoDecoder: Object.assign(function () {}, {
      isConfigSupported: (config: VideoDecoderConfig) =>
        Promise.resolve({ supported: true, config }),
    }),
    MediaStream: none,
    MediaStreamTrackGenerator: none,
  });
  vi.resetModules();
  const { installUiClock } = await import("@comma/ui/clock");
  const { createVirtualUiClock } = await import("@comma/ui/clock/virtual");
  clock = createVirtualUiClock();
  restoreClock = installUiClock(clock);
  mesh = await import("../meshScreenStream");
});

afterEach(() => restoreClock());

const settle = async () => {
  for (let turn = 0; turn < 50; turn++) await Promise.resolve();
};

it("hands on the clipboard's types, copies and sound of the view that runs, and sends a paste to it", async () => {
  const views: {
    emit: (event: ScreenViewEvent) => void;
    reject: (error: Error) => void;
  }[] = [];
  const said: { view: number; message: ScreenViewMessage }[] = [];
  const types: (readonly string[])[] = [];
  const copies: ScreenClip[] = [];
  const sound: (number | null)[] = [];
  const peer = mesh.openMeshScreenStream({
    open: (onEvent, signal) =>
      new Promise((_resolve, reject) => {
        views.push({ emit: onEvent, reject });
        signal.addEventListener("abort", () => reject(new Error("cancelled")));
      }),
    send: (view, message) => said.push({ view, message }),
    onStream: () => undefined,
    onState: () => undefined,
    onFailure: () => undefined,
    onUnavailable: () => expect.unreachable("this page decodes"),
    onClipboardTypes: (t) => types.push(t),
    onClipboard: (clip) => copies.push(clip),
    onAudio: (data) => sound.push(data === null ? null : data[0]!),
  });
  await settle();
  const view = views[0]!;
  view.emit({ type: "open", view: 7, clipboard: ["text", "png"] });
  expect(types).toEqual([["text", "png"]]);

  // Sound before its format is not played; after it, each packet is.
  view.emit({ type: "audio", ts: 1, data: new Uint8Array(3840).fill(1) });
  view.emit({ type: "audioConfig", codec: "pcm_s16le" });
  view.emit({ type: "audio", ts: 2, data: new Uint8Array(3840).fill(2) });
  expect(sound).toEqual([2]);

  view.emit({ type: "clipboard", clip: { type: "text", text: "复制的" } });
  expect(copies).toEqual([{ type: "text", text: "复制的" }]);

  peer.setClipboard!({ type: "text", text: "粘贴的" }, true);
  expect(said).toEqual([
    { view: 7, message: { clipboard: { type: "text", text: "粘贴的" }, paste: true } },
  ]);

  // The view goes (the link dropped after it showed nothing: it fails): its sound stops, its clipboard is not carried.
  view.reject(Object.assign(new Error("gone"), { code: "forbidden" }));
  await settle();
  expect(sound).toEqual([2, null]);
  expect(types.at(-1)).toEqual([]);
  peer.close();
});

it("decodes Opus packets to the PCM it plays, opens muted where the sound is off here, and turns it on and off", async () => {
  // A decoder that gives back each packet as 960 stereo frames of its first byte as samples (WebCodecs' AudioDecoder's shape).
  const decoded: number[] = [];
  class FakeAudioDecoder {
    state = "unconfigured";
    #output: (audio: unknown) => void;
    constructor(init: { output: (audio: unknown) => void }) {
      this.#output = init.output;
    }
    configure() {
      this.state = "configured";
    }
    decode(chunk: { data: Uint8Array }) {
      const value = chunk.data[0]!;
      decoded.push(value);
      this.#output({
        numberOfFrames: 960,
        numberOfChannels: 2,
        // Each sample `value` as PCM16, so a packet's first byte is `value`.
        copyTo: (into: Float32Array) => into.fill(value / 0x7fff),
        close: () => undefined,
      });
    }
    close() {
      this.state = "closed";
    }
  }
  Object.assign(globalThis, {
    AudioDecoder: FakeAudioDecoder,
    EncodedAudioChunk: function (this: object, init: object) {
      Object.assign(this, init);
    },
  });
  const views: { emit: (event: ScreenViewEvent) => void }[] = [];
  const said: { view: number; message: ScreenViewMessage }[] = [];
  const sound: (number | null)[] = [];
  let carries = 0;
  const peer = mesh.openMeshScreenStream({
    open: (onEvent, signal) =>
      new Promise((_resolve, reject) => {
        views.push({ emit: onEvent });
        signal.addEventListener("abort", () => reject(new Error("cancelled")));
      }),
    send: (view, message) => said.push({ view, message }),
    onStream: () => undefined,
    onState: () => undefined,
    onFailure: () => undefined,
    onUnavailable: () => expect.unreachable("this page decodes"),
    onAudio: (data) =>
      sound.push(data === null ? null : data.length === 3840 ? data[0]! : -1),
    onSound: () => carries++,
    sound: () => false,
  });
  await settle();
  const view = views[0]!;
  view.emit({ type: "open", view: 3 });
  // Muted here: the view is told at once.
  expect(said).toEqual([{ view: 3, message: { sound: false } }]);
  view.emit({ type: "audioConfig", codec: "opus" });
  expect(carries).toBe(1);
  view.emit({ type: "audio", ts: 1, data: new Uint8Array(150).fill(5) });
  expect(decoded).toEqual([5]);
  expect(sound).toEqual([5]);
  peer.sound!(true);
  expect(said.at(-1)).toEqual({ view: 3, message: { sound: true } });
  peer.close();
  delete (globalThis as { AudioDecoder?: unknown }).AudioDecoder;
});
