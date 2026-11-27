import { useLayoutEffect, useRef, useState } from "react";
import { cx } from "../../utils";

/** How wide a character reads: 2 past Latin-1 (CJK and the like), else 1. */
const widthOf = (char: string) => (char.codePointAt(0)! > 0xff ? 2 : 1);
const widthOfText = (text: string) =>
  Array.from(text).reduce((total, char) => total + widthOf(char), 0);

/**
 * Where a path is cut when it does not fit: `head` gives way (it ends in "…"), `tail` is always shown. The tail is
 * the last folder with its separator when that is short (`/scripts`), else the last `maxTailUnits` of the text. A
 * short text is all head: it is never cut.
 */
export function splitMiddleEllipsis(
  text: string,
  maxTailUnits = 8
): { head: string; tail: string } {
  if (widthOfText(text) <= maxTailUnits + 2) return { head: text, tail: "" };
  const lastSeparator = Math.max(text.lastIndexOf("/"), text.lastIndexOf("\\"));
  if (lastSeparator >= 2) {
    const leaf = text.slice(lastSeparator);
    const leafWidth = widthOfText(leaf);
    if (leafWidth >= 2 && leafWidth <= maxTailUnits)
      return { head: text.slice(0, lastSeparator), tail: leaf };
  }
  const chars = Array.from(text);
  let cut = chars.length;
  let width = 0;
  while (cut > 0 && width + widthOf(chars[cut - 1]!) <= maxTailUnits) {
    cut -= 1;
    width += widthOf(chars[cut]!);
  }
  return { head: chars.slice(0, cut).join(""), tail: chars.slice(cut).join("") };
}

const ELLIPSIS = "…";

/** The longest prefix of `chars` (at least none) that `fits` with what follows it. */
function longestFitting(chars: readonly string[], fits: (prefix: string) => boolean) {
  let low = 0;
  let high = chars.length;
  while (low < high) {
    const mid = Math.ceil((low + high) / 2);
    if (fits(chars.slice(0, mid).join(""))) low = mid;
    else high = mid - 1;
  }
  return chars.slice(0, low).join("");
}

/**
 * `text` as one line within `maxWidth` (by `measure`): whole when it fits, else its head cut where an ellipsis joins
 * it to the tail `splitMiddleEllipsis` keeps (`~/Downlo…n-assets`), with no gap between them. A width that is not
 * known (0) keeps the whole text.
 */
export function fitMiddleEllipsis(
  text: string,
  maxWidth: number,
  measure: (text: string) => number,
  maxTailUnits = 8
): string {
  if (maxWidth <= 0 || measure(text) <= maxWidth) return text;
  const { head, tail } = splitMiddleEllipsis(text, maxTailUnits);
  const limit = maxWidth - 0.5;
  // No tail, or a box too narrow even for the tail: the start of the text, cut at its end.
  if (!tail || measure(ELLIPSIS + tail) > limit) {
    const start = longestFitting(
      Array.from(tail ? text : head),
      (prefix) => measure(prefix + ELLIPSIS) <= limit
    );
    return start + ELLIPSIS;
  }
  const kept = longestFitting(
    Array.from(head),
    (prefix) => measure(prefix + ELLIPSIS + tail) <= limit
  );
  return kept + ELLIPSIS + tail;
}

let measuringContext: CanvasRenderingContext2D | null | undefined;

/** How wide text is in `font` (a canvas's measure); without a canvas (a test's DOM), about 7px a narrow character. */
function textMeasurer(font: string): (text: string) => number {
  if (measuringContext === undefined)
    measuringContext =
      typeof document === "undefined"
        ? null
        : document.createElement("canvas").getContext("2d");
  const context = measuringContext;
  if (!context) return (text) => widthOfText(text) * 7;
  return (text) => {
    context.font = font;
    return context.measureText(text).width;
  };
}

/**
 * A path on one line that, when too wide for its box, loses the middle of it (`~/Downlo…n-assets`), never its end.
 * A hidden copy of the whole path holds the box's width, so cutting the shown text never narrows the box it is
 * measured in.
 */
export function MiddleEllipsis({
  className,
  text,
}: {
  className?: string;
  text: string;
}) {
  const ref = useRef<HTMLSpanElement | null>(null);
  const [shown, setShown] = useState(text);

  useLayoutEffect(() => {
    const element = ref.current;
    if (!element) return;
    const update = () => {
      const width = element.clientWidth;
      if (width <= 0) {
        setShown(text);
        return;
      }
      const style = getComputedStyle(element);
      setShown(
        fitMiddleEllipsis(
          text,
          width,
          textMeasurer(
            `${style.fontStyle} ${style.fontWeight} ${style.fontSize} ${style.fontFamily}`
          )
        )
      );
    };
    update();
    if (typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(update);
    observer.observe(element);
    return () => observer.disconnect();
  }, [text]);

  return (
    <span className={cx("inline-grid min-w-0 max-w-full", className)}>
      <span
        aria-hidden
        className="pointer-events-none invisible h-0 overflow-hidden whitespace-pre before:content-[attr(data-sizer)]"
        data-sizer={text}
      />
      <span ref={ref} className="min-w-0 overflow-hidden whitespace-pre">
        {shown}
      </span>
    </span>
  );
}
