export interface CommaDockLike {
  hide(): void;
  isVisible(): boolean;
  show(): Promise<void>;
}

export async function applyCommaDockVisibility({
  dock,
  visible,
}: {
  dock: CommaDockLike;
  visible: boolean;
}) {
  if (!visible) {
    dock.hide();
    return;
  }

  // Electron's `dock.show()` is not idempotent: while the app is active it
  // activates the Dock, re-registers the process as a foreground application
  // and activates Comma again. Leave an already visible tile alone.
  if (dock.isVisible()) return;

  await dock.show();
  // The bundle owns the icon, including system appearance changes. Setting a
  // raster image here would replace the Icon Composer rendition.
}
