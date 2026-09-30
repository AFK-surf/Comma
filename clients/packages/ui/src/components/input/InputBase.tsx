import { createContext, useContext, type ReactNode, type Ref } from "react";
import type { GroupProps, InputProps as AriaInputProps } from "react-aria-components";
import { Group as AriaGroup, Input as AriaInput } from "react-aria-components";
import { cx, definedProps, sortCx } from "../utils";

export type InputBaseSize = "sm" | "md";

type TextFieldContextValue = {
  size?: InputBaseSize;
  wrapperClassName?: string;
  inputClassName?: string;
  iconClassName?: string;
};

export const TextFieldContext = createContext<TextFieldContextValue>({});

type InputBaseProps = Omit<AriaInputProps, "size"> &
  Pick<GroupProps, "isInvalid" | "isDisabled"> & {
    ref?: Ref<HTMLInputElement>;
    size?: InputBaseSize;
    leadingIcon?: ReactNode;
    trailingIcon?: ReactNode;
    suppressFocusRing?: boolean;
    wrapperClassName?: string;
    inputClassName?: string;
    iconClassName?: string;
  };

export const InputBase = ({
  size = "md",
  isInvalid,
  isDisabled,
  leadingIcon,
  trailingIcon,
  suppressFocusRing = false,
  placeholder,
  wrapperClassName,
  inputClassName,
  iconClassName,
  ...inputProps
}: InputBaseProps) => {
  const context = useContext(TextFieldContext);
  const inputSize = context.size ?? size;
  const hasLeadingIcon = Boolean(leadingIcon);
  const hasTrailingIcon = Boolean(trailingIcon);

  const sizes = sortCx({
    sm: {
      root: cx(
        "px-3 py-2 text-sm",
        hasLeadingIcon && "pl-9",
        hasTrailingIcon && "pr-9"
      ),
      iconLeading: "left-3",
      iconTrailing: "right-3",
      height: "min-h-9",
    },
    md: {
      root: cx(
        "px-3.5 py-2 text-sm",
        hasLeadingIcon && "pl-10",
        hasTrailingIcon && "pr-10"
      ),
      iconLeading: "left-3.5",
      iconTrailing: "right-3.5",
      height: "min-h-10",
    },
  });

  return (
    <AriaGroup
      {...definedProps({
        isDisabled,
        isInvalid,
      })}
      className={({ isFocusWithin, isDisabled: disabled, isInvalid: invalid }) =>
        cx(
          "group/input relative flex w-full min-w-0 items-center rounded-md bg-primary shadow-xs ring-1 ring-primary ring-inset transition-shadow",
          sizes[inputSize].height,
          isFocusWithin &&
            !disabled &&
            !suppressFocusRing &&
            "ring-2 ring-border-brand shadow-focus-brand-shadow-xs",
          disabled && "cursor-not-allowed bg-disabled opacity-60",
          invalid && "ring-error",
          invalid &&
            isFocusWithin &&
            !suppressFocusRing &&
            "ring-2 ring-error-solid shadow-focus-error-shadow-xs",
          context.wrapperClassName,
          wrapperClassName
        )
      }
    >
      {leadingIcon && (
        <span
          className={cx(
            "pointer-events-none absolute text-quaternary",
            sizes[inputSize].iconLeading,
            context.iconClassName,
            iconClassName
          )}
        >
          {leadingIcon}
        </span>
      )}
      <AriaInput
        {...inputProps}
        {...definedProps({ placeholder })}
        className={cx(
          "w-full min-w-0 bg-transparent text-primary outline-none placeholder:text-placeholder disabled:cursor-not-allowed disabled:text-disabled",
          sizes[inputSize].root,
          context.inputClassName,
          inputClassName
        )}
      />
      {trailingIcon && (
        <span
          className={cx(
            "pointer-events-none absolute text-quaternary",
            sizes[inputSize].iconTrailing
          )}
        >
          {trailingIcon}
        </span>
      )}
    </AriaGroup>
  );
};
