/** One viewer input event on the stream's `input` data channel. `x` and `y` are fractions of the video frame. */
export type ScreenStreamInput =
  | { type: "move"; x: number; y: number; mods: Modifier[] }
  | {
      type: "down" | "up";
      x: number;
      y: number;
      button: 0 | 1 | 2;
      clicks: number;
      mods: Modifier[];
    }
  | { type: "scroll"; x: number; y: number; dx: number; dy: number; mods: Modifier[] }
  | { type: "keydown" | "keyup"; code: string; mods: Modifier[] };

type Modifier = "shift" | "ctrl" | "alt" | "meta";

type Keys = { shiftKey: boolean; ctrlKey: boolean; altKey: boolean; metaKey: boolean };
type Point = { clientX: number; clientY: number };
type Box = { left: number; top: number; width: number; height: number };

export function modifiers(event: Keys): Modifier[] {
  const mods: Modifier[] = [];
  if (event.shiftKey) mods.push("shift");
  if (event.ctrlKey) mods.push("ctrl");
  if (event.altKey) mods.push("alt");
  if (event.metaKey) mods.push("meta");
  return mods;
}

/**
 * Where a pointer is in the picture, as fractions of it. The video element
 * letterboxes a picture whose shape differs from its own, so the fractions
 * are of the picture inside the element, clamped to its edges.
 */
export function pictureFraction(
  point: Point,
  element: Box,
  picture: { width: number; height: number }
): { x: number; y: number } {
  if (
    !(
      picture.width > 0 &&
      picture.height > 0 &&
      element.width > 0 &&
      element.height > 0
    )
  )
    return { x: 0, y: 0 };
  const scale = Math.min(
    element.width / picture.width,
    element.height / picture.height
  );
  const width = picture.width * scale;
  const height = picture.height * scale;
  const left = element.left + (element.width - width) / 2;
  const top = element.top + (element.height - height) / 2;
  return {
    x: clamp((point.clientX - left) / width),
    y: clamp((point.clientY - top) / height),
  };
}

/** The wire's button: 0 primary, 1 secondary, 2 middle. DOM numbers the last two the other way. */
export function wireButton(button: number): 0 | 1 | 2 {
  return button === 2 ? 1 : button === 1 ? 2 : 0;
}

function clamp(value: number) {
  return Math.min(1, Math.max(0, value));
}
