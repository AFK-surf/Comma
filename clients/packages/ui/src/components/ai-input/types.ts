import type {
  ChangeEvent,
  DOMAttributes,
  ReactNode,
  TextareaHTMLAttributes,
} from "react";
import type { AiInputMenuRegistration, AiInputRichValue } from "./richText";

export type AiInputAttachmentType = "image" | "file" | "quote";

/**
 * Where an attachment is in its upload. Image tiles show this on the tile
 * itself; a failed one is pressable to retry.
 */
export type AiInputAttachmentState = "ready" | "loading" | "error";
export type AiInputSize = "default" | "small";

export interface AiInputAttachment {
  id: string;
  type?: AiInputAttachmentType;
  name: string;
  meta?: string;
  thumbnailSrc?: string;
  alt?: string;
  /** Full plain text revealed on hover. Quote chips carry the whole selection. */
  detail?: string;
  /** Defaults to "ready" — a settled attachment showing its own content. */
  state?: AiInputAttachmentState;
  onRemove?: () => void;
  /** Called when a failed attachment is pressed to upload again. */
  onRetry?: () => void;
}

export interface AiInputClipboard {
  readFiles?(): Promise<File[]>;
  readText(): Promise<string>;
  writeText(text: string): Promise<void>;
}

export type AiInputNativeAttributes = Omit<
  TextareaHTMLAttributes<HTMLTextAreaElement>,
  keyof DOMAttributes<HTMLTextAreaElement> | "defaultValue" | "value"
> &
  Omit<
    DOMAttributes<HTMLElement>,
    "children" | "dangerouslySetInnerHTML" | "onChange" | "onSubmit"
  >;

export type AiInputProps = AiInputNativeAttributes & {
  /** Runtime adapter for the custom Cut, Copy, and Paste menu actions. */
  clipboard?: AiInputClipboard;
  size?: AiInputSize;
  value?: string;
  defaultValue?: string;
  /** Native textarea change event. Use onValueChange for both plain and rich modes. */
  onChange?: (event: ChangeEvent<HTMLTextAreaElement>) => void;
  onValueChange?: (value: string) => void;
  onSubmit?: (value: string) => void;
  /**
   * Enables the shared rich editor even when there are no trigger menus.
   * Global/data/ARIA attributes and common DOM handlers are forwarded; native
   * textarea-only layout and form attributes do not apply in this mode.
   */
  richText?: boolean;
  /** Trigger menus such as `/skill` and `@plugin`. Supplying one enables rich text. */
  menuRegistrations?: readonly AiInputMenuRegistration[];
  /** Optional controlled structured value for restoring rich tokens. */
  richValue?: AiInputRichValue;
  /**
   * Projects a value set from outside (a restored draft, a hand-over from
   * another surface) into tokens, so serialized mentions come back as pills
   * instead of their wire text. Typing never re-projects.
   */
  richValueFromText?: ((text: string) => AiInputRichValue) | undefined;
  onRichValueChange?: (value: AiInputRichValue) => void;
  onRichSubmit?: (value: AiInputRichValue) => void;
  attachments?: AiInputAttachment[];
  onAttachmentRemove?: (attachment: AiInputAttachment) => void;
  onAttachPress?: () => void | Promise<void>;
  /** File drops on the shell. When set, enables the drop overlay and drag handlers. */
  onDropFiles?: (dataTransfer: DataTransfer) => void;
  /**
   * Files on the clipboard at paste time. When set, a paste carrying files
   * routes here instead of inserting text, so Cmd/Ctrl+V attaches the same way
   * a drop does. Text-only pastes are untouched.
   */
  onPasteFiles?: (clipboardData: DataTransfer) => void;
  /** Overlay title while files are dragged over; defaults to `ui_ai_drop_anything_here`. */
  dropPlaceholder?: string;
  onAccessPress?: () => void;
  /** May return a promise; rejection aborts the recording UI. */
  onVoicePress?: () => void | Promise<unknown>;
  onVoiceCancel?: () => void;
  onVoiceConfirm?: (durationSeconds: number) => void;
  accessLabel?: string;
  attachLabel?: string;
  voiceLabel?: string;
  /** Measured 0..1 capture level; omitted where no capture backs the button. */
  voiceLevel?: number;
  sendLabel?: string;
  showAccessButton?: boolean;
  showAttachButton?: boolean;
  showVoiceButton?: boolean;
  toolbarLeading?: ReactNode;
  toolbarTrailing?: ReactNode;
  textareaClassName?: string;
  richEditorClassName?: string;
  textareaMaxHeight?: number;
  textareaMeasurementWidthMode?: "rendered" | "narrowest";
  textareaMinHeight?: number;
  onLayoutHeightChange?: (layout: {
    contentHeight: number;
    textareaHeight: number;
  }) => void;
  onTextareaHeightChange?: (height: number) => void;
  submitDisabled?: boolean;
  submitPending?: boolean;
};

/**
 * Props the composer hands on to one of its parts. They arrive destructured,
 * so a prop the host left out comes through as an explicit `undefined`.
 */
export type ForwardedAiInputProps<K extends keyof AiInputProps> = {
  [P in K]?: AiInputProps[P] | undefined;
};
