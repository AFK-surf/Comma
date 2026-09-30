import {
  messages,
  taskStatusBucketLabel,
  visibleTaskStatusBuckets as taskStatusBuckets,
  type CommaLocale,
  type VisibleTaskStatusBucket as TaskStatusBucket,
} from "@comma/i18n";
import { BUCKET_TO_STATUS_ID } from "./statusMapping";
import { useCommaLocale } from "@comma/i18n/react";
import {
  createElement,
  type CSSProperties,
  type PointerEvent as ReactPointerEvent,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
  type RefObject,
} from "react";
import { isReducedMotionEnabled, subscribeToReducedMotion } from "../../tokens";
import { Tooltip } from "../tooltip";
import { statusIconMarkup } from "./statusIconMarkup";

/* The web component registers itself on import. Importing it lazily on first
   mount keeps the @comma/ui barrel free of module side effects — every window
   bundles the barrel, including ones that never render an indicator. */
let elementRegistration: Promise<unknown> | undefined;

function isStatusIndicatorElementDefined(): boolean {
  return (
    typeof customElements !== "undefined" &&
    customElements.get("status-indicator") !== undefined
  );
}

function ensureStatusIndicatorElement(): Promise<unknown> {
  elementRegistration ??= import("status-indicator");
  return elementRegistration;
}

export const statusIds = [
  "backlog",
  "in-progress",
  "needs-review",
  "done",
  "cancel",
] as const;

export type StatusId = (typeof statusIds)[number];

interface StatusDefinition {
  color: string;
  icon: string;
  id: StatusId;
  label: string;
}

export interface StatusIndicatorElement extends HTMLElement {
  statuses: StatusDefinition[];
  value: StatusId;
}

export interface StatusIndicatorProps {
  "aria-label"?: string;
  className?: string;
  onChange?: (value: StatusId) => void;
  value: StatusId;
}

type StatusIndicatorTokens = CSSProperties & Record<`--si-${string}`, string | number>;

const iconistsMarkup = statusIconMarkup;
const optionKeyGlyph = "⌥";

function statusIndexFromEvent(event: Event): number | undefined {
  const status = event
    .composedPath()
    .find(
      (target): target is HTMLElement =>
        target instanceof HTMLElement && target.matches('[role="radio"][data-index]')
    );
  if (!status) return undefined;

  const index = Number(status.dataset.index);
  return Number.isInteger(index) && index >= 0 && index < statusIds.length
    ? index
    : undefined;
}

const BUCKET_PRESENTATION: Record<TaskStatusBucket, { color: string; icon: string }> = {
  backlog: {
    color: "var(--color-markdown-icon-primary)",
    icon: iconistsMarkup.backlog,
  },
  in_progress: {
    color: "var(--color-markdown-icon-primary)",
    icon: iconistsMarkup.inProgress,
  },
  needs_review: {
    color: "var(--color-yellow-500)",
    icon: iconistsMarkup.needsReview,
  },
  done: {
    color: "var(--color-fg-success-primary)",
    icon: iconistsMarkup.done,
  },
  cancelled: {
    color: "var(--color-error-500)",
    icon: iconistsMarkup.cancel,
  },
};

// Order, ids, and labels all derive from the canonical bucket vocabulary.
function commaStatusDefinitions(locale: CommaLocale): StatusDefinition[] {
  return taskStatusBuckets.map((bucket) => ({
    id: BUCKET_TO_STATUS_ID[bucket],
    label: taskStatusBucketLabel(bucket, locale),
    ...BUCKET_PRESENTATION[bucket],
  }));
}

const commaStatusIndicatorTokens: StatusIndicatorTokens = {
  "--si-dot": "var(--color-fg-disabled)",
  "--si-dot-hover": "var(--color-markdown-icon-primary)",
  "--si-dot-hover-bg": "var(--color-bg-quaternary)",
  "--si-duration-in": "var(--motion-duration-feedback-in)",
  "--si-duration-out": "var(--motion-duration-feedback-out)",
  "--si-ease-color": "var(--motion-easing-icon-swap)",
  "--si-ease-out": "var(--motion-easing-smooth-out)",
  "--si-ease-return": "var(--motion-easing-surface-smooth-out)",
  "--si-focus-ring": "var(--color-fg-primary)",
  "--si-label": "var(--color-text-primary)",
  "--si-pill-bg": "var(--color-bg-quaternary)",
};

