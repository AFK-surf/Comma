import type { ReactNode, Ref } from "react";
import type { TextProps as AriaTextProps } from "react-aria-components";
import { Text as AriaText } from "react-aria-components";
import { cx } from "../utils";

type HintTextProps = AriaTextProps & {
  isInvalid?: boolean;
  ref?: Ref<HTMLElement>;
  size?: "sm" | "md";
  children: ReactNode;
};

export const HintText = ({
  isInvalid,
  className,
  size = "md",
  ...props
}: HintTextProps) => (
  <AriaText
    {...props}
    slot={isInvalid ? "errorMessage" : "description"}
    className={cx(
      "text-sm text-tertiary",
      size === "sm" && "text-xs",
      isInvalid && "text-error-primary",
      "group-invalid:text-error-primary",
      className
    )}
  />
);
