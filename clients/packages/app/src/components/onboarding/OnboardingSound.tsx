import { useCommaMessages } from "@comma/i18n/react";
import { getNativeBridge } from "@comma/native-bridge";
import { MediaVolumeControl, motionDuration } from "@comma/ui";
import { type RefObject, useCallback, useEffect, useRef, useState } from "react";
import clickSoundUrl from "./assets/onboarding-click.webm";
import introSoundUrl from "./assets/onboarding-intro.webm";

export type OnboardingSound = {
  /** The sound's element; the onboarding renders it. */
  audioRef: RefObject<HTMLAudioElement | null>;
  src: string;
  /** From 0, muted, to 1. */
  volume: number;
  setVolume: (volume: number) => void;
  /** Mutes, or brings back the volume the sound had before. */
  toggleMuted: () => void;
  /** A click, as Start and Start chatting are pressed. */
  click: () => void;
};

/**
 * Over half the Mac's output volume, the onboarding's sounds play 30%
 * quieter: they are meant to be heard, not to startle.
 */
const loudOutput = 0.5;
const loudOutputGain = 0.7;

/** A key that does not start sound in a browser that waits for the user. */
const passiveKeys = new Set([
  "Alt",
  "CapsLock",
  "Control",
  "Escape",
  "Fn",
  "Meta",
  "Shift",
]);

/**
 * The onboarding's sound. Its intro plays once, from the moment the screen
 * starts to dim (`play` as the onboarding mounts). The window that shows the
 * onboarding over the desktop lets it play by itself (Main's window options).
 * A browser that holds sound back until the user does something plays it
 * after their first press or key inside the onboarding instead; if that is
 * refused too, it stays silent. The volume and mute are the user's for this
 * onboarding only, and apply at once, to the intro and to the clicks alike.
 * As the onboarding exits (`ending`), the sound fades out with the light.
 *
 * Both play at the user's volume times a gain read once from the Mac's output
 * volume (`loudOutputGain` above `loudOutput`); the intro waits for that read,
 * which Main starts as it creates the window, so it never starts loud and then
 * drops. Where the volume cannot be read (the web) the gain is 1.
 */
export function useOnboardingSound({
  ending,
  play,
}: {
  ending: boolean;
  play: boolean;
}): OnboardingSound {
  const audioRef = useRef<HTMLAudioElement>(null);
  const [volume, setVolumeState] = useState(1);
  // The volume set last, and the last one with sound, which unmuting restores.
  const levels = useRef({ audible: 1, volume: 1 });
  const endingRef = useRef(ending);
  useEffect(() => {
    endingRef.current = ending;
  });

  const [gain, setGain] = useState<number>();
  const gainRef = useRef(1);
  useEffect(() => {
    let live = true;
    const settle = (next: number) => {
      gainRef.current = next;
      if (live) setGain(next);
    };
    getNativeBridge()
      .onboarding.outputVolume()
      .then(
        ({ volume: output }) =>
          settle(output !== null && output > loudOutput ? loudOutputGain : 1),
        () => settle(1)
      );
    return () => {
      live = false;
    };
  }, []);
  const gainKnown = gain !== undefined;

  // The click is its own element, loaded ahead so a press sounds at once.
  const clickRef = useRef<HTMLAudioElement>(undefined);
  useEffect(() => {
    const element = new Audio(clickSoundUrl);
    element.preload = "auto";
    clickRef.current = element;
    return () => {
      element.pause();
      clickRef.current = undefined;
    };
  }, []);
  const click = useCallback(() => {
    const element = clickRef.current;
    if (!element || levels.current.volume === 0) return;
    element.currentTime = 0;
    element.volume = levels.current.volume * gainRef.current;
    void Promise.resolve(element.play()).catch(() => undefined);
  }, []);

  const setVolume = useCallback((next: number) => {
    const value = Math.min(1, Math.max(0, next));
    levels.current.volume = value;
    if (value > 0) levels.current.audible = value;
    setVolumeState(value);
  }, []);
  const toggleMuted = useCallback(() => {
    const { audible, volume: current } = levels.current;
    setVolume(current > 0 ? 0 : audible);
  }, [setVolume]);

  useEffect(() => {
    const audio = audioRef.current;
    if (audio && !endingRef.current) audio.volume = volume * (gain ?? 1);
  }, [gain, volume]);

  useEffect(() => {
    const audio = audioRef.current;
    if (!play || !gainKnown || !audio) return undefined;
    const target = audio.ownerDocument;
    let active = true;
    let retry: number | undefined;
    const gestures = ["keydown", "pointerup"] as const;
    const stopWaiting = () => {
      for (const type of gestures) target.removeEventListener(type, onGesture, true);
    };
    const start = (waitForUser: boolean) => {
      let starting: Promise<void> | undefined;
      try {
        starting = audio.play();
      } catch {
        return;
      }
      void Promise.resolve(starting).catch((error: unknown) => {
        if (!active || !waitForUser) return;
        if (!(error instanceof DOMException) || error.name !== "NotAllowedError")
          return;
        for (const type of gestures) target.addEventListener(type, onGesture, true);
      });
    };
    // The press or key has made the page one the user acted on by the time
    // the next task runs, whichever event the browser counts it on.
    function onGesture(event: Event) {
      if (event instanceof KeyboardEvent && passiveKeys.has(event.key)) return;
      stopWaiting();
      retry = window.setTimeout(() => {
        if (active && !endingRef.current) start(false);
      }, 0);
    }
    start(true);
    return () => {
      active = false;
      stopWaiting();
      window.clearTimeout(retry);
      audio.pause();
    };
  }, [gainKnown, play]);

  // The sound fades out as the light lifts, and stops.
  useEffect(() => {
    const audio = audioRef.current;
    if (!ending || !audio || audio.paused) return undefined;
    const from = audio.volume;
    let startedAt: number | undefined;
    let frame = requestAnimationFrame(function fade(now) {
      // Counted from the first frame: a frame's time can precede this effect.
      startedAt ??= now;
      const progress = Math.min(1, (now - startedAt) / motionDuration.onboardingExit);
      audio.volume = from * (1 - progress) ** 2;
      if (progress < 1) frame = requestAnimationFrame(fade);
      else audio.pause();
    });
    return () => cancelAnimationFrame(frame);
  }, [ending]);

  return { audioRef, click, setVolume, src: introSoundUrl, toggleMuted, volume };
}

