import { cx } from "../utils";

export const keycapSymbol = (key: string) => (key === "Space" ? "␣" : key);

export interface SettingsShortcutKeycapsProps {
  className?: string;
  keys: readonly string[];
}

export const SettingsShortcutKeycaps = ({
  className,
  keys,
}: SettingsShortcutKeycapsProps) => {
  if (keys.length === 0) return null;

  const accessibleName = `Keyboard shortcut: ${keys.join(" ")}`;

  return (
    <span
      aria-label={accessibleName}
      className={cx("settings-shortcut-keycaps", className)}
      data-slot="settings-keycaps"
    >
      <span aria-hidden="true" className="settings-shortcut__keycaps">
        {keys.map((key, index) => (
          <span
            className="settings-shortcut__keycap-shell"
            data-wide={keycapSymbol(key).length > 1 ? "true" : undefined}
            key={`${key}-${index}`}
          >
            <kbd className="settings-shortcut__keycap">{keycapSymbol(key)}</kbd>
          </span>
        ))}
      </span>
    </span>
  );
};
