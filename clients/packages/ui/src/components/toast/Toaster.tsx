import { Toaster as SonnerToaster, type ToasterProps } from "sonner";
import { useLayoutEffect, useRef, type CSSProperties } from "react";
import { cx } from "../utils";
import { toastLayout } from "../../tokens";
import {
  registerToastObstructionTarget,
  toastObstructionRightProperty,
} from "./toastObstruction";

const toasterToastOptions: NonNullable<ToasterProps["toastOptions"]> = {
  classNames: {
    // The `!` resets keep sonner's own card chrome off; `Toast` owns padding,
    // background, border and shadow. The `comma-` class is also what lifts our
    // motion overrides above sonner's unlayered stylesheet.
    toast: "comma-sonner-toast w-full !p-0 !bg-transparent !border-0 !shadow-none",
    title: "w-full",
  },
};

// Width the window's right edge gives up to a surface the stack cannot cover;
// 0px whenever nothing claims it. See `toastObstruction`.
const obstructionRight = `var(${toastObstructionRightProperty}, 0px)`;

const toasterStyle = {
  "--width": `min(var(--toast-width-single), calc(100vw - ${obstructionRight} - var(--spacing-xl) * 2))`,
} as CSSProperties;

// Sonner takes the four insets as one value; only the right one steps around an
// obstruction, so the offsets are spelled out per side rather than shared.
const toasterOffset = {
  bottom: toastLayout.viewportInset,
  left: toastLayout.viewportInset,
  right: `calc(${toastLayout.viewportInset}px + ${obstructionRight})`,
  top: toastLayout.viewportInset,
} as const;

export type CommaToasterProps = Omit<ToasterProps, "toastOptions"> & {
  toastOptions?: ToasterProps["toastOptions"];
};

/**
 * Mount once at the root of a window to give it a toast stack, anchored to that
 * window's own bottom-right corner — or, where a native surface has claimed
 * that corner, just clear of it (`claimToastObstructionRight`). A window
 * without one has no toast surface at all — see `setToastsEnabled`.
 *
 * The stack is a top-layer surface: it stays usable over an open modal. React
 * Aria reads the marker on its host — a modal leaves the host out of its inert
 * sweep, lets focus move into it, and does not count a press on a toast as a
 * press outside the modal.
 */
export const Toaster = ({
  className,
  position = "bottom-right",
  gap = toastLayout.stackGap,
  visibleToasts = 3,
  expand = false,
  offset = toasterOffset,
  mobileOffset = toasterOffset,
  closeButton = false,
  style,
  toastOptions,
  ...props
}: CommaToasterProps) => {
  // The obstruction width lands on this host as an inline custom property and
  // reaches sonner's stack by inheritance; see `toastObstruction`.
  const hostRef = useRef<HTMLDivElement | null>(null);
  useLayoutEffect(() => {
    const host = hostRef.current;
    if (!host) return undefined;
    return registerToastObstructionTarget(host);
  }, []);

  return (
    <div data-react-aria-top-layer="true" data-slot="toast-host" ref={hostRef}>
      <SonnerToaster
        className={cx("comma-sonner-toaster [-webkit-app-region:no-drag]", className)}
        position={position}
        gap={gap}
        visibleToasts={visibleToasts}
        expand={expand}
        offset={offset}
        mobileOffset={mobileOffset}
        closeButton={closeButton}
        style={{ ...toasterStyle, ...style }}
        toastOptions={{ ...toasterToastOptions, ...toastOptions }}
        {...props}
      />
    </div>
  );
};
