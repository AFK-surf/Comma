import { type HTMLAttributes, type Key, useEffect, useRef, useState } from "react";
import { cx } from "../utils";
import { afterAnimations } from "../../tokens/motion";

// Settles the swap where the Web Animations API is missing (tests, old engines).
const titleSwapFallbackMs = 200;

export interface TitleSwapProps extends Omit<
  HTMLAttributes<HTMLSpanElement>,
  "children"
> {
  text: string;
  /**
   * What the title names, such as a Task id. A new title for the same thing
   * blurs across; a host reused for another thing shows its title at once.
   */
  identity?: Key | undefined;
  /** Classes the text itself needs, such as a line clamp. */
  textClassName?: string | undefined;
}

type Swap = {
  identity: Key | undefined;
  text: string;
  leaving?: string;
  version: number;
};

/**
 * A title that an agent may rename while it is on screen. The new text enters
 * where it will rest while the old one fades out over it, so the host sizes to
 * the new title at once and nothing around it is laid out twice. Only opacity,
 * transform and a small blur move, and only during the swap.
 */
export function TitleSwap({
  className,
  identity,
  text,
  textClassName,
  ...props
}: TitleSwapProps) {
  const [swap, setSwap] = useState<Swap>({ identity, text, version: 0 });
  if (swap.text !== text || swap.identity !== identity) {
    setSwap({
      identity,
      text,
      version: swap.version + 1,
      ...(swap.identity === identity && swap.text ? { leaving: swap.text } : {}),
    });
  }
  const swapping = swap.leaving !== undefined;
  const hostRef = useRef<HTMLSpanElement>(null);

  useEffect(() => {
    const host = hostRef.current;
    if (!swapping || !host) return undefined;
    const version = swap.version;
    return afterAnimations(host, titleSwapFallbackMs, () =>
      setSwap((current) =>
        current.version === version
          ? { identity: current.identity, text: current.text, version }
          : current
      )
    );
  }, [swap.version, swapping]);

  return (
    <span
      {...props}
      className={cx("comma-title-swap", className)}
      data-swapping={swapping ? "true" : undefined}
      ref={hostRef}
    >
      {swapping ? (
        <span
          aria-hidden
          className={cx("comma-title-swap-text", textClassName)}
          data-motion="exit"
          key={`leaving-${swap.version}`}
        >
          {swap.leaving}
        </span>
      ) : null}
      <span
        className={cx("comma-title-swap-text", textClassName)}
        data-motion={swapping ? "enter" : undefined}
        key={swap.version}
      >
        {swap.text}
      </span>
    </span>
  );
}
