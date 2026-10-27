import { ChevronLeft } from "lucide-react";
import { cn } from "cn";
import { useEffect, useRef, useState, type ReactNode } from "react";
import { Button } from "@/components/ui/button";
import { useNavigation, useScreenPlace } from "@/components/navigation";

/**
 * A screen (DESIGN.md §4): its navigation bar, then its content, which
 * scrolls under the bar. The bar holds the way back (labelled with the screen
 * under this one), the title and the screen's actions. The title is centered
 * on compact, as on a phone, and at the leading end from 640px, as on an iPad
 * or the web, where a column can be narrow. A section's first
 * screen shows its title large at the top of the content; it moves into the
 * bar once it scrolls away, as an iOS app does. Every other screen has its
 * title in the bar.
 */
export function Screen({
  title,
  largeTitle,
  actions,
  width = "readable",
  children,
}: {
  title: string;
  /** A large title over the content. A section's first screen has one. */
  largeTitle?: boolean;
  /** One or two icon buttons, or one text button: the screen's actions. */
  actions?: ReactNode;
  /** `readable` keeps text to 672px; `full` fills the screen (a grid, a board). */
  width?: "readable" | "full";
  children: ReactNode;
}) {
  const { depth, backTitle, inSplit } = useScreenPlace();
  const navigation = useNavigation();
  const large = largeTitle ?? (depth === 1 && !inSplit);
  const scroller = useRef<HTMLDivElement>(null);
  const heading = useRef<HTMLHeadingElement>(null);
  // The bar's title shows once the large title has scrolled under the bar.
  const [inlineTitle, setInlineTitle] = useState(!large);
  const [scrolled, setScrolled] = useState(false);

  useEffect(() => {
    setInlineTitle(!large);
    const target = heading.current;
    const root = scroller.current;
    if (!large || !target || !root || typeof IntersectionObserver === "undefined") return;
    const observer = new IntersectionObserver(
      ([entry]) => setInlineTitle(!entry!.isIntersecting),
      { root, threshold: 0 },
    );
    observer.observe(target);
    return () => observer.disconnect();
  }, [large]);

  return (
    <>
      {/* The hairline under the bar shows once content scrolls under it. */}
      <header
        className={cn(
          "relative flex h-11 shrink-0 items-center justify-between gap-2 border-b px-2 transition-colors",
          scrolled ? "border-border" : "border-transparent",
        )}
      >
        <div className="flex min-w-0 shrink-0 items-center">
          {depth > 1 ? (
            <Button
              type="button"
              variant="ghost"
              className="gap-0.5 px-1.5 text-primary hover:bg-transparent hover:text-primary/80"
              onClick={navigation.pop}
            >
              <ChevronLeft aria-hidden className="size-5" />
              <span className="max-w-32 truncate">{backTitle ?? "Back"}</span>
            </Button>
          ) : null}
        </div>
        {large ? (
          <span
            aria-hidden
            className={cn(
              "pointer-events-none absolute inset-x-24 truncate text-center text-headline transition-opacity sm:static sm:min-w-0 sm:flex-1 sm:px-2 sm:text-left",
              inlineTitle ? "opacity-100" : "opacity-0",
            )}
          >
            {title}
          </span>
        ) : (
          <h1 className="pointer-events-none absolute inset-x-24 truncate text-center text-headline sm:static sm:min-w-0 sm:flex-1 sm:px-2 sm:text-left">
            {title}
          </h1>
        )}
        <div className="flex min-w-0 shrink-0 items-center justify-end gap-1">
          {actions}
        </div>
      </header>
      <div
        ref={scroller}
        className="min-h-0 flex-1 overflow-y-auto overscroll-contain"
        onScroll={(event) => setScrolled(event.currentTarget.scrollTop > 0)}
      >
        <div
          className={cn(
            "mx-auto flex w-full min-w-0 flex-col gap-6 px-4 pt-1 sm:px-6 lg:px-8",
            width === "readable" && "max-w-2xl",
          )}
          style={{ paddingBottom: "max(1.5rem, env(safe-area-inset-bottom))" }}
        >
          {large ? (
            <h1 ref={heading} className="text-large-title">
              {title}
            </h1>
          ) : null}
          {children}
        </div>
      </div>
    </>
  );
}
