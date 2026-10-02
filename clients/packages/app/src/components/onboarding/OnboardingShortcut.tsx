import { useCommaMessages } from "@comma/i18n/react";
import { Button, CircleInfoIcon, motionDuration } from "@comma/ui";
import { useEffect, useId, useLayoutEffect, useRef, useState } from "react";
import { OnboardingSwap } from "./OnboardingCard";
import { playKeysShake, playPartsEnter } from "./onboardingMotion";
import {
  onboardingShortcutKey,
  type OnboardingKeycap,
  type OnboardingKeycapId,
} from "./onboardingShortcutKeys";

type KeySet = ReadonlySet<OnboardingKeycapId>;
const noKeys: KeySet = new Set();

/** Each modifier of the shortcut, and whether a key event says it is held. */
const heldModifier = {
  alt: (event: KeyboardEvent) => event.altKey,
  control: (event: KeyboardEvent) => event.ctrlKey,
  meta: (event: KeyboardEvent) => event.metaKey,
  shift: (event: KeyboardEvent) => event.shiftKey,
} as const;

/**
 * The onboarding's last step, once the conversation has stepped back: the
 * Open Comma shortcut drawn as the keys of a Mac keyboard, and what it does.
 * Main suspends the shortcut while the onboarding window is open, so its keys
 * reach this page instead of opening Comma. Each key presses flat under the
 * user's finger while it is held and turns green once pressed. Neither the
 * order nor holding them together is checked: once every key has been
 * pressed the step is done (`onPressed`): every key is green, and the title
 * and its words turn into the success in place. Any other key says which
 * keys to press, without stacking; Tab, Escape, M (the sound) and keys aimed
 * at the onboarding's own controls keep their meaning.
 *
 * Skip, under the keys, goes on to the welcome page without them; it is the
 * one thing here that takes the pointer. The step is a group named by its
 * title and described by its words, with the shortcut spelled out; the note
 * and the success are announced politely.
 */
