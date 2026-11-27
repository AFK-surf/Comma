import { useCommaMessages } from "@comma/i18n/react";
import type { HTMLAttributes, ReactNode } from "react";
import { Button as AriaButton } from "react-aria-components";
import { XIcon } from "../icons";
import { cx } from "../utils";

export type TagSize = "sm" | "md" | "lg";
export type TagColor = "gray" | "brand" | "error" | "warning" | "success";

const colorClasses: Record<TagColor, string> = {
  gray: "border border-primary bg-primary text-secondary",
  brand:
    "bg-[color:var(--comma-badge-brand-bg)] text-[color:var(--comma-badge-brand-fg)]",
  error: "bg-[color:var(--comma-badge-error-bg)] text-utility-error-700",
  warning: "bg-[color:var(--comma-badge-warning-bg)] text-utility-warning-700",
  success: "bg-[color:var(--comma-badge-success-bg)] text-utility-success-700",
};

const sizeClasses: Record<TagSize, string> = {
  sm: "px-2 py-0.5 text-xs leading-4 gap-1",
  md: "px-2.5 py-0.5 text-xs leading-[18px] gap-1",
  lg: "px-2.5 py-1 text-sm leading-5 gap-1.5",
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
        "inline-flex items-center rounded-[5px] whitespace-nowrap font-medium",
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
