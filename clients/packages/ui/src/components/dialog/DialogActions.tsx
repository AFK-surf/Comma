import { useContext } from "react";
import { Button } from "../Button";
import { OverlayTriggerStateContext } from "react-aria-components";
import { XIcon } from "../icons";
import { definedProps } from "../utils";
import { DialogShortcutIcon } from "./DialogShortcutIcon";
import {
  dialogActionButton,
  dialogActionsRow,
  dialogActionsRowSplit,
  dialogActionsTrailingGroup,
  dialogCloseButton,
  dialogCloseButtonStyle,
} from "./styles";
import type { DialogAction, DialogShortcut, DialogShortcutTone } from "./types";

export const resolveShortcut = (action: DialogAction): DialogShortcut | undefined => {
  if (action.shortcut === false) return undefined;
  if (action.shortcut) return action.shortcut;

  if (action.hierarchy === "secondary-gray") return "esc";
  if (action.hierarchy === "primary" || action.hierarchy === "destructive")
    return "enter";
  return undefined;
};

/** Brand-filled buttons carry the white keycap; everything else the gray one. */
const resolveShortcutTone = (action: DialogAction): DialogShortcutTone =>
  action.hierarchy === "primary" || action.hierarchy === "destructive"
    ? "onPrimary"
    : "default";

const DialogActionButton = ({ action }: { action: DialogAction }) => {
  const overlayState = useContext(OverlayTriggerStateContext);
  const shortcut = resolveShortcut(action);

  const handlePress = () => {
    if (action.onPress) {
      action.onPress();
      return;
    }

    overlayState?.close();
  };

  return (
    <Button
      type="button"
      className={dialogActionButton}
      hierarchy={action.hierarchy ?? "secondary-gray"}
      size="md"
      {...definedProps({
        disabled: action.disabled,
        onPress: handlePress,
        adornmentTrailing: shortcut ? (
          <DialogShortcutIcon shortcut={shortcut} tone={resolveShortcutTone(action)} />
        ) : undefined,
      })}
    >
      {action.label}
    </Button>
  );
};

export const DialogCloseButton = ({ onPress }: { onPress?: () => void }) => (
  <Button
    {...definedProps({ onPress })}
    aria-label="Close dialog"
    className={dialogCloseButton}
    hierarchy="tertiary-gray"
    iconLeading={<XIcon />}
    iconOnly
    size="md"
    style={dialogCloseButtonStyle}
  />
);

export const DialogActions = ({ actions }: { actions?: DialogAction[] }) => {
  if (!actions?.length) return null;

  if (actions.length >= 3) {
    const leading = actions[0];
    const trailing = actions.slice(1);

    if (!leading) return null;

    return (
      <div className={dialogActionsRowSplit}>
        <DialogActionButton action={leading} />
        <div className={dialogActionsTrailingGroup}>
          {trailing.map((action) => (
            <DialogActionButton key={action.label} action={action} />
          ))}
        </div>
      </div>
    );
  }

  return (
    <div className={dialogActionsRow}>
      {actions.map((action) => (
        <DialogActionButton key={action.label} action={action} />
      ))}
    </div>
  );
};
