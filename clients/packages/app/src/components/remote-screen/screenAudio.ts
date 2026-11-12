// A computer's system output as its view carries it (@comma/mesh screen-wire.ts `audio`: 20 ms packets of 48 kHz
// stereo PCM16, or Opus packets decoded to them first: `createScreenOpusDecoder`), played here. Each packet is played after those queued, as it comes: started once a reserve is queued,
// emptied after a stall in the transport and as it runs dry (an underrun refills the reserve first), and stopped when
// muted, when the view opens again and when it closes. Timestamps say when a packet was captured; playback starts on
// arrival, not on the video's clock.
//
// Ported from still.fail (github.com/AFK-surf/still.fail, afk/main 3d517e022e) apps/mbui/mbui/src/host/win_stream.cpp
// `sound_play`, `sound_stop` (its XAudio2 voice), itself apple_stream.m's `audio_play` (60 ms reserve, 300 ms most) with
// a reserve that follows how late packets come: 100 ms at first, a gap between two packets longer than it covers making
// it that long and a packet more, at most 300 ms; emptied once more than the reserve and 200 ms are queued. The rules are
// `ScreenAudioReserve`, as there; what plays them is Web Audio here (an AudioBufferSourceNode a packet, each started
// where the last ends), not XAudio2 or AVAudioEngine.

import { uiClock } from "@comma/ui/clock";

/** One packet: 960 frames of interleaved stereo PCM16, little-endian (20 ms at 48 kHz). */
export const AUDIO_PACKET_BYTES = 3840;
/** How a view's Opus packets are decoded: 48 kHz stereo, as its PCM is. */
const OPUS_CONFIG: AudioDecoderConfig = {
  codec: "opus",
  sampleRate: 48_000,
  numberOfChannels: 2,
};
const PACKET_FRAMES = 960;
const PACKET_MS = 20;
const RATE = 48_000;
/** The reserve at first, in packets: 100 ms. */
const RESERVE_FIRST = 5;
/** The largest reserve: 300 ms. */
const RESERVE_MOST = 15;
/** Queued past the reserve by this many packets (200 ms), the transport stalled: emptied. */
const STALL = 10;
/** A gap this long or longer is a pause in the sound, not a late packet. */
const PAUSE_MS = 1000;

/** What to do with a packet that came, as still.fail's `sound_play` decides it. */
export type ReserveStep = {
  /** Let go of what is queued first (a stall, or run dry while playing). */
  flush: boolean;
  /** Start playing once this packet is queued: the reserve is. */
  start: boolean;
};

/** How much is held before sound starts, and when what is queued is let go. Pure: `now` in ms, `queued` in packets. */
export class ScreenAudioReserve {
  /** The reserve, in packets. */
  reserve = RESERVE_FIRST;
  playing = false;
  #lastAt: number | undefined;

  /** A packet came at `now` with `queued` packets queued and not played yet. */
  take(now: number, queued: number): ReserveStep {
    // How long since the last packet: a gap longer than the reserve covers makes it that long and a packet more.
    if (this.#lastAt !== undefined) {
      const gap = now - this.#lastAt;
      const need = Math.floor(gap / PACKET_MS) + 2;
      if (gap < PAUSE_MS && need > this.reserve && this.reserve < RESERVE_MOST)
        this.reserve = Math.min(need, RESERVE_MOST);
    }
    this.#lastAt = now;
    // More than the reserve and 200 ms queued (a stall), or run dry while playing: emptied, the reserve filled again.
    const flush = queued >= this.reserve + STALL || (this.playing && queued === 0);
    if (flush) {
      this.playing = false;
      queued = 0;
    }
    // Started once its reserve is queued.
    const start = !this.playing && queued + 1 >= this.reserve;
    if (start) this.playing = true;
    return { flush, start };
  }

  /** Stopped (muted, the view opened again or closed): what is queued goes; the reserve is kept. */
  stop(): void {
    this.playing = false;
    this.#lastAt = undefined;
  }
}

/** A packet's PCM16 as Web Audio's two float channels. */
export function packetChannels(
  data: Uint8Array
): [Float32Array<ArrayBuffer>, Float32Array<ArrayBuffer>] {
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const left = new Float32Array(PACKET_FRAMES);
  const right = new Float32Array(PACKET_FRAMES);
  for (let frame = 0; frame < PACKET_FRAMES; frame++) {
    left[frame] = view.getInt16(frame * 4, true) / 32768;
    right[frame] = view.getInt16(frame * 4 + 2, true) / 32768;
  }
  return [left, right];
}

export type ScreenAudioPlayer = {
  /** One packet, played after those queued; one of another size is let be. */
  play(data: Uint8Array): void;
  /** What is queued let go, nothing playing, until the next packet. */
  stop(): void;
  /** Let go of for good. */
  close(): void;
};

/**
 * Plays packets on Web Audio. While it holds its reserve, packets wait here; once started each is scheduled where the
 * last ends, so what is queued is what is scheduled and not yet heard.
 */
