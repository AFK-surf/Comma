export interface MainWindowLike {
  focus(): void;
  isDestroyed(): boolean;
  isMinimized(): boolean;
  restore(): void;
  show(): void;
  showInactive(): void;
}

export async function openOrCreateMainWindow({
  createWindow,
  activate = true,
  window,
}: {
  activate?: boolean;
  createWindow(): Promise<void>;
  window: MainWindowLike | undefined;
}) {
  if (!window || window.isDestroyed()) {
    await createWindow();
    return;
  }

  if (window.isMinimized()) window.restore();
  if (activate) {
    window.show();
    window.focus();
  } else {
    window.showInactive();
  }
}
