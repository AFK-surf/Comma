/* oxlint-disable jsx-a11y/no-autofocus -- Search is the picker's primary keyboard interaction when it opens. */
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import {
  InputField,
  Menu,
  MenuItem,
  MenuPopover,
  MenuSeparator,
  cx,
  menuFilterFieldClasses,
  menuSurfaceClasses,
} from "@comma/ui";
import { useMemo, useState, type RefObject } from "react";
import { Dialog as AriaDialog } from "react-aria-components";
import type { CommaTaskLabel } from "../../../../api";
import { LabelDot } from "../../../tasks/labelColor";

export interface TaskLabelPickerProps {
  /** The chip or "+" the panel opens from. */
  anchorRef: RefObject<HTMLElement | null>;
  /** Ids of the labels on the Task, in their applied order. */
  appliedIds: readonly string[];
  isDisabled: boolean;
  isOpen: boolean;
  labels: readonly CommaTaskLabel[];
  /** The next full set of label ids, applied ones first in their existing order. */
  onChange: (labelIds: string[]) => void;
  onOpenChange: (isOpen: boolean) => void;
}

/**
 * The label picker behind a Task's label chips and its "+": a searchable,
 * multi-select list of the catalog. Labels on the Task sit first, checked;
 * the rest follow after a hairline, each checking on press. Every press
 * writes the whole set, so the panel stays open for a run of changes.
 */
export function TaskLabelPicker({
  anchorRef,
  appliedIds,
  isDisabled,
  isOpen,
  labels,
  onChange,
  onOpenChange,
}: TaskLabelPickerProps) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const [query, setQuery] = useState("");
  const normalizedQuery = query.trim().toLocaleLowerCase(locale);
  const { applied, rest } = useMemo(() => {
    const matches = (label: CommaTaskLabel) =>
      label.name.toLocaleLowerCase(locale).includes(normalizedQuery);
    const byId = new Map(labels.map((label) => [label.id, label]));
    return {
      applied: appliedIds.flatMap((id) => byId.get(id) ?? []).filter(matches),
      rest: labels.filter((label) => !appliedIds.includes(label.id) && matches(label)),
    };
  }, [appliedIds, labels, locale, normalizedQuery]);

  const row = (label: CommaTaskLabel) => (
    <MenuItem
      activeClassName="bg-secondary-hover"
      contentClassName="h-8"
      gutter="none"
      icon={<LabelDot className="size-md" color={label.color} />}
      id={label.id}
      isDisabled={isDisabled}
      key={label.id}
      selectionIndicator="checkbox"
      textValue={label.name}
    >
      <span className="text-primary">{label.name}</span>
    </MenuItem>
  );

  return (
    <MenuPopover
      isOpen={isOpen}
      onOpenChange={(next) => {
        if (!next) setQuery("");
        onOpenChange(next);
      }}
      placement="bottom start"
      triggerRef={anchorRef}
    >
      <AriaDialog
        aria-label={messages.task_panel_label()}
        className={cx(
          menuSurfaceClasses,
          "flex w-56 min-w-0 flex-col overflow-hidden bg-popup-secondary p-0 shadow-2xl"
        )}
        data-testid="task-label-picker"
      >
        <InputField
          aria-label={messages.task_panel_label_search_placeholder()}
          autoFocus
          className="w-full"
          fieldSize="sm"
          onChange={(event) => setQuery(event.target.value)}
          placeholder={messages.task_panel_label_search_placeholder()}
          suppressFocusRing
          value={query}
          wrapperClassName={menuFilterFieldClasses}
        />
        {applied.length === 0 && rest.length === 0 ? (
          <p className="m-0 px-lg py-md text-center text-sm text-disabled">
            {messages.tasks_filter_no_options()}
          </p>
        ) : (
          <Menu
            aria-label={messages.task_panel_label()}
            className="flex min-w-0 flex-col gap-xxs px-sm py-sm"
            onSelectionChange={(keys) => {
              const selected =
                keys === "all"
                  ? new Set(labels.map((label) => label.id))
                  : new Set(Array.from(keys, String));
              onChange([
                ...appliedIds.filter((id) => selected.has(id)),
                ...labels
                  .filter(
                    (label) => selected.has(label.id) && !appliedIds.includes(label.id)
                  )
                  .map((label) => label.id),
              ]);
            }}
            selectedKeys={appliedIds}
            selectionMode="multiple"
            shouldCloseOnSelect={false}
            variant="embedded"
          >
            {applied.map(row)}
            {applied.length > 0 && rest.length > 0 ? (
              // Runs edge to edge like the field's hairline above it.
              <MenuSeparator className="-mx-sm" />
            ) : null}
            {rest.map(row)}
          </Menu>
        )}
      </AriaDialog>
    </MenuPopover>
  );
}
