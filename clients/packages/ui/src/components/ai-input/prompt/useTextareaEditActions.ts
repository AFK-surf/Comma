import { useCallback, type ChangeEvent, type RefObject } from "react";
import type { TextEditContextMenuAction } from "../../menu";
import type { AiInputClipboard, ForwardedAiInputProps } from "../types";

export interface TextareaSelection {
  start: number;
  end: number;
}

export interface TextareaEditActionsOptions extends ForwardedAiInputProps<
  "maxLength" | "onChange" | "onValueChange" | "value"
> {
  clipboard: AiInputClipboard;
  pasteFilesFromMenu: () => Promise<boolean>;
  requestMeasure: () => void;
  restoreTextareaSelection: () => void;
  /** Where the caret goes back to once the menu hands focus back. */
  savedTextareaSelectionRef: RefObject<TextareaSelection | null>;
  /** Keeps an uncontrolled draft in step with a menu edit. */
  setDraftValue: (value: string) => void;
  textareaRef: RefObject<HTMLTextAreaElement | null>;
}

/**
 * Runs an edit menu action on the plain prompt's saved selection. Cut and
 * Paste write the value the way typing would, through the host's change
 * handlers, then put the caret back in the next frame.
 */
export function useTextareaEditActions({
  clipboard,
  maxLength,
  onChange,
  onValueChange,
  pasteFilesFromMenu,
  requestMeasure,
  restoreTextareaSelection,
  savedTextareaSelectionRef,
  setDraftValue,
  textareaRef,
  value,
}: TextareaEditActionsOptions) {
  const applyTextareaValue = useCallback(
    (nextValue: string, selectionStart: number, selectionEnd: number) => {
      const textarea = textareaRef.current;
      if (value === undefined) {
        setDraftValue(nextValue);
      }
      onValueChange?.(nextValue);
      if (textarea && onChange) {
        const previousValue = textarea.value;
        textarea.value = nextValue;
        onChange({
          target: textarea,
          currentTarget: textarea,
        } as ChangeEvent<HTMLTextAreaElement>);
        if (value !== undefined) {
          textarea.value = previousValue;
        }
      }
      savedTextareaSelectionRef.current = {
        start: selectionStart,
        end: selectionEnd,
      };
      requestAnimationFrame(() => {
        const nextTextarea = textareaRef.current;
        if (!nextTextarea) return;
        nextTextarea.focus({ preventScroll: true });
        nextTextarea.setSelectionRange(selectionStart, selectionEnd);
        requestMeasure();
      });
    },
    [
      onChange,
      onValueChange,
      requestMeasure,
      savedTextareaSelectionRef,
      setDraftValue,
      textareaRef,
      value,
    ]
  );

  return useCallback(
    async (action: TextEditContextMenuAction) => {
      const textarea = textareaRef.current;
      if (!textarea) return;

      textarea.focus({ preventScroll: true });
      restoreTextareaSelection();
      const start = textarea.selectionStart;
      const end = textarea.selectionEnd;
      const selected = textarea.value.slice(start, end);

      if (action === "copy") {
        if (!selected) return;
        await clipboard.writeText(selected);
        savedTextareaSelectionRef.current = { start, end };
        return;
      }

      if (action === "cut") {
        if (!selected) return;
        await clipboard.writeText(selected);
        const nextValue = `${textarea.value.slice(0, start)}${textarea.value.slice(end)}`;
        applyTextareaValue(nextValue, start, start);
        return;
      }

      if (action === "paste") {
        try {
          if (await pasteFilesFromMenu()) return;
          const text = await clipboard.readText();
          const availableLength =
            maxLength === undefined
              ? text.length
              : Math.max(0, maxLength - (textarea.value.length - (end - start)));
          const insertedText = text.slice(0, availableLength);
          const nextValue = `${textarea.value.slice(0, start)}${insertedText}${textarea.value.slice(end)}`;
          const caret = start + insertedText.length;
          applyTextareaValue(nextValue, caret, caret);
        } catch {
          savedTextareaSelectionRef.current = { start, end };
        }
        return;
      }

      textarea.select();
      savedTextareaSelectionRef.current = {
        start: 0,
        end: textarea.value.length,
      };
    },
    [
      applyTextareaValue,
      clipboard,
      maxLength,
      pasteFilesFromMenu,
      restoreTextareaSelection,
      savedTextareaSelectionRef,
      textareaRef,
    ]
  );
}
