import { isReducedMotionEnabled, subscribeToReducedMotion } from "@comma/ui";
import { useSyncExternalStore } from "react";

const serverSnapshot = () => false;

/** The OS preference or Comma's own reduced-motion setting, kept current. */
export function useReducedMotion() {
  return useSyncExternalStore(
    subscribeToReducedMotion,
    isReducedMotionEnabled,
    serverSnapshot
  );
}
