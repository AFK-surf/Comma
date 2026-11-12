import { describe, expect, it } from "vitest";
import { createFrameComma } from "../frame";
import { createMockComma } from "../mock";
import { miniAppCapabilityOps } from "../sdk";

describe("device capabilities", () => {
  it("delivers selected microphone channels separately and stops on device removal", async () => {
    const device = {
      id: "interface",
      name: "Audio interface",
      channelCount: { min: 1, max: 4 },
      sampleRate: { min: 44100, max: 96000 },
    };
    const comma = createMockComma({
      capabilities: ["microphone"],
      audioInputs: [device],
    });
    expect(await comma.microphone.devices()).toEqual([device]);
    const heard: number[][][] = [];
    const ends: string[] = [];
    const mic = await comma.microphone.startChannels(
      { deviceId: device.id, channelCount: 4, channels: [2, 0] },
      (samples) => heard.push(samples.map((channel) => [...channel])),
      (reason) => ends.push(reason)
    );
    expect(mic).toMatchObject({ channelCount: 4, channels: [2, 0], sampleRate: 48000 });
    comma.mock.microphoneChannels([
      Float32Array.of(0.125),
      Float32Array.of(0.25),
      Float32Array.of(0.5),
      Float32Array.of(0.75),
    ]);
    expect(heard).toEqual([[[0.5], [0.125]]]);
    comma.mock.audioInputs([]);
    expect(ends).toEqual(["ended"]);
    comma.mock.microphoneChannels([]);
    expect(heard).toHaveLength(1);
    await mic.stop();
    await expect(
      comma.microphone.startChannels(
        { channelCount: 4, channels: [4] },
        () => undefined
      )
    ).rejects.toMatchObject({ code: "invalid" });
    await expect(
      comma.microphone.startChannels(
        { channelCount: 4, channels: [1, 1] },
        () => undefined
      )
    ).rejects.toMatchObject({ code: "invalid" });
  });

  it("delivers microphone and MIDI streams until the app stops them", async () => {
    const comma = createMockComma({
      capabilities: ["microphone", "midi"],
      sampleRate: 44_100,
      midiInputs: [{ id: "k1", name: "Keys" }],
    });
    const heard: number[][] = [];
    const mic = await comma.microphone.start((samples) => heard.push([...samples]));
    expect(mic.sampleRate).toBe(44_100);
    comma.mock.microphone(Float32Array.from([0.5, -0.5]));
    expect(heard).toEqual([[0.5, -0.5]]);

    const notes: { input: string; data: number[] }[] = [];
    const midi = await comma.midi.start((message) =>
      notes.push({ input: message.input, data: [...message.data] })
    );
    expect(midi.inputs).toEqual([{ id: "k1", name: "Keys" }]);
    comma.mock.midi({ input: "k1", data: Uint8Array.from([0x90, 60, 100]), time: 1 });
    expect(notes).toEqual([{ input: "k1", data: [0x90, 60, 100] }]);

    await mic.stop();
    await midi.stop();
    comma.mock.microphone(Float32Array.from([1]));
    comma.mock.midi({ input: "k1", data: Uint8Array.from([0x80, 60, 0]), time: 2 });
    expect(heard).toHaveLength(1);
    expect(notes).toHaveLength(1);
    expect(comma.mock.calls.map((call) => call.op)).toEqual([
      "microphone.start",
      "midi.start",
      "microphone.stop",
      "midi.stop",
    ]);
  });

  it("lets the app choose an audio input and follow its changes", async () => {
    const mac = { id: "mac", name: "MacBook Microphone" };
    const usb = { id: "usb", name: "USB Audio" };
    const comma = createMockComma({
      capabilities: ["microphone"],
      grants: ["microphone"],
      audioInputs: [mac, usb],
    });
    expect(await comma.microphone.devices()).toEqual([mac, usb]);
    const lists: string[][] = [];
    const watch = await comma.microphone.watch((devices) =>
      lists.push(devices.map((device) => device.id))
    );
    expect(watch.devices).toEqual([mac, usb]);

    const ends: string[] = [];
    const mic = await comma.microphone.start(
      () => undefined,
      (reason) => ends.push(reason),
      { deviceId: "usb" }
    );
    expect(mic.device).toEqual(usb);
    expect(comma.mock.calls.at(-1)).toEqual({
      op: "microphone.start",
      args: { deviceId: "usb" },
    });
    // Unplugging the input ends its stream and tells the watch.
    comma.mock.audioInputs([mac]);
    expect(ends).toEqual(["ended"]);
    expect(lists).toEqual([["mac"]]);

    await watch.stop();
    comma.mock.audioInputs([mac, usb]);
    expect(lists).toHaveLength(1);
    await expect(
      comma.microphone.start(() => undefined, undefined, { deviceId: 3 as never })
    ).rejects.toMatchObject({ code: "invalid" });
  });

  it("tells the app when the host ends a stream, and ignores data of streams it does not hold", async () => {
    const frame = createFrameComma({
      init: {
        app: { id: "a", name: "A", version: 1 },
        viewer: null,
        theme: "light",
        tokens: {},
        locale: "en",
        timeZone: "UTC",
        capabilities: ["microphone"],
        grants: ["microphone"],
        storage: [],
        backend: false,
      },
      capabilityOps: miniAppCapabilityOps,
      assetUrl: () => undefined,
      call: async () => ({ stream: 7, sampleRate: 48_000 }),
    });
    const heard: Float32Array[] = [];
    const ends: string[] = [];
    await frame.comma.microphone.start(
      (samples) => heard.push(samples),
      (reason) => ends.push(reason)
    );
    frame.streamData(8, new Float32Array(1));
    frame.streamData(7, new Float32Array(2));
    frame.streamEnd(7, "ended");
    frame.streamData(7, new Float32Array(3));
    expect(heard.map((samples) => samples.length)).toEqual([2]);
    expect(ends).toEqual(["ended"]);
  });

  it("checks grants and answers the one-shot device calls", async () => {
    const comma = createMockComma({
      capabilities: ["camera", "location", "clipboard.read", "share", "haptics"],
      grants: ["camera", "clipboard.read", "share", "haptics"],
      clipboardText: "pasted",
      confirmShare: (content) => content.text !== "no",
    });
    expect(comma.supports("location.current")).toBe(true);
    expect(comma.supports("midi.start")).toBe(false);
    await expect(comma.location.current()).rejects.toMatchObject({
      code: "not_granted",
    });
    expect(await comma.camera.capture()).toBeNull();
    expect(await comma.clipboard.read()).toBe("pasted");
    expect(await comma.share({ text: "score" })).toEqual({ shared: true });
    expect(await comma.share({ text: "no" })).toEqual({ shared: false });
    expect(await comma.haptics(40)).toEqual({ played: true });
    expect(comma.mock.haptics).toEqual([[40]]);
    expect(comma.mock.shares).toEqual([{ text: "score" }]);
  });
});
