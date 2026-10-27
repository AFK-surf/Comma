import type { VoiceCallValue, VoiceValue } from "@comma/core/contract";
import { defaultCommaClientSettings } from "@comma/native-bridge";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { uiClock } from "@comma/ui/clock";
import { fireEvent, render, screen, waitFor } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { afterEach, expect, it, vi } from "vitest";
import { CallAudio } from "../components/voice/callAudio";
import {
  CommaWebClientSettingsProvider,
  useCommaClientSettings,
} from "../components/commaClientSettings";
import {
  DesktopCallAudio,
  formatElapsed,
  HomeCallControl,
} from "../components/voice/DesktopCall";

// Home's call to the Router on the desktop (voice labs): a phone button while the workspace can take calls; while a
// call is up, a card with "Calling…" or the time talked, mute and hang up; nothing after it ends.

const workspace = "wsp_call";

/** Settings › Debug's voice labs switch, turned off. */
function LabsOff() {
  const { update } = useCommaClientSettings();
  return (
    <button type="button" onClick={() => void update({ voiceLabsEnabled: false })}>
      Labs off
    </button>
  );
}

function open({
  labs = true,
  platform = "electron" as "electron" | "web",
  call = { phase: "idle" } as Partial<VoiceCallValue>,
} = {}) {
  installNativeBridgeMock({ platform });
  let current: VoiceCallValue = {
    available: true,
    phase: "idle",
    workspace: null,
    muted: false,
    connectedAt: null,
    ...call,
  };
  const made: [string, unknown][] = [];
  const core = createScriptedCore({
    values: (topic): VoiceCallValue | VoiceValue | undefined =>
      topic.topic === "voiceCall"
        ? current
        : topic.topic === "voice"
          ? {
              workspace,
              integration: {
                lines: ["+15550001111"],
                numbers: [],
                readiness: { ready: true, reason: null },
                sessions_url: "wss://salix.example/s",
                readiness_url: "https://salix.example/r",
                preferences: { voice: null, custom_voice: null, router_calls: true },
                voices: [],
              },
              keys: [],
              integrationError: false,
              keysError: false,
            }
          : undefined,
    calls: (name, params) => {
      made.push([name, params]);
      if (name === "voiceCall.start")
        current = { ...current, phase: "calling", workspace };
      if (name === "voiceCall.end")
        current = { ...current, phase: "idle", workspace: null, connectedAt: null };
      if (name === "voiceCall.setMuted")
        current = { ...current, muted: (params as { muted: boolean }).muted };
      core.changed("voiceCall");
      return null;
    },
  });
  const user = userEvent.setup();
  render(
    core.wrap(
      <CommaWebClientSettingsProvider
        initialSettings={{ ...defaultCommaClientSettings, voiceLabsEnabled: labs }}
      >
        <HomeCallControl workspaceId={workspace} />
        <DesktopCallAudio />
        <LabsOff />
      </CommaWebClientSettingsProvider>
    )
  );
  return {
    user,
    called: (name: string) => made.filter(([n]) => n === name).map(([, p]) => p),
    answer: (next: Partial<VoiceCallValue>) => {
      current = { ...current, ...next };
      core.changed("voiceCall");
    },
  };
}

it("calls the Router, shows the card while it rings and talks, and leaves nothing after hanging up", async () => {
  const t = open();
  await t.user.click(await screen.findByRole("button", { name: "Call" }));
  expect(t.called("voiceCall.start")).toEqual([{ workspace }]);
  expect(await screen.findByTestId("voice-call-status")).toHaveTextContent("Calling…");

  // Salix answered: the time talked replaces "Calling…".
  t.answer({ phase: "connected", connectedAt: uiClock.now() - 4_000 });
  await waitFor(() =>
    expect(screen.getByTestId("voice-call-status")).toHaveTextContent("00:04")
  );

  await t.user.click(screen.getByRole("button", { name: "Mute" }));
  expect(t.called("voiceCall.setMuted")).toEqual([{ muted: true }]);
  expect(await screen.findByRole("button", { name: "Unmute" })).toHaveAttribute(
    "aria-pressed",
    "true"
  );

  await t.user.click(screen.getByRole("button", { name: "Hang up" }));
  expect(t.called("voiceCall.end")).toEqual([{}]);
  await waitFor(() => expect(screen.queryByTestId("voice-call-card")).toBeNull());
  expect(screen.getByRole("button", { name: "Call" })).toBeInTheDocument();
});

it("offers no call without voice labs, or off the desktop", async () => {
  open({ labs: false });
  expect(screen.queryByRole("button", { name: "Call" })).toBeNull();
  document.body.replaceChildren();
  open({ platform: "web" });
  expect(screen.queryByRole("button", { name: "Call" })).toBeNull();
});

it("shows the time talked as minutes and seconds, with hours past an hour", () => {
  expect(formatElapsed(4)).toBe("00:04");
  expect(formatElapsed(75)).toBe("01:15");
  expect(formatElapsed(3_725)).toBe("1:02:05");
});

