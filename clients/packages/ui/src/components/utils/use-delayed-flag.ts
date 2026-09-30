import { useEffect, useState } from "react";

/**
 * True only once `active` has held for `delayMs`, and false the moment it
 * clears. A loading state that resolves in a few milliseconds — a cached read,
 * an immediate error — would otherwise paint a placeholder for one frame and
 * take it away again, which reads as a flicker rather than as feedback.
 */
export const useDelayedFlag = (active: boolean, delayMs: number) => {
  const [raised, setRaised] = useState(false);

  useEffect(() => {
    if (!active) {
      setRaised(false);
      return undefined;
    }
    const timer = setTimeout(() => setRaised(true), delayMs);
    return () => clearTimeout(timer);
  }, [active, delayMs]);

  return raised && active;
};
