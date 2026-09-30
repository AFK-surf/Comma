export const telegramSettingsRoute = "/settings?category=channels";

export function telegramSettingsRouteForReturn(value: string): string {
  const workspace = new URL(value).searchParams.get("workspace_id");
  return workspace && /^wsp_[A-Za-z0-9_-]{1,128}$/.test(workspace)
    ? `${telegramSettingsRoute}&telegram-workspace=${encodeURIComponent(workspace)}`
    : telegramSettingsRoute;
}

/** This is a navigation hint only; Settings reads the canonical binding. */
export function isTelegramReturnUrl(value: string, expectedScheme: string): boolean {
  try {
    const url = new URL(value);
    return (
      url.protocol === `${expectedScheme}:` &&
      url.hostname === "telegram" &&
      url.pathname === "/return" &&
      !url.username &&
      !url.password &&
      !url.port
    );
  } catch {
    return false;
  }
}
