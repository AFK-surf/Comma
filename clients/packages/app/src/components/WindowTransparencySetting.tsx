import { useCallback } from "react";
import { SettingsSliderField } from "@comma/ui/components/settings";
import { defaultCommaClientAppearancePreferences } from "@comma/native-bridge";
import { useCommaMessages } from "@comma/i18n/react";
import { commaWindowTransparencyProperty, useCommaAppearance } from "./commaAppearance";

const percent = (value: number) => `${value}%`;

/**
 * How much of the macOS window material shows through the window color: the
 * content under Appearance's translucent window switch. A drag previews on
 * the page root only. Every settings write restyles the whole app and
 * persists through Main to every window, so the value commits once the drag
 * is released or arrow keys stop.
 */
export function WindowTransparencySetting() {
  const m = useCommaMessages();
  const { setWindowTransparency, windowTransparency } = useCommaAppearance();

  const preview = useCallback((value: number) => {
    const shown = percent(Math.round(Math.min(100, Math.max(0, value))));
    const root = document.documentElement;
    if (root.style.getPropertyValue(commaWindowTransparencyProperty) !== shown) {
      root.style.setProperty(commaWindowTransparencyProperty, shown);
    }
  }, []);

  return (
    <SettingsSliderField
      defaultValue={defaultCommaClientAppearancePreferences.windowTransparency}
      formatValue={percent}
      keyPageStep={10}
      keyStep={1}
      label={m.settings_window_transparency()}
      max={100}
      min={0}
      onPaint={preview}
      onValueCommit={setWindowTransparency}
      resetLabel={m.settings_window_transparency_reset()}
      value={windowTransparency}
      valueText={percent}
    />
  );
}
