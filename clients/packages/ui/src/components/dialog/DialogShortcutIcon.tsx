import { cx } from "../utils";
import { DialogEnterIcon } from "./DialogShortcutIcons";
import { dialogShortcutKey, dialogShortcutKeyTone } from "./styles";
import type { DialogShortcut, DialogShortcutTone } from "./types";

type DialogShortcutIconProps = {
  shortcut: DialogShortcut;
  /** Chip palette. `onPrimary` is the white overlay used on brand-filled buttons. */
  tone?: DialogShortcutTone;
  className?: string;
};

/** Figma dialog footer shortcuts — keycaps rendered inside the action buttons. */
export const DialogShortcutIcon = ({
  shortcut,
  tone = "default",
  className,
}: DialogShortcutIconProps) => (
  <span
    aria-hidden
    className={cx(dialogShortcutKey, dialogShortcutKeyTone[tone], className)}
    data-slot="dialog-shortcut"
  >
    {shortcut === "esc" ? (
      "ESC"
    ) : (
      <DialogEnterIcon className="size-full translate-y-px" />
    )}
  </span>
);
