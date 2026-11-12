import type { ScreenClip, ScreenDeviceId, ScreenQuality } from "@comma/core-client";
import { uiClock } from "@comma/ui/clock";
import { useCallback, useSyncExternalStore } from "react";
import type { ScreenStreamInput } from "./screenStreamInput";
import {
  openMeshScreenStream,
  type ScreenStreamPeer,
  type ScreenStreamState,
} from "./meshScreenStream";
import type { ScreenDeviceState } from "./screenDevice";
import {
  createScreenAudioPlayer,
  screenOpusDecodes,
  type ScreenAudioPlayer,
} from "./screenAudio";
import { screenQualityBounds } from "./screenQuality";
import type { ScreenClipType } from "./screenClipboard";
import {
  screenFailureKind,
  screenFailureRetries,
  screenIsLocked,
} from "./screenFailure";
import type { ScreenStreamSource, ScreenStreamTarget } from "./ScreenStreamStage";
import type {
  ScreenAgentPointer,
  ScreenCursor,
  ScreenStreamStats,
} from "./screenStreamStats";

/** What a holder of a stream shows. */
export type HeldScreenStreamView = {
  state: ScreenStreamState;
  media: MediaStream | null;
  /** Why it failed, when it says. */
  failure?: string | undefined;
  /** The apps it really shows, and how many of their windows are on screen, once it says. */
  target?: { apps: readonly string[]; windows: number } | undefined;
  /** How a device stands, once it says. */
  device?: ScreenDeviceState | undefined;
  /** Why the computer did not let this stream drive, when Control was asked of it. */
  refused?: string | undefined;
  /** The clipboard's types the open view carries while it drives; none: no clipboard. */
  clipboard?: readonly ScreenClipType[] | undefined;
  /** The computer's sound comes on the open view (whether or not it is muted here). */
  audio?: boolean | undefined;
  /** An agent's lease on the device lasts now, as its station says. */
  agent?: boolean | undefined;
};

export type HeldScreenStream = {
  send(input: ScreenStreamInput): void;
  /** This holder drives (Control) or only watches; the stream drives while any of its holders does. */
  control(on: boolean): void;
  /** The view's statistics so far: one object that goes on counting, read as often as they are shown. */
  stats(): ScreenStreamStats;
  /** Hears the screen's pointer as the station says it, at once with the last; until the returned function. */
  watchCursor(listener: (cursor: ScreenCursor) => void): () => void;
  /** Hears where an agent's finger is on the device as it acts; until the returned function. */
  watchAgentPointer(listener: (at: ScreenAgentPointer) => void): () => void;
  /** Opens a stream that failed anew, for all who hold it. */
  retry(): void;
  /** Sets the screen's clipboard and, with `paste`, pastes it there: the station takes it only while the view drives. */
  setClipboard(clip: ScreenClip, paste: boolean): void;
  /**
   * Hears each copy made on the screen while the stream drives, until the returned function. One holder hears it, the
   * first that listens: a copy goes onto this device's clipboard once.
   */
  onCopied(listener: (clip: ScreenClip) => void): () => void;
  release(): void;
};

type SharedStream = {
  view: HeldScreenStreamView;
  holders: Set<(view: HeldScreenStreamView) => void>;
  /** The holders that drive. */
  drivers: Set<(view: HeldScreenStreamView) => void>;
  /** Drives or watches as its drivers say now. */
  steer(): void;
  /** Apart from `view`: they change many times a second, and only the statistics and the pointer read them. */
  stats: ScreenStreamStats;
  cursor: ScreenCursor | undefined;
  cursorListeners: Set<(cursor: ScreenCursor) => void>;
  agentPointerListeners: Set<(at: ScreenAgentPointer) => void>;
  copiedListeners: Set<(clip: ScreenClip) => void>;
  send(input: ScreenStreamInput): void;
  setClipboard(clip: ScreenClip, paste: boolean): void;
  repaint(): void;
  retry(): void;
  close(): void;
  cancelClose: (() => void) | undefined;
};

