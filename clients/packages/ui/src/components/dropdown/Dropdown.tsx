import { useCommaMessages } from "@comma/i18n/react";
import { useContext, useMemo, useRef, type ReactNode, type Ref } from "react";
import { mergeRefs } from "react-aria";
import type { Key } from "react-aria-components";
import {
  Button as AriaButton,
  ListBox as AriaListBox,
  ListBoxLoadMoreItem as AriaListBoxLoadMoreItem,
  ListBoxSection as AriaListBoxSection,
  Header as AriaHeader,
  Select as AriaSelect,
  SelectStateContext as AriaSelectStateContext,
  SelectValue as AriaSelectValue,
  Separator as AriaSeparator,
} from "react-aria-components";
import { ChevronDownIcon, LoadingCircleIcon } from "../icons";
import { menuItemGutterClasses, menuItemRowChromeClasses } from "../menu/styles";
import { HintText, Label } from "../form";
import { cx, definedProps } from "../utils";
import {
  SelectContext,
  type SelectItemType,
  SelectPopover,
  SelectRowContent,
  selectRowHeightClassName,
} from "./select-primitives";
import { SelectItem } from "./SelectItem";

export interface DropdownItem {
  id: string;
  label: string;
  subtitle?: string;
  disabled?: boolean;
  /** CSS font-family for the label, so a font option previews its face. */
  fontFamily?: string;
  leading?: ReactNode;
  separatorBefore?: boolean;
  group?: string;
}

export interface DropdownProps {
  label?: string;
  hint?: string;
  placeholder?: string;
  items: DropdownItem[];
  value?: string;
  defaultValue?: string;
  onChange?: (id: string) => void;
  onOpenChange?: (isOpen: boolean) => void;
  isOpen?: boolean;
  size?: "xs" | "sm" | "md";
  disabled?: boolean;
  destructive?: boolean;
  className?: string;
  contentAlign?: "start" | "end";
  width?: "default" | "content";
  ariaLabel?: string;
  triggerRef?: Ref<HTMLButtonElement | null>;
  /** Shows a loading row after the options while more are on the way. */
  loading?: boolean;
  /**
   * Renders only the rows in view, for a flat list of hundreds of options
   * (no groups or separators). Rows take the trigger's width, so give the
   * trigger a fixed width.
   */
  virtualized?: boolean;
}

interface DropdownTriggerContentProps {
  isLabelFluid: boolean;
  items: SelectItemType[];
  placeholder: string;
}

const DropdownTriggerContent = ({
  isLabelFluid,
  items,
  placeholder,
}: DropdownTriggerContentProps) => {
  const state = useContext(AriaSelectStateContext);
  const selectedKey = state?.selectedItems[0]?.key;
  const selectedLeading =
    selectedKey == null
      ? undefined
      : items.find((item) => item.id === String(selectedKey))?.leading;

  return (
    <SelectRowContent
      className="w-full"
      indicator={<ChevronDownIcon className="size-5 text-quaternary" />}
      isLabelFluid={isLabelFluid}
      {...definedProps({ leading: selectedLeading })}
      label={
        <AriaSelectValue className="block min-w-0 truncate text-sm text-primary">
          {({ selectedText, defaultChildren }) => (
            <span
              className={cx(
                "block truncate whitespace-nowrap",
                !selectedText && "text-disabled"
              )}
              data-slot="dropdown-trigger-label"
            >
              {selectedText ?? defaultChildren ?? placeholder}
            </span>
          )}
        </AriaSelectValue>
      }
    />
  );
};

