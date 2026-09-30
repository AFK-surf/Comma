import type { ReactNode } from "react";

export type TooltipShortcutKey = string | ReactNode;

export type TooltipRow = {
  label: ReactNode;
  shortcut?: TooltipShortcutKey | readonly TooltipShortcutKey[];
  shortcutLabel?: string;
  suffix?: ReactNode;
};

interface TooltipBubbleProps {
  content: ReactNode;
  supportingText?: ReactNode;
  shortcut?: TooltipShortcutKey | readonly TooltipShortcutKey[];
  suffix?: ReactNode;
  rows?: readonly TooltipRow[];
}

const shortcutKeyClassName =
  "inline-flex shrink-0 items-center justify-center rounded-xs bg-tooltip-shortcut-bg font-sans text-[length:calc(var(--text-xs)*0.9)] font-medium leading-none text-tooltip-shortcut-text";
const compactShortcutKeyClassName = `${shortcutKeyClassName} size-[calc(18px*0.9)]`;
const wideShortcutKeyClassName = `${shortcutKeyClassName} h-[calc(18px*0.9)] min-w-[calc(18px*0.9)] px-xs`;

const toShortcutKeys = (
  shortcut?: TooltipShortcutKey | readonly TooltipShortcutKey[]
): TooltipShortcutKey[] | undefined => {
  if (shortcut === undefined) return undefined;
  if (typeof shortcut === "string") return [shortcut];
  if (Array.isArray(shortcut)) return [...shortcut];
  return [shortcut];
};

const shortcutAccessibleName = (keys: TooltipShortcutKey[], shortcutLabel?: string) => {
  if (shortcutLabel) return shortcutLabel;
  const labels = keys.filter((key): key is string => typeof key === "string");
  return labels.length > 0 ? labels.join(" ") : undefined;
};

const TooltipShortcutKeys = ({
  shortcut,
  shortcutLabel,
}: {
  shortcut?: TooltipShortcutKey | readonly TooltipShortcutKey[];
  shortcutLabel?: string;
}) => {
  const keys = toShortcutKeys(shortcut);
  if (!keys?.length) return null;

  const accessibleName = shortcutAccessibleName(keys, shortcutLabel);

  return (
    <span
      className="inline-flex shrink-0 items-center gap-xxs"
      data-slot="tooltip-shortcut"
      {...(accessibleName
        ? { "aria-label": `Keyboard shortcut: ${accessibleName}` }
        : {})}
    >
      {keys.map((key, index) => (
        <kbd
          className={
            typeof key === "string" && key.length > 1
              ? wideShortcutKeyClassName
              : compactShortcutKeyClassName
          }
          // Shortcut sequences can repeat the same key, so position is part of identity.
          key={`${typeof key === "string" ? key : "icon"}-${index}`}
        >
          {key}
        </kbd>
      ))}
    </span>
  );
};

const TooltipRowContent = ({
  label,
  shortcut,
  shortcutLabel,
  suffix,
  stacked,
}: TooltipRow & { stacked: boolean }) => (
  <span
    className={`flex max-w-full items-center ${stacked ? "w-full justify-between gap-md" : "gap-xs"}`}
  >
    <span className="min-w-0 max-w-full whitespace-nowrap text-xs font-medium text-tooltip-text">
      {label}
    </span>
    <TooltipShortcutKeys
      {...(shortcut !== undefined ? { shortcut } : {})}
      {...(shortcutLabel !== undefined ? { shortcutLabel } : {})}
    />
    {suffix ? (
      <span className="min-w-0 max-w-full whitespace-nowrap text-xs font-medium text-tooltip-text">
        {suffix}
      </span>
    ) : null}
  </span>
);

export const TooltipBubble = ({
  content,
  supportingText,
  shortcut,
  suffix,
  rows,
}: TooltipBubbleProps) => {
  const resolvedRows =
    rows && rows.length > 0 ? rows : [{ label: content, shortcut, suffix }];
  const stacked = resolvedRows.length > 1;
  const firstRow = resolvedRows[0] ?? { label: content, shortcut, suffix };

  return (
    <span
      className={`inline-flex w-max max-w-[min(320px,calc(100vw-32px))] flex-col items-start overflow-hidden rounded-md border-[length:var(--border-width-0-5)] border-tooltip-border bg-tooltip-bg px-md text-left shadow-xs ${supportingText || stacked ? "py-md" : "py-xs"}`}
      data-slot="tooltip-bubble"
    >
      {stacked ? (
        <span className="flex w-full flex-col gap-xxs">
          {resolvedRows.map((row, index) => (
            <TooltipRowContent
              key={`${typeof row.label === "string" ? row.label : "row"}-${index}`}
              stacked
              {...row}
            />
          ))}
        </span>
      ) : (
        <TooltipRowContent stacked={false} {...firstRow} />
      )}
      {supportingText ? (
        <span className="mt-xxs min-w-0 max-w-full break-words text-xs font-normal text-tooltip-supporting-text">
          {supportingText}
        </span>
      ) : null}
    </span>
  );
};