export function OnboardingShortcut({
  active,
  delay,
  keycaps,
  onPressed,
  onSkip,
  reducedMotion,
  takeFocus,
  together,
}: {
  /** The step is on; while the light clears it, its keys no longer listen. */
  active: boolean;
  /** How long the conversation takes to step back: the step arrives after it. */
  delay: number;
  /** The shortcut's keys, in the order macOS writes them. */
  keycaps: readonly OnboardingKeycap[];
  /** Every key of the shortcut has been pressed, in any order. */
  onPressed: () => void;
  /** Skip: on to the welcome page without the keys. */
  onSkip: () => void;
  reducedMotion: boolean;
  /** Moves the focus to `control`, as the onboarding does for each part. */
  takeFocus: (control: HTMLElement) => void;
  /** The keys' names joined as the reader's language joins them. */
  together: string;
}) {
  const messages = useCommaMessages();
  const titleId = useId();
  const eyebrowId = useId();
  const bodyId = useId();
  const instructionId = useId();
  const groupRef = useRef<HTMLFieldSetElement>(null);
  const keysRef = useRef<HTMLDivElement>(null);
  const names = keycaps.map(({ name }) => name);

  // Held now, and pressed at some point in this attempt.
  const [pressed, setPressed] = useState<KeySet>(noKeys);
  const [lit, setLit] = useState<KeySet>(noKeys);
  const litRef = useRef(lit);
  const [done, setDone] = useState(false);
  // The wrong-key note: its count re-announces a repeat without stacking.
  const [wrong, setWrong] = useState({ count: 0, shown: false });

  const latest = useRef({ keycaps, onPressed, reducedMotion });
  useLayoutEffect(() => {
    latest.current = { keycaps, onPressed, reducedMotion };
    litRef.current = lit;
  });

  // The parts arrive one after another once the conversation has stepped
  // back, once however often the effect runs.
  const arrived = useRef(false);
  useLayoutEffect(() => {
    const group = groupRef.current;
    if (!group || arrived.current) return;
    arrived.current = true;
    playPartsEnter(
      [...group.querySelectorAll<HTMLElement>("[data-onboarding-part]")],
      reducedMotion,
      {
        calm: true,
        delay,
        duration: motionDuration.onboardingIntroPartEnter,
        stagger: 3 * motionDuration.revealStagger,
      }
    );
  }, [delay, reducedMotion]);

  // The step then takes the focus, and only then do keys count: a Return
  // pressed to hurry Comma along is not a wrong key.
  const [armed, setArmed] = useState(false);
  useEffect(() => {
    const group = groupRef.current;
    if (!group || armed) return undefined;
    const timer = window.setTimeout(() => {
      takeFocus(group);
      setArmed(true);
    }, delay);
    return () => window.clearTimeout(timer);
  }, [armed, delay, takeFocus]);

  // The note that a wrong key was pressed leaves after a while; each wrong
  // key keeps it a while longer.
  useEffect(() => {
    if (!wrong.shown) return undefined;
    const timer = window.setTimeout(
      () => setWrong((current) => ({ ...current, shown: false })),
      motionDuration.onboardingKeyHint
    );
    return () => window.clearTimeout(timer);
  }, [wrong]);

  // Once done, keys going up still let go of their keys; nothing else counts.
  const listening = active && armed;
  useEffect(() => {
    if (!listening) return undefined;
    let held: KeySet = noKeys;
    // Every key pressed in this attempt, together or one after the other.
    let seen: KeySet = litRef.current;
    let finished = seen.size === latest.current.keycaps.length;
    const hold = (next: KeySet) => {
      held = next;
      setPressed(next);
      if (next.size === 0) return;
      seen = new Set([...seen, ...next]);
      setLit((current) =>
        [...next].every((id) => current.has(id))
          ? current
          : new Set([...current, ...next])
      );
    };
    // The modifiers held, as the event says, and the shortcut's key as it
    // went down or up.
    const holding = (event: KeyboardEvent, key: boolean) => {
      const next = new Set<OnboardingKeycapId>();
      for (const { id } of latest.current.keycaps) {
        if (id === "key" ? key : heldModifier[id](event)) next.add(id);
      }
      return next;
    };
    const keydown = (event: KeyboardEvent) => {
      if (finished) return;
      const { keycaps: keys, onPressed: pressedAll } = latest.current;
      const verdict = onboardingShortcutKey(event, keys, {
        onControl: aimedAtControl(event.target),
      });
      if (verdict.kind === "ignore") return;
      // The step's keys do nothing else here: M in the shortcut does not mute.
      event.preventDefault();
      if (verdict.kind === "wrong") {
        setWrong((current) => ({ count: current.count + 1, shown: true }));
        if (keysRef.current)
          playKeysShake(keysRef.current, latest.current.reducedMotion);
        return;
      }
      if (event.repeat) return;
      const next = holding(event, verdict.id === "key" || held.has("key"));
      hold(next);
      if (seen.size < keys.length) return;
      finished = true;
      setWrong((current) => ({ ...current, shown: false }));
      setDone(true);
      pressedAll();
    };
    const keyup = (event: KeyboardEvent) => {
      const keycap = latest.current.keycaps.find(({ codes }) =>
        codes.includes(event.code)
      );
      // macOS sends no key-up for other keys while ⌘ is held: ⌘ going up
      // lets everything go.
      if (event.key === "Meta") {
        hold(noKeys);
        return;
      }
      if (!keycap) return;
      hold(holding(event, keycap.id !== "key" && held.has("key")));
    };
    // The window lost the keyboard: nothing is held.
    const release = () => hold(noKeys);
    window.addEventListener("keydown", keydown, true);
    window.addEventListener("keyup", keyup, true);
    window.addEventListener("blur", release);
    document.addEventListener("visibilitychange", release);
    return () => {
      window.removeEventListener("keydown", keydown, true);
      window.removeEventListener("keyup", keyup, true);
      window.removeEventListener("blur", release);
      document.removeEventListener("visibilitychange", release);
    };
  }, [listening]);

  const shown = !done && wrong.shown ? "wrong" : "none";
  const wrongText = messages.onboarding_shortcut_wrong({ keys: together });

  return (
    <fieldset
      aria-describedby={`${eyebrowId} ${bodyId} ${instructionId}`}
      aria-labelledby={titleId}
      className="comma-onboarding-shortcut"
      ref={groupRef}
      tabIndex={-1}
    >
      <p
        className="comma-onboarding-shortcut__eyebrow"
        data-onboarding-part=""
        id={eyebrowId}
      >
        {messages.onboarding_shortcut_eyebrow()}
      </p>
      <h2
        className="comma-onboarding-shortcut__title"
        data-onboarding-part=""
        id={titleId}
      >
        <OnboardingSwap
          states={[
            {
              key: "try",
              label: messages.onboarding_shortcut_title({ keys: names.join(" + ") }),
            },
            { key: "done", label: messages.onboarding_shortcut_done_title() },
          ]}
          value={done ? "done" : "try"}
        />
      </h2>
      <p
        className="comma-onboarding-shortcut__body"
        data-onboarding-part=""
        id={bodyId}
      >
        <OnboardingSwap
          states={[
            { key: "try", label: messages.onboarding_shortcut_body() },
            { key: "done", label: messages.onboarding_shortcut_done_body() },
          ]}
          value={done ? "done" : "try"}
        />
      </p>
      <span className="app-sr-only" id={instructionId}>
        {messages.onboarding_shortcut_instruction({ keys: together })}
      </span>
      <div
        aria-hidden="true"
        className="comma-onboarding-shortcut__keys-part"
        data-onboarding-part=""
      >
        <div className="comma-onboarding-shortcut__keys" ref={keysRef}>
          {keycaps.map((keycap, index) => (
            <OnboardingKeycapView
              done={done}
              key={keycap.id}
              keycap={keycap}
              lit={lit.has(keycap.id)}
              pressed={pressed.has(keycap.id)}
              separated={index > 0}
            />
          ))}
        </div>
      </div>
      {/* Seen, it trades places in a slot that holds its height; heard, it
          is announced once per press from the status below. */}
      <span aria-hidden="true" className="comma-onboarding-shortcut__note">
        <OnboardingSwap
          states={[
            { key: "none", label: null },
            {
              key: "wrong",
              label: (
                <span className="comma-onboarding-shortcut__wrong">
                  <CircleInfoIcon />
                  {wrongText}
                </span>
              ),
            },
          ]}
          value={shown}
        />
      </span>
      <output className="app-sr-only">
        {done ? (
          messages.onboarding_shortcut_done_body()
        ) : shown === "wrong" ? (
          <span key={wrong.count}>{wrongText}</span>
        ) : null}
      </output>
      <div className="comma-onboarding-shortcut__actions" data-onboarding-part="">
        <Button
          className="comma-onboarding-shortcut__action"
          hierarchy="tertiary-gray"
          isDisabled={done}
          onPress={onSkip}
          size="md"
        >
          {messages.onboarding_shortcut_skip()}
        </Button>
      </div>
    </fieldset>
  );
}

