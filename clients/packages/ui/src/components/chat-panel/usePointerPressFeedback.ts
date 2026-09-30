import {
  type FocusEventHandler,
  type KeyboardEventHandler,
  type PointerEventHandler,
  useCallback,
} from "react";

export const usePointerPressFeedback = <T extends HTMLElement>() => {
  const onPointerDown = useCallback<PointerEventHandler<T>>((event) => {
    if (!event.isPrimary || event.button !== 0) return;
    event.currentTarget.dataset.pointerPressed = "true";
  }, []);

  const clearPointerPress = useCallback<PointerEventHandler<T>>((event) => {
    delete event.currentTarget.dataset.pointerPressed;
  }, []);
  const clearPointerPressOnBlur = useCallback<FocusEventHandler<T>>((event) => {
    delete event.currentTarget.dataset.pointerPressed;
  }, []);
  const clearPointerPressOnKeyDown = useCallback<KeyboardEventHandler<T>>((event) => {
    delete event.currentTarget.dataset.pointerPressed;
  }, []);

  return {
    "data-no-press-feedback": true,
    onBlurCapture: clearPointerPressOnBlur,
    onKeyDownCapture: clearPointerPressOnKeyDown,
    onPointerCancel: clearPointerPress,
    onPointerDown,
    onPointerLeave: clearPointerPress,
    onPointerUp: clearPointerPress,
  } as const;
};
