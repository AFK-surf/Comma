import { cn } from "cn";
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
  type ReactNode,
} from "react";

/**
 * The app's navigation, as a phone, iPad and web app has it (DESIGN.md §3, §8):
 * the app's sections in a tab bar (compact) or a sidebar (regular and wide),
 * and in each section a stack of screens that a person pushes and pops. Each
 * section keeps its own stack, as an iOS app does. The app runs in a frame
 * without a URL of its own, so all of it lives in memory, never in `location`
 * or `history`.
 */

export type SizeClass = "compact" | "regular" | "wide";

const REGULAR = "(min-width: 640px)";
const WIDE = "(min-width: 1024px)";
const REDUCED_MOTION = "(prefers-reduced-motion: reduce)";

function media(query: string): MediaQueryList | null {
  return typeof window !== "undefined" && typeof window.matchMedia === "function"
    ? window.matchMedia(query)
    : null;
}

function subscribeMedia(callback: () => void) {
  const lists = [REGULAR, WIDE, REDUCED_MOTION].map(media);
  for (const list of lists) list?.addEventListener("change", callback);
  return () => {
    for (const list of lists) list?.removeEventListener("change", callback);
  };
}

/**
 * The size class of the app's own frame, never of the device (DESIGN.md §3):
 * compact below 640px (a phone, a chat panel), regular to 1023px (an iPad, a
 * narrow window), wide from 1024px (a web app).
 */
export function useSizeClass(): SizeClass {
  return useSyncExternalStore(
    subscribeMedia,
    () =>
      media(WIDE)?.matches ? "wide" : media(REGULAR)?.matches ? "regular" : "compact",
    () => "compact",
  );
}

function useReducedMotion(): boolean {
  return useSyncExternalStore(
    subscribeMedia,
    () => media(REDUCED_MOTION)?.matches ?? true,
    () => true,
  );
}

export interface Navigation {
  /** Shows `screen` over the current one. `title` labels the back button on the screen after it. */
  push(title: string, screen: ReactNode): void;
  /** Goes back one screen. */
  pop(): void;
}

/** Where a screen is: its depth in its stack and the title of the screen under it. */
export interface ScreenPlace {
  depth: number;
  backTitle: string | undefined;
  /** The detail column of a split view: a root screen, but not the section's first. */
  inSplit?: boolean;
}

const NavigationContext = createContext<Navigation | null>(null);
export const ScreenPlaceContext = createContext<ScreenPlace>({
  depth: 1,
  backTitle: undefined,
});

export function useNavigation(): Navigation {
  const navigation = useContext(NavigationContext);
  if (!navigation) throw new Error("useNavigation needs an <AppShell> or <Stack> above it.");
  return navigation;
}

export function useScreenPlace(): ScreenPlace {
  return useContext(ScreenPlaceContext);
}

interface Entry {
  key: number;
  title: string;
  screen: ReactNode;
  motion?: "push" | "pop" | undefined;
}

/**
 * One section's stack of screens. On compact a pushed screen slides in from the
 * trailing edge and a popped one slides back out; wider classes swap at once.
 * Escape goes back, so a mouse and a keyboard have the edge swipe's way back.
 * Screens under the top one stay mounted: going back finds them as they were,
 * scroll position included.
 */
