interface ImeKeyEventLike {
  isComposing?: boolean;
  keyCode?: number;
}

/**
 * Whether a keydown belongs to an IME composition. Chromium marks the key
 * that confirms a candidate with `isComposing`; WebKit ends the composition
 * before that keydown, so only its `keyCode` 229 still identifies it.
 */
export function isImeKeyEvent(event: ImeKeyEventLike): boolean {
  return event.isComposing === true || event.keyCode === 229;
}

const WEBKIT_COMPOSITION_CONFIRM_WINDOW_MS = 100;

/**
 * WebKit can deliver the confirming Enter after `compositionend` without the
 * IME markers above. Following ProseMirror's `inOrNearComposition`, swallow
 * one keydown shortly after `compositionend` in WebKit only. Chromium never
 * needs this: an Enter there after `compositionend` is a new key press (and
 * with a Korean IME, the Enter that the user meant to send).
 */
export function consumeWebKitImeConfirmation(lastCompositionEndAtRef: {
  current: number | null;
}): boolean {
  const endedAt = lastCompositionEndAtRef.current;
  if (endedAt === null || !isWebKitBrowser()) return false;
  if (Date.now() - endedAt >= WEBKIT_COMPOSITION_CONFIRM_WINDOW_MS) return false;
  lastCompositionEndAtRef.current = null;
  return true;
}

function isWebKitBrowser() {
  return typeof navigator !== "undefined" && /Apple Computer/.test(navigator.vendor);
}