/**
 * One key, drawn: a white face over its foot, the legend as the Mac
 * keyboard prints it. Held, it presses flat; pressed once, it is green.
 */
function OnboardingKeycapView({
  done,
  keycap,
  lit,
  pressed,
  separated,
}: {
  done: boolean;
  keycap: OnboardingKeycap;
  lit: boolean;
  pressed: boolean;
  separated: boolean;
}) {
  return (
    <>
      {separated ? <span className="comma-onboarding-shortcut__plus">+</span> : null}
      <span
        className="comma-onboarding-keycap"
        data-done={done || undefined}
        data-lit={lit || undefined}
        data-bar={keycap.bar || undefined}
        data-pressed={pressed || undefined}
        data-wide={keycap.wide || undefined}
      >
        {keycap.glyph ? (
          <>
            <span className="comma-onboarding-keycap__glyph">{keycap.glyph}</span>
            <span className="comma-onboarding-keycap__name">{keycap.label}</span>
          </>
        ) : keycap.bar ? (
          <span className="comma-onboarding-keycap__name">{keycap.label}</span>
        ) : (
          <span className="comma-onboarding-keycap__letter">{keycap.label}</span>
        )}
      </span>
    </>
  );
}

/**
 * Whether a key goes to one of the onboarding's own controls (Close, the
 * volume and its slider, the step's Skip) rather than to the step.
 */
function aimedAtControl(target: EventTarget | null) {
  return (
    target instanceof Element &&
    target.closest("button, input, select, textarea, a[href], [role='slider']") !== null
  );
}
