import logoAnimationMarkup from "virtual:comma-logo-animation-markup";
import "./mainWindowBoot.css";

const bootId = "comma-main-window-boot";

/**
 * No application imports: this is the main window's first paint. It shows the
 * logo animation until the first Session screen replaces it.
 */
export function showMainWindowBoot() {
  // Every window loads this document. Read the role from the preload global:
  // loading the bridge module here would delay the paint.
  if (globalThis.commaNative?.self.role !== "main-window") return;

  const boot = document.createElement("div");
  boot.id = bootId;
  boot.className = "comma-main-window-boot";
  // Until the application applies its appearance, the window background
  // follows the system theme. Resolve the logo colour against the same theme.
  boot.dataset.theme = matchMedia("(prefers-color-scheme: dark)").matches
    ? "Dark mode"
    : "Light mode";
  boot.setAttribute("aria-hidden", "true");
  // The PageLoading mark, one size step larger.
  const mark = document.createElement("span");
  mark.className = "size-9 shrink-0 text-disabled";
  // Build-time markup of the logo animation component, not external input.
  mark.innerHTML = logoAnimationMarkup;
  boot.append(mark);
  document.body.append(boot);
}

export function dismissMainWindowBoot() {
  document.getElementById(bootId)?.remove();
}
