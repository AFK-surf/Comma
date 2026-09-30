import {
  type FocusEventHandler,
  type KeyboardEventHandler,
  useCallback,
  useEffect,
  useRef,
} from "react";

const keyboardFocusMotionAttribute = "keyboardFocusMotion";

export const useKeyboardFocusMotion = () => {
  const animationFramesRef = useRef<number[]>([]);

  const cancelScheduledReset = useCallback(() => {
    for (const frame of animationFramesRef.current) cancelAnimationFrame(frame);
    animationFramesRef.current = [];
  }, []);

  useEffect(() => cancelScheduledReset, [cancelScheduledReset]);

  const onFocusCapture = useCallback<FocusEventHandler<HTMLElement>>(
    (event) => {
      cancelScheduledReset();
      const target = event.target;
      if (target instanceof HTMLElement && target.matches(":focus-visible")) {
        event.currentTarget.dataset[keyboardFocusMotionAttribute] = "instant";
        return;
      }
      delete event.currentTarget.dataset[keyboardFocusMotionAttribute];
    },
    [cancelScheduledReset]
  );

  const onBlurCapture = useCallback<FocusEventHandler<HTMLElement>>(
    (event) => {
      const owner = event.currentTarget;
      const nextTarget = event.relatedTarget;
      if (nextTarget instanceof Node && owner.contains(nextTarget)) return;
      if (owner.dataset[keyboardFocusMotionAttribute] !== "instant") return;

      cancelScheduledReset();
      const firstFrame = requestAnimationFrame(() => {
        const secondFrame = requestAnimationFrame(() => {
          delete owner.dataset[keyboardFocusMotionAttribute];
          animationFramesRef.current = [];
        });
        animationFramesRef.current = [secondFrame];
      });
      animationFramesRef.current = [firstFrame];
    },
    [cancelScheduledReset]
  );

  const onKeyDownCapture = useCallback<KeyboardEventHandler<HTMLElement>>(
    (event) => {
      if (event.key !== "Tab") return;
      cancelScheduledReset();
      event.currentTarget.dataset[keyboardFocusMotionAttribute] = "instant";
    },
    [cancelScheduledReset]
  );

  return { onBlurCapture, onFocusCapture, onKeyDownCapture };
};
