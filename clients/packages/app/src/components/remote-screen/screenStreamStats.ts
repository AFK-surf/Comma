import type { ScreenViewEvent } from "@comma/core/contract";

type StationState = Extract<ScreenViewEvent, { type: "state" }>["state"];

/** The screen's pointer as the station says it (`state.cursor`). */
export type ScreenCursor = NonNullable<StationState["cursor"]>;
/** Where an agent's finger is on a device it leases, as the station says it (0..1 of the picture). */
export type ScreenAgentPointer = NonNullable<StationState["agentPointer"]>;

/**
 * What a view's statistics show, as it comes (still.fail's web/src/screen/ScreenPanel.tsx `NetChip`): the picture's
 * codec and size (its config), how the station makes it (`state.video`) and how late its frames are (`state.latency`),
 * and the frames and their bytes counted as they come, which the panel reads each second while it is open. Each is
 * absent where it is not had: the frames are counted from the first.
 */
export type ScreenStreamStats = {
  codec?: string | undefined;
  width?: number | undefined;
  height?: number | undefined;
  video?: StationState["video"];
  latency?: StationState["latency"];
  frames?: number | undefined;
  bytes?: number | undefined;
};

/** Frames and bits a second between two readings of the same stats, `ms` apart. */
export function streamRate(
  was: { frames?: number | undefined; bytes?: number | undefined },
  now: { frames?: number | undefined; bytes?: number | undefined },
  ms: number
): { fps: number; bps: number } | null {
  if (
    !(ms > 0) ||
    was.frames === undefined ||
    was.bytes === undefined ||
    now.frames === undefined ||
    now.bytes === undefined
  )
    return null;
  const seconds = ms / 1000;
  return {
    fps: (now.frames - was.frames) / seconds,
    bps: ((now.bytes - was.bytes) * 8) / seconds,
  };
}

/** Bits a second as a link's speed is said: 850 kbps, 4.2 Mbps, 33 Mbps (still.fail's `bitrate`). */
export function bitrateText(bps: number): string {
  if (bps >= 1e6) return `${(bps / 1e6).toFixed(bps >= 1e7 ? 0 : 1)} Mbps`;
  return `${Math.round(bps / 1e3)} kbps`;
}

/** A codec as people name it. */
export function codecText(codec: string): string {
  return codec === "h264" ? "H.264" : codec === "h265" ? "H.265" : codec.toUpperCase();
}
