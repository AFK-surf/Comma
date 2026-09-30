import { useCommaMessages } from "@comma/i18n/react";
import { ChevronRightSmallIcon, cx } from "@comma/ui";

/**
 * Where the list is inside the space: the space, then each folder entered.
 * Every crumb but the last is a button back to that level. It is the list's
 * own history, on purpose separate from the app's back and forward, which
 * move between routes and must not be hijacked by stepping into a folder.
 */
export function DriveBreadcrumb({
  onNavigate,
  path,
  spaceName,
}: {
  /** Jump to a folder depth; 0 is the space root. */
  onNavigate: (depth: number) => void;
  path: readonly string[];
  spaceName: string;
}) {
  const messages = useCommaMessages();
  const crumbs = [spaceName, ...path];
  return (
    <nav
      aria-label={messages.drive_breadcrumb_label()}
      className="flex min-w-0 items-center gap-xxs px-md py-sm"
      data-testid="drive-breadcrumb"
    >
      {crumbs.map((crumb, depth) => {
        const last = depth === crumbs.length - 1;
        return (
          <span className="flex min-w-0 items-center gap-xxs" key={`${depth}:${crumb}`}>
            {depth > 0 ? (
              <ChevronRightSmallIcon
                aria-hidden
                className="size-4 shrink-0 text-quaternary"
              />
            ) : null}
            {last ? (
              <span
                aria-current="location"
                className="truncate text-sm font-medium text-primary"
                data-testid="drive-breadcrumb-current"
              >
                {crumb}
              </span>
            ) : (
              <button
                className={cx(
                  "truncate rounded-xs border-0 bg-transparent p-0 text-sm text-quaternary outline-none",
                  "hover:text-secondary focus-visible:shadow-focus-gray"
                )}
                onClick={() => onNavigate(depth)}
                type="button"
              >
                {crumb}
              </button>
            )}
          </span>
        );
      })}
    </nav>
  );
}
