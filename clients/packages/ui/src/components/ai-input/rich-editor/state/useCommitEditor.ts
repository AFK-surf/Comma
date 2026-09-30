import { useCallback } from "react";
import type { AiInputRichValue } from "../../richText";
import { placeCaretAtEnd, revealTrailingCaret } from "../dom/caret";
import { readEditorSnapshot, type EditorReadSnapshot } from "../dom/readEditor";
import { syncTrailingLineBreak, writeRichValue } from "../dom/writeEditor";
import { pruneTokenMap } from "../tokens/tokenMap";
import {
  CLOSED_TOKEN_TOOLTIP,
  type TokenTooltipState,
} from "../tokens/useTokenTooltip";
import { richValueSignature } from "./useEditorSync";
import type { RichEditorState } from "./useRichEditorState";

export type CommitEditor = ReturnType<typeof useCommitEditor>;

/**
 * Reads the edited DOM back into a value and hands it to the composer. An
 * edit that would pass maxLength is rolled back to the last accepted value.
 */
export function useCommitEditor(
  state: RichEditorState,
  { setTokenTooltip, tokenTooltipId }: TokenTooltipState,
  {
    effectiveMaxLength,
    immutable,
    onEditorChange,
    refreshMenu,
    richValue,
  }: {
    effectiveMaxLength: number | undefined;
    immutable: boolean;
    onEditorChange: (value: AiInputRichValue, element: HTMLDivElement) => void;
    refreshMenu: (preferredSnapshot?: EditorReadSnapshot) => void;
    richValue: AiInputRichValue | undefined;
  }
) {
  const {
    editorContentRevisionRef,
    editorRef,
    editorSnapshotRef,
    internalPlainTextRef,
    internalSignatureRef,
    lastAcceptedValueRef,
    setActiveMenu,
    setActiveTokenId,
    setEditorRevision,
    suppressedKeyUpRef,
    tokenMapRef,
    triggerRangeRef,
  } = state;

  return useCallback(
    (clearWhitespaceOnly = false) => {
      const editor = editorRef.current;
      if (!editor) return;
      let snapshot = readEditorSnapshot(editor, tokenMapRef.current);
      let next = snapshot.richValue;
      if (
        clearWhitespaceOnly &&
        next.tokens.length === 0 &&
        next.plainText.trim().length === 0
      ) {
        editor.replaceChildren();
        snapshot = readEditorSnapshot(editor, tokenMapRef.current);
        next = snapshot.richValue;
      }
      const rollbackValue = richValue ?? lastAcceptedValueRef.current;
      if (
        effectiveMaxLength !== undefined &&
        next.plainText.length > effectiveMaxLength &&
        next.plainText.length >= rollbackValue.plainText.length
      ) {
        writeRichValue(
          editor,
          rollbackValue,
          tokenMapRef.current,
          tokenTooltipId,
          immutable
        );
        editorSnapshotRef.current = null;
        editorContentRevisionRef.current += 1;
        internalSignatureRef.current = richValueSignature(rollbackValue);
        internalPlainTextRef.current = rollbackValue.plainText;
        editor.dataset.empty = String(rollbackValue.plainText.length === 0);
        triggerRangeRef.current = null;
        suppressedKeyUpRef.current = null;
        setActiveMenu(null);
        setActiveTokenId(null);
        setTokenTooltip(CLOSED_TOKEN_TOOLTIP);
        if (document.activeElement === editor) placeCaretAtEnd(editor);
        return;
      }
      syncTrailingLineBreak(editor, next.plainText);
      pruneTokenMap(next, tokenMapRef.current);
      editorSnapshotRef.current = snapshot;
      editorContentRevisionRef.current += 1;
      internalSignatureRef.current = richValueSignature(next);
      internalPlainTextRef.current = next.plainText;
      lastAcceptedValueRef.current = next;
      editor.dataset.empty = String(next.plainText.length === 0);
      onEditorChange(next, editor);
      revealTrailingCaret(editor, tokenMapRef.current);
      setEditorRevision((current) => current + 1);
      refreshMenu(snapshot);
    },
    [
      editorContentRevisionRef,
      editorRef,
      editorSnapshotRef,
      effectiveMaxLength,
      immutable,
      internalPlainTextRef,
      internalSignatureRef,
      lastAcceptedValueRef,
      onEditorChange,
      refreshMenu,
      richValue,
      setActiveMenu,
      setActiveTokenId,
      setEditorRevision,
      setTokenTooltip,
      suppressedKeyUpRef,
      tokenMapRef,
      tokenTooltipId,
      triggerRangeRef,
    ]
  );
}
