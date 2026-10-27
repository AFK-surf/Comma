import { useCall, useTopic } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { getNativeBridge } from "@comma/native-bridge";
import { uiClock } from "@comma/ui/clock";
import { CallIcon, MicrophoneOffIcon } from "@comma/ui/components/icons";
import { toast } from "@comma/ui/components/toast";
import { cx } from "@comma/ui/components/utils";
import {
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type PointerEvent as ReactPointerEvent,
} from "react";
import { createPortal } from "react-dom";
import { Button as AriaButton } from "react-aria-components";
import { CommaProductMark } from "../CommaProductMark";
import { useOptionalCommaClientSettings } from "../commaClientSettings";
import { useRouterDisplayName } from "../router-identity/RouterIdentityProvider";
import { CallAudio } from "./callAudio";
import "./desktopCall.css";

// The desktop's call to the Router (Settings › Debug › Voice labs): a phone button at the top right of Home's chat, and
// while a call is up, a card there with the Router, "Calling…" or the time talked, mute and hang up. The core runs the
// call (voice-call.ts); Main holds its socket; this window plays and records its audio (callAudio.ts).

/** Whether this app can call the Router: the desktop, with voice labs on. */
export function useDesktopCallEnabled(): boolean {
  const settings = useOptionalCommaClientSettings();
  return (
    getNativeBridge().platform === "electron" && settings?.voiceLabsEnabled === true
  );
}

/** The call, while one is dialled or up; null otherwise (and without voice labs). */
export function useDesktopCall() {
  const enabled = useDesktopCallEnabled();
  const { value } = useTopic(enabled ? { topic: "voiceCall" } : null);
  return value && value.phase !== "idle" ? value : null;
}

/** The phone button and the call card, for Home's chat of `workspaceId`. */
export function HomeCallControl({ workspaceId }: { workspaceId: string | undefined }) {
  const m = useCommaMessages();
  const enabled = useDesktopCallEnabled();
  const call = useCall();
  const { value: voiceCall } = useTopic(enabled ? { topic: "voiceCall" } : null);
  const { value: voice } = useTopic(
    enabled && workspaceId ? { topic: "voice", prefer: workspaceId } : null
  );
  const ready = voice?.integration?.readiness.ready === true;
  if (!enabled || !voiceCall?.available) return null;
  if (voiceCall.phase !== "idle") return <CallCardAt />;
  if (!workspaceId || !ready) return null;
  return (
    <div className="comma-call-anchor">
      <AriaButton
        aria-label={m.voice_call_start()}
        className="comma-call-button comma-icon-press"
        data-testid="voice-call-start"
        onPress={() => {
          void call("voiceCall.start", { workspace: workspaceId }).catch(() =>
            toast.error(m.voice_call_failed())
          );
        }}
      >
        <CallIcon aria-hidden className="size-5" />
      </AriaButton>
    </div>
  );
}

/**
 * The card floats over the window from the phone button's corner, outside the chat's own clipping, so it can be
 * dragged anywhere in the window.
 */
function CallCardAt() {
  const anchor = useRef<HTMLDivElement>(null);
  const [corner, setCorner] = useState<{ top: number; right: number } | null>(null);
  useLayoutEffect(() => {
    const element = anchor.current;
    if (!element) return;
    const rect = element.getBoundingClientRect();
    setCorner({
      top: rect.top,
      right: element.ownerDocument.documentElement.clientWidth - rect.right,
    });
  }, []);
  return (
    <div className="comma-call-anchor" ref={anchor}>
      {corner
        ? createPortal(
            <div
              className="comma-call-float"
              style={{ top: corner.top, right: corner.right }}
            >
              <CallCard />
            </div>,
            anchor.current!.ownerDocument.body
          )
        : null}
    </div>
  );
}

function CallCard() {
  const m = useCommaMessages();
  const call = useCall();
  const routerName = useRouterDisplayName();
  const voiceCall = useDesktopCall();
  const elapsed = useElapsed(voiceCall?.connectedAt ?? null);
  const drag = useCardDrag();
  if (!voiceCall) return null;
  const muted = voiceCall.muted;
  return (
    <div
      className="comma-call-card"
      data-phase={voiceCall.phase}
      data-testid="voice-call-card"
      {...drag}
    >
      <div className="comma-call-card-who">
        <span aria-hidden className="comma-call-card-avatar">
          <CommaProductMark />
        </span>
        <div className="min-w-0">
          <div className="comma-call-card-name">{routerName}</div>
          <div className="comma-call-card-status" data-testid="voice-call-status">
            {voiceCall.phase === "connected" && elapsed !== null
              ? formatElapsed(elapsed)
              : m.voice_call_calling()}
          </div>
        </div>
      </div>
      <div className="comma-call-card-actions">
        <AriaButton
          aria-label={muted ? m.voice_call_unmute() : m.voice_call_mute()}
          aria-pressed={muted}
          className={cx("comma-call-card-mute", muted && "comma-call-card-mute-on")}
          data-testid="voice-call-mute"
          onPress={() => void call("voiceCall.setMuted", { muted: !muted })}
        >
          {/* The phones' mute key: the crossed microphone, lit while muted. */}
          <MicrophoneOffIcon aria-hidden className="size-5" />
        </AriaButton>
        <AriaButton
          aria-label={m.voice_call_end()}
          className="comma-call-card-end"
          data-testid="voice-call-end"
          onPress={() => void call("voiceCall.end", {})}
        >
          <CallIcon aria-hidden className="comma-call-hang-up-icon size-5" />
        </AriaButton>
      </div>
    </div>
  );
}

