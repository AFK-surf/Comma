import { CheckboxGroup as AriaCheckboxGroup } from "react-aria-components";
import { HintText, Label } from "../form";
import { cx, definedProps } from "../utils";
import { Checkbox } from "./Checkbox";
import type { CheckboxSize } from "./Checkbox";

export interface CheckboxGroupOption {
  id: string;
  label: string;
  hint?: string;
  disabled?: boolean;
}

export interface CheckboxGroupProps {
  legend?: string;
  hint?: string;
  options: CheckboxGroupOption[];
  value?: string[];
  defaultValue?: string[];
  onChange?: (value: string[]) => void;
  size?: CheckboxSize;
  className?: string;
}

export const CheckboxGroup = ({
  legend,
  hint,
  options,
  value,
  defaultValue = [],
  onChange,
  size = "md",
  className,
}: CheckboxGroupProps) => (
  <AriaCheckboxGroup
    {...definedProps({
      value,
      onChange,
    })}
    defaultValue={defaultValue}
    className={cx("flex flex-col", className)}
  >
    {legend && <Label className="mb-3">{legend}</Label>}
    <div className="flex flex-col gap-4">
      {options.map((opt) => (
        <Checkbox
          key={opt.id}
          id={opt.id}
          value={opt.id}
          size={size}
          label={opt.label}
          {...definedProps({
            hint: opt.hint,
            disabled: opt.disabled,
          })}
        />
      ))}
    </div>
    {hint && <HintText className="mt-3">{hint}</HintText>}
  </AriaCheckboxGroup>
);