/**
 * The sound's volume, beside Close: the media player's volume control, as a
 * disc on the light field with its slider opening under it. When Close goes
 * (`alone`), the volume slides into its place, possibly under a still
 * pointer: its tooltip stays closed until that pointer moves.
 */
export function OnboardingSoundControl({
  alone,
  sound,
}: {
  alone: boolean;
  sound: OnboardingSound;
}) {
  const messages = useCommaMessages();
  const still = useStillPointerSince(alone);
  return (
    <MediaVolumeControl
      buttonClassName="comma-onboarding-corner-button"
      className="comma-onboarding-volume"
      labels={{
        muted: messages.onboarding_sound_muted(),
        mute: messages.onboarding_sound_mute(),
        popover: messages.onboarding_sound_controls(),
        slider: messages.onboarding_sound_slider(),
        unmute: messages.onboarding_sound_unmute(),
        volume: (percent) => messages.onboarding_sound_volume({ percent }),
      }}
      onToggleMuted={sound.toggleMuted}
      onVolumeChange={sound.setVolume}
      placement="bottom"
      popoverClassName="comma-onboarding-volume__popover"
      tone="dark"
      tooltipDisabled={still}
      volume={sound.volume}
    />
  );
}

/**
 * Whether the pointer has stayed where it was last pressed since `layout`
 * last changed. A browser reports a control that moved under a still pointer
 * as hovered, and may send a move at the same spot; neither is the user
 * pointing at it.
 */
function useStillPointerSince(layout: unknown) {
  const [seen, setSeen] = useState(layout);
  const [still, setStill] = useState(false);
  if (seen !== layout) {
    setSeen(layout);
    setStill(true);
  }
  const pressedAt = useRef<{ x: number; y: number }>(undefined);
  useEffect(() => {
    const record = (event: PointerEvent) => {
      pressedAt.current = { x: event.clientX, y: event.clientY };
    };
    document.addEventListener("pointerdown", record, true);
    document.addEventListener("pointerup", record, true);
    return () => {
      document.removeEventListener("pointerdown", record, true);
      document.removeEventListener("pointerup", record, true);
    };
  }, []);
  useEffect(() => {
    if (!still) return undefined;
    const move = (event: PointerEvent) => {
      const from = pressedAt.current;
      if (from && event.clientX === from.x && event.clientY === from.y) return;
      setStill(false);
    };
    document.addEventListener("pointermove", move, true);
    return () => document.removeEventListener("pointermove", move, true);
  }, [still]);
  return still;
}