// A `<video>` takes some time to attach to a stream, and misses a frame written before: when a frame is shown again for
// a new holder, at each of these.
const REPAINT_AFTER_MS = [50, 250];

// A stream that failed tries again this often and when the network comes back, showing what it shows meanwhile: a
// person may be away, and the way back may have come by itself.
const TRY_AGAIN_MS = 30_000;

// A stream keeps the apps it started with, so one opened on a locked Mac stays on loginwindow after the unlock. While it
// says locked, a new stream with nothing pinned looks at what is frontmost by then.
const LOCKED_LOOK_AGAIN_MS = 5_000;

/**
 * Whether a computer's sound is muted here, by its source's key: one choice for every stream of it, until the app ends.
 * Muting is this device's alone; the computer sends none to a view muted here (its `sound`), and again once it is not.
 */
const muted = new Map<string, boolean>();
const muteListeners = new Set<(sourceKey: string) => void>();

export const screenAudioMuted = (sourceKey: string): boolean =>
  muted.get(sourceKey) === true;

export function setScreenAudioMuted(sourceKey: string, on: boolean): void {
  if (screenAudioMuted(sourceKey) === on) return;
  muted.set(sourceKey, on);
  for (const listener of muteListeners) listener(sourceKey);
}

/** A computer's sound muted here or not, and the switch. */
export function useScreenAudioMuted(
  sourceKey: string
): [muted: boolean, toggle: () => void] {
  const on = useSyncExternalStore(
    (listener) => {
      muteListeners.add(listener);
      return () => void muteListeners.delete(listener);
    },
    () => screenAudioMuted(sourceKey)
  );
  const toggle = useCallback(
    () => setScreenAudioMuted(sourceKey, !screenAudioMuted(sourceKey)),
    [sourceKey]
  );
  return [on, toggle];
}

// A stream with no holder stays open this long. The card and the side panel
// pass one stream between them without a new connection.
const LINGER_MS = 1000;

const nothing: () => void = () => undefined;

/** Whether a target is one of a computer's devices, not its own screen. */
export const isDeviceTarget = (target: ScreenStreamTarget): target is ScreenDeviceId =>
  target.startsWith("android:") || target.startsWith("simulator:");

const streams = new Map<string, SharedStream>();

/**
 * The apps a source's "app" target was found to be, until the person picks anew. A later stream of it asks for them by
 * name: pressing Control or coming back must not pick whatever is frontmost by then. A name is not an identity: another
 * app of the same name would match too, and an app started again is matched by a new stream.
 */
const pinned = new Map<string, readonly string[]>();

function publish(
  key: string,
  shared: SharedStream,
  view: Partial<HeldScreenStreamView>
) {
  if (streams.get(key) !== shared) return;
  shared.view = { ...shared.view, ...view };
  for (const holder of shared.holders) holder(shared.view);
}

