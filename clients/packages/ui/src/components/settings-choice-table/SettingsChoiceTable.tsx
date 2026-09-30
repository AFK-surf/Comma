import { useId, type ReactNode } from "react";
import { InputField } from "../input/InputField";
import { ScrollArea } from "../scroll-area";
import { cx } from "../utils";

export interface SettingsChoiceTableRow {
  id: string;
  label: string;
  description?: string;
}

/** A searchable table with a single selected choice. */
export function SettingsChoiceTable({
  label,
  choiceLabel,
  rows,
  value,
  onChange,
  disabled,
  searchLabel,
  search,
  onSearchChange,
  action,
  secondaryAction,
  message,
  emptyLabel,
  loading = false,
}: {
  label: string;
  choiceLabel: string;
  rows: SettingsChoiceTableRow[];
  value: string;
  onChange: (id: string) => void;
  disabled: boolean;
  searchLabel: string;
  search: string;
  onSearchChange: (value: string) => void;
  action: ReactNode;
  secondaryAction: ReactNode;
  message?: string;
  emptyLabel: string;
  loading?: boolean;
}) {
  const group = useId();
  const query = search.toLowerCase();
  const visibleRows = rows.filter((row) =>
    `${row.label} ${row.description ?? ""}`.toLowerCase().includes(query)
  );
  return (
    <div className="w-full min-w-0" aria-busy={loading}>
      <div className="mb-lg flex flex-wrap items-center gap-md">
        <div className="min-w-0 flex-1 basis-40">
          <InputField
            className="w-full"
            aria-label={searchLabel}
            placeholder={searchLabel}
            value={search}
            disabled={disabled || rows.length === 0}
            onChange={(event) => onSearchChange(event.target.value)}
          />
        </div>
        {action}
      </div>
      <div className="rounded-lg border border-primary">
        <ScrollArea
          edgeEffect="none"
          contentStyle={{ width: "100%", minWidth: 0 }}
          viewportClassName="max-h-[320px]"
          orientation="vertical"
        >
          <table
            aria-label={label}
            className="w-full table-fixed border-collapse text-left text-sm"
          >
            <thead className="sticky top-0 bg-secondary text-tertiary">
              <tr>
                <th scope="col" className="px-lg py-md font-medium">
                  {choiceLabel}
                </th>
              </tr>
            </thead>
            <tbody>
              {loading
                ? [0, 1, 2].map((row) => (
                    <tr
                      key={row}
                      aria-hidden="true"
                      className="border-t border-primary"
                    >
                      <td aria-label={choiceLabel} className="px-lg py-lg">
                        <div className="h-4 w-3/4 rounded bg-tertiary" />
                      </td>
                    </tr>
                  ))
                : visibleRows.map((row) => (
                    <tr
                      key={row.id}
                      data-selected={value === row.id}
                      className={cx(
                        "border-t border-primary",
                        value === row.id ? "bg-secondary" : "hover:bg-secondary"
                      )}
                      onClick={(event) => {
                        if (
                          !disabled &&
                          !(event.target as HTMLElement).closest("input,label")
                        )
                          onChange(row.id);
                      }}
                    >
                      <td className="px-lg py-md align-middle">
                        <label className="flex cursor-pointer items-center gap-md text-primary">
                          <input
                            type="radio"
                            name={group}
                            value={row.id}
                            checked={value === row.id}
                            aria-label={row.label}
                            disabled={disabled}
                            className="size-4 shrink-0 accent-current"
                            onChange={() => onChange(row.id)}
                          />
                          <span className="min-w-0 [overflow-wrap:anywhere]">
                            <span className="block font-medium">{row.label}</span>
                            {row.description && (
                              <span className="block text-xs text-tertiary">
                                {row.description}
                              </span>
                            )}
                          </span>
                        </label>
                      </td>
                    </tr>
                  ))}
              {!loading && visibleRows.length === 0 && (
                <tr>
                  <td className="px-lg py-3xl text-center text-tertiary">
                    {emptyLabel}
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </ScrollArea>
      </div>
      <div className="mt-md flex flex-wrap items-center justify-between gap-md">
        <output className="min-w-0 flex-1 text-xs text-tertiary">{message}</output>
        {secondaryAction}
      </div>
    </div>
  );
}
