import { useCallback, useRef, type CompositionEvent, type KeyboardEvent } from "react";
import { consumeWebKitImeConfirmation, isImeKeyEvent } from "../../utils";
import type { ForwardedAiInputProps } from "../types";
import type { VoiceRecording } from "../voice/useVoiceRecording";

export interface PromptKeyboardOptions extends ForwardedAiInputProps<
  "onCompositionEnd" | "onCompositionStart" | "onKeyDown"
> {
  /** Whether the ContextMenu key or Shift+F10 opens the plain prompt's edit menu. */
  editMenuEnabled: boolean;
  onSubmit: () => void;
  openEditMenu: (pointer: null) => void;
  voice: Pick<VoiceRecording, "canStartVoiceRecording" | "startVoiceRecording">;
}

export type PromptKeyboard = ReturnType<typeof usePromptKeyboard>;

/**
 * The prompt's own keys: Ctrl+D starts dictation in either prompt; the plain
 * prompt also opens its edit menu from the keyboard and submits on Enter,
 * unless that Enter confirms an IME composition.
 */
export function usePromptKeyboard({
  editMenuEnabled,
  onCompositionEnd,
  onCompositionStart,
  onKeyDown,
  onSubmit,
  openEditMenu,
  voice: { canStartVoiceRecording, startVoiceRecording },
}: PromptKeyboardOptions) {
  const composingRef = useRef(false);
  const lastCompositionEndAtRef = useRef<number | null>(null);

  const startVoiceFromShortcut = useCallback(
    (event: KeyboardEvent<HTMLElement>) => {
      if (
        !canStartVoiceRecording ||
        event.repeat ||
        !event.ctrlKey ||
        event.altKey ||
        event.metaKey ||
        event.shiftKey ||
        event.key.toLowerCase() !== "d" ||
        composingRef.current ||
        isImeKeyEvent(event.nativeEvent)
      ) {
        return false;
      }

      event.preventDefault();
      startVoiceRecording();
      return true;
    },
    [canStartVoiceRecording, startVoiceRecording]
  );

  const handleKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    onKeyDown?.(event);
    if (event.defaultPrevented) return;
    if (startVoiceFromShortcut(event)) return;

    if (
      editMenuEnabled &&
      (event.key === "ContextMenu" || (event.shiftKey && event.key === "F10"))
    ) {
      event.preventDefault();
      openEditMenu(null);
      return;
    }

    if (event.key !== "Enter") return;
    if (
      isImeKeyEvent(event.nativeEvent) ||
      consumeWebKitImeConfirmation(lastCompositionEndAtRef)
    ) {
      event.preventDefault();
    } else if (!event.shiftKey && !composingRef.current) {
      event.preventDefault();
      onSubmit();
    }
  };

  const handleRichKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    onKeyDown?.(event);
    if (event.defaultPrevented) return;
    startVoiceFromShortcut(event);
  };

  const handleCompositionStart = (event: CompositionEvent<HTMLTextAreaElement>) => {
    composingRef.current = true;
    onCompositionStart?.(event);
  };

  const handleCompositionEnd = (event: CompositionEvent<HTMLTextAreaElement>) => {
    composingRef.current = false;
    lastCompositionEndAtRef.current = Date.now();
    onCompositionEnd?.(event);
  };

  return {
    handleCompositionEnd,
    handleCompositionStart,
    handleKeyDown,
    handleRichKeyDown,
  };
}