const reducedMotionStyle = `
.dotc {
  transition: background-color var(--si-duration-out) var(--si-ease-color);
}
.item[aria-checked="false"]:hover .dotc,
.item[aria-checked="false"]:active .dotc {
  transform: none;
}
.item::after,
.item[aria-checked="false"]:hover::after,
.item[aria-checked="false"]:active::after {
  transform: none;
  transition: opacity var(--si-duration-out) var(--si-ease-color);
}
.glyph--spin svg {
  animation: none;
}
.icon svg path.check {
  transition: none;
  stroke-dashoffset: 0;
}
`;

const getReducedMotionServerSnapshot = () => false;
const useBrowserLayoutEffect =
  typeof window === "undefined" ? useEffect : useLayoutEffect;

export function StatusIndicator({
  "aria-label": ariaLabel,
  className,
  onChange,
  value,
}: StatusIndicatorProps) {
  const locale = useCommaLocale();
  const [elementReady, setElementReady] = useState(isStatusIndicatorElementDefined);
  const [indicator, setIndicator] = useState<StatusIndicatorElement | null>(null);
  const [focusedShortcutIndex, setFocusedShortcutIndex] = useState<number>();
  const [hoveredShortcutIndex, setHoveredShortcutIndex] = useState<number>();
  const [lastShortcutIndex, setLastShortcutIndex] = useState<number>();
  const [, setShadowRevision] = useState(0);

  useEffect(() => {
    if (elementReady) return undefined;
    let active = true;
    void ensureStatusIndicatorElement().then(() => {
      if (active) setElementReady(true);
    });
    return () => {
      active = false;
    };
  }, [elementReady]);
  const onChangeRef = useRef(onChange);
  onChangeRef.current = onChange;
  const statuses = useMemo(() => commaStatusDefinitions(locale), [locale]);
  const reducedMotion = useSyncExternalStore(
    subscribeToReducedMotion,
    isReducedMotionEnabled,
    getReducedMotionServerSnapshot
  );

  useEffect(() => {
    if (!indicator) return undefined;
    const handleChange = (event: Event) => {
      const detail = (event as CustomEvent<{ value: StatusId }>).detail;
      if (detail?.value) onChangeRef.current?.(detail.value);
    };
    indicator.addEventListener("change", handleChange);
    return () => indicator.removeEventListener("change", handleChange);
  }, [indicator]);

  useEffect(() => {
    const shadowRoot = indicator?.shadowRoot;
    if (!shadowRoot) return undefined;

    const handleFocusIn = (event: Event) => {
      const index = statusIndexFromEvent(event);
      if (index !== undefined) {
        setFocusedShortcutIndex(index);
        setLastShortcutIndex(index);
      }
    };
    const handleFocusOut = (event: Event) => {
      const relatedTarget = (event as FocusEvent).relatedTarget;
      if (relatedTarget instanceof Node && shadowRoot.contains(relatedTarget)) {
        return;
      }
      setFocusedShortcutIndex(undefined);
    };
    const observer = new MutationObserver((records) => {
      if (records.some((record) => record.type === "childList")) {
        setShadowRevision((current) => current + 1);
      }
    });

    shadowRoot.addEventListener("focusin", handleFocusIn);
    shadowRoot.addEventListener("focusout", handleFocusOut);
    observer.observe(shadowRoot, { childList: true });
    return () => {
      shadowRoot.removeEventListener("focusin", handleFocusIn);
      shadowRoot.removeEventListener("focusout", handleFocusOut);
      observer.disconnect();
    };
  }, [indicator]);

  useEffect(() => {
    if (!indicator) return undefined;
    const ownerWindow = indicator.ownerDocument.defaultView;
    if (!ownerWindow) return undefined;

    const handleShortcut = (event: KeyboardEvent) => {
      if (
        event.defaultPrevented ||
        event.isComposing ||
        event.repeat ||
        !event.altKey ||
        event.ctrlKey ||
        event.metaKey ||
        event.shiftKey
      ) {
        return;
      }

      const match = /^Digit([1-5])$/.exec(event.code);
      if (!match) return;

      const nextStatus = statusIds[Number(match[1]) - 1];
      if (!nextStatus) return;

      event.preventDefault();
      if (indicator.value === nextStatus) return;

      indicator.value = nextStatus;
      onChangeRef.current?.(nextStatus);
    };

    ownerWindow.addEventListener("keydown", handleShortcut);
    return () => ownerWindow.removeEventListener("keydown", handleShortcut);
  }, [indicator]);

  // React skips property writes when the prop reference is unchanged, so a
  // parent that rejects a user selection would leave the element out of sync.
  useBrowserLayoutEffect(() => {
    if (indicator && indicator.value !== value) indicator.value = value;
  });

  useBrowserLayoutEffect(() => {
    if (!indicator?.shadowRoot) return;

    const statusOptions = indicator.shadowRoot.querySelectorAll<HTMLElement>(
      '[role="radio"][data-index]'
    );
    statusOptions.forEach((status, index) => {
      status.setAttribute("aria-keyshortcuts", `Alt+${index + 1}`);
    });
  }, [indicator, statuses]);

  useBrowserLayoutEffect(() => {
    if (!indicator?.shadowRoot) return undefined;

    const style = document.createElement("style");
    style.dataset.commaReducedMotion = "true";
    style.textContent = reducedMotionStyle;

    const snapToSelectedStatus = () => {
      const step = Reflect.get(indicator, "_step") as
        | ((milliseconds: number) => void)
        | undefined;
      step?.call(indicator, 10_000);
    };

    if (reducedMotion) {
      indicator.shadowRoot.append(style);
      snapToSelectedStatus();
      indicator.addEventListener("change", snapToSelectedStatus);
    }

    return () => {
      style.remove();
      indicator.removeEventListener("change", snapToSelectedStatus);
    };
  }, [indicator, reducedMotion, value]);

  const activeShortcutIndex = hoveredShortcutIndex ?? focusedShortcutIndex;
  // Keep the last concrete segment as the anchor while the tooltip exits.
  // Falling back to the host during that transition makes the surface jump.
  const shortcutTargetIndex = activeShortcutIndex ?? lastShortcutIndex;
  const tooltipTargetElement =
    shortcutTargetIndex === undefined
      ? indicator
      : (indicator?.shadowRoot?.querySelector<HTMLElement>(
          `[role="radio"][data-index="${shortcutTargetIndex}"]`
        ) ?? indicator);
  const tooltipTriggerRef = useMemo<RefObject<Element | null>>(
    () => ({ current: tooltipTargetElement }),
    [tooltipTargetElement]
  );

  if (!elementReady) {
    // Reserve the pill row's height so the switcher doesn't shift when the
    // element chunk lands (one-time, first mount only).
    return createElement("div", {
      "aria-hidden": true,
      className,
      // Pill height (28px) from tokens: 24 + 4.
      style: {
        blockSize: "calc(var(--spacing-3xl) + var(--spacing-xs))",
      } as CSSProperties,
    });
  }

  const selectedStatusIndex = Math.max(0, statusIds.indexOf(value));
  const tooltipStatusIndex = shortcutTargetIndex ?? selectedStatusIndex;
  const tooltipStatus = statuses[tooltipStatusIndex] ?? statuses[0]!;
  const indicatorElement = createElement("status-indicator", {
    "aria-label": ariaLabel ?? messages.ui_task_status_label(undefined, { locale }),
    className,
    ref: setIndicator,
    statuses,
    style: commaStatusIndicatorTokens,
    value,
  });

  return (
    <Tooltip
      content={tooltipStatus.label}
      isOpen={activeShortcutIndex !== undefined}
      placement="top"
      shortcut={[optionKeyGlyph, String(tooltipStatusIndex + 1)]}
      triggerRef={tooltipTriggerRef}
    >
      <span
        className="inline-flex shrink-0"
        data-slot="status-indicator-trigger"
        onPointerLeave={() => {
          setHoveredShortcutIndex(undefined);
        }}
        onPointerMove={(event: ReactPointerEvent<HTMLElement>) => {
          const index = statusIndexFromEvent(event.nativeEvent);
          if (index !== undefined) {
            setHoveredShortcutIndex(index);
            setLastShortcutIndex(index);
          }
        }}
      >
        {indicatorElement}
      </span>
    </Tooltip>
  );
}
