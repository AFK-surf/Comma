import type {
  ClipboardEvent,
  CompositionEvent,
  DragEvent,
  HTMLAttributes,
  InputEvent,
  KeyboardEvent,
} from "react";
import { placeSelectionAtPoint } from "../dom/caret";
import { insertTextAtSelection } from "../dom/editing";
import {
  readEditorSnapshot,
  readRichValue,
  readSelectedPlainText,
} from "../dom/readEditor";
import { writeRichValue } from "../dom/writeEditor";
import type { EditorEventContext } from "./editorEventContext";

type DivAttributes = HTMLAttributes<HTMLDivElement>;

/**
 * Text arriving in the editor: typing (held to maxLength, and undone while the
 * editor is read-only or disabled), IME composition, paste and drop as plain
 * text, and the menu re-read after each key.
 */
export function createInputHandlers(
  {
    commitEditor,
    currentExternalValue,
    effectiveMaxLength,
    immutable,
    menu: { refreshMenu },
    onEditorLayoutChange,
    state: {
      composingRef,
      dismissedMenuSignatureRef,
      editorContentRevisionRef,
      editorSnapshotRef,
      internalPlainTextRef,
      lastCompositionEndAtRef,
      suppressedKeyUpRef,
      tokenMapRef,
    },
    tooltip: { tokenTooltipId },
  }: EditorEventContext,
  {
    onBeforeInputProp,
    onCompositionEndProp,
    onCompositionStartProp,
    onDropProp,
    onInputProp,
    onKeyUpProp,
    onPasteProp,
  }: {
    onBeforeInputProp: DivAttributes["onBeforeInput"];
    onCompositionEndProp: DivAttributes["onCompositionEnd"];
    onCompositionStartProp: DivAttributes["onCompositionStart"];
    onDropProp: DivAttributes["onDrop"];
    onInputProp: DivAttributes["onInput"];
    onKeyUpProp: DivAttributes["onKeyUp"];
    onPasteProp: DivAttributes["onPaste"];
  }
) {
  const handleInput = (event: InputEvent<HTMLDivElement>) => {
    onInputProp?.(event);
    if (immutable) {
      event.preventDefault();
      writeRichValue(
        event.currentTarget,
        currentExternalValue,
        tokenMapRef.current,
        tokenTooltipId,
        immutable
      );
      editorSnapshotRef.current = null;
      editorContentRevisionRef.current += 1;
      return;
    }
    if (event.currentTarget.textContent === "") event.currentTarget.replaceChildren();
    if (composingRef.current) {
      editorSnapshotRef.current = null;
      editorContentRevisionRef.current += 1;
      event.currentTarget.dataset.empty = String(
        event.currentTarget.textContent?.length === 0
      );
      onEditorLayoutChange(event.currentTarget);
      // An IME query keeps the trigger menu live: the marked text filters
      // the panel on every composition step, without committing the editor
      // mid-composition. Selection stays blocked until compositionend.
      refreshMenu(readEditorSnapshot(event.currentTarget, tokenMapRef.current));
      return;
    }
    commitEditor(event.nativeEvent.inputType?.startsWith("delete") === true);
  };

  const handleBeforeInput = (event: InputEvent<HTMLDivElement>) => {
    onBeforeInputProp?.(event);
    if (event.defaultPrevented) return;
    if (immutable) {
      event.preventDefault();
      return;
    }
    if (effectiveMaxLength === undefined) return;

    const nativeEvent = event.nativeEvent;
    if (!nativeEvent.inputType?.startsWith("insert") || !nativeEvent.data) return;
    const editor = event.currentTarget;
    const currentLength = composingRef.current
      ? readRichValue(editor, tokenMapRef.current).plainText.length
      : internalPlainTextRef.current.length;
    const selectedLength = readSelectedPlainText(editor, tokenMapRef.current).length;
    const nextLength = currentLength - selectedLength + nativeEvent.data.length;
    if (nextLength > effectiveMaxLength && nextLength >= currentLength) {
      event.preventDefault();
    }
  };

  const handleKeyUp = (event: KeyboardEvent<HTMLDivElement>) => {
    onKeyUpProp?.(event);
    const wasSuppressed = suppressedKeyUpRef.current === event.key;
    if (wasSuppressed) {
      suppressedKeyUpRef.current = null;
    }
    if (event.defaultPrevented || wasSuppressed) return;
    refreshMenu();
  };

  const handlePaste = (event: ClipboardEvent<HTMLDivElement>) => {
    onPasteProp?.(event);
    if (event.defaultPrevented) return;
    event.preventDefault();
    if (immutable) return;
    insertTextAtSelection(event.clipboardData.getData("text/plain"));
    commitEditor();
  };

  const handleDrop = (event: DragEvent<HTMLDivElement>) => {
    onDropProp?.(event);
    if (event.defaultPrevented) return;
    event.preventDefault();
    if (immutable) return;
    placeSelectionAtPoint(event.currentTarget, event.clientX, event.clientY);
    insertTextAtSelection(event.dataTransfer.getData("text/plain"));
    commitEditor();
  };

  const handleCompositionStart = (event: CompositionEvent<HTMLDivElement>) => {
    onCompositionStartProp?.(event);
    if (event.defaultPrevented || immutable) return;
    composingRef.current = true;
    // The menu stays open through the composition: an IME query ("@任务")
    // must filter live instead of flickering the panel closed. Only the
    // cached snapshot is dropped; the trigger range re-derives per input.
    editorSnapshotRef.current = null;
    dismissedMenuSignatureRef.current = null;
  };

  const handleCompositionEnd = (event: CompositionEvent<HTMLDivElement>) => {
    onCompositionEndProp?.(event);
    composingRef.current = false;
    lastCompositionEndAtRef.current = Date.now();
    if (event.defaultPrevented || immutable) return;
    commitEditor();
  };

  return {
    handleBeforeInput,
    handleCompositionEnd,
    handleCompositionStart,
    handleDrop,
    handleInput,
    handleKeyUp,
    handlePaste,
  };
}
