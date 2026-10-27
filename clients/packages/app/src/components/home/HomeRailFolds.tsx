import {
  createContext,
  useCallback,
  useContext,
  useLayoutEffect,
  useRef,
  useState,
  type CSSProperties,
  type ReactNode,
  type RefObject,
} from "react";
import {
  commaHomeRailFoldsOpen,
  commaHomeRailMinWidth,
  commaHomeGreetPreferredMinWidth,
  commaHomeTasksPreferredWidth,
  mergeHomeRailFolds,
  resolveHomeRailFolds,
  type CommaHomeRailFolds,
  type CommaHomeRailName,
} from "../shellGeometry";
import { isReducedMotionEnabled } from "@comma/ui/tokens";
import { useChatSidebarOpen } from "../chat-sidebar/ChatSidebarContext";
import { useRailFoldSpring } from "../railFoldSpring";

/** The gutter each rail's track carries beside the chat (`--spacing-xl`). */
const commaHomeRailGutter = 16;

export interface CommaHomeRailState {
  /** Shut by the reader from the rail's edge handle. */
  widths?: Record<CommaHomeRailName, number>;
  setWidth?: (rail: CommaHomeRailName, width: number) => void;
  collapsed: CommaHomeRailFolds;
  /** Shut by the route width: the rail no longer has a legible width. */
  folds: CommaHomeRailFolds;
  toggleCollapsed: (rail: CommaHomeRailName) => void;
}

const homeRailStateOpen: CommaHomeRailState = {
  collapsed: commaHomeRailFoldsOpen,
  folds: commaHomeRailFoldsOpen,
  toggleCollapsed: () => {},
};

const HomeRailStateContext = createContext<CommaHomeRailState>(homeRailStateOpen);

export function HomeRailFoldProvider({
  children,
  state,
}: {
  children: ReactNode;
  state: CommaHomeRailState;
}) {
  return (
    <HomeRailStateContext.Provider value={state}>
      {children}
    </HomeRailStateContext.Provider>
  );
}

/**
 * Moves one Home rail. The track width reads `--comma-home-<rail>-fold` on the
 * layout; the surface fades and shifts from its own non-inherited progress,
 * so a frame restyles those two elements and not the rail's content.
 *
 * A reader's toggle plays the fold spring. A fold the route width forces
 * lands at once, in the same layout as whatever moved the route (the Chat
 * Sidebar opening, a window drag), which moves it in one step too.
 *
 * When the reader shuts a rail, the chat column keeps its current width and
 * rides the growing track, then takes the new width once at rest. The thread
 * wraps its text once instead of on every frame of the fold.
 */
function useHomeRailFoldMotion(
  layoutRef: RefObject<HTMLDivElement | null>,
  rail: CommaHomeRailName,
  shut: boolean,
  readerCollapsed: boolean,
  autoFolded: boolean,
  preferredWidth: number
) {
  const previousReaderCollapsed = useRef(readerCollapsed);
  const readerMoved = previousReaderCollapsed.current !== readerCollapsed;
  const foldProperty = `--comma-home-${rail}-fold`;
  useRailFoldSpring(shut, {
    span: () => preferredWidth + commaHomeRailGutter,
    timing: () => (readerMoved ? { kind: "spring" } : { kind: "instant" }),
    write: (progress, phase) => {
      const layout = layoutRef.current;
      if (!layout) return;
      const railElement = layout.querySelector<HTMLElement>(
        `:scope > .comma-home-${rail}-rail`
      );
      const surface = railElement?.querySelector<HTMLElement>(
        ":scope > .comma-home-rail-surface"
      );
      layout.style.setProperty(foldProperty, String(progress));
      if (phase === "rest") {
        railElement?.removeAttribute("data-fold-moving");
        surface?.style.removeProperty("--comma-home-rail-fold-progress");
        const chat = layout.querySelector<HTMLElement>(":scope > .comma-home-chat");
        if (chat?.dataset.foldHeldBy === rail) releaseChatWidth(chat);
      } else {
        railElement?.setAttribute("data-fold-moving", phase);
        surface?.style.setProperty("--comma-home-rail-fold-progress", String(progress));
      }
    },
  });

  useLayoutEffect(() => {
    const chat = layoutRef.current?.querySelector<HTMLElement>(
      ":scope > .comma-home-chat"
    );
    if (!chat) return;
    // An auto-folded rail is already shut, so a reader collapse moves nothing.
    const opensRoom = shut && readerMoved && !autoFolded;
    if (opensRoom && !chat.dataset.foldHeldBy && !isReducedMotionEnabled()) {
      chat.style.width = `${chat.getBoundingClientRect().width}px`;
      chat.style.justifySelf = "center";
      chat.dataset.foldHeldBy = rail;
    } else if (!shut && chat.dataset.foldHeldBy === rail) {
      // Reopened mid-fold: the track now narrows, so the chat follows it.
      releaseChatWidth(chat);
    }
  }, [autoFolded, layoutRef, rail, readerMoved, shut]);

  useLayoutEffect(() => {
    previousReaderCollapsed.current = readerCollapsed;
  }, [readerCollapsed]);
}

function releaseChatWidth(chat: HTMLElement) {
  chat.style.removeProperty("width");
  chat.style.removeProperty("justify-self");
  delete chat.dataset.foldHeldBy;
}

