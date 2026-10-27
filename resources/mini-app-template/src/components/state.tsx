import { CircleAlert } from "lucide-react";
import { cn } from "cn";
import type { ReactNode } from "react";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";

/** The states every screen has (DESIGN.md §9): what will arrive, nothing yet, and what failed. */

export function LoadingList({
  rows = 3,
  label = "Loading",
}: {
  rows?: number;
  label?: string;
}) {
  return (
    <div
      aria-busy="true"
      aria-label={label}
      className="flex flex-col gap-2"
      role="status"
    >
      {Array.from({ length: rows }, (_, index) => (
        <Skeleton key={index} className="h-11 w-full rounded-xl" />
      ))}
    </div>
  );
}

export function EmptyState({
  icon,
  title,
  description,
  action,
  className,
}: {
  icon?: ReactNode;
  title: ReactNode;
  /** What to do first. */
  description?: ReactNode;
  /** The action that fills the screen, usually the screen's primary action. */
  action?: ReactNode;
  className?: string;
}) {
  return (
    <div
      className={cn(
        "flex flex-col items-center justify-center gap-1 rounded-xl border border-dashed px-6 py-8 text-center",
        className,
      )}
      role="status"
    >
      {icon ? (
        <span className="mb-2 flex size-10 items-center justify-center rounded-full bg-muted text-muted-foreground [&_svg]:size-5">
          {icon}
        </span>
      ) : null}
      <p className="text-headline">{title}</p>
      {description ? (
        <p className="max-w-prose text-subheadline text-balance text-muted-foreground">
          {description}
        </p>
      ) : null}
      {action ? <div className="mt-3">{action}</div> : null}
    </div>
  );
}

export function ErrorState({
  title = "Something went wrong",
  detail,
  onRetry,
  retryLabel = "Try again",
  className,
}: {
  title?: ReactNode;
  /** The reason, in words a person can act on. */
  detail?: ReactNode;
  onRetry?: () => void;
  retryLabel?: string;
  className?: string;
}) {
  return (
    <div
      className={cn(
        "flex flex-col gap-3 rounded-xl border border-destructive/30 bg-destructive/5 px-4 py-3",
        className,
      )}
      role="alert"
    >
      <div className="flex items-start gap-2">
        <CircleAlert
          aria-hidden
          className="mt-0.5 size-4 shrink-0 text-destructive"
        />
        <div className="flex min-w-0 flex-col gap-0.5">
          <p className="text-headline">{title}</p>
          {detail ? (
            <p className="text-footnote break-words text-muted-foreground">
              {detail}
            </p>
          ) : null}
        </div>
      </div>
      {onRetry ? (
        <div>
          <Button type="button" variant="outline" size="sm" onClick={onRetry}>
            {retryLabel}
          </Button>
        </div>
      ) : null}
    </div>
  );
}
