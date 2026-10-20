import {
  createContext,
  useCallback,
  useContext,
  useLayoutEffect,
  useState,
} from "react";

/**
 * A widget sits deep inside a row's Markdown, yet the row's width depends on it.
 * Each mounted widget reports +1, then -1 when it leaves, so the row can mark
 * itself instead of the stylesheet finding the widget with `:has()`.
 */
const WidgetPresenceContext = createContext<((change: 1 | -1) => void) | undefined>(
  undefined
);

/** Provides the reporter from {@link useWidgetPresence} to the widgets it wraps. */
export const WidgetPresence = WidgetPresenceContext.Provider;

/** Whether any widget inside the provider is mounted, and the reporter to provide. */
export function useWidgetPresence() {
  const [widgets, setWidgets] = useState(0);
  const reportWidget = useCallback(
    (change: 1 | -1) => setWidgets((count) => count + change),
    []
  );
  return [widgets > 0, reportWidget] as const;
}

/** Counts the calling widget in; a layout effect so the row's mark lands before paint. */
export function useReportWidgetPresence() {
  const reportWidget = useContext(WidgetPresenceContext);
  useLayoutEffect(() => {
    reportWidget?.(1);
    return () => reportWidget?.(-1);
  }, [reportWidget]);
}
