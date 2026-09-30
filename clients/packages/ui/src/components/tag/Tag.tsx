import { useCommaMessages } from "@comma/i18n/react";
import type { HTMLAttributes, ReactNode } from "react";
import { Button as AriaButton } from "react-aria-components";
import { XIcon } from "../icons";
import { cx } from "../utils";

export type TagSize = "sm" | "md" | "lg";
export type TagColor = "gray" | "brand" | "error" | "warning" | "success";

const colorClasses: Record<TagColor, string> = {
  gray: "bg-primary text-secondary border-primary",
  brand: "bg-utility-brand-50 text-utility-brand-700 border-utility-brand-200",
  error: "bg-utility-error-50 text-utility-error-700 border-utility-error-200",
  warning: "bg-utility-warning-50 text-utility-warning-700 border-utility-warning-200",
  success: "bg-utility-success-50 text-utility-success-700 border-utility-success-200",
};

const sizeClasses: Record<TagSize, string> = {
  sm: "px-2 py-0.5 text-xs gap-1",
  md: "px-2.5 py-0.5 text-sm gap-1",
  lg: "px-2.5 py-1 text-sm gap-1.5",
};

export interface TagProps extends HTMLAttributes<HTMLSpanElement> {
  size?: TagSize;
  color?: TagColor;
  onRemove?: () => void;
  children?: ReactNode;
}

export const Tag = ({
  size = "md",
  color = "gray",
  onRemove,
  className,
  children,
  ...rest
}: TagProps) => {
  const messages = useCommaMessages();
  return (
    <span
      className={cx(
        "inline-flex items-center rounded-md border font-medium",
        colorClasses[color],
        sizeClasses[size],
        className
      )}
      {...rest}
    >
      {children}
      {onRemove && (
        <AriaButton
          type="button"
          onPress={onRemove}
          aria-label={messages.common_remove()}
          className="rounded p-0.5 text-disabled outline-none hover:bg-secondary hover:text-tertiary focus-visible:shadow-focus-gray"
        >
          <XIcon className="size-3" />
        </AriaButton>
      )}
    </span>
  );
};