const clamp = (value: number, min: number, max: number) =>
  Math.min(Math.max(value, min), Math.max(min, max));

/**
 * The card follows the pointer from anywhere but its buttons, and stays inside the window. Each call's card starts at
 * the top right (a new card is a new call).
 */
function useCardDrag() {
  const [offset, setOffset] = useState({ x: 0, y: 0 });
  const grab = useRef<{
    pointer: number;
    startX: number;
    startY: number;
    from: { x: number; y: number };
    min: { x: number; y: number };
    max: { x: number; y: number };
  } | null>(null);
  return {
    style: { transform: `translate(${offset.x}px, ${offset.y}px)` },
    onPointerDown: (event: ReactPointerEvent<HTMLDivElement>) => {
      if (event.button !== 0 || (event.target as Element).closest("button")) return;
      const card = event.currentTarget.getBoundingClientRect();
      const view = event.currentTarget.ownerDocument.documentElement;
      // Where the card would be without the offset: its moves are bounded by the window around that.
      const left = card.left - offset.x;
      const top = card.top - offset.y;
      grab.current = {
        pointer: event.pointerId,
        startX: event.clientX,
        startY: event.clientY,
        from: offset,
        min: { x: -left, y: -top },
        max: {
          x: view.clientWidth - card.width - left,
          y: view.clientHeight - card.height - top,
        },
      };
      // The card keeps the pointer even when it moves faster than the card.
      event.currentTarget.setPointerCapture?.(event.pointerId);
    },
    onPointerMove: (event: ReactPointerEvent<HTMLDivElement>) => {
      const held = grab.current;
      if (!held || held.pointer !== event.pointerId) return;
      setOffset({
        x: clamp(held.from.x + event.clientX - held.startX, held.min.x, held.max.x),
        y: clamp(held.from.y + event.clientY - held.startY, held.min.y, held.max.y),
      });
    },
    onPointerUp: (event: ReactPointerEvent<HTMLDivElement>) => {
      if (grab.current?.pointer === event.pointerId) grab.current = null;
    },
    onPointerCancel: () => {
      grab.current = null;
    },
  };
}

/** Seconds since `since` (epoch ms), counted each second; null without a start. */
export function useElapsed(since: number | null): number | null {
  const [now, setNow] = useState(() => uiClock.now());
  useEffect(() => {
    if (since === null) return undefined;
    setNow(uiClock.now());
    return uiClock.every(1_000, () => setNow(uiClock.now()));
  }, [since]);
  return since === null ? null : Math.max(0, Math.floor((now - since) / 1_000));
}

const pad = (n: number) => String(n).padStart(2, "0");

export function formatElapsed(seconds: number): string {
  const minutes = Math.floor(seconds / 60);
  return minutes >= 60
    ? `${Math.floor(minutes / 60)}:${pad(minutes % 60)}:${pad(seconds % 60)}`
    : `${pad(minutes)}:${pad(seconds % 60)}`;
}

/**
 * The call's speaker and microphone in this window: on from Main's start to its stop, muted as the call says. Mounted
 * once per main window, so the call keeps its audio whatever page is shown; turning voice labs off ends the call.
 */
export function DesktopCallAudio() {
  const enabled = useDesktopCallEnabled();
  const call = useDesktopCall();
  const callApi = useCall();
  const endCall = useRef(() => callApi("voiceCall.end", {}));
  endCall.current = () => callApi("voiceCall.end", {});
  const muted = call?.muted ?? false;
  const [audio, setAudio] = useState<CallAudio | null>(null);

  useEffect(() => {
    if (!enabled) return undefined;
    const bridge = getNativeBridge();
    if (bridge.platform !== "electron") return undefined;
    let current: CallAudio | null = null;
    const stop = () => {
      current?.stop();
      current = null;
      setAudio(null);
    };
    const unsubscribe = bridge.voiceCall.onAudio((event) => {
      switch (event.kind) {
        case "start": {
          stop();
          const next = new CallAudio({
            microphone: (pcm) =>
              void bridge.voiceCall.microphone(pcm).catch(() => undefined),
            played: (name) =>
              void bridge.voiceCall.played({ name }).catch(() => undefined),
          });
          current = next;
          setAudio(next);
          void next.start().catch(() => {
            // No microphone (refused or missing): the call cannot be heard, so it ends.
            if (current === next) void endCall.current().catch(() => undefined);
          });
          return;
        }
        case "audio":
          current?.play(event.pcm);
          return;
        case "mark":
          current?.mark(event.name);
          return;
        case "clear":
          current?.clear();
          return;
        case "stop":
          stop();
          return;
      }
    });
    return () => {
      unsubscribe();
      stop();
      // Voice labs turned off (or the window gone): with no card and no audio left, the call itself ends.
      void endCall.current().catch(() => undefined);
    };
  }, [enabled]);

  useEffect(() => {
    audio?.setMuted(muted);
  }, [audio, muted]);

  return null;
}