export function Stack({
  title,
  root,
  active = true,
  resetKey = 0,
}: {
  title: string;
  root: ReactNode;
  /** The stack on screen: only it answers Escape. */
  active?: boolean;
  /** A new value pops to the root (the section's tab chosen again). */
  resetKey?: number;
}) {
  const sizeClass = useSizeClass();
  const reducedMotion = useReducedMotion();
  const animate = sizeClass === "compact" && !reducedMotion;
  const nextKey = useRef(1);
  const [entries, setEntries] = useState<Entry[]>([{ key: 0, title, screen: null }]);

  useEffect(() => {
    if (resetKey) setEntries((current) => current.slice(0, 1));
  }, [resetKey]);

  const push = useCallback(
    (pushedTitle: string, screen: ReactNode) =>
      setEntries((current) => [
        ...current.filter((entry) => entry.motion !== "pop"),
        {
          key: nextKey.current++,
          title: pushedTitle,
          screen,
          motion: animate ? "push" : undefined,
        },
      ]),
    [animate],
  );
  const pop = useCallback(
    () =>
      setEntries((current) => {
        const live = current.filter((entry) => entry.motion !== "pop");
        if (live.length < 2) return current;
        if (!animate) return live.slice(0, -1);
        return [...live.slice(0, -1), { ...live.at(-1)!, motion: "pop" }];
      }),
    [animate],
  );
  // The end of a slide: a pushed screen settles, a popped one leaves.
  const settle = (key: number) =>
    setEntries((current) =>
      current.flatMap((entry) =>
        entry.key !== key
          ? [entry]
          : entry.motion === "pop"
            ? []
            : [{ ...entry, motion: undefined }],
      ),
    );

  const depth = entries.filter((entry) => entry.motion !== "pop").length;
  useEffect(() => {
    if (!active || depth < 2) return;
    const onKey = (event: KeyboardEvent) => {
      // An open sheet takes Escape first.
      if (event.key !== "Escape" || event.defaultPrevented) return;
      if (document.querySelector("dialog[open]")) return;
      pop();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [active, depth, pop]);

  const navigation = useMemo(() => ({ push, pop }), [push, pop]);
  const top = entries.at(-1)!;
  return (
    <NavigationContext.Provider value={navigation}>
      <div className="relative h-full min-h-0 overflow-hidden">
        {entries.map((entry, index) => {
          const isTop = index === entries.length - 1;
          const isUnder = index === entries.length - 2;
          const visible = isTop || (isUnder && top.motion !== undefined);
          const motion =
            entry.motion ??
            (isUnder && top.motion === "push"
              ? "under"
              : isUnder && top.motion === "pop"
                ? "uncover"
                : undefined);
          return (
            <ScreenPlaceContext.Provider
              key={entry.key}
              value={{ depth: index + 1, backTitle: entries[index - 1]?.title }}
            >
              <div
                className="absolute inset-0 flex min-h-0 flex-col bg-background"
                data-motion={motion}
                hidden={!visible}
                inert={!isTop || entry.motion === "pop"}
                onAnimationEnd={(event) => {
                  if (event.target === event.currentTarget && entry.motion)
                    settle(entry.key);
                }}
              >
                {index === 0 ? root : entry.screen}
              </div>
            </ScreenPlaceContext.Provider>
          );
        })}
      </div>
    </NavigationContext.Provider>
  );
}

export interface Destination {
  id: string;
  title: string;
  /** A lucide icon; the tab bar and the sidebar size it. */
  icon: ReactNode;
  /** The section's first screen. */
  root: ReactNode;
}

/**
 * The app's frame: its sections (2 to 5) in a tab bar at the bottom on compact,
 * as a phone app has them, and in a sidebar on regular and wide, as an iPad or
 * a web app has them. An app with one section shows neither. Choosing the
 * current section again goes back to its first screen.
 */
export function AppShell({ destinations }: { destinations: readonly Destination[] }) {
  const sizeClass = useSizeClass();
  const [selected, setSelected] = useState(destinations[0]!.id);
  const [resets, setResets] = useState<Record<string, number>>({});
  const choose = (id: string) => {
    if (id === selected) setResets((current) => ({ ...current, [id]: (current[id] ?? 0) + 1 }));
    else setSelected(id);
  };
  const sections = destinations.length > 1;
  const compact = sizeClass === "compact";
  return (
    <div className={cn("flex h-full min-h-0", compact ? "flex-col" : "flex-row")}>
      {sections ? (
        compact ? (
          <TabBar destinations={destinations} onChoose={choose} selected={selected} />
        ) : (
          <Sidebar destinations={destinations} onChoose={choose} selected={selected} />
        )
      ) : null}
      {/* The stacks keep their place in the tree, so a resize keeps every section's screens. */}
      <div className="min-h-0 min-w-0 flex-1 order-first sm:order-none">
        {destinations.map((destination) => (
          <div
            key={destination.id}
            className="h-full min-h-0"
            hidden={destination.id !== selected}
          >
            <Stack
              active={destination.id === selected}
              resetKey={resets[destination.id] ?? 0}
              root={destination.root}
              title={destination.title}
            />
          </div>
        ))}
      </div>
    </div>
  );
}

interface SectionsProps {
  destinations: readonly Destination[];
  selected: string;
  onChoose: (id: string) => void;
}

/** The phone's tab bar: icon over label, the current section in the accent color. */
function TabBar({ destinations, selected, onChoose }: SectionsProps) {
  return (
    <nav
      aria-label="Sections"
      className="shrink-0 border-t bg-background"
      data-slot="tab-bar"
      style={{ paddingBottom: "env(safe-area-inset-bottom)" }}
    >
      <ul className="flex">
        {destinations.map((destination) => {
          const current = destination.id === selected;
          return (
            <li key={destination.id} className="min-w-0 flex-1">
              <button
                aria-current={current ? "page" : undefined}
                className={cn(
                  "flex h-12 w-full min-w-0 cursor-pointer flex-col items-center justify-center gap-0.5 text-caption-2 font-medium outline-none focus-visible:bg-accent",
                  current ? "text-primary" : "text-muted-foreground",
                )}
                onClick={() => onChoose(destination.id)}
                type="button"
              >
                <span aria-hidden className="flex [&_svg]:size-6">
                  {destination.icon}
                </span>
                <span className="max-w-full truncate px-1">{destination.title}</span>
              </button>
            </li>
          );
        })}
      </ul>
    </nav>
  );
}

/** The iPad and web sidebar: the sections as rows, the current one filled. */
function Sidebar({ destinations, selected, onChoose }: SectionsProps) {
  return (
    <nav
      aria-label="Sections"
      className="flex w-56 shrink-0 flex-col gap-0.5 overflow-y-auto border-r bg-secondary p-2 pt-3 lg:w-64"
      data-slot="sidebar"
    >
      {destinations.map((destination) => {
        const current = destination.id === selected;
        return (
          <button
            key={destination.id}
            aria-current={current ? "page" : undefined}
            className={cn(
              "flex min-h-8 w-full min-w-0 cursor-pointer items-center gap-2.5 rounded-md px-2.5 text-left text-body outline-none focus-visible:ring-2 focus-visible:ring-ring/50",
              current
                ? "bg-accent font-medium text-foreground"
                : "text-muted-foreground hover:bg-accent hover:text-foreground",
            )}
            data-slot="list-row"
            onClick={() => onChoose(destination.id)}
            type="button"
          >
            <span aria-hidden className="flex shrink-0 [&_svg]:size-4">
              {destination.icon}
            </span>
            <span className="truncate">{destination.title}</span>
          </button>
        );
      })}
    </nav>
  );
}
