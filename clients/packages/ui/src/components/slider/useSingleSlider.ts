import {
  useCallback,
  useRef,
  useState,
  type KeyboardEvent,
  type PointerEvent,
} from "react";
import { pointerRatio, valueToPercent } from "./slider-geometry";

const clamp = (value: number, min: number, max: number) =>
  Math.min(Math.max(value, min), max);

const snapToStep = (value: number, min: number, max: number, step: number) => {
  const steps = Math.round((value - min) / step);
  return clamp(min + steps * step, min, max);
};

type UseSingleSliderOptions = {
  min: number;
  max: number;
  step: number;
  value?: number;
  defaultValue: number;
  disabled?: boolean;
  onValueChange?: (value: number) => void;
};

export const useSingleSlider = ({
  min,
  max,
  step,
  value,
  defaultValue,
  disabled = false,
  onValueChange,
}: UseSingleSliderOptions) => {
  const [internalValue, setInternalValue] = useState(defaultValue);
  const trackRef = useRef<HTMLDivElement>(null);
  const isDraggingRef = useRef(false);
  const currentValue = value ?? internalValue;

  const updateValue = useCallback(
    (next: number) => {
      const snapped = snapToStep(next, min, max, step);
      if (!value) setInternalValue(snapped);
      onValueChange?.(snapped);
    },
    [max, min, onValueChange, step, value]
  );

  const getValueFromPointer = useCallback(
    (clientX: number) => {
      const track = trackRef.current;
      if (!track) return min;

      const ratio = pointerRatio(clientX, track.getBoundingClientRect());
      return snapToStep(min + ratio * (max - min), min, max, step);
    },
    [max, min, step]
  );

  const handleTrackPointerDown = (event: PointerEvent<HTMLDivElement>) => {
    if (disabled) return;
    isDraggingRef.current = true;
    event.currentTarget.setPointerCapture(event.pointerId);
    updateValue(getValueFromPointer(event.clientX));
  };

  const handlePointerMove = (event: PointerEvent<HTMLDivElement>) => {
    if (disabled || !isDraggingRef.current) return;
    updateValue(getValueFromPointer(event.clientX));
  };

  const handlePointerUp = (event: PointerEvent<HTMLDivElement>) => {
    if (!isDraggingRef.current) return;
    isDraggingRef.current = false;
    event.currentTarget.releasePointerCapture(event.pointerId);
  };

  const handleThumbKeyDown = (event: KeyboardEvent<HTMLButtonElement>) => {
    if (disabled) return;

    const delta =
      event.key === "ArrowRight" || event.key === "ArrowUp"
        ? step
        : event.key === "ArrowLeft" || event.key === "ArrowDown"
          ? -step
          : 0;
    if (!delta) return;

    event.preventDefault();
    updateValue(currentValue + delta);
  };

  const handleThumbPointerDown = (event: PointerEvent<HTMLButtonElement>) => {
    if (disabled || !trackRef.current) return;
    event.stopPropagation();
    isDraggingRef.current = true;
    trackRef.current.setPointerCapture(event.pointerId);
  };

  return {
    trackRef,
    currentValue,
    percent: valueToPercent(currentValue, min, max),
    handleTrackPointerDown,
    handlePointerMove,
    handlePointerUp,
    handleThumbKeyDown,
    handleThumbPointerDown,
  };
};
