import type { ReactNode } from "react";
import { Button as AriaButton, MenuTrigger } from "react-aria-components";
import { Button } from "../Button";
import { Menu, MenuItem, MenuPopover, MenuSeparator } from "../menu";
import {
  EditBigIcon,
  MoreHorizontalIcon,
  PlusIcon,
  ReloadIcon,
  TrashCanIcon,
} from "../icons";
import { useDelayedFlag } from "../utils";

/** See the note on the twin in subscription-accounts. */
const skeletonDelayMs = 250;

export interface ModelTemplateRow {
  id: string;
  name: string;
  icon?: ReactNode;
  model: string;
  /** Which credential runs this model — the fact that decides who is billed. */
  source: string;
  /** The agent roles pointed at this model, when any are. */
  assignedTo: string;
  actionsLabel: string;
  onEdit: () => void;
  onDelete: () => void;
}

export function ModelTemplatesTable({
  label,
  labels,
  error,
  rows,
  disabled,
  loaded,
  onAdd,
  onRetry,
}: {
  label: string;
  error: string;
  labels: {
    name: string;
    source: string;
    actions: string;
    edit: string;
    delete: string;
    add: string;
    empty: string;
    emptyHint: string;
    loading: string;
    retry: string;
  };
  rows: ModelTemplateRow[];
  disabled: boolean;
  loaded: boolean;
  onAdd: () => void;
  onRetry: () => void;
}) {
  const failed = !loaded && !!error;
  const pending = useDelayedFlag(!loaded && !failed && disabled, skeletonDelayMs);
  return (
    <div className="flex w-full min-w-0 flex-col gap-lg">
      {error ? (
        <p role="alert" className="text-pretty text-sm text-error-primary">
          {error}
        </p>
      ) : null}
      {failed ? (
        // A failed load keeps this exact box while the retry runs: swapping
        // it for a taller skeleton and back is two reflows in one keypress.
        <div className="flex">
          <Button
            size="sm"
            hierarchy="secondary-gray"
            iconLeading={<ReloadIcon />}
            disabled={disabled}
            onPress={onRetry}
          >
            {labels.retry}
          </Button>
        </div>
      ) : pending ? (
        <div aria-busy="true" className="flex flex-col gap-md">
          <output className="sr-only">{labels.loading}</output>
          {[0, 1].map((index) => (
            <div
              aria-hidden
              key={index}
              className="h-14 rounded-lg bg-secondary motion-safe:animate-pulse"
            />
          ))}
        </div>
      ) : !loaded ? null : rows.length === 0 ? (
        <div className="flex flex-col items-center gap-xs rounded-lg border-[0.5px] border-primary bg-secondary px-xl py-4xl text-center">
          <p className="text-balance text-sm font-medium text-primary">
            {labels.empty}
          </p>
          <p className="max-w-[42ch] text-pretty text-sm text-tertiary">
            {labels.emptyHint}
          </p>
          <div className="mt-md flex">
            <Button size="sm" iconLeading={<PlusIcon />} onPress={onAdd}>
              {labels.add}
            </Button>
          </div>
        </div>
      ) : (
        <div className="overflow-hidden rounded-lg border-[0.5px] border-primary">
          <table
            aria-label={label}
            aria-busy={!loaded && disabled}
            className="w-full table-fixed border-collapse text-left text-sm"
          >
            <thead className="bg-secondary text-xs text-tertiary">
              <tr>
                <th scope="col" className="px-md py-md font-medium">
                  {labels.name}
                </th>
                <th scope="col" className="w-[38%] px-md py-md font-medium">
                  {labels.source}
                </th>
                <th scope="col" className="w-14 px-md py-md">
                  <span className="sr-only">{labels.actions}</span>
                </th>
              </tr>
            </thead>
            <tbody>
              {rows.map((row) => (
                <tr
                  key={row.id}
                  className="border-t-[0.5px] border-primary hover:bg-secondary"
                >
                  <th scope="row" className="min-w-0 px-md py-lg align-top font-normal">
                    <div
                      className="flex items-center gap-sm truncate font-medium text-primary"
                      title={row.name}
                    >
                      {row.icon}
                      {row.name}
                    </div>
                    {row.model !== row.name ? (
                      <div className="truncate text-xs text-tertiary" title={row.model}>
                        {row.model}
                      </div>
                    ) : null}
                  </th>
                  <td className="px-md py-lg align-top">
                    <div className="truncate text-sm text-primary" title={row.source}>
                      {row.source}
                    </div>
                    {/* A saved model runs nothing until an agent points at it,
                        so the row says whether one does. */}
                    <div className="truncate text-xs text-tertiary">
                      {row.assignedTo}
                    </div>
                  </td>
                  <td aria-label={row.actionsLabel} className="px-md py-lg align-top">
                    <div className="-my-sm flex justify-end">
                      <MenuTrigger>
                        <AriaButton
                          aria-label={row.actionsLabel}
                          isDisabled={disabled}
                          className="inline-flex size-10 items-center justify-center rounded-sm text-tertiary outline-none transition-colors duration-150 ease-out hover:bg-secondary hover:text-secondary focus-visible:ring-2 disabled:opacity-50 aria-expanded:bg-secondary"
                        >
                          <MoreHorizontalIcon className="size-4" />
                        </AriaButton>
                        <MenuPopover placement="bottom end">
                          <Menu aria-label={row.actionsLabel}>
                            <MenuItem
                              id="edit"
                              icon={<EditBigIcon />}
                              textValue={labels.edit}
                              onAction={row.onEdit}
                            >
                              {labels.edit}
                            </MenuItem>
                            <MenuSeparator />
                            <MenuItem
                              id="delete"
                              icon={<TrashCanIcon />}
                              textValue={labels.delete}
                              tone="destructive"
                              onAction={row.onDelete}
                            >
                              {labels.delete}
                            </MenuItem>
                          </Menu>
                        </MenuPopover>
                      </MenuTrigger>
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {loaded && rows.length > 0 ? (
        <div className="flex">
          <Button
            size="sm"
            hierarchy="secondary-gray"
            iconLeading={<PlusIcon />}
            disabled={disabled}
            onPress={onAdd}
          >
            {labels.add}
          </Button>
        </div>
      ) : null}
    </div>
  );
}
