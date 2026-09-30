import { useId, type InputHTMLAttributes, type ReactNode } from "react";
import { TextField as AriaTextField } from "react-aria-components";
import { HelpCircleIcon } from "../icons";
import { HintText, Label } from "../form";
import { cx } from "../utils";
import { InputBase, TextFieldContext } from "./InputBase";

export type InputFieldSize = "sm" | "md";

export interface InputFieldProps extends Omit<
  InputHTMLAttributes<HTMLInputElement>,
  "size" | "value" | "defaultValue" | "onChange"
> {
  /** Plain text, or marked-up text when one word needs emphasis ("Type ‘name’ to confirm"). */
  label?: ReactNode;
  hint?: string;
  /** Secondary action related to obtaining or understanding the field value. */
  hintAction?: ReactNode;
  errorMessage?: string;
  fieldSize?: InputFieldSize;
  destructive?: boolean;
  leadingIcon?: ReactNode;
  trailingIcon?: ReactNode;
  showHelpIcon?: boolean;
  suppressFocusRing?: boolean;
  wrapperClassName?: string;
  value?: string;
  defaultValue?: string;
  onChange?: (event: React.ChangeEvent<HTMLInputElement>) => void;
}

export const InputField = ({
  label,
  hint,
  hintAction,
  errorMessage,
  fieldSize = "md",
  destructive = false,
  leadingIcon,
  trailingIcon,
  showHelpIcon = false,
  suppressFocusRing = false,
  wrapperClassName,
  id,
  className,
  disabled,
  value,
  defaultValue,
  onChange,
  name,
  placeholder,
  type,
  readOnly,
  required,
  autoComplete,
  autoFocus,
  maxLength,
  minLength,
  pattern,
  inputMode,
  onKeyDown,
  onBlur,
  onFocus,
  "aria-label": ariaLabel,
}: InputFieldProps) => {
  const generatedId = useId();
  const inputId = id ?? generatedId;
  const hasError = destructive || Boolean(errorMessage);
  const trailing =
    trailingIcon ??
    (showHelpIcon ? <HelpCircleIcon className="size-4 text-disabled" /> : undefined);

  const handleChange = (nextValue: string) => {
    onChange?.({ target: { value: nextValue } } as React.ChangeEvent<HTMLInputElement>);
  };

  return (
    <TextFieldContext.Provider value={{ size: fieldSize }}>
      <AriaTextField
        id={inputId}
        // Let React Aria focus after the overlay focus scope mounts. Native
        // input autofocus fires earlier and can dismiss a parent popover.
        {...(autoFocus !== undefined ? { autoFocus } : {})}
        {...(ariaLabel !== undefined ? { "aria-label": ariaLabel } : {})}
        {...(name !== undefined ? { name } : {})}
        {...(value !== undefined ? { value } : {})}
        {...(defaultValue !== undefined ? { defaultValue } : {})}
        {...(disabled !== undefined ? { isDisabled: disabled } : {})}
        onChange={handleChange}
        isInvalid={hasError}
        {...(required !== undefined ? { isRequired: required } : {})}
        className={cx("flex w-80 max-w-full flex-col gap-1.5", className)}
      >
        {({ isInvalid, isRequired }) => (
          <>
            {label && (
              <Label isRequired={isRequired} isInvalid={isInvalid}>
                {label}
              </Label>
            )}
            <InputBase
              size={fieldSize}
              isInvalid={isInvalid}
              suppressFocusRing={suppressFocusRing}
              {...(wrapperClassName !== undefined ? { wrapperClassName } : {})}
              {...(ariaLabel !== undefined ? { "aria-label": ariaLabel } : {})}
              {...(disabled !== undefined ? { isDisabled: disabled } : {})}
              {...(leadingIcon !== undefined ? { leadingIcon } : {})}
              {...(trailing !== undefined ? { trailingIcon: trailing } : {})}
              {...(placeholder !== undefined ? { placeholder } : {})}
              {...(type !== undefined ? { type } : {})}
              {...(readOnly !== undefined ? { readOnly } : {})}
              {...(autoComplete !== undefined ? { autoComplete } : {})}
              {...(maxLength !== undefined ? { maxLength } : {})}
              {...(minLength !== undefined ? { minLength } : {})}
              {...(pattern !== undefined ? { pattern } : {})}
              {...(inputMode !== undefined ? { inputMode } : {})}
              {...(onKeyDown !== undefined ? { onKeyDown } : {})}
              {...(onBlur !== undefined ? { onBlur } : {})}
              {...(onFocus !== undefined ? { onFocus } : {})}
            />
            {hasError && errorMessage ? (
              <HintText isInvalid>{errorMessage}</HintText>
            ) : (
              hint && <HintText>{hint}</HintText>
            )}
            {hintAction && <div className="flex items-center">{hintAction}</div>}
          </>
        )}
      </AriaTextField>
    </TextFieldContext.Provider>
  );
};