export function createScreenAudioPlayer(
  now: () => number = () => uiClock.now()
): ScreenAudioPlayer {
  const rules = new ScreenAudioReserve();
  let context: AudioContext | undefined;
  /** Packets held while the reserve fills. */
  let waiting: Uint8Array[] = [];
  /** Where the next scheduled packet starts (the context's seconds), and what is scheduled. */
  let next = 0;
  const scheduled = new Set<AudioBufferSourceNode>();
  let closed = false;

  const ensure = (): AudioContext => {
    context ??= new AudioContext({ sampleRate: RATE, latencyHint: "interactive" });
    if (context.state === "suspended") void context.resume().catch(() => undefined);
    return context;
  };
  const queued = (ctx: AudioContext): number =>
    rules.playing
      ? Math.max(0, Math.round((next - ctx.currentTime) * (1000 / PACKET_MS)))
      : waiting.length;
  const letGo = () => {
    for (const node of scheduled) {
      try {
        node.stop();
      } catch {
        // (not started yet)
      }
      node.disconnect();
    }
    scheduled.clear();
    waiting = [];
    next = 0;
  };
  const schedule = (ctx: AudioContext, data: Uint8Array) => {
    const buffer = ctx.createBuffer(2, PACKET_FRAMES, RATE);
    const [left, right] = packetChannels(data);
    buffer.copyToChannel(left, 0);
    buffer.copyToChannel(right, 1);
    const node = ctx.createBufferSource();
    node.buffer = buffer;
    node.connect(ctx.destination);
    next = Math.max(next, ctx.currentTime);
    node.start(next);
    next += PACKET_FRAMES / RATE;
    scheduled.add(node);
    node.addEventListener(
      "ended",
      () => {
        scheduled.delete(node);
        node.disconnect();
      },
      { once: true }
    );
  };

  return {
    play(data) {
      if (closed || data.length !== AUDIO_PACKET_BYTES) return;
      const ctx = ensure();
      const step = rules.take(now(), queued(ctx));
      if (step.flush) letGo();
      if (rules.playing && !step.start) {
        schedule(ctx, data);
        return;
      }
      waiting.push(data);
      if (!step.start) return;
      // The reserve is queued: what waited starts now, one after another.
      const held = waiting;
      waiting = [];
      next = ctx.currentTime;
      for (const packet of held) schedule(ctx, packet);
    },
    stop() {
      rules.stop();
      letGo();
    },
    close() {
      closed = true;
      rules.stop();
      letGo();
      void context?.close().catch(() => undefined);
      context = undefined;
    },
  };
}

/**
 * Whether this page decodes Opus (WebCodecs' `AudioDecoder`): then a computer's sound is asked as Opus, about 64 kbit/s
 * where PCM is 1.5 Mbit/s. Asked once: the answer once known, before then its promise, which a view waits for (a few ms)
 * so the first is not left on PCM; false where there is no `AudioDecoder`.
 */
let opusDecodes: boolean | Promise<boolean> | undefined;
export const screenOpusDecodes = (): boolean | Promise<boolean> => {
  if (opusDecodes !== undefined) return opusDecodes;
  if (typeof AudioDecoder === "undefined") return (opusDecodes = false);
  return (opusDecodes = AudioDecoder.isConfigSupported(OPUS_CONFIG).then(
    (said) => (opusDecodes = said.supported === true),
    () => (opusDecodes = false)
  ));
};

/**
 * `audio` as interleaved PCM16, `into` (its frames × channels × 2 bytes): read as `f32-planar`, the one conversion
 * WebCodecs requires of every page (`s16` and the rest are a page's choice), and made 16-bit here.
 */
export function pcm16Of(audio: AudioData, into: Uint8Array): void {
  const frames = audio.numberOfFrames;
  const channels = audio.numberOfChannels;
  const out = new DataView(into.buffer, into.byteOffset, into.byteLength);
  const plane = new Float32Array(frames);
  for (let c = 0; c < channels; c++) {
    audio.copyTo(plane, { planeIndex: c, format: "f32-planar" });
    for (let i = 0; i < frames; i++) {
      const v = Math.max(-1, Math.min(1, plane[i]!));
      out.setInt16((i * channels + c) * 2, Math.round(v * 0x7fff), true);
    }
  }
}

/** A view's Opus packets made the PCM packets `onPcm` plays (3840 bytes each), in order. */
export type ScreenOpusDecoder = {
  decode(ts: number, data: Uint8Array): void;
  close(): void;
};

export function createScreenOpusDecoder(
  onPcm: (pcm: Uint8Array) => void
): ScreenOpusDecoder {
  let broken = false;
  const decoder = new AudioDecoder({
    output: (audio) => {
      try {
        const pcm = new Uint8Array(audio.numberOfFrames * audio.numberOfChannels * 2);
        pcm16Of(audio, pcm);
        // One Opus packet of 20 ms is one of PCM: another length plays nothing (the player takes whole packets).
        if (pcm.byteLength === AUDIO_PACKET_BYTES) onPcm(pcm);
      } finally {
        audio.close();
      }
    },
    // A packet it could not decode: the sound stops for this view, its pictures go on.
    error: () => void (broken = true),
  });
  decoder.configure(OPUS_CONFIG);
  return {
    decode(ts, data) {
      if (broken || decoder.state !== "configured") return;
      decoder.decode(new EncodedAudioChunk({ type: "key", timestamp: ts, data }));
    },
    close() {
      if (decoder.state !== "closed") decoder.close();
    },
  };
}
