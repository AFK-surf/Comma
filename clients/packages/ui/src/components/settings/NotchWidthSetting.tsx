import { useCallback, useRef, type CSSProperties } from "react";
import { Button } from "../Button";
import { CommaLogoAnimation } from "../comma-mascot";
import { cx } from "../utils";
import {
  SettingsSliderField,
  type SettingsSliderFieldHandle,
} from "./SettingsSliderField";

/**
 * The compact Notch as NotchKit lays it out, in points. The physical notch is
 * a MacBook Pro's; the reader's own may differ by a few points.
 */
const notch = {
  width: 185,
  height: 32,
  /** NotchConfiguration.compactContentInsets. */
  inset: 8,
  /** The shell's top flare: compact corner radius 12 x top ratio 0.5. */
  shoulder: 6,
  /** The activity mark (20) and its spacing (10), ahead of the title. */
  mark: 30,
  /** Below this a title shows too few letters; NotchHost drops it too. */
  minimumTitle: 36,
} as const;

/**
 * Screen the preview shows at rest, in points. A Notch wider than this view
 * pulls the view back, the way a camera keeps its subject in frame, so the
 * whole shell and its content stay visible at every width.
 */
const restingViewPoints = 640;
/** Menu bar kept beside the widest Notch once the view pulls back. */
const viewMargin = 14;
const stageHeight = 120;

export interface NotchWidthSettingLabels {
  /** The slider's name, shown inside it. */
  width: string;
  reset: string;
  /** Shows the width on the real Notch once. */
  preview: string;
  /** Spoken value of the slider, such as "156 pt on each side". */
  valueText: (value: number) => string;
  /** The running Task title the preview shows beside the notch. */
  sampleTitle: string;
}

export interface NotchWidthSettingProps {
  /** Points the compact Notch reaches past each side of the physical notch. */
  value: number;
  defaultValue: number;
  min: number;
  max: number;
  disabled?: boolean;
  labels: NotchWidthSettingLabels;
  /** Called once a resize settles: on release, or after arrow keys stop. */
  onValueCommit: (value: number) => void;
  /** Shows a width on the real Notch; without it there is no such action. */
  onPreview?: (value: number) => void;
  className?: string;
}

/**
 * Live preview of the compact Notch over a menu bar, sized by a slider field
 * beneath it (SettingsSliderField). The field paints the preview each frame,
 * so no React render runs while it moves.
 */
export const NotchWidthSetting = ({
  value,
  defaultValue,
  min,
  max,
  disabled = false,
  labels,
  onValueCommit,
  onPreview,
  className,
}: NotchWidthSettingProps) => {
  const screenRef = useRef<HTMLDivElement>(null);
  const shellRef = useRef<HTMLDivElement>(null);
  const fieldRef = useRef<SettingsSliderFieldHandle>(null);

  const paint = useCallback((width: number) => {
    const screen = screenRef.current;
    const shell = shellRef.current;
    if (!screen || !shell) return;

    const outer = (width + notch.inset) * 2 + notch.width;
    shell.style.width = `calc(${outer} * var(--notch-pt))`;
    const view = String(
      Math.max(restingViewPoints, outer + 2 * (notch.shoulder + viewMargin))
    );
    if (screen.style.getPropertyValue("--notch-view-points") !== view) {
      screen.style.setProperty("--notch-view-points", view);
    }
    const titled = width - notch.mark >= notch.minimumTitle ? "true" : "false";
    if (shell.dataset.titled !== titled) shell.dataset.titled = titled;
  }, []);

  return (
    <div
      className={cx("comma-notch-width", className)}
      data-disabled={disabled ? "true" : undefined}
      data-slot="notch-width-setting"
      style={
        {
          "--notch-stage-ratio": `${restingViewPoints} / ${stageHeight}`,
        } as CSSProperties
      }
    >
      <div aria-hidden="true" className="comma-notch-width__stage">
        <div className="comma-notch-width__screen" ref={screenRef}>
          <div className="comma-notch-width__window">
            <span className="comma-notch-width__lights">
              <span />
              <span />
              <span />
            </span>
          </div>
          <div className="comma-notch-width__menubar">
            <span className="comma-notch-width__menus">
              <span className="comma-notch-width__glyph" />
              <span className="comma-notch-width__menu" data-app="true" />
              <span className="comma-notch-width__menu" />
              <span className="comma-notch-width__menu" />
              <span className="comma-notch-width__menu" />
              <span className="comma-notch-width__menu" />
              <span className="comma-notch-width__menu" />
            </span>
            <span className="comma-notch-width__status">
              <span className="comma-notch-width__glyph" />
              <span className="comma-notch-width__glyph" />
              <span className="comma-notch-width__glyph" data-battery="true" />
              <span className="comma-notch-width__menu" data-clock="true" />
            </span>
          </div>
          <div className="comma-notch-width__shell" data-titled="true" ref={shellRef}>
            <span className="comma-notch-width__leading">
              <CommaLogoAnimation className="comma-notch-width__mark" size={14} />
              <span className="comma-notch-width__title">{labels.sampleTitle}</span>
            </span>
            <span className="comma-notch-width__camera" />
            <span className="comma-notch-width__count">1</span>
          </div>
        </div>
      </div>

      <SettingsSliderField
        defaultValue={defaultValue}
        disabled={disabled}
        label={labels.width}
        max={max}
        min={min}
        onPaint={paint}
        onValueCommit={onValueCommit}
        resetLabel={labels.reset}
        handleRef={fieldRef}
        {...(onPreview
          ? {
              trailing: (
                <Button
                  disabled={disabled}
                  hierarchy="secondary-gray"
                  // The real Notch shows the width the reader sees here, saved first.
                  onPress={() => {
                    const field = fieldRef.current;
                    if (field) onPreview(field.settledValue());
                  }}
                  size="sm"
                >
                  {labels.preview}
                </Button>
              ),
            }
          : {})}
        value={value}
        valueText={labels.valueText}
      />
    </div>
  );
};
