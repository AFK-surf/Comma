/**
 * Shared token-name formatting, used by both the CSS generator
 * and the Tailwind preset so emitted names always match.
 */
export const kebab = (value: string): string =>
  value
    .replace(/([a-z0-9])([A-Z])/g, "$1-$2")
    .replace(/([a-zA-Z])(\d)/g, "$1-$2")
    .toLowerCase();