export const Dropdown = ({
  label,
  hint,
  placeholder,
  items,
  value,
  defaultValue,
  onChange,
  onOpenChange,
  isOpen,
  size = "md",
  disabled = false,
  destructive = false,
  className,
  contentAlign = "start",
  width = "default",
  ariaLabel,
  triggerRef,
  loading = false,
  virtualized = false,
}: DropdownProps) => {
  const ownTriggerRef = useRef<HTMLButtonElement>(null);
  const setTriggerRef = useMemo(
    () => mergeRefs(ownTriggerRef, triggerRef),
    [triggerRef]
  );
  const messages = useCommaMessages();
  const resolvedPlaceholder = placeholder ?? messages.ui_select_option();
  const resolvedAriaLabel = ariaLabel ?? label ?? resolvedPlaceholder;
  const selectItems: SelectItemType[] = items.map((item) => ({
    id: item.id,
    label: item.label,
    leading: item.leading,
    ...definedProps({
      subtitle: item.subtitle,
      disabled: item.disabled,
      fontFamily: item.fontFamily,
      separatorBefore: item.separatorBefore,
    }),
  }));

  const handleChange = (key: Key | null) => {
    if (key != null) onChange?.(String(key));
  };

  return (
    <SelectContext.Provider value={{ contentAlign, size, virtualized }}>
      <AriaSelect<SelectItemType>
        aria-label={resolvedAriaLabel}
        {...definedProps({
          selectedKey: value,
          defaultSelectedKey: defaultValue,
          isOpen,
          onOpenChange,
        })}
        onSelectionChange={handleChange}
        isDisabled={disabled}
        className={cx(
          "flex max-w-full flex-col gap-1.5",
          width === "content" ? "w-fit" : "w-80",
          className
        )}
        data-slot="dropdown"
        data-width={width}
      >
        {(state) => (
          <>
            {label && <Label>{label}</Label>}
            <AriaButton
              ref={setTriggerRef}
              aria-label={resolvedAriaLabel}
              className={cx(
                "flex min-w-0 items-center rounded-md border bg-primary px-[calc(var(--spacing-lg)+var(--spacing-xxs))] text-left text-sm shadow-xs outline-none transition-[border-color,background-color,box-shadow] duration-[var(--motion-duration-state-change)] ease-[var(--motion-easing-smooth-out)]",
                width === "content" ? "w-fit max-w-full" : "w-full",
                selectRowHeightClassName[size],
                destructive ? "border-error" : "border-primary",
                state.isFocusVisible &&
                  (destructive
                    ? "shadow-focus-error-shadow-xs"
                    : "shadow-focus-brand-shadow-xs"),
                state.isDisabled && "cursor-not-allowed bg-disabled text-disabled",
                state.isOpen && "pointer-events-none opacity-0"
              )}
              data-no-press-feedback=""
              data-slot="dropdown-trigger"
            >
              <DropdownTriggerContent
                isLabelFluid={width !== "content"}
                items={selectItems}
                placeholder={resolvedPlaceholder}
              />
            </AriaButton>
            <SelectPopover
              className={destructive ? "border-error" : "border-primary"}
              data-slot="dropdown-popover"
              items={selectItems}
              size={size}
              triggerRef={ownTriggerRef}
              virtualized={virtualized}
            >
              <AriaListBox
                shouldFocusOnHover={false}
                shouldSelectOnPressUp
                className={cx(
                  "outline-none",
                  virtualized ? "w-full" : "w-max min-w-full"
                )}
              >
                {Array.from(new Set(items.map((item) => item.group))).map((group) => {
                  const children = selectItems
                    .filter((_, index) => items[index]?.group === group)
                    .flatMap((item) => [
                      item.separatorBefore ? (
                        <AriaSeparator
                          data-slot="dropdown-separator"
                          className="mx-md my-xs border-t-[length:var(--border-width-0-5)] border-primary"
                          key={`${item.id}-separator`}
                        />
                      ) : null,
                      <SelectItem
                        id={item.id}
                        key={item.id}
                        label={item.label}
                        {...definedProps({
                          subtitle: item.subtitle,
                          isDisabled: item.disabled,
                          fontFamily: item.fontFamily,
                          leading: item.leading,
                        })}
                      />,
                    ]);
                  return group ? (
                    <AriaListBoxSection key={group} aria-label={group}>
                      <AriaHeader className="px-lg pt-md pb-xs text-xs font-medium text-tertiary">
                        {group}
                      </AriaHeader>
                      {children}
                    </AriaListBoxSection>
                  ) : (
                    children
                  );
                })}
                {loading ? (
                  <AriaListBoxLoadMoreItem
                    className={menuItemGutterClasses}
                    data-slot="dropdown-loading"
                    isLoading
                  >
                    <div
                      className={cx(
                        "flex items-center gap-md text-sm text-tertiary",
                        menuItemRowChromeClasses,
                        selectRowHeightClassName[size]
                      )}
                    >
                      <LoadingCircleIcon
                        aria-hidden="true"
                        className="size-4 motion-safe:animate-spin"
                      />
                      {messages.common_loading()}
                    </div>
                  </AriaListBoxLoadMoreItem>
                ) : null}
              </AriaListBox>
            </SelectPopover>
            {hint && <HintText>{hint}</HintText>}
          </>
        )}
      </AriaSelect>
    </SelectContext.Provider>
  );
};
