// The 画质 of a view of a computer's screen over the mesh, as still.fail's viewer has it (its apps/mbui
// sfpages/screen.mbt `screen_quality`, `ScreenSess::bounds`; screen_panel.mbt `screen_qualities`): 自动, 流畅, 高清 or
// 原画, one choice the core keeps with the account on this device (`screenQuality`). It sets the bounds the view asks,
// and goes to the station as `quality`, which sets how high its bit rate goes and whether its picture is made smaller
// for a slow link. A change opens the view anew (`holdScreenStream` keys a stream by it).
import { useCall, useTopic, type ScreenQuality } from "@comma/core-client";
import { useCallback } from "react";

/** The choices in the order the menu shows them: 自动 first (no `quality`). */
export const SCREEN_QUALITY_CHOICES = ["auto", "smooth", "hd", "original"] as const;
export type ScreenQualityChoice = (typeof SCREEN_QUALITY_CHOICES)[number];

/** The largest a view asks (still.fail's 原画): the source gives its largest size within it (an Android device's long side at most 2560, an X11 desktop at most 3840×2160). */
const WHOLE = { maxWidth: 7680, maxHeight: 4320 };

/**
 * The bounds a view asks at a 画质. 自动 asks what Cue's views always asked: a device's `side`, else nothing (the
 * station's 1920×1080). 流畅 1280×720 and 高清 1920×1080 (a device's long side at most 1280 or 1920, within its
 * `side`), 原画 the largest the source supports (WHOLE).
 */
export function screenQualityBounds(
  quality: ScreenQuality | undefined,
  side?: number
): { maxWidth?: number; maxHeight?: number } {
  if (quality === "original") return WHOLE;
  if (quality === undefined) return side ? { maxWidth: side, maxHeight: side } : {};
  const [long, short] = quality === "smooth" ? [1280, 720] : [1920, 1080];
  if (!side) return { maxWidth: long, maxHeight: short };
  const most = Math.min(side, long);
  return { maxWidth: most, maxHeight: most };
}

/** The 画质 chosen (undefined: 自动), and the choice. */
export function useScreenQuality(): [
  quality: ScreenQuality | undefined,
  choose: (quality: ScreenQuality | undefined) => void,
] {
  const { value } = useTopic({ topic: "screenQuality" });
  const call = useCall();
  const choose = useCallback(
    (quality: ScreenQuality | undefined) => {
      // A choice not kept (no account) leaves 自动; nothing to tell the person.
      void call("devices.chooseScreenQuality", { quality: quality ?? null }).catch(
        () => undefined
      );
    },
    [call]
  );
  return [value?.quality ?? undefined, choose];
}
