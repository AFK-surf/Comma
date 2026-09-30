import type { ReactNode } from "react";
import { PlaceholderIcon } from "../icons";
import { cx } from "../utils";

export interface ButtonGroupItem {
  id: string;
  label?: string;
  icon?: ReactNode;
  dot?: boolean;
  disabled?: boolean;
}

export interface ButtonGroupProps {
  items: ButtonGroupItem[];
  value?: string;
  defaultValue?: string;
  onChange?: (id: string) => void;
  className?: string;
}

export const ButtonGroup = ({
  items,
  value,
  defaultValue,
  onChange,
  className,
}: ButtonGroupProps) => {
  const selected = value ?? defaultValue ?? items[0]?.id;

  return (
    <fieldset
      className={cx(
        "m-0 inline-flex min-w-0 overflow-hidden rounded-md border border-primary p-0 shadow-xs",
        className
      )}
    >
      {items.map((item) => {
        const isCurrent = item.id === selected;

        return (
          <button
            key={item.id}
            type="button"
            disabled={item.disabled}
            aria-pressed={isCurrent}
            onClick={() => onChange?.(item.id)}
            className={cx(
              "inline-flex min-h-10 items-center justify-center gap-2 border-r border-primary px-4 py-2 text-sm font-semibold transition-colors last:border-r-0",
              "focus-visible:z-10 focus-visible:shadow-focus-gray-shadow-xs focus:outline-none",
              isCurrent
                ? "bg-secondary text-primary"
                : "bg-primary text-secondary hover:bg-secondary",
              item.disabled && "cursor-not-allowed text-disabled hover:bg-primary"
            )}
          >
            {item.dot && (
              <span
                aria-hidden
                className="size-2 shrink-0 rounded-full bg-fg-success-primary"
              />
            )}
            {item.icon && !item.dot && <span className="shrink-0">{item.icon}</span>}
            {item.label}
            {item.icon && item.label === undefined && !item.dot && (
              <PlaceholderIcon className="size-5" />
            )}
          </button>
        );
      })}
    </fieldset>
  );
};
