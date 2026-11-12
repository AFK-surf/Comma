import { SettingsSliderField } from "@comma/ui/components/settings";
import { defaultCommaClientAppearancePreferences } from "@comma/native-bridge";
import { useCommaMessages } from "@comma/i18n/react";
import {
  useCommaAppearance,
  useCommaWindowTransparencyTarget,
} from "./commaAppearance";

const percent = (value: number) => `${value}%`;

/**
 * How much of the macOS window material shows through the window color: the
 * content under Appearance's translucent window switch. A drag previews on the
 * window's shell only, which restyles the shell alone. A settings write
 * persists through Main to every window, so the value commits once the drag
 * is released or arrow keys stop.
 */
export function WindowTransparencySetting() {
  const m = useCommaMessages();
  const { setWindowTransparency, windowTransparency } = useCommaAppearance();
  const { preview } = useCommaWindowTransparencyTarget();

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
