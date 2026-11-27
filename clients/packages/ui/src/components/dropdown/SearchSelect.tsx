import { useCallback, useId, useState } from "react";
import {
  Button as AriaButton,
  Dialog as AriaDialog,
  DialogTrigger,
} from "react-aria-components";
import { HintText, Label } from "../form";
import { CheckIcon, ChevronDownIcon } from "../icons";
import { MenuPopover } from "../menu";
import { menuItemGutterClasses, menuItemRowChromeClasses } from "../menu/styles";
import { ScrollArea } from "../scroll-area";
import { cx } from "../utils";
import { spacing } from "../../tokens";
import { selectRowHeightClassName } from "./select-primitives";

export interface SearchSelectItem {
  id: string;
  label: string;
  /** Quiet text after the label, such as the option's ID. */
  detail?: string;
}

export interface SearchSelectProps {
  /** Names the field, its trigger and its panel. */
  label: string;
  hint?: string;
  /** The chosen option's ID. */
  value: string;
  /** What the closed trigger shows: the chosen option's name, or a state. */
  display: string;
  /** Shows `display` as a placeholder, not a chosen value. */
  muted?: boolean;
  /** The options for what is typed in the panel's search box. */
  items: (query: string) => SearchSelectItem[];
  onChange: (id: string) => void;
  searchPlaceholder: string;
  /** Shown in the panel when no option matches. */
  emptyText: string;
  disabled?: boolean;
  className?: string;
}

/**
 * A select whose panel starts with a search box: one trigger in the form,
 * the same as a small `Dropdown`, and a panel that filters a long list as
 * the user types. The caller decides the options for each query, so a typed
 * value such as a pasted ID can be offered as an option of its own.
 */
export function SearchSelect({
  label,
  hint,
  value,
  display,
  muted = false,
  items,
  onChange,
  searchPlaceholder,
  emptyText,
  disabled = false,
  className,
}: SearchSelectProps) {
  const valueId = useId();
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const options = items(query);
  // The panel opens to type in: its search box takes focus once, when it mounts.
  const focusSearch = useCallback(
    (input: HTMLInputElement | null) => input?.focus({ preventScroll: true }),
    []
  );

  return (
    <div
      className={cx("flex w-80 max-w-full flex-col gap-1.5", className)}
      data-slot="search-select"
    >
      <Label>{label}</Label>
      <DialogTrigger
        isOpen={open}
        onOpenChange={(next) => {
          setOpen(next);
          // Each opening starts from the whole list.
          if (next) setQuery("");
        }}
      >
        <AriaButton
          aria-label={label}
          aria-describedby={valueId}
          isDisabled={disabled}
          className={({ isFocusVisible, isDisabled }) =>
            cx(
              "flex w-full min-w-0 items-center gap-md rounded-md border border-primary bg-primary px-[calc(var(--spacing-lg)+var(--spacing-xxs))] text-left text-sm shadow-xs outline-none transition-[border-color,background-color,box-shadow] duration-[var(--motion-duration-state-change)] ease-[var(--motion-easing-smooth-out)]",
              selectRowHeightClassName.sm,
              isFocusVisible && "shadow-focus-brand-shadow-xs",
              isDisabled && "cursor-not-allowed bg-disabled text-disabled"
            )
          }
          data-no-press-feedback=""
          data-slot="search-select-trigger"
        >
          <span
            id={valueId}
            className={cx(
              "min-w-0 flex-1 truncate",
              muted || disabled ? "text-disabled" : "text-primary"
            )}
          >
            {display}
          </span>
          <ChevronDownIcon className="size-5 shrink-0 text-quaternary" />
        </AriaButton>
        {/* The panel stays below its trigger while its list shrinks to the search. */}
        <MenuPopover offset={spacing.xs} placement="bottom start" shouldFlip={false}>
          <AriaDialog
            aria-label={label}
            data-slot="search-select-panel"
            className="flex w-[var(--trigger-width)] max-w-[calc(100vw-(var(--spacing-lg)*2))] flex-col gap-xs rounded-xl border border-primary bg-primary py-sm shadow-lg outline-none"
          >
            <div className={menuItemGutterClasses}>
              <input
                aria-label={searchPlaceholder}
                autoComplete="off"
                className="w-full rounded-md bg-primary px-md py-xs text-sm text-primary ring-1 ring-primary ring-inset outline-none placeholder:text-placeholder focus:ring-2"
                onChange={(event) => setQuery(event.target.value)}
                placeholder={searchPlaceholder}
                ref={focusSearch}
                type="search"
                value={query}
              />
            </div>
            <ScrollArea className="max-h-72" edgeEffect="mask">
              {options.length === 0 ? (
                <p className="px-[calc(var(--spacing-sm)+var(--spacing-md))] py-sm text-sm text-tertiary">
                  {emptyText}
                </p>
              ) : (
                <div className={cx("flex flex-col", menuItemGutterClasses)}>
                  {options.map((option) => {
                    const selected = option.id === value;
                    return (
                      <button
                        aria-pressed={selected}
                        className={cx(
                          "flex w-full min-w-0 cursor-pointer items-center gap-md text-left text-sm outline-none hover:bg-secondary focus-visible:bg-secondary",
                          menuItemRowChromeClasses,
                          selectRowHeightClassName.sm,
                          selected ? "text-primary" : "text-secondary"
                        )}
                        data-slot="search-select-option"
                        key={option.id}
                        onClick={() => {
                          onChange(option.id);
                          setOpen(false);
                        }}
                        type="button"
                      >
                        <span className="min-w-0 truncate">{option.label}</span>
                        {option.detail ? (
                          <span className="min-w-0 shrink truncate text-xs text-tertiary">
                            {option.detail}
                          </span>
                        ) : null}
                        <CheckIcon
                          aria-hidden="true"
                          className={cx(
                            "ml-auto size-5 shrink-0 text-fg-brand-primary",
                            selected ? "opacity-100" : "opacity-0"
                          )}
                        />
                      </button>
                    );
                  })}
                </div>
              )}
            </ScrollArea>
          </AriaDialog>
        </MenuPopover>
      </DialogTrigger>
      {hint ? <HintText>{hint}</HintText> : null}
    </div>
  );
}
