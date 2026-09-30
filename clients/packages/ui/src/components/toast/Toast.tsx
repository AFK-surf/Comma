import { cx, definedProps } from "../utils";
import { ToastActions, ToastCloseButton } from "./ToastActions";
import {
  ToastErrorIcon,
  ToastGaugeIcon,
  ToastInfoIcon,
  ToastSuccessIcon,
  ToastWarningIcon,
} from "./ToastIcons";
import {
  toastDescription,
  toastRowGap,
  toastShellBase,
  toastShellVariant,
  toastStatusIcon,
  toastTitleMd,
  toastTitleSmAction,
} from "./styles";
import type { ToastGlyph, ToastIntent, ToastProps } from "./types";

const intentIcon = {
  error: ToastErrorIcon,
  info: ToastInfoIcon,
  success: ToastSuccessIcon,
  warning: ToastWarningIcon,
} satisfies Record<ToastIntent, unknown>;

const intentColor: Record<ToastIntent, string> = {
  error: "text-fg-error-primary",
  info: "text-toast-icon-primary",
  success: "text-fg-success-primary",
  warning: "text-fg-warning-primary",
};

const glyphIcon = { gauge: ToastGaugeIcon } satisfies Record<ToastGlyph, unknown>;

const ToastStatusIcon = ({
  icon,
  intent,
}: {
  icon?: ToastGlyph;
  intent: ToastIntent;
}) => {
  const Icon = icon ? glyphIcon[icon] : intentIcon[intent];
  return <Icon className={cx(toastStatusIcon, intentColor[intent])} />;
};

export const Toast = ({
  title,
  description,
  variant = "single",
  intent = variant === "action" ? "success" : "info",
  icon,
  onClose,
  actions,
  className,
  testId,
}: ToastProps) => {
  const shellClass = cx(toastShellBase, toastShellVariant[variant], className);
  const shellTestId = testId ? { "data-testid": testId } : {};

  if (variant === "action") {
    return (
      <output aria-live="polite" className={shellClass} {...shellTestId}>
        <div className="flex w-full flex-col">
          <div className={cx("flex w-full items-center", toastRowGap)}>
            <ToastStatusIcon {...definedProps({ icon })} intent={intent} />
            <p className={cx("min-w-0 flex-1", toastTitleSmAction)}>{title}</p>
            <ToastCloseButton {...definedProps({ onPress: onClose })} />
          </div>
          {description && (
            <div className={cx("flex w-full items-center", toastRowGap)}>
              <span className={cx(toastStatusIcon, "shrink-0")} aria-hidden />
              <p className={cx("min-w-0 flex-1", toastDescription)}>{description}</p>
            </div>
          )}
        </div>
        <ToastActions {...definedProps({ actions })} />
      </output>
    );
  }

  if (variant === "description") {
    return (
      <output aria-live="polite" className={shellClass} {...shellTestId}>
        <div className={cx("flex w-full items-start", toastRowGap)}>
          <ToastStatusIcon {...definedProps({ icon })} intent={intent} />
          <div className="flex min-w-0 flex-1 flex-col items-start gap-xxs">
            <p className={toastTitleMd}>{title}</p>
            {description && <p className={toastDescription}>{description}</p>}
          </div>
          <ToastCloseButton {...definedProps({ onPress: onClose })} />
        </div>
      </output>
    );
  }

  return (
    <output aria-live="polite" className={shellClass} {...shellTestId}>
      <div className={cx("flex w-full items-center", toastRowGap)}>
        <ToastStatusIcon {...definedProps({ icon })} intent={intent} />
        <p className={cx("min-w-0 flex-1", toastTitleMd)}>{title}</p>
        <ToastCloseButton {...definedProps({ onPress: onClose })} />
      </div>
    </output>
  );
};
