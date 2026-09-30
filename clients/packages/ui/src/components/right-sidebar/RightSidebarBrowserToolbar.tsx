import type {
  ComponentPropsWithoutRef,
  FormEvent,
  PointerEvent as ReactPointerEvent,
  TransitionEvent as ReactTransitionEvent,
} from "react";
import { useCommaMessages } from "@comma/i18n/react";
import { useEffect, useRef, useState } from "react";
import { Focusable } from "react-aria-components";
import {
  ArrowLeftIcon,
  ArrowRightIcon,
  GlobeIcon,
  ReloadIcon,
  SquareCursorIcon,
  SettingsSliderHorizontalIcon,
  XIcon,
} from "../icons";
import { isReducedMotionEnabled, motionDuration } from "../../tokens/motion";
import { Tooltip } from "../tooltip";
import { cx } from "../utils";

export type RightSidebarBrowserToolbarProps = Omit<
  ComponentPropsWithoutRef<"form">,
  "children" | "onSubmit"
> & {
  address: string;
  addressInvalid?: boolean | undefined;
  addressPlaceholder?: string | undefined;
  canGoBack: boolean;
  canGoForward: boolean;
  disabled?: boolean | undefined;
  loading?: boolean | undefined;
  inspecting?: boolean | undefined;
  onAddressChange: (value: string) => void;
  onAddressFocus?: (() => void) | undefined;
  onAddressBlur?: (() => void) | undefined;
  onAddressSubmit: () => void;
  onBack: () => void;
  onForward: () => void;
  onInspect?: (() => void) | undefined;
  /** Hands the page to the system browser; independent of `disabled`. */
  onOpenExternal?: (() => void) | undefined;
  onPermissions?:
    | ((anchor: { x: number; y: number; width: number; height: number }) => void)
    | undefined;
  onReload: () => void;
  onStop?: (() => void) | undefined;
};

/**
 * The reload glyph turning is the only thing that says "reloading" before the
 * network answers, and a click cuts that turn off twice over: the press ends
 * before the sweep lands, and `loading` swaps in the stop X before the glyph
 * comes back. So hold the press through its travel however briefly the button
 * was clicked, then hold the swap until the recoil has settled. The turn always
 * plays once, whole, and the X arrives to a glyph at rest.
 */
const toolbarButtonClassName =
  "comma-right-sidebar-browser-button comma-icon-press relative inline-flex size-7 shrink-0 items-center justify-center rounded-sm border-0 bg-transparent p-xs text-sidebar-icon-primary outline-none transition-[background-color] duration-150 ease-[cubic-bezier(0.23,1,0.32,1)] focus-visible:shadow-focus-gray disabled:cursor-default disabled:opacity-40";

type ReloadMotionPhase = "idle" | "travel" | "held" | "recoil";

// transitionend is authoritative. This only prevents a lost event from leaving
// the toolbar stuck, and deliberately sits beyond the declared CSS duration.
const reloadTransitionFallbackBufferMs = 30;