it("drags the card within the window, but not from its buttons", async () => {
  open({ call: { phase: "calling", workspace } });
  const card = await screen.findByTestId("voice-call-card");
  // A 300 × 120 card at the top right of a 1200 × 800 window.
  // A 300 × 120 card at the top right of a 1200 × 800 window, where it is moved to.
  vi.spyOn(card, "getBoundingClientRect").mockImplementation(() => {
    const [, x = "0", y = "0"] =
      /translate\((-?\d+)px, (-?\d+)px\)/.exec(card.style.transform) ?? [];
    return DOMRect.fromRect({
      x: 880 + Number(x),
      y: 20 + Number(y),
      width: 300,
      height: 120,
    });
  });
  vi.spyOn(document.documentElement, "clientWidth", "get").mockReturnValue(1200);
  vi.spyOn(document.documentElement, "clientHeight", "get").mockReturnValue(800);
  const drag = (target: Element, from: [number, number], to: [number, number]) => {
    fireEvent.pointerDown(target, {
      button: 0,
      pointerId: 1,
      clientX: from[0],
      clientY: from[1],
    });
    fireEvent.pointerMove(card, { pointerId: 1, clientX: to[0], clientY: to[1] });
    fireEvent.pointerUp(card, { pointerId: 1, clientX: to[0], clientY: to[1] });
  };

  drag(card, [900, 40], [800, 90]);
  expect(card.style.transform).toBe("translate(-100px, 50px)");

  // Past the window's edge it stops at the edge.
  drag(card, [900, 40], [2000, -500]);
  expect(card.style.transform).toBe("translate(20px, -20px)");

  // A press on a button is a press, not a drag.
  drag(screen.getByRole("button", { name: "Mute" }), [900, 40], [500, 400]);
  expect(card.style.transform).toBe("translate(20px, -20px)");
});

it("ends the call when voice labs are turned off during it", async () => {
  const t = open({
    call: { phase: "connected", workspace, connectedAt: uiClock.now() },
  });
  expect(await screen.findByTestId("voice-call-card")).toBeInTheDocument();
  expect(t.called("voiceCall.end")).toEqual([]);

  await t.user.click(screen.getByRole("button", { name: "Labs off" }));
  await waitFor(() => expect(t.called("voiceCall.end")).toEqual([{}]));
  expect(screen.queryByTestId("voice-call-card")).toBeNull();
});

afterEach(() => vi.unstubAllGlobals());

/** A `CallAudio` on a stand-in for the window's audio: its microphone and the sources it plays, ended by hand. */
async function fakeCallAudio() {
  let process: ((event: { inputBuffer: AudioBuffer }) => void) | undefined;
  const sources: EventTarget[] = [];
  class FakeAudioContext {
    currentTime = 0;
    destination = {};
    createMediaStreamSource = () => ({ connect: () => {} });
    createScriptProcessor = () => ({
      addEventListener: (_: string, listener: typeof process) => (process = listener),
      connect: () => {},
      disconnect: () => {},
    });
    createBuffer = (_: number, length: number) => ({
      duration: length / 24_000,
      getChannelData: () => new Float32Array(length),
    });
    createBufferSource = () => {
      const source = Object.assign(new EventTarget(), {
        buffer: null,
        connect: () => {},
        start: () => {},
        stop: () => {},
      });
      sources.push(source);
      return source;
    };
    close = async () => {};
  }
  vi.stubGlobal("AudioContext", FakeAudioContext);
  vi.stubGlobal("navigator", {
    mediaDevices: { getUserMedia: async () => ({ getTracks: () => [] }) },
  });
  const frames: Uint8Array[] = [];
  const played: string[] = [];
  const audio = new CallAudio({
    microphone: (pcm) => frames.push(pcm),
    played: (name) => played.push(name),
  });
  await audio.start();
  return {
    audio,
    frames,
    played,
    sources,
    /** 960 samples of a loud voice: two 20 ms frames. */
    speak: () =>
      process!({
        inputBuffer: { getChannelData: () => new Float32Array(960).fill(0.5) } as never,
      }),
  };
}

it("keeps sending the microphone's frames while muted, as silence", async () => {
  const { audio, frames, speak } = await fakeCallAudio();
  speak();
  expect(frames).toHaveLength(2);
  expect(frames[0]!.some((byte) => byte !== 0)).toBe(true);

  // The server ends a call that sends no audio for a minute: muted, the frames go on, all zero.
  audio.setMuted(true);
  speak();
  expect(frames).toHaveLength(4);
  expect(frames.slice(2).every((frame) => frame.every((byte) => byte === 0))).toBe(
    true
  );

  audio.stop();
});

it("answers every mark after a piece of audio once it has played", async () => {
  const { audio, played, sources } = await fakeCallAudio();
  audio.play(new Uint8Array(960));
  audio.mark("a");
  audio.mark("b");
  audio.play(new Uint8Array(960));
  audio.mark("c");
  expect(played).toEqual([]);

  sources[0]!.dispatchEvent(new Event("ended"));
  expect(played).toEqual(["a", "b"]);
  sources[1]!.dispatchEvent(new Event("ended"));
  expect(played).toEqual(["a", "b", "c"]);

  audio.stop();
});