/** Keep animated geometry on the layout owner, outside the content trees. */
export function HomeLayout({ children }: { children: ReactNode }) {
  const { collapsed, folds, widths } = useContext(HomeRailStateContext);
  const shut = mergeHomeRailFolds(folds, collapsed);
  // React renders only the first value of each fold; the fold motion writes
  // every later one. A value React wrote in the commit would land the rail at
  // its end before a reader's spring could start from where it is.
  const [firstShut] = useState(shut);
  const layoutRef = useRef<HTMLDivElement>(null);
  useHomeRailFoldMotion(
    layoutRef,
    "greet",
    shut.greet,
    collapsed.greet,
    folds.greet,
    widths?.greet ?? commaHomeGreetPreferredMinWidth
  );
  useHomeRailFoldMotion(
    layoutRef,
    "tasks",
    shut.tasks,
    collapsed.tasks,
    folds.tasks,
    widths?.tasks ?? commaHomeTasksPreferredWidth
  );
  const style = {
    "--comma-home-greet-preferred": `${widths?.greet ?? commaHomeGreetPreferredMinWidth}px`,
    "--comma-home-tasks-preferred": `${widths?.tasks ?? commaHomeTasksPreferredWidth}px`,
    "--comma-home-greet-fold": firstShut.greet ? 1 : 0,
    "--comma-home-tasks-fold": firstShut.tasks ? 1 : 0,
  } as CSSProperties;
  return (
    <div
      className="comma-home-layout"
      ref={layoutRef}
      data-greet-folded={shut.greet}
      data-testid="home-responsive-layout"
      style={style}
    >
      {children}
    </div>
  );
}

/** Whether the rail is out of the layout, from either cause. */
export function useHomeRailFolded(rail: CommaHomeRailName) {
  const { collapsed, folds } = useContext(HomeRailStateContext);
  return mergeHomeRailFolds(folds, collapsed)[rail];
}

/**
 * The rail's own collapse state, kept apart from the width fold: a rail the
 * route cannot hold has nothing to expand into, so its handle stands down
 * rather than offering a click that could not widen anything.
 */
export function useHomeRailCollapse(rail: CommaHomeRailName) {
  const { collapsed, folds, toggleCollapsed, widths, setWidth } =
    useContext(HomeRailStateContext);
  return {
    width: widths?.[rail] ?? commaHomeRailMinWidth,
    setWidth,
    autoFolded: folds[rail],
    collapsed: collapsed[rail],
    toggleCollapsed,
    /** Where each rail's fold is heading, not where its transition is now. */
    shut: mergeHomeRailFolds(folds, collapsed),
    tasksWidth: widths?.tasks ?? commaHomeTasksPreferredWidth,
  };
}

/**
 * Publishes each Home rail's fold marker from the route width. The rails
 * themselves are responsive columns (styles.css) and every unfolded width is
 * a legal resting shape; the marker only flips where a rail can no longer
 * hold its content floor, so this renders nothing and sets state only on a
 * flip — never per frame of a drag.
 */
export function HomeRailFolds({
  active,
  greetWidth = commaHomeGreetPreferredMinWidth,
  greetCollapsed = false,
  onStateChange,
  routeRef,
}: {
  active: boolean;
  greetWidth?: number;
  greetCollapsed?: boolean;
  onStateChange: (folds: CommaHomeRailFolds) => void;
  routeRef: RefObject<HTMLElement | null>;
}) {
  const onStateChangeRef = useRef(onStateChange);
  onStateChangeRef.current = onStateChange;
  // The parent retains its last folds across a lease remount; this observer
  // follows the replaced Home DOM. Its first valid measurement must publish
  // even an open state, rather than treating an unmeasured default as truth.
  const publishedRef = useRef<CommaHomeRailFolds | undefined>(undefined);
  const trailingOpen = useChatSidebarOpen();

  const publishFolds = useCallback(
    (routeWidth: number, preferredGreetWidth = greetWidth) => {
      if (routeWidth <= 0) return;
      const folds = resolveHomeRailFolds({
        previous: publishedRef.current ?? commaHomeRailFoldsOpen,
        routeWidth,
        greetWidth: preferredGreetWidth,
        greetCollapsed,
      });
      if (folds === publishedRef.current) return;
      publishedRef.current = folds;
      onStateChangeRef.current(folds);
    },
    [greetWidth, greetCollapsed]
  );

  // The fold has to land while a drag runs, at the threshold, not as a
  // correction applied after the pointer stops. It also has to land in the
  // commit that opens or closes the Chat Sidebar, which takes its width in one
  // step, so the chat column lays out once for both.
  useLayoutEffect(() => {
    const route = routeRef.current;
    if (!active || !route || typeof ResizeObserver === "undefined") return undefined;
    const layout = route.querySelector<HTMLElement>(".comma-home-layout");
    const greetRail = layout?.querySelector<HTMLElement>(
      ":scope > .comma-home-greet-rail"
    );
    const measure = () => {
      // A seam drag previews its width in CSS and commits the preference on
      // release. Read that inline value without resolving styles so Tasks can
      // fold or return while the pointer is still down. The shared observer
      // delivers the rail change after layout; only a fold flip reaches React.
      const preferredGreetWidth = Number.parseFloat(
        layout?.style.getPropertyValue("--comma-home-greet-preferred") ?? ""
      );
      publishFolds(
        route.clientWidth,
        Number.isFinite(preferredGreetWidth) ? preferredGreetWidth : undefined
      );
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(route);
    if (greetRail) observer.observe(greetRail);
    return () => observer.disconnect();
  }, [active, publishFolds, routeRef, trailingOpen]);

  return null;
}
