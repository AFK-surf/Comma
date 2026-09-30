import { useCallback, useLayoutEffect, useRef } from "react";

export function useOutgoingAnimationCompletion(
  onOutgoingAnimationComplete: ((launchId: number) => void) | undefined
) {
  const onOutgoingAnimationCompleteRef = useRef(onOutgoingAnimationComplete);

  useLayoutEffect(() => {
    onOutgoingAnimationCompleteRef.current = onOutgoingAnimationComplete;
  }, [onOutgoingAnimationComplete]);

  return useCallback((launchId: number) => {
    onOutgoingAnimationCompleteRef.current?.(launchId);
  }, []);
}
