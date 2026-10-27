import type { ReactNode } from "react";
import type { ButtonHierarchy } from "../Button";
import type { InputFieldProps } from "../input";

export type DialogShortcut = "esc" | "enter";

/** Keycap palette — `onPrimary` is the white overlay used on brand-filled buttons. */
export type DialogShortcutTone = "default" | "onPrimary";

export interface DialogAction {
  label: string;
  onPress?: () => void;
  hierarchy?: ButtonHierarchy;
  /** Renders the button disabled and takes it out of the Enter shortcut. */
  disabled?: boolean;
  /** Footer shortcut badge rendered as a trailing icon. Defaults: secondary-gray → esc, primary/destructive → enter. */
  shortcut?: DialogShortcut | false;
}

export type DialogInputProps = Pick<
  InputFieldProps,
  | "label"
  | "aria-label"
  | "placeholder"
  | "hint"
  | "errorMessage"
  | "destructive"
  | "value"
  | "defaultValue"
  | "onChange"
  | "name"
  | "type"
  | "required"
  | "autoFocus"
  | "disabled"
  | "maxLength"
>;

export interface DialogPanelProps {
  title: string;
  /** Plain text, or marked-up text when part of it must not wrap (a path). */
  description?: ReactNode;
  /** Show the top-right close button. Defaults to false. */
  showCloseButton?: boolean;
  /**
   * `compose` makes something new, as Linear's New issue: a breadcrumb title row
   * (`titleLeading` › title) over a body that brings its own fields and footer.
   */
  variant?: "default" | "input" | "compose";
  /** compose: where the new item goes (a chip), before the title. */
  titleLeading?: ReactNode;
  input?: DialogInputProps;
  onClose?: () => void;
  actions?: DialogAction[];
  children?: ReactNode;
}

export interface DialogProps extends DialogPanelProps {
  /** Controlled open state. */
  isOpen?: boolean;
  /** Uncontrolled initial open state. */
  defaultOpen?: boolean;
  /** Called when the dialog opens or closes. */
  onOpenChange?: (isOpen: boolean) => void;
  /** Optional trigger rendered before the overlay (uses DialogTrigger internally). */
  trigger?: ReactNode;
  /** Close when clicking the backdrop or pressing Escape. Defaults to true. */
  isDismissable?: boolean;
  className?: string;
}
