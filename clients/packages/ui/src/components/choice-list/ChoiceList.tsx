import type { KeyboardEvent, ReactNode } from "react";
import { CheckboxBase } from "../checkbox/CheckboxBase";
import { RadioBase } from "../checkbox/RadioBase";
import { cx } from "../utils";

export type ChoiceListOption = {
  id: string;
  label: ReactNode;
  description?: ReactNode;
  /** Beside the label, e.g. a Recommended badge. */
  badge?: ReactNode;
};

export type ChoiceListProps = {
  /** The native radio group's name; unique on the page. */
  name: string;
  /** Checkboxes instead of radios. */
  multiple?: boolean;
  options: readonly ChoiceListOption[];
  /** The ids picked. */
  value: readonly string[];
  onChange: (next: string[]) => void;
  /** The element that names the list (the question). */
  labelledBy: string;
  disabled?: boolean;
  /** Shows each option's number key (1–9) beside it: on while the person uses the keyboard. */
  showShortcuts?: boolean;
  /** A key pressed on an option's input, with the option's index: number keys, Enter, typing. */
  onOptionKeyDown?: (event: KeyboardEvent<HTMLInputElement>, index: number) => void;
  /** Rows after the options in the same list, e.g. a free answer (`ChoiceListRow`). */
  children?: ReactNode;
  className?: string;
};

/**
 * A short list to pick from: each option one bordered row, the whole row its native radio or checkbox's label, so
 * the browser owns state, arrow keys and what a screen reader says. A picked row only turns gray; the radio or the
 * box itself carries the brand color. Selection changes are instant.
 */
export function ChoiceList({
  name,
  multiple = false,
  options,
  value,
  onChange,
  labelledBy,
  disabled = false,
  showShortcuts = false,
  onOptionKeyDown,
  children,
  className,
}: ChoiceListProps) {
  const picked = new Set(value);
  const toggle = (id: string, checked: boolean) => {
    if (!multiple) {
      onChange([id]);
      return;
    }
    onChange(
      checked
        ? options
            .filter((option) => option.id === id || picked.has(option.id))
            .map((option) => option.id)
        : value.filter((current) => current !== id)
    );
  };

  return (
    <div
      aria-labelledby={labelledBy}
      className={cx("comma-choice-list", className)}
      data-shortcuts={showShortcuts ? "on" : "off"}
      role={multiple ? "group" : "radiogroup"}
    >
      {options.map((option, index) => {
        const checked = picked.has(option.id);
        const descriptionId = option.description
          ? `${name}-${option.id}-description`
          : undefined;
        return (
          <label
            className="comma-choice-list-option"
            data-checked={checked}
            key={option.id}
          >
            <input
              aria-describedby={descriptionId}
              aria-keyshortcuts={index < 9 ? String(index + 1) : undefined}
              checked={checked}
              className="comma-choice-list-input"
              disabled={disabled}
              name={name}
              onChange={(event) => toggle(option.id, event.currentTarget.checked)}
              onKeyDown={
                onOptionKeyDown ? (event) => onOptionKeyDown(event, index) : undefined
              }
              type={multiple ? "checkbox" : "radio"}
              value={option.id}
            />
            <ChoiceListIndicator
              checked={checked}
              disabled={disabled}
              multiple={multiple}
            />
            <span className="comma-choice-list-body">
              <span className="comma-choice-list-label">
                {option.label}
                {option.badge}
              </span>
              {option.description ? (
                <span className="comma-choice-list-description" id={descriptionId}>
                  {option.description}
                </span>
              ) : null}
            </span>
            {index < 9 ? (
              <kbd aria-hidden="true" className="comma-choice-list-key">
                {index + 1}
              </kbd>
            ) : null}
          </label>
        );
      })}
      {children}
    </div>
  );
}

/** The radio or checkbox drawn for a row: the brand color only when picked. */
export function ChoiceListIndicator({
  checked,
  disabled = false,
  multiple,
}: {
  checked: boolean;
  disabled?: boolean;
  multiple: boolean;
}) {
  return multiple ? (
    <CheckboxBase
      className="comma-choice-list-indicator"
      isDisabled={disabled}
      isSelected={checked}
    />
  ) : (
    <RadioBase
      className="comma-choice-list-indicator"
      isDisabled={disabled}
      isSelected={checked}
    />
  );
}

/**
 * A row of the list that is not one of its options, such as a free answer: the same border and picked fill, and a
 * focus ring while anything inside it has focus.
 */
export function ChoiceListRow({
  checked,
  className,
  children,
}: {
  checked: boolean;
  className?: string;
  children: ReactNode;
}) {
  return (
    <div
      className={cx("comma-choice-list-option comma-choice-list-row", className)}
      data-checked={checked}
    >
      {children}
    </div>
  );
}
