import { useCommaMessages } from "@comma/i18n/react";
import { useState, type ReactNode } from "react";
import { BarsThreeIcon, LayoutColumnIcon } from "../icons";
import { cx } from "../utils";

export type TaskView = "list" | "board";

export interface TaskViewToggleProps {
  value?: TaskView;
  defaultValue?: TaskView;
  onChange?: (view: TaskView) => void;
  disabled?: boolean;
  listLabel?: string;
  boardLabel?: string;
  className?: string;
}

const optionRoot =
  "inline-flex size-6 items-center justify-center rounded-full border border-secondary bg-primary text-quaternary outline-none focus-visible:z-10 focus-visible:shadow-focus-gray-shadow-xs focus:outline-none [&_svg]:size-3";

const optionActive = "bg-tertiary text-primary";

const optionDisabled = "cursor-not-allowed border-secondary bg-disabled text-disabled";

export const TaskViewToggle = ({
  value,
  defaultValue = "board",
  onChange,
  disabled = false,
  listLabel,
  boardLabel,
  className,
}: TaskViewToggleProps) => {
  const messages = useCommaMessages();
  const [internalValue, setInternalValue] = useState<TaskView>(value ?? defaultValue);
  const selected = value ?? internalValue;
  const resolvedListLabel = listLabel ?? messages.tasks_list_view();
  const resolvedBoardLabel = boardLabel ?? messages.tasks_board_view();

  const handleSelect = (next: TaskView) => {
    if (disabled || next === selected) return;
    if (value === undefined) setInternalValue(next);
    onChange?.(next);
  };

  const renderOption = (view: TaskView, label: string, icon: ReactNode) => {
    const isCurrent = view === selected;
    return (
      <button
        aria-label={label}
        aria-pressed={isCurrent}
        className={cx(
          optionRoot,
          isCurrent && optionActive,
          disabled && optionDisabled
        )}
        data-view={view}
        disabled={disabled}
        onClick={() => handleSelect(view)}
        type="button"
      >
        {icon}
      </button>
    );
  };

  return (
    <fieldset
      className={cx("m-0 inline-flex min-w-0 gap-md border-0 p-0", className)}
      data-slot="task-view-toggle"
    >
      {renderOption("list", resolvedListLabel, <BarsThreeIcon />)}
      {renderOption("board", resolvedBoardLabel, <LayoutColumnIcon />)}
    </fieldset>
  );
};
