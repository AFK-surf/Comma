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

type UseRangeSliderOptions = {
  min: number;
  max: number;
  step: number;
  value?: [number, number];
  defaultValue: [number, number];
  disabled?: boolean;
  onValueChange?: (value: [number, number]) => void;
};

export const useRangeSlider = ({
  min,
  max,
  step,
  value,
  defaultValue,
  disabled = false,
  onValueChange,
}: UseRangeSliderOptions) => {
  const [internalValue, setInternalValue] = useState<[number, number]>(defaultValue);
  const trackRef = useRef<HTMLDivElement>(null);
  const activeThumbRef = useRef<"start" | "end" | null>(null);
  const currentValue = value ?? internalValue;

  const updateValue = useCallback(
    (next: [number, number]) => {
      const sorted: [number, number] = [
        Math.min(next[0], next[1]),
        Math.max(next[0], next[1]),
      ];
      if (!value) setInternalValue(sorted);
      onValueChange?.(sorted);
    },
    [onValueChange, value]
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

  const setThumbValue = useCallback(
    (thumb: "start" | "end", nextValue: number) => {
      const [start, end] = currentValue;

      if (thumb === "start") {
        updateValue([Math.min(nextValue, end), end]);
        return;
      }

      updateValue([start, Math.max(nextValue, start)]);
    },
    [currentValue, updateValue]
  );

  const handleTrackPointerDown = (event: PointerEvent<HTMLDivElement>) => {
    if (disabled) return;

    const nextValue = getValueFromPointer(event.clientX);
    const [start, end] = currentValue;
    const distanceToStart = Math.abs(nextValue - start);
    const distanceToEnd = Math.abs(nextValue - end);
    const thumb = distanceToStart <= distanceToEnd ? "start" : "end";

    activeThumbRef.current = thumb;
    event.currentTarget.setPointerCapture(event.pointerId);
    setThumbValue(thumb, nextValue);
  };

  const handlePointerMove = (event: PointerEvent<HTMLDivElement>) => {
    if (disabled || !activeThumbRef.current) return;
    setThumbValue(activeThumbRef.current, getValueFromPointer(event.clientX));
  };

  const handlePointerUp = (event: PointerEvent<HTMLDivElement>) => {
    if (!activeThumbRef.current) return;
    activeThumbRef.current = null;
    event.currentTarget.releasePointerCapture(event.pointerId);
  };

  const handleThumbKeyDown =
    (thumb: "start" | "end") => (event: KeyboardEvent<HTMLButtonElement>) => {
      if (disabled) return;

      const delta =
        event.key === "ArrowRight" || event.key === "ArrowUp"
          ? step
          : event.key === "ArrowLeft" || event.key === "ArrowDown"
            ? -step
            : 0;
      if (!delta) return;

      event.preventDefault();
      const current = thumb === "start" ? currentValue[0] : currentValue[1];
      setThumbValue(thumb, snapToStep(current + delta, min, max, step));
    };

  const handleThumbPointerDown =
    (thumb: "start" | "end") => (event: PointerEvent<HTMLButtonElement>) => {
      if (disabled || !trackRef.current) return;
      event.stopPropagation();
      activeThumbRef.current = thumb;
      trackRef.current.setPointerCapture(event.pointerId);
    };

  const startPercent = valueToPercent(currentValue[0], min, max);
  const endPercent = valueToPercent(currentValue[1], min, max);

  return {
    trackRef,
    currentValue,
    startPercent,
    endPercent,
    handleTrackPointerDown,
    handlePointerMove,
    handlePointerUp,
    handleThumbKeyDown,
    handleThumbPointerDown,
  };
};