function open(
  key: string,
  options: {
    source: ScreenStreamSource;
    target: ScreenStreamTarget;
    control: boolean;
    background: string | undefined;
    side?: number;
    quality?: ScreenQuality;
  }
): SharedStream {
  let closed = false;
  // What the stream drives with now: it changes on the open view (a station from before: the stream opens anew).
  let control = options.control;
  let cancelAgain = nothing;
  // Trying again by itself: a mesh still out of reach is a reason to wait, not to go another way.
  let quietly = false;
  const stopAgain = () => {
    cancelAgain();
    cancelAgain = nothing;
  };
  const tryAgain = () => {
    stopAgain();
    if (closed || shared.view.state !== "failed") return;
    // Quietly: what it shows, and Try again, stay until it comes back or fails anew.
    quietly = true;
    peer.close();
    peer = start();
  };
  let stopLooking = nothing;
  // A new stream on a locked Mac is under way: nothing has changed for the person until it says what it shows.
  let looking = false;
  const armLook = () => {
    stopLooking();
    stopLooking = uiClock.after(LOCKED_LOOK_AGAIN_MS, () => {
      stopLooking = nothing;
      if (closed) return;
      looking = true;
      peer.close();
      peer = start();
    });
  };
  const armAgain = (why: string, code?: string) => {
    stopAgain();
    if (closed || !screenFailureRetries(why, code)) return;
    const stopTimer = uiClock.after(TRY_AGAIN_MS, tryAgain);
    globalThis.addEventListener?.("online", tryAgain);
    cancelAgain = () => {
      stopTimer();
      globalThis.removeEventListener?.("online", tryAgain);
    };
  };
  // A stream of its own, to drive where the open one cannot switch.
  const reopen = () => {
    stopAgain();
    stopLooking();
    peer.close();
    peer = start();
  };
  // The computer's sound, played once for every holder of the stream; stopped while muted here.
  let player: ScreenAudioPlayer | undefined;
  // Muted, the computer is told to send none (and to send it again once not).
  const hearMute = (sourceKey: string) => {
    if (sourceKey !== options.source.key) return;
    const off = screenAudioMuted(sourceKey);
    if (off) player?.stop();
    peer.sound?.(!off);
  };
  muteListeners.add(hearMute);
  const shared: SharedStream = {
    view: { state: "connecting", media: null },
    holders: new Set(),
    drivers: new Set(),
    steer: () => {
      const next = shared.drivers.size > 0;
      if (closed || next === control) return;
      if (next) publish(key, shared, { refused: undefined });
      if (peer.control?.(next)) {
        control = next;
        return;
      }
      // A station from before takes Control only as a view opens: a stream that drives serves who only watches
      // (their stages send nothing), and one that does not opens anew to drive.
      if (!next) return;
      control = true;
      reopen();
    },
    stats: {},
    cursor: undefined,
    cursorListeners: new Set(),
    agentPointerListeners: new Set(),
    copiedListeners: new Set(),
    send: (input) => peer.send(input),
    setClipboard: (clip, paste) => peer.setClipboard?.(clip, paste),
    repaint: () => peer.repaint?.(),
    retry: () => {
      if (shared.view.state !== "failed") return;
      stopAgain();
      stopLooking();
      quietly = false;
      peer.close();
      publish(key, shared, { state: "connecting", media: null, failure: undefined });
      peer = start();
    },
    close: () => {
      closed = true;
      stopAgain();
      stopLooking();
      muteListeners.delete(hearMute);
      player?.close();
      player = undefined;
      peer.close();
    },
    cancelClose: undefined,
  };
  streams.set(key, shared);
  const mesh = options.source.view;
  const start = (): ScreenStreamPeer =>
    openMeshScreenStream({
      control,
      open: (onEvent, signal, codecs, driving) => {
        const ask = (opus: boolean) => {
          const apps =
            options.target === "app" ? pinned.get(options.source.key) : undefined;
          return mesh.open(
            {
              target: options.target,
              control: driving,
              background: options.background,
              codecs,
              // A computer's sound (a device's is not carried, nor this app's own computer's: it would loop).
              // Opus where this page decodes it (a twentieth of PCM's bytes).
              ...(isDeviceTarget(options.target) || options.source.self?.()
                ? {}
                : { audio: opus ? ("opus" as const) : true }),
              ...(apps ? { apps } : {}),
              ...screenQualityBounds(options.quality, options.side),
              ...(options.quality ? { quality: options.quality } : {}),
            },
            onEvent,
            signal
          );
        };
        // Known after the first view: then the view is asked at once, as it was before the question.
        const decodes = screenOpusDecodes();
        return typeof decodes === "boolean" ? ask(decodes) : decodes.then(ask);
      },
      send: mesh.send,
      onStream: (media) => publish(key, shared, { media }),
      onState: (state) => {
        if (looking && state !== "live") return;
        publish(key, shared, {
          state,
          ...(state === "live" ? { failure: undefined } : {}),
        });
      },
      onFailure: (failure, code) => {
        stopLooking();
        // Between the lock and what comes after it there may be no app at all: look again.
        if (looking && screenFailureKind(failure) === "app-gone") {
          armLook();
          return;
        }
        looking = false;
        if (screenIsLocked(shared.view.target?.apps))
          publish(key, shared, { target: undefined });
        // Out of reach, or a page that cannot decode, is said in the app's words. A refusal's own sentence says more
        // than its code.
        const kind = code === undefined ? undefined : screenFailureKind(code);
        const ours = kind === "unreachable" || kind === "unsupported";
        publish(key, shared, { failure: ours ? code : failure });
        armAgain(failure, code);
      },
      onTarget: (target) => {
        looking = false;
        stopLooking();
        // Looking again never carries Control: whoever holds this lets go of it, and the person says so anew.
        if (options.target === "app" && !control && screenIsLocked(target.apps))
          armLook();
        if (
          options.target === "app" &&
          target.apps.length > 0 &&
          !screenIsLocked(target.apps)
        )
          pinned.set(options.source.key, target.apps);
        publish(key, shared, { target });
      },
      onDevice: (device) => publish(key, shared, { device }),
      onRefused: (refused) => publish(key, shared, { refused }),
      // A station from before kept what the view opened with: one that drives serves who only watches, and one
      // that does not opens anew to drive.
      onSwitchLost: () => {
        if (control) reopen();
        else control = true;
      },
      onCursor: (cursor) => {
        shared.cursor = cursor;
        for (const listener of shared.cursorListeners) listener(cursor);
      },
      onAgent: (on) => {
        if (shared.view.agent !== on) publish(key, shared, { agent: on });
      },
      onAgentPointer: (at) => {
        for (const listener of shared.agentPointerListeners) listener(at);
      },
      onClipboardTypes: (types) => {
        if ((shared.view.clipboard ?? []).join() !== types.join())
          publish(key, shared, { clipboard: types.length > 0 ? types : undefined });
      },
      // A copy made on the screen goes to one holder (the station sends it only while the view drives).
      onClipboard: (clip) => {
        if (control) [...shared.copiedListeners][0]?.(clip);
      },
      sound: () => !screenAudioMuted(options.source.key),
      onSound: () => {
        // (known to be this app's own computer only after the view opened: never played)
        if (!options.source.self?.() && !shared.view.audio)
          publish(key, shared, { audio: true });
      },
      onAudio: (data) => {
        if (data === null) {
          player?.stop();
          if (shared.view.audio) publish(key, shared, { audio: false });
          return;
        }
        if (options.source.self?.()) return;
        if (!shared.view.audio) publish(key, shared, { audio: true });
        if (screenAudioMuted(options.source.key)) return;
        (player ??= createScreenAudioPlayer()).play(data);
      },
      onStats: (stats) => Object.assign(shared.stats, stats),
      onFrame: (bytes) => {
        shared.stats.frames = (shared.stats.frames ?? 0) + 1;
        shared.stats.bytes = (shared.stats.bytes ?? 0) + bytes;
      },
      // Out of the mesh's reach (or this page decodes nothing): said so, and tried again by itself.
      onUnavailable: () => {
        if (closed) return;
        if (looking) {
          looking = false;
          quietly = true;
          publish(key, shared, {
            state: "failed",
            failure: "unreachable",
            target: undefined,
          });
        }
        if (!quietly) publish(key, shared, { state: "failed", failure: "unreachable" });
        armAgain("unreachable");
      },
    });
  let peer = start();
  return shared;
}

