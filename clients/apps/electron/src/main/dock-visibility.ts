export interface CommaDockLike {
  hide(): void;
  isVisible(): boolean;
  show(): Promise<void>;
}

export async function applyCommaDockVisibility({
  dock,
  restoreIcon,
  visible,
}: {
  dock: CommaDockLike;
  restoreIcon(): void;
  visible: boolean;
}) {
  if (!visible) {
    dock.hide();
    return;
  }

  // Electron's `dock.show()` is not idempotent: while the app is active it
  // activates the Dock, re-registers the process as a foreground application
  // and activates Comma again. That re-registration rebuilds the Dock tile from
  // the bundle icon asynchronously, which drops the Comma icon set through
  // `dock.setIcon()` and races the restore below. Every launch with the
  // preference enabled went through it although the tile was already there.
  if (dock.isVisible()) return;

  await dock.show();
  // macOS may restore Electron's default icon after a hidden Dock tile returns.
  restoreIcon();
}
