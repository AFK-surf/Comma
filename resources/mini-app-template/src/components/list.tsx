import { ChevronRight } from "lucide-react";
import { cn } from "cn";
import type { ComponentProps, ReactNode } from "react";

/**
 * The standard list (DESIGN.md §9), inset and grouped as in iOS Settings:
 * rows on one card, hairlines between them, 44px tall on a touch screen and
 * denser with a mouse. A row that navigates or acts is a button and
 * highlights on hover and press.
 */
export function List({ className, ...props }: ComponentProps<"ul">) {
  return (
    <ul
      className={cn(
        "flex w-full min-w-0 flex-col overflow-hidden rounded-xl border bg-card",
        className,
      )}
      {...props}
    />
  );
}

const rowClass =
  "flex min-h-10 w-full min-w-0 items-center gap-3 px-4 py-2 text-left text-body";

export function ListItem({
  leading,
  title,
  description,
  trailing,
  chevron = false,
  selected = false,
  onClick,
  disabled = false,
  className,
  ...props
}: Omit<ComponentProps<"li">, "title"> & {
  /** An icon (`size-5`) or an avatar. */
  leading?: ReactNode;
  title: ReactNode;
  description?: ReactNode;
  /** A value in muted tabular text, or one small control. */
  trailing?: ReactNode;
  /** The row opens a detail screen. */
  chevron?: boolean;
  /** The row's item is open beside the list (a split view). */
  selected?: boolean;
  /** Makes the whole row the control. */
  onClick?: () => void;
  disabled?: boolean;
}) {
  const content = (
    <>
      {leading ? (
        <span className="flex size-5 shrink-0 items-center justify-center text-muted-foreground [&_svg]:size-5">
          {leading}
        </span>
      ) : null}
      <span className="flex min-w-0 flex-1 flex-col">
        <span className="truncate">{title}</span>
        {description ? (
          <span className="line-clamp-2 text-footnote text-muted-foreground">
            {description}
          </span>
        ) : null}
      </span>
      {trailing ? (
        <span className="flex shrink-0 items-center gap-2 text-muted-foreground tabular-nums">
          {trailing}
        </span>
      ) : null}
      {chevron ? (
        <ChevronRight
          aria-hidden
          className="size-4 shrink-0 text-muted-foreground"
        />
      ) : null}
    </>
  );
  return (
    <li className={cn("border-b last:border-b-0", className)} {...props}>
      {onClick ? (
        <button
          type="button"
          aria-current={selected || undefined}
          data-slot="list-row"
          className={cn(
            rowClass,
            "cursor-pointer outline-none hover:bg-accent focus-visible:bg-accent active:bg-accent disabled:pointer-events-none disabled:opacity-50",
            selected && "bg-accent",
          )}
          disabled={disabled}
          onClick={onClick}
        >
          {content}
        </button>
      ) : (
        <div className={cn(rowClass, disabled && "opacity-50")} data-slot="list-row">
          {content}
        </div>
      )}
    </li>
  );
}

/**
 * A group of rows with its header and footer, as in iOS Settings: the header
 * names the group, the footer explains it. Both are small and muted, and line
 * up with the rows' text.
 */
export function ListSection({
  header,
  footer,
  className,
  children,
}: {
  header?: ReactNode;
  footer?: ReactNode;
  className?: string;
  children: ReactNode;
}) {
  return (
    <section
      className={cn("flex min-w-0 flex-col gap-1.5", className)}
      aria-label={typeof header === "string" ? header : undefined}
    >
      {header ? (
        <h2 className="px-4 text-footnote text-muted-foreground">{header}</h2>
      ) : null}
      {children}
      {footer ? (
        <p className="px-4 text-footnote text-muted-foreground">{footer}</p>
      ) : null}
    </section>
  );
}