export const RightSidebarBrowserToolbar = ({
  address,
  addressInvalid = false,
  addressPlaceholder = "Search or enter URL",
  canGoBack,
  canGoForward,
  className,
  disabled = false,
  loading = false,
  inspecting = false,
  onAddressBlur,
  onAddressChange,
  onAddressFocus,
  onAddressSubmit,
  onBack,
  onForward,
  onInspect,
  onOpenExternal,
  onPermissions,
  onReload,
  onStop,
  ...formProps
}: RightSidebarBrowserToolbarProps) => {
  const messages = useCommaMessages();
  const handleSubmit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (disabled) return;
    onAddressSubmit();
  };

  // Extends the CSS press state past a fast pointerup so the sweep completes.
  const [reloadPressHeld, setReloadPressHeld] = useState(false);
  // Holds back the stop X while the glyph is still turning or coming back.
  const [reloadTurning, setReloadTurning] = useState(false);
  const reloadPressedRef = useRef(false);
  const reloadPointerDownRef = useRef(false);
  const reloadSwapOwedRef = useRef(false);
  const reloadMotionPhaseRef = useRef<ReloadMotionPhase>("idle");
  const reloadIconSlotRef = useRef<HTMLSpanElement>(null);
  const reloadFallbackTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const reloadFrameRef = useRef<number | null>(null);

  const clearReloadPhaseFallback = () => {
    if (reloadFallbackTimerRef.current !== null) {
      clearTimeout(reloadFallbackTimerRef.current);
      reloadFallbackTimerRef.current = null;
    }
    if (reloadFrameRef.current !== null) {
      cancelAnimationFrame(reloadFrameRef.current);
      reloadFrameRef.current = null;
    }
  };

  useEffect(() => clearReloadPhaseFallback, []);

  /**
   * A missing transitionend must not leave the toolbar stuck. Arm the watchdog
   * from the next frame, after the phase's style has been applied; ordinary
   * completion still comes from the browser's rotate transition event. A slow
   * renderer can outlive the nominal duration, so the fallback must also wait
   * for an unfinished rotation instead of cutting it off by wall-clock time.
   */
  const armReloadPhaseFallback = (duration: number, done: () => void) => {
    clearReloadPhaseFallback();
    reloadFrameRef.current = requestAnimationFrame(() => {
      reloadFrameRef.current = null;
      const timer = setTimeout(() => {
        const finish = () => {
          // An event, unmount, or newer press may have retired this watchdog
          // while its animation promise was pending.
          if (reloadFallbackTimerRef.current !== timer) return;
          reloadFallbackTimerRef.current = null;
          done();
        };
        const rotation = reloadIconSlotRef.current
          ?.querySelector("svg")
          ?.getAnimations?.()
          .find(
            (animation) =>
              "transitionProperty" in animation &&
              animation.transitionProperty === "rotate"
          );
        if (rotation) {
          const afterTransitionEvents = () => {
            if (reloadFallbackTimerRef.current !== timer) return;
            // finished promises settle before transitionend is dispatched.
            // Let the event retire this phase before using its lost-event path.
            reloadFrameRef.current = requestAnimationFrame(() => {
              reloadFrameRef.current = null;
              finish();
            });
          };
          void rotation.finished.then(afterTransitionEvents, afterTransitionEvents);
        } else finish();
      }, duration + reloadTransitionFallbackBufferMs);
      reloadFallbackTimerRef.current = timer;
    });
  };

  const finishReloadRecoil = () => {
    if (reloadMotionPhaseRef.current !== "recoil") return;
    clearReloadPhaseFallback();
    reloadMotionPhaseRef.current = "idle";
    if (!reloadSwapOwedRef.current) return;
    reloadSwapOwedRef.current = false;
    setReloadTurning(false);
  };

  const beginReloadRecoil = () => {
    reloadMotionPhaseRef.current = "recoil";
    setReloadPressHeld(false);
    armReloadPhaseFallback(motionDuration.pressRecoil, finishReloadRecoil);
  };

  const finishReloadTravel = () => {
    if (reloadMotionPhaseRef.current !== "travel") return;
    clearReloadPhaseFallback();
    if (reloadPointerDownRef.current) {
      reloadMotionPhaseRef.current = "held";
      return;
    }
    beginReloadRecoil();
  };

  const handleReloadTransitionEnd = (event: ReactTransitionEvent<HTMLSpanElement>) => {
    if (
      event.propertyName !== "rotate" ||
      !(event.target instanceof Element) ||
      !event.target.classList.contains("comma-icon-press-refresh")
    ) {
      return;
    }

    if (reloadMotionPhaseRef.current === "travel") finishReloadTravel();
    else if (reloadMotionPhaseRef.current === "recoil") finishReloadRecoil();
  };

  const handleReloadPointerDown = (event: ReactPointerEvent<HTMLButtonElement>) => {
    // Reduced motion turns nothing, and a keyboard press never gets here, so
    // both fall through to the immediate swap below.
    if (
      event.button !== 0 ||
      !event.isPrimary ||
      loading ||
      disabled ||
      isReducedMotionEnabled()
    )
      return;
    clearReloadPhaseFallback();
    reloadPressedRef.current = true;
    reloadPointerDownRef.current = true;
    reloadMotionPhaseRef.current = "travel";
    setReloadPressHeld(true);
    armReloadPhaseFallback(motionDuration.pressTravel, finishReloadTravel);
  };

  const handleReloadPointerEnd = (cancelled: boolean) => {
    reloadPointerDownRef.current = false;
    if (cancelled) reloadPressedRef.current = false;
    // A long hold has already finished its outward travel. Let CSS recoil now;
    // the following click will owe the eventual glyph swap to this phase.
    if (reloadMotionPhaseRef.current === "held") beginReloadRecoil();
  };

  const handleReloadPointerLeave = (event: ReactPointerEvent<HTMLButtonElement>) => {
    if (event.buttons !== 0) handleReloadPointerEnd(true);
  };

  const handleReloadOrStop = () => {
    if (loading) {
      onStop?.();
      return;
    }
    onReload();

    if (!reloadPressedRef.current) return;
    reloadPressedRef.current = false;
    setReloadTurning(true);
    reloadSwapOwedRef.current = true;
  };

  const showStop = loading && !reloadTurning;

  return (
    <form
      {...formProps}
      aria-label={formProps["aria-label"] ?? "Browser navigation"}
      className={cx(
        "comma-right-sidebar-browser-toolbar relative flex h-10 items-center gap-xl border-b-[0.5px] border-primary bg-main-panel-bg px-lg py-sm",
        className
      )}
      data-loading={loading ? "true" : "false"}
      data-slot="right-sidebar-browser-toolbar"
      onSubmit={handleSubmit}
    >
      <div className="flex shrink-0 items-center gap-xs">
        <button
          aria-label="Back"
          className={toolbarButtonClassName}
          disabled={disabled || !canGoBack}
          onClick={onBack}
          type="button"
        >
          <ArrowLeftIcon className="comma-icon-press-back size-5" />
        </button>
        <button
          aria-label="Forward"
          className={toolbarButtonClassName}
          disabled={disabled || !canGoForward}
          onClick={onForward}
          type="button"
        >
          <ArrowRightIcon className="comma-icon-press-forward size-5" />
        </button>
        <button
          aria-label={loading ? "Stop loading" : "Reload"}
          className={cx(toolbarButtonClassName, "comma-right-sidebar-browser-reload")}
          disabled={disabled}
          onClick={handleReloadOrStop}
          onPointerCancel={() => handleReloadPointerEnd(true)}
          onPointerDown={handleReloadPointerDown}
          onPointerLeave={handleReloadPointerLeave}
          onPointerUp={() => handleReloadPointerEnd(false)}
          type="button"
          {...(reloadPressHeld ? { "data-press-held": "" } : {})}
        >
          <span aria-hidden className="invisible size-5" />
          <span
            aria-hidden
            className={cx(
              "comma-right-sidebar-browser-icon absolute inset-0 flex items-center justify-center",
              showStop
                ? "comma-right-sidebar-browser-icon-exit"
                : "comma-right-sidebar-browser-icon-enter"
            )}
            data-visible={showStop ? "false" : "true"}
            onTransitionEnd={handleReloadTransitionEnd}
            ref={reloadIconSlotRef}
          >
            <ReloadIcon
              className={cx(
                "comma-icon-press-refresh size-5",
                showStop && "comma-right-sidebar-browser-reload-spin"
              )}
            />
          </span>
          <span
            aria-hidden
            className={cx(
              "comma-right-sidebar-browser-icon absolute inset-0 flex items-center justify-center",
              showStop
                ? "comma-right-sidebar-browser-icon-enter"
                : "comma-right-sidebar-browser-icon-exit"
            )}
            data-visible={showStop ? "true" : "false"}
          >
            <XIcon className="size-5" />
          </span>
        </button>
      </div>

      <label className="comma-right-sidebar-browser-address flex min-w-0 flex-1 items-start rounded-xs px-md py-xs outline-none transition-colors duration-150 ease-[cubic-bezier(0.23,1,0.32,1)]">
        <span className="sr-only">Address</span>
        <input
          aria-invalid={addressInvalid ? "true" : undefined}
          className={cx(
            "m-0 w-full min-w-0 border-0 bg-transparent p-0 text-sm leading-5 tracking-[-0.14px] text-secondary outline-none transition-colors duration-150 ease-[cubic-bezier(0.23,1,0.32,1)] placeholder:text-placeholder",
            addressInvalid && "text-error-primary"
          )}
          disabled={disabled}
          onBlur={onAddressBlur}
          onChange={(event) => onAddressChange(event.currentTarget.value)}
          onFocus={onAddressFocus}
          placeholder={addressPlaceholder}
          spellCheck={false}
          type="text"
          value={address}
        />
      </label>

      {onPermissions || onInspect || onOpenExternal ? (
        <div className="flex shrink-0 items-center gap-xs">
          {onPermissions ? (
            <button
              type="button"
              className={toolbarButtonClassName}
              aria-label="Site permissions"
              title="Site permissions"
              disabled={disabled}
              onClick={(event) => {
                const { x, y, width, height } =
                  event.currentTarget.getBoundingClientRect();
                onPermissions({
                  x: Math.round(x),
                  y: Math.round(y),
                  width: Math.round(width),
                  height: Math.round(height),
                });
              }}
            >
              <SettingsSliderHorizontalIcon className="size-5" />
            </button>
          ) : null}
          {onInspect ? (
            <button
              aria-label={inspecting ? "Cancel element selection" : "Select element"}
              aria-pressed={inspecting}
              className={cx(
                toolbarButtonClassName,
                inspecting && "bg-button-tertiary-bg-hover text-fg-brand-primary"
              )}
              disabled={disabled}
              onClick={onInspect}
              title={inspecting ? "Cancel element selection" : "Select element"}
              type="button"
            >
              <SquareCursorIcon className="size-5" />
            </button>
          ) : null}
          {onOpenExternal ? (
            <Tooltip content={messages.chat_open_in_default_browser()} placement="left">
              <Focusable>
                <button
                  aria-label={messages.chat_open_in_default_browser()}
                  className={toolbarButtonClassName}
                  onClick={onOpenExternal}
                  type="button"
                >
                  <GlobeIcon className="size-5" />
                </button>
              </Focusable>
            </Tooltip>
          ) : null}
        </div>
      ) : null}

      {loading ? (
        <progress
          aria-label="Loading page"
          className="comma-right-sidebar-browser-progress"
        />
      ) : null}
    </form>
  );
};
