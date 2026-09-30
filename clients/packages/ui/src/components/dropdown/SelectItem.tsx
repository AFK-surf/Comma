import { useContext } from "react";
import type { ListBoxItemProps as AriaListBoxItemProps } from "react-aria-components";
import {
  ListBoxItem as AriaListBoxItem,
  Text as AriaText,
} from "react-aria-components";
import { CheckIcon } from "../icons";
import { menuItemGutterClasses, menuItemRowChromeClasses } from "../menu/styles";
import { cx, definedProps } from "../utils";
import {
  SelectContext,
  type SelectItemType,
  SelectRowContent,
  selectRowHeightClassName,
} from "./select-primitives";

type SelectItemProps = Omit<AriaListBoxItemProps<SelectItemType>, "id"> &
  SelectItemType;

export const SelectItem = ({
  label,
  subtitle,
  id,
  isDisabled,
  fontFamily,
  leading,
  className,
  children,
  ...props
}: SelectItemProps) => {
  const { size, virtualized } = useContext(SelectContext);
  const text = label ?? (typeof children === "string" ? children : "");

  return (
    <AriaListBoxItem
      id={id}
      textValue={text}
      {...definedProps({ isDisabled })}
      {...props}
      className={(state) =>
        cx(
          "w-full outline-none",
          menuItemGutterClasses,
          typeof className === "function" ? className(state) : className
        )
      }
      data-slot="dropdown-option"
    >
      {(state) => (
        <div
          className={cx(
            "flex cursor-pointer items-center text-sm text-secondary outline-none select-none",
            virtualized ? "w-full" : "w-max min-w-full",
            menuItemRowChromeClasses,
            (state.isFocusVisible || (state.isHovered && !state.isSelected)) &&
              "bg-secondary",
            state.isSelected && "text-primary",
            state.isDisabled && "cursor-not-allowed opacity-50",
            selectRowHeightClassName[size]
          )}
          data-slot="dropdown-option-content"
        >
          <SelectRowContent
            className="w-full"
            indicator={
              <CheckIcon
                className={cx(
                  "size-5 text-fg-brand-primary transition-[opacity,filter,transform] duration-200 ease-[cubic-bezier(0.2,0,0,1)]",
                  state.isSelected
                    ? "opacity-100 blur-0 scale-100"
                    : "opacity-0 blur-[4px] scale-[0.25]"
                )}
              />
            }
            leading={leading}
            label={
              <>
                <AriaText
                  slot="label"
                  className={cx(
                    "block",
                    virtualized ? "truncate" : "whitespace-nowrap",
                    subtitle && "leading-4"
                  )}
                  data-slot="dropdown-option-label"
                  {...definedProps({ style: fontFamily ? { fontFamily } : undefined })}
                >
                  {label ?? children}
                </AriaText>
                {subtitle && (
                  <AriaText
                    slot="description"
                    className="block max-w-72 truncate text-xs leading-4 text-tertiary"
                    data-slot="dropdown-option-subtitle"
                    title={subtitle}
                  >
                    {subtitle}
                  </AriaText>
                )}
              </>
            }
          />
        </div>
      )}
    </AriaListBoxItem>
  );
};
