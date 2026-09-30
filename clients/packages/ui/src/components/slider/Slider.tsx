import { useId } from "react";
import { cx, definedProps } from "../utils";
import { rangeFillLeft, rangeFillWidth, singleFillWidth } from "./slider-geometry";
import { SliderThumb } from "./SliderThumb";
import { labelPadding, type SliderLabelPosition } from "./styles";
import { useRangeSlider } from "./useRangeSlider";
import { useSingleSlider } from "./useSingleSlider";

export type { SliderLabelPosition };

type SliderBaseProps = {
  min?: number;
  max?: number;
  step?: number;
  formatValue?: (value: number) => string;
  disabled?: boolean;
  className?: string;
  id?: string;
};

export type SingleSliderProps = SliderBaseProps & {
  range?: false;
  value?: number;
  defaultValue?: number;
  onValueChange?: (value: number) => void;
};

export type RangeSliderProps = SliderBaseProps & {
  range: true;
  value?: [number, number];
  defaultValue?: [number, number];
  labelPosition?: SliderLabelPosition;
  onValueChange?: (value: [number, number]) => void;
};

export type SliderProps = SingleSliderProps | RangeSliderProps;

const SLIDER_WIDTH = "w-80 max-w-full";

const SingleSlider = ({
  min = 0,
  max = 100,
  step = 1,
  value,
  defaultValue = 50,
  formatValue = (current) => `${current}%`,
  disabled = false,
  className,
  id,
  onValueChange,
}: SingleSliderProps) => {
  const generatedId = useId();
  const sliderId = id ?? generatedId;

  const {
    trackRef,
    currentValue,
    percent,
    handleTrackPointerDown,
    handlePointerMove,
    handlePointerUp,
    handleThumbKeyDown,
    handleThumbPointerDown,
  } = useSingleSlider({
    min,
    max,
    step,
    defaultValue,
    disabled,
    ...definedProps({
      value,
      onValueChange,
    }),
  });

  return (
    <div
      id={sliderId}
      className={cx(
        "relative select-none py-2",
        SLIDER_WIDTH,
        disabled && "opacity-60",
        className
      )}
    >
      <div
        ref={trackRef}
        className={cx(
          "relative h-5 touch-none",
          disabled ? "cursor-not-allowed" : "cursor-pointer"
        )}
        onPointerDown={handleTrackPointerDown}
        onPointerMove={handlePointerMove}
        onPointerUp={handlePointerUp}
      >
        <div className="absolute left-0 right-0 top-1/2 h-1.5 -translate-y-1/2 rounded-full bg-secondary" />
        <div
          className="absolute left-0 top-1/2 h-1.5 -translate-y-1/2 rounded-full bg-brand-solid"
          style={{ width: singleFillWidth(percent) }}
        />
        <SliderThumb
          position={percent}
          value={currentValue}
          min={min}
          max={max}
          label={formatValue(currentValue)}
          labelPosition="none"
          ariaLabel="Slider value"
          disabled={disabled}
          onKeyDown={handleThumbKeyDown}
          onPointerDown={handleThumbPointerDown}
        />
      </div>
    </div>
  );
};

const RangeSlider = ({
  min = 0,
  max = 100,
  step = 1,
  value,
  defaultValue = [min, Math.min(min + Math.round((max - min) * 0.25), max)],
  labelPosition = "none",
  formatValue = (current) => `${current}%`,
  disabled = false,
  className,
  id,
  onValueChange,
}: RangeSliderProps) => {
  const generatedId = useId();
  const sliderId = id ?? generatedId;

  const {
    trackRef,
    currentValue,
    startPercent,
    endPercent,
    handleTrackPointerDown,
    handlePointerMove,
    handlePointerUp,
    handleThumbKeyDown,
    handleThumbPointerDown,
  } = useRangeSlider({
    min,
    max,
    step,
    defaultValue,
    disabled,
    ...definedProps({
      value,
      onValueChange,
    }),
  });

  const [startValue, endValue] = currentValue;

  return (
    <div
      id={sliderId}
      className={cx(
        "relative select-none",
        SLIDER_WIDTH,
        labelPadding[labelPosition],
        disabled && "opacity-60",
        className
      )}
    >
      <div
        ref={trackRef}
        className={cx(
          "relative h-5 touch-none",
          disabled ? "cursor-not-allowed" : "cursor-pointer"
        )}
        onPointerDown={handleTrackPointerDown}
        onPointerMove={handlePointerMove}
        onPointerUp={handlePointerUp}
      >
        <div className="absolute left-0 right-0 top-1/2 h-1.5 -translate-y-1/2 rounded-full bg-secondary" />
        <div
          className="absolute top-1/2 h-2 -translate-y-1/2 rounded-full bg-brand-solid"
          style={{
            left: rangeFillLeft(startPercent),
            width: rangeFillWidth(startPercent, endPercent),
          }}
        />
        <SliderThumb
          position={startPercent}
          value={startValue}
          min={min}
          max={max}
          label={formatValue(startValue)}
          labelPosition={labelPosition}
          ariaLabel="Minimum value"
          disabled={disabled}
          onKeyDown={handleThumbKeyDown("start")}
          onPointerDown={handleThumbPointerDown("start")}
        />
        <SliderThumb
          position={endPercent}
          value={endValue}
          min={min}
          max={max}
          label={formatValue(endValue)}
          labelPosition={labelPosition}
          ariaLabel="Maximum value"
          disabled={disabled}
          onKeyDown={handleThumbKeyDown("end")}
          onPointerDown={handleThumbPointerDown("end")}
        />
      </div>
    </div>
  );
};

export const Slider = (props: SliderProps) =>
  props.range ? <RangeSlider {...props} /> : <SingleSlider {...props} />;