/**
 * Holds a stream of one source and target. All holders share one stream, which
 * drives while any of them does (`control`; the others' stages send nothing):
 * over the mesh Watch and Control change on the open view, so the picture goes on
 * as it was. A person who moves or switches away keeps the stream through the card
 * and back. `listen` runs at once with what the stream shows, and on each change
 * until `release`. A stream that failed opens anew for a new holder.
 */
export function holdScreenStream(
  options: {
    source: ScreenStreamSource;
    target: ScreenStreamTarget;
    control: boolean;
    background: string | undefined;
    /** A device's picture at most this long, in its long side. */
    side?: number;
    /** The 画质 chosen (none: 自动): another opens a stream of its own, as still.fail asks the view again. */
    quality?: ScreenQuality;
  },
  listen: (view: HeldScreenStreamView) => void
): HeldScreenStream {
  const key = `${options.source.key}\n${options.target}\n${options.side ?? ""}\n${options.quality ?? ""}\n${
    options.target === "app" ? (pinned.get(options.source.key)?.join("\n") ?? "") : ""
  }`;
  const usable = () => {
    const stream = streams.get(key);
    if (stream?.view.state !== "failed" || stream.holders.size > 0) return stream;
    stream.cancelClose?.();
    streams.delete(key);
    stream.close();
    return undefined;
  };
  const shared = usable();
  // Another stream of this source and target that nobody holds (it lingers for a holder that takes it back) goes at
  // once: this holder asks it otherwise (another 画质 or size), and the station counts the old view against the member
  // until it closes (three a member, systems/station/src/mesh/screens.ts MAX_VIEWS_A_MEMBER), so the new one would be refused while it lingered.
  if (!shared) {
    const same = `${options.source.key}\n${options.target}\n`;
    for (const [other, stream] of streams) {
      if (other === key || !other.startsWith(same) || stream.holders.size > 0) continue;
      stream.cancelClose?.();
      streams.delete(other);
      stream.close();
    }
  }
  const held = shared ?? open(key, options);
  held.cancelClose?.();
  held.cancelClose = undefined;
  held.holders.add(listen);
  const drive = (on: boolean) => {
    if (on) held.drivers.add(listen);
    else held.drivers.delete(listen);
    held.steer();
  };
  drive(options.control);
  listen(held.view);
  // It comes to a stream that may be still, with nothing to show until the next frame.
  const repaints = shared
    ? REPAINT_AFTER_MS.map((ms) => uiClock.after(ms, () => held.repaint()))
    : [];
  const cursorListeners = new Set<(cursor: ScreenCursor) => void>();
  const agentPointerListeners = new Set<(at: ScreenAgentPointer) => void>();
  return {
    send: (input) => held.send(input),
    control: drive,
    stats: () => held.stats,
    watchCursor(listener) {
      cursorListeners.add(listener);
      held.cursorListeners.add(listener);
      if (held.cursor) listener(held.cursor);
      return () => {
        cursorListeners.delete(listener);
        held.cursorListeners.delete(listener);
      };
    },
    watchAgentPointer(listener) {
      agentPointerListeners.add(listener);
      held.agentPointerListeners.add(listener);
      return () => {
        agentPointerListeners.delete(listener);
        held.agentPointerListeners.delete(listener);
      };
    },
    retry: () => held.retry(),
    setClipboard: (clip, paste) => held.setClipboard(clip, paste),
    onCopied(listener) {
      held.copiedListeners.add(listener);
      return () => void held.copiedListeners.delete(listener);
    },
    release() {
      for (const cancel of repaints) cancel();
      for (const listener of cursorListeners) held.cursorListeners.delete(listener);
      for (const listener of agentPointerListeners)
        held.agentPointerListeners.delete(listener);
      held.holders.delete(listen);
      drive(false);
      if (held.holders.size > 0 || streams.get(key) !== held) return;
      held.cancelClose = uiClock.after(LINGER_MS, () => {
        streams.delete(key);
        held.close();
      });
    },
  };
}

const targets = new Map<string, ScreenStreamTarget>();
const targetListeners = new Set<() => void>();
const subscribeTargets = (listener: () => void) => {
  targetListeners.add(listener);
  return () => void targetListeners.delete(listener);
};

/** What a source shows, the same wherever it shows: its app or the whole desktop. */
export function useScreenStreamTarget(
  sourceKey: string,
  initial: ScreenStreamTarget = "app"
): [target: ScreenStreamTarget, toggle: () => void] {
  const target = useSyncExternalStore(
    subscribeTargets,
    () => targets.get(sourceKey) ?? initial
  );
  const toggle = useCallback(() => {
    pinned.delete(sourceKey);
    targets.set(
      sourceKey,
      (targets.get(sourceKey) ?? initial) === "display" ? "app" : "display"
    );
    for (const listener of targetListeners) listener();
  }, [initial, sourceKey]);
  return [target, toggle];
}
