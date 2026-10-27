import { useCommaMessages } from "@comma/i18n/react";
import { SquareGridCircleIcon } from "../icons";

export type MiniAppCardProps = {
  name: string;
  /** The deployed Version this card shows. */
  version: number;
  /** The message's summary. */
  summary: string;
};

/**
 * A Task message's app card where the app cannot run (a Task's report): the launch cover a live thread shows
 * (`MiniAppChrome` `cover`), with an empty phone screen, then the app's name, its Version and the summary.
 */
export function MiniAppCard({ name, version, summary }: MiniAppCardProps) {
  const messages = useCommaMessages();
  return (
    <div
      className="flex w-full min-w-0 flex-col overflow-hidden rounded-2xl bg-primary shadow-xs ring-1 ring-primary"
      data-testid="mini-app-card"
    >
      <div
        aria-hidden
        className="flex h-30 justify-center overflow-hidden bg-tertiary pt-xl"
      >
        <span className="flex w-1/2 justify-center rounded-t-2xl bg-primary pt-3xl shadow-sm ring-1 ring-primary">
          <SquareGridCircleIcon className="size-6 text-fg-quaternary" />
        </span>
      </div>
      <div className="flex min-w-0 flex-col gap-xxs border-t-[0.5px] border-primary px-lg py-md">
        <span className="flex min-w-0 items-baseline gap-xs">
          <span className="truncate text-sm font-medium text-primary">{name}</span>
          <span className="shrink-0 text-xs text-tertiary">
            {messages.mini_app_cover_version({ version: String(version) })}
          </span>
        </span>
        <p className="m-0 text-sm text-secondary">{summary}</p>
      </div>
    </div>
  );
}
