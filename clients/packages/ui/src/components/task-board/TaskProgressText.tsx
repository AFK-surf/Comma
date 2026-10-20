import {
  useCallback,
  useLayoutEffect,
  useRef,
  useState,
  type TransitionEvent,
} from "react";
import { cx } from "../utils";

type Layer = { key: number; text: string; entering: boolean };

export interface TaskProgressTextProps {
  children: string;
  /** Applied to each line, e.g. the running-task shimmer. */
  className?: string | undefined;
}

/**
 * A running Task's progress on one truncated line. When the words change, the
 * new line rises in as the old one leaves upward, cross-fading through a small
 * blur (task-board.css). The first words render at rest, so a list of cards
 * does not animate as it mounts. A quick run of changes keeps one leaving
 * line at most; the line before it goes at once. A leaving line with no
 * fade to run (reduced motion zeroes it) goes at once too, since no
 * transition ends to remove it.
 */
export function TaskProgressText({ children: text, className }: TaskProgressTextProps) {
  const [layers, setLayers] = useState<{ current: Layer; leaving: Layer | undefined }>(
    () => ({ current: { key: 0, text, entering: false }, leaving: undefined })
  );
  if (layers.current.text !== text) {
    setLayers(({ current }) => ({
      current: { key: current.key + 1, text, entering: true },
      leaving: current,
    }));
  }
  const leavingRef = useRef<HTMLSpanElement>(null);
  const drop = useCallback(
    () =>
      setLayers((state) => (state.leaving ? { ...state, leaving: undefined } : state)),
    []
  );
  const settle = (event: TransitionEvent<HTMLSpanElement>) => {
    if (event.target !== event.currentTarget || event.propertyName !== "opacity")
      return;
    drop();
  };
  const { current, leaving } = layers;
  useLayoutEffect(() => {
    const line = leavingRef.current;
    if (line && !fades(line)) drop();
  }, [drop, leaving?.key]);
  // Each line truncates itself, so a shimmer on the line fills its ellipsis too.
  const lineClassName = cx("comma-task-progress-line min-w-0 truncate", className);
  return (
    <span className="comma-task-progress-text" data-slot="task-progress-text">
      {leaving ? (
        <span
          aria-hidden
          className={lineClassName}
          data-state="leaving"
          key={leaving.key}
          onTransitionCancel={settle}
          onTransitionEnd={settle}
          ref={leavingRef}
        >
          {leaving.text}
        </span>
      ) : null}
      <span
        className={lineClassName}
        data-state={current.entering ? "entering" : undefined}
        key={current.key}
      >
        {current.text}
      </span>
    </span>
  );
}

/** Whether any of the line's transitions runs: reduced motion zeroes them all. */
function fades(line: HTMLElement) {
  return getComputedStyle(line)
    .transitionDuration.split(",")
    .some((duration) => Number.parseFloat(duration) > 0);
}
