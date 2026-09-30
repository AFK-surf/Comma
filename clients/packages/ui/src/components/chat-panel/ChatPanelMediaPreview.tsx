import {
  type ReactNode,
  type RefObject,
  useCallback,
  useEffect,
  useRef,
  useState,
} from "react";
import { Dialog as AriaDialog, Modal, ModalOverlay } from "react-aria-components";
import { CrossLargeIcon } from "../icons";
import { NativeSurfaceSuppressor } from "../native-surface/NativeSurfaceSuppressor";
import { cx } from "../utils";
import { usePointerPressFeedback } from "./usePointerPressFeedback";

export interface ChatPanelMediaPreviewProps {
  actions?: ReactNode;
  children: ReactNode;
  instantMotion?: boolean;
  isOpen: boolean;
  onOpenChange: (isOpen: boolean) => void;
  returnFocusRef?: RefObject<HTMLElement | null>;
  title: string;
  variant?: "default" | "filmstrip";
}

export const ChatPanelMediaPreview = ({
  actions,
  children,
  instantMotion = false,
  isOpen,
  onOpenChange,
  returnFocusRef,
  title,
  variant = "default",
}: ChatPanelMediaPreviewProps) => {
  const [keyboardClosing, setKeyboardClosing] = useState(false);
  const dialogRef = useRef<HTMLElement | null>(null);
  const wasOpenRef = useRef(false);
  const closePressFeedback = usePointerPressFeedback<HTMLButtonElement>();

  const suppressExitMotion = useCallback(() => {
    const dialog = dialogRef.current;
    dialog
      ?.closest<HTMLElement>(".chat-panel-media-preview-overlay")
      ?.setAttribute("data-instant-motion", "true");
    dialog
      ?.closest<HTMLElement>(".chat-panel-media-preview-modal")
      ?.setAttribute("data-instant-motion", "true");
  }, []);

  useEffect(() => {
    if (isOpen) setKeyboardClosing(false);
    if (wasOpenRef.current && !isOpen && returnFocusRef?.current) {
      const focusTimer = setTimeout(() => returnFocusRef.current?.focus(), 0);
      wasOpenRef.current = isOpen;
      return () => clearTimeout(focusTimer);
    }
    wasOpenRef.current = isOpen;
    return undefined;
  }, [isOpen, returnFocusRef]);

  useEffect(() => {
    if (!isOpen || !dialogRef.current) return;
    const dialog = dialogRef.current;
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      if (
        event.target instanceof Element &&
        event.target.closest('.chat-panel-media-volume-popover[data-open="true"]')
      ) {
        return;
      }
      suppressExitMotion();
      setKeyboardClosing(true);
    };
    dialog.addEventListener("keydown", handleKeyDown, true);
    return () => dialog.removeEventListener("keydown", handleKeyDown, true);
  }, [isOpen, suppressExitMotion]);

  return (
    <ModalOverlay
      className={(state) =>
        cx(
          "chat-panel-media-preview-overlay",
          state.isEntering && !instantMotion && "is-entering",
          state.isExiting && "is-exiting",
          state.isExiting && keyboardClosing && "is-instant"
        )
      }
      isDismissable
      isOpen={isOpen}
      onOpenChange={onOpenChange}
    >
      <Modal
        className={(state) =>
          cx(
            "chat-panel-media-preview-modal",
            state.isEntering && !instantMotion && "is-entering",
            state.isExiting && "is-exiting",
            state.isExiting && keyboardClosing && "is-instant"
          )
        }
        data-variant={variant}
        onClick={
          variant === "filmstrip"
            ? (event) => {
                if (event.target !== event.currentTarget) return;
                onOpenChange(false);
              }
            : undefined
        }
        onPointerDown={
          variant === "default"
            ? (event) => {
                if (event.target !== event.currentTarget) return;
                onOpenChange(false);
              }
            : undefined
        }
      >
        <NativeSurfaceSuppressor />
        <AriaDialog
          aria-label={title}
          className="chat-panel-media-preview-dialog"
          ref={dialogRef}
        >
          {({ close }) => (
            <>
              <div className="chat-panel-media-preview-actions">
                {actions}
                <button
                  aria-label="Close preview"
                  className="chat-panel-media-preview-close"
                  {...closePressFeedback}
                  onClick={(event) => {
                    if (event.detail === 0) {
                      suppressExitMotion();
                      setKeyboardClosing(true);
                    }
                    close();
                  }}
                  title="Close preview"
                  type="button"
                >
                  <CrossLargeIcon className="size-2xl" />
                </button>
              </div>
              {children}
            </>
          )}
        </AriaDialog>
      </Modal>
    </ModalOverlay>
  );
};
