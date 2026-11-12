import { afterEach, describe, expect, it, vi } from "vitest";
import { MiniAppDevices } from "../miniAppDevices";

afterEach(() => vi.unstubAllGlobals());

function audioFixture(channelCount = 4) {
  const track = Object.assign(new EventTarget(), {
    stop: vi.fn(),
    label: "Interface",
    getSettings: () => ({ deviceId: "usb", channelCount }),
  });
  const getUserMedia = vi.fn(async () => ({
    getTracks: () => [track],
    getAudioTracks: () => [track],
  }));
  vi.stubGlobal("navigator", { mediaDevices: { getUserMedia } });
  const capture = Object.assign(new EventTarget(), {
    connect: vi.fn(),
    disconnect: vi.fn(),
  });
  const close = vi.fn(async () => undefined);
  vi.stubGlobal(
    "AudioContext",
    class {
      sampleRate = 48000;
      destination = {};
      createMediaStreamSource = () => ({ connect: vi.fn(), disconnect: vi.fn() });
      createScriptProcessor = () => capture;
      close = close;
    }
  );
  const send = vi.fn();
  const host = new MiniAppDevices(send, () => null);
  return { host, track, getUserMedia, capture, close, send };
}

describe("host microphone channels", () => {
  it("copies and transfers selected channels in order, then releases the input when stopped", async () => {
    const t = audioFixture();
    expect(
      await t.host.run("microphone.startChannels", {
        deviceId: "usb",
        channelCount: 4,
        channels: [2, 0],
      })
    ).toMatchObject({
      ok: true,
      value: { stream: 1, channelCount: 4, channels: [2, 0], sampleRate: 48000 },
    });
    expect(t.getUserMedia).toHaveBeenCalledWith({
      audio: expect.objectContaining({
        channelCount: { exact: 4 },
        deviceId: { exact: "usb" },
      }),
    });
    const input = [
      Float32Array.of(0.125),
      Float32Array.of(0.25),
      Float32Array.of(0.5),
      Float32Array.of(0.75),
    ];
    t.capture.dispatchEvent(
      Object.assign(new Event("audioprocess"), {
        inputBuffer: {
          numberOfChannels: 4,
          getChannelData: (channel: number) => input[channel],
        },
      })
    );
    const [message, transferred] = t.send.mock.calls[0]!;
    expect(message).toEqual({ type: "stream", stream: 1, data: [input[2], input[0]] });
    expect(message.data[0]).not.toBe(input[2]);
    expect(transferred).toEqual(
      message.data.map((channel: Float32Array) => channel.buffer)
    );
    await t.host.run("microphone.stop", { stream: 1 });
    expect(t.track.stop).toHaveBeenCalledOnce();
    expect(t.close).toHaveBeenCalledOnce();
    t.capture.dispatchEvent(
      Object.assign(new Event("audioprocess"), { inputBuffer: {} })
    );
    expect(t.send).toHaveBeenCalledTimes(1);
  });

  it("refuses a browser that supplies fewer channels and releases the stream", async () => {
    const t = audioFixture(2);
    expect(
      await t.host.run("microphone.startChannels", { channelCount: 4 })
    ).toMatchObject({ ok: false, code: "unsupported" });
    expect(t.track.stop).toHaveBeenCalledOnce();
    expect(t.send).not.toHaveBeenCalled();
  });

  it("releases the input if constructing the audio graph fails", async () => {
    const t = audioFixture();
    vi.stubGlobal(
      "AudioContext",
      vi.fn(function unavailableAudioContext() {
        throw new Error("No audio context");
      })
    );
    expect(
      await t.host.run("microphone.startChannels", { channelCount: 4 })
    ).toMatchObject({ ok: false });
    expect(t.track.stop).toHaveBeenCalledOnce();
  });

  it("reports capability ranges only when the browser exposes them", async () => {
    const t = audioFixture();
    vi.stubGlobal("navigator", {
      mediaDevices: {
        enumerateDevices: async () => [
          {
            kind: "audioinput",
            deviceId: "usb",
            label: "Interface",
            getCapabilities: () => ({
              channelCount: { min: 1, max: 4 },
              sampleRate: { min: 44100, max: 96000 },
            }),
          },
          { kind: "audioinput", deviceId: "default", label: "Default" },
        ],
      },
    });
    expect(await t.host.run("microphone.devices", {})).toEqual({
      ok: true,
      value: {
        devices: [
          {
            id: "usb",
            name: "Interface",
            channelCount: { min: 1, max: 4 },
            sampleRate: { min: 44100, max: 96000 },
          },
          { id: "default", name: "Default" },
        ],
      },
    });
  });
});
