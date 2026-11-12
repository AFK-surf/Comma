import { useCommaMessages } from "@comma/i18n/react";
import { useCallback, useRef, useState } from "react";
import { isDeviceTarget, type HeldScreenStreamView } from "./remoteScreenStream";
import { screenFailureKind, screenIsLocked } from "./screenFailure";
import type { ScreenStreamTarget } from "./ScreenStreamStage";

/**
 * What a screen shows and whether it may be driven, for whatever holds its stage. `dropControl` runs when what it shows
 * can no longer be driven: taking Control back takes the person's say.
 */
export function useScreenStreamShows({
  target,
  appName,
  deviceName,
  dropControl,
}: {
  target: ScreenStreamTarget;
  appName: string | undefined;
  /** A device's name, where it shows one of the computer's devices. */
  deviceName?: string | undefined;
  dropControl(): void;
}) {
  const messages = useCommaMessages();
  const [showing, setShowing] = useState<HeldScreenStreamView["target"]>();
  const [gone, setGone] = useState(false);
  const drop = useRef(dropControl);
  drop.current = dropControl;
  const onTarget = useCallback((next: HeldScreenStreamView["target"]) => {
    setShowing(next);
    if (next && (next.windows === 0 || screenIsLocked(next.apps))) drop.current();
  }, []);
  const onFailure = useCallback((failure: string | undefined) => {
    const left = screenFailureKind(failure) === "app-gone";
    setGone(left);
    if (left) drop.current();
  }, []);
  // A picture of something else is another thing to drive: that takes the person's say.
  const forget = () => {
    dropControl();
    setShowing(undefined);
    setGone(false);
  };
  const locked = target === "app" && screenIsLocked(showing?.apps);
  const title: string =
    deviceName ??
    (target === "display"
      ? messages.remote_screen_desktop()
      : (appName ??
        (locked ? undefined : showing?.apps.join(", ")) ??
        messages.remote_screen_app()));
  // An app is driven only by its name: until it is known, what Control would drive is not.
  const named =
    isDeviceTarget(target) ||
    target === "display" ||
    appName !== undefined ||
    showing !== undefined;
  const noWindow = target === "app" && showing?.windows === 0;
  const notice: string | undefined = locked
    ? messages.remote_screen_locked()
    : noWindow
      ? messages.remote_screen_no_window({ app: title })
      : undefined;
  return {
    locked,
    title,
    notice,
    canControl: named && !noWindow && !gone && !locked,
    forget,
    stage: {
      onTarget,
      onFailure,
    },
  };
}
