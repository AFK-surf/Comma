import { useId } from "react";
import { InputField } from "../input";
import { cx, definedProps } from "../utils";
import { DialogActions, DialogCloseButton } from "./DialogActions";
import {
  dialogContentGroup,
  dialogDescription,
  dialogHeader,
  dialogTitle,
} from "./styles";
import type { DialogPanelProps } from "./types";

interface DialogPanelInternalProps extends DialogPanelProps {
  titleId?: string;
  descriptionId?: string;
}

export const DialogPanel = ({
  title,
  description,
  titleId,
  descriptionId,
  showCloseButton = false,
  variant = "default",
  input,
  onClose,
  actions,
  children,
}: DialogPanelInternalProps) => {
  const instanceId = useId();
  const resolvedTitleId = titleId ?? `${instanceId}-title`;
  const resolvedDescriptionId = description
    ? (descriptionId ?? `${instanceId}-description`)
    : undefined;
  const body =
    variant === "input" && input ? (
      <InputField {...input} suppressFocusRing className="w-full" />
    ) : (
      children
    );

  return (
    <>
      {showCloseButton ? (
        <DialogCloseButton {...definedProps({ onPress: onClose })} />
      ) : null}
      <div className={dialogContentGroup}>
        <div className={cx(dialogHeader, showCloseButton && "pr-4xl")}>
          <h2 id={resolvedTitleId} className={dialogTitle}>
            {title}
          </h2>
          {description && (
            <p id={resolvedDescriptionId} className={dialogDescription}>
              {description}
            </p>
          )}
        </div>
        {body}
      </div>
      <DialogActions {...definedProps({ actions })} />
    </>
  );
};

export const dialogPanelShellClass = "relative w-dialog-default max-w-full";
