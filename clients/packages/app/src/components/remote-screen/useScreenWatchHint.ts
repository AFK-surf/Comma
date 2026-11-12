import { useCommaMessages } from "@comma/i18n/react";
import { uiClock, type CancelUiTimer } from "@comma/ui/clock";
import { useCallback, useEffect, useRef, useState } from "react";
import { screenControlRefusal } from "./screenFailure";

/** How long the hint stays, and how long after it a further press says nothing (going to Control starts it anew). */
const SHOWN_MS = 2600;
const QUIET_MS = 20_000;

/**
 * The brief word on a picture that only watches, said when it is pressed or typed on: a press every moment does not say
 * it every moment. Going to Control puts it away. It says what stands in the way of Control where something does: why
 * the computer refused it, until the person asks again (`asked`) or something else shows (`showing`), or the `notice`.
 */
export function useScreenWatchHint({
  control,
  canControl,
  notice,
  showing,
}: {
  control: boolean;
  canControl: boolean;
  notice: string | undefined;
  showing: string;
}) {
  const messages = useCommaMessages();
  const [shown, setShown] = useState(false);
  const [refusal, setRefusal] = useState<string>();
  useEffect(() => setRefusal(undefined), [showing]);
  const quietUntil = useRef<number | undefined>(undefined);
  const hide = useRef<CancelUiTimer | undefined>(undefined);
  const stop = useCallback(() => {
    hide.current?.();
    hide.current = undefined;
  }, []);
  const show = useCallback(() => {
    stop();
    quietUntil.current = uiClock.monotonic() + QUIET_MS;
    setShown(true);
    hide.current = uiClock.after(SHOWN_MS, () => setShown(false));
  }, [stop]);
  const nudge = useCallback(() => {
    const until = quietUntil.current;
    if (until === undefined || uiClock.monotonic() >= until) show();
  }, [show]);
  useEffect(() => {
    if (!control) return;
    stop();
    quietUntil.current = undefined;
    setShown(false);
  }, [control, stop]);
  useEffect(() => stop, [stop]);
  return {
    /** Why the computer would not be driven, while that stands. */
    refusal,
    /** The computer refused Control, in its own words: says why at once. */
    refused: (why: string) => {
      setRefusal(screenControlRefusal(why, messages));
      show();
    },
    /** The person asks for Control again. */
    asked: () => setRefusal(undefined),
    /** Control is what the person is being pointed to now. */
    attention: shown && canControl && !refusal,
    /** For the stage. */
    watching: {
      hint:
        refusal ??
        (canControl
          ? messages.remote_screen_watch_hint()
          : (notice ?? messages.remote_screen_watch_only())),
      shown,
      onInput: nudge,
    },
  };
}
