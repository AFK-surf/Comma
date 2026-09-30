import type { ReactNode, Ref } from "react";
import type { LabelProps as AriaLabelProps } from "react-aria-components";
import { Label as AriaLabel } from "react-aria-components";
import { cx } from "../utils";

type LabelProps = AriaLabelProps & {
  children: ReactNode;
  isInvalid?: boolean;
  isRequired?: boolean;
  ref?: Ref<HTMLLabelElement>;
};

export const Label = ({ isInvalid, isRequired, className, ...props }: LabelProps) => (
  <AriaLabel
    data-label="true"
    {...props}
    className={cx(
      "flex cursor-default items-center gap-0.5 text-sm font-medium text-secondary",
      className
    )}
  >
    {props.children}
    <span
      aria-hidden="true"
      className={cx(
        "hidden text-fg-brand-primary",
        isRequired && "block",
        typeof isRequired === "undefined" && "group-required:block",
        isInvalid && "text-error-primary",
        typeof isInvalid === "undefined" && "group-invalid:text-error-primary"
      )}
    >
      *
    </span>
  </AriaLabel>
);
