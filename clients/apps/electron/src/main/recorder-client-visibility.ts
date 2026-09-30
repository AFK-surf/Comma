import type { BrowserWindow } from "electron";

/** Reconcile native visibility commands and lifecycle events into the host. */
export function bindRecorderClientVisibility(
  window: Pick<
    BrowserWindow,
    | "isDestroyed"
    | "isVisible"
    | "isMinimized"
    | "show"
    | "showInactive"
    | "hide"
    | "minimize"
    | "restore"
  > & {
    on(
      event: "show" | "restore" | "hide" | "minimize" | "closed",
      listener: () => void
    ): unknown;
  },
  publish: (visible: boolean) => void,
  isCurrent: () => boolean = () => true
) {
  const update = (visible: boolean) => {
    if (isCurrent()) publish(visible && !window.isDestroyed());
  };
  // RecorderVisibility.tla Show/Hide maps to MeetingRecorder.tla Visibility:
  // shown/restored versus hidden/minimized/closed.
  // isVisible() can still report the old occlusion state inside a show callback.
  window.on("show", () => update(true));
  window.on("restore", () => update(true));
  window.on("hide", () => update(false));
  window.on("minimize", () => update(false));
  window.on("closed", () => update(false));
  const reconcile = () =>
    update(!window.isDestroyed() && window.isVisible() && !window.isMinimized());
  // RecorderVisibility.tla Command: completion can occur without its event.
  // Reconcile only after the real command returns; system-driven changes still
  // use the listeners above. No timer, synthetic event, or focus fallback.
  for (const method of [
    "show",
    "showInactive",
    "hide",
    "minimize",
    "restore",
  ] as const) {
    const invoke = window[method].bind(window);
    window[method] = () => {
      invoke();
      reconcile();
    };
  }
  reconcile();
}
