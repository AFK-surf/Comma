import { useEffect, useSyncExternalStore } from "react";

/**
 * Whether the first-launch onboarding covers this window's product. The
 * product stays mounted under it, so for as long as it is open:
 * - the app's shortcuts and application-menu commands stand down, because
 *   they would open or navigate surfaces the user cannot see;
 * - Home holds back its workspace feedback, because the onboarding reports
 *   workspace preparation itself. What still applies shows once it closes.
 *
 * The in-window overlay holds it while mounted, its exit included. Where the
 * onboarding runs in a window of its own, the product window holds it for as
 * long as that window is open. Listeners hear only when the answer flips.
 */
let holders = 0;
const listeners = new Set<() => void>();

const setHolders = (next: number) => {
  const wasOpen = holders > 0;
  holders = next;
  if (wasOpen === holders > 0) return;
  for (const listener of listeners) listener();
};

export const isOnboardingOpen = () => holders > 0;

export function subscribeOnboardingOpen(listener: () => void) {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

export const useOnboardingOpen = () =>
  useSyncExternalStore(subscribeOnboardingOpen, isOnboardingOpen);

/** Holds the onboarding open until the returned release runs; releasing twice is a no-op. */
export function holdOnboardingOpen(): () => void {
  let held = true;
  setHolders(holders + 1);
  return () => {
    if (!held) return;
    held = false;
    setHolders(holders - 1);
  };
}

/** Holds the onboarding open, in the sense above, while `open` and the caller is mounted. */
export function useHoldOnboardingOpen(open = true) {
  useEffect(() => (open ? holdOnboardingOpen() : undefined), [open]);
}
