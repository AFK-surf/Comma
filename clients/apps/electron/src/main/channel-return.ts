export const channelSettingsRoute = "/settings?category=channels";

/** The channels whose connect flow returns to Comma by `<scheme>://<channel>/return`. */
const returnChannels = new Set(["telegram", "linear"]);

/** This is a navigation hint only; Settings reads the canonical binding. */
export function isChannelReturnUrl(value: string, expectedScheme: string): boolean {
  try {
    const url = new URL(value);
    return (
      url.protocol === `${expectedScheme}:` &&
      returnChannels.has(url.hostname) &&
      url.pathname === "/return" &&
      !url.username &&
      !url.password &&
      !url.port
    );
  } catch {
    return false;
  }
}
