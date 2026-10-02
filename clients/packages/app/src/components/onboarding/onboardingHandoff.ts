import { useEffect, useRef } from "react";

/**
 * "Start chatting" hands the user from the onboarding to Home's composer. The
 * onboarding host announces it once the onboarding has left this window: on
 * the web after the overlay's exit, in Electron when Main reports that the
 * onboarding window has closed and the main window has the focus back.
 *
 * Only a Home mounted at that moment answers; nothing waits for a later one.
 * Start chatting is the onboarding's one way out (Skip setup leads to it); an
 * onboarding window the user closes by hand (⌘W) ends without a hand-off.
 */
const listeners = new Set<() => void>();

export function announceOnboardingHandoff() {
  for (const listener of listeners) listener();
}

/** Calls the latest `onHandoff` at each hand-off while the caller is mounted. */
export function useOnboardingHandoff(onHandoff: () => void) {
  const latest = useRef(onHandoff);
  useEffect(() => {
    latest.current = onHandoff;
  });
  useEffect(() => {
    const listener = () => latest.current();
    listeners.add(listener);
    return () => {
      listeners.delete(listener);
    };
  }, []);
}
