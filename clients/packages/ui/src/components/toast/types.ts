export type ToastVariant = "single" | "description" | "action";

export type ToastIntent = "info" | "success" | "warning" | "error";

/**
 * A glyph that names what the toast is about, shown in place of the intent's
 * own. It keeps the intent's color, so an error still reads as an error.
 */
export type ToastGlyph = "gauge";

export interface ToastAction {
  label: string;
  onPress?: () => void;
  hierarchy?: "secondary-gray" | "tertiary-gray";
}

export interface ToastProps {
  title: string;
  description?: string;
  variant?: ToastVariant;
  intent?: ToastIntent;
  icon?: ToastGlyph;
  onClose?: () => void;
  actions?: ToastAction[];
  className?: string;
  /** Stable hook for tests; rendered as `data-testid` on the toast shell. */
  testId?: string;
}
