import { useLayoutEffect, useMemo, useRef } from "react";
import type { AiInputRichValue } from "../../richText";
import { writeRichValue } from "../dom/writeEditor";
import { syncTokenMap } from "../tokens/tokenMap";
import {
  CLOSED_TOKEN_TOOLTIP,
  type TokenTooltipState,
} from "../tokens/useTokenTooltip";
import type { RichEditorState } from "./useRichEditorState";

export function richValueSignature(value: AiInputRichValue) {
  return JSON.stringify(
    value.segments.map((segment) =>
      segment.type === "text"
        ? ["text", segment.text]
        : [
            "token",
            segment.instanceId,
            segment.menuId,
            segment.itemId,
            segment.trigger,
            segment.plainText,
            segment.label,
            segment.description ?? null,
          ]
    )
  );
}

/**
 * Writes the parent's value into the editor whenever it is not the one the
 * editor last produced, keeps each token's state attributes in step, and
 * drops the open menu and selected token once the editor turns read-only.
 * Returns the parent's value.
 */
export function useEditorSync(
  state: RichEditorState,
  { setTokenTooltip, tokenTooltipId }: TokenTooltipState,
  {
    immutable,
    richValue,
    toRichValue,
    value,
  }: {
    immutable: boolean;
    richValue: AiInputRichValue | undefined;
    toRichValue: (text: string) => AiInputRichValue;
    value: string;
  }
) {
  const {
    activeTokenId,
    dismissedMenuSignatureRef,
    editorContentRevisionRef,
    editorRef,
    editorRevision,
    editorSnapshotRef,
    internalPlainTextRef,
    internalSignatureRef,
    lastAcceptedValueRef,
    setActiveMenu,
    setActiveTokenId,
    suppressedKeyUpRef,
    tokenMapRef,
    triggerRangeRef,
  } = state;
  const initializedRef = useRef(false);
  const currentExternalValue = useMemo(
    () => richValue ?? toRichValue(value),
    [richValue, toRichValue, value]
  );
  // O(draft) serialization; memoized because the editor re-renders on every
  // parent state emit (each keystroke round-trip and stream chunk).
  const externalSignature = useMemo(
    () => richValueSignature(currentExternalValue),
    [currentExternalValue]
  );

  useLayoutEffect(() => {
    const editor = editorRef.current;
    if (!editor) return;
    if (initializedRef.current) {
      const externallyMatchesInternal = richValue
        ? externalSignature === internalSignatureRef.current
        : value === internalPlainTextRef.current;
      if (externallyMatchesInternal) {
        if (richValue) {
          syncTokenMap(currentExternalValue, tokenMapRef.current);
          lastAcceptedValueRef.current = currentExternalValue;
        }
        return;
      }
    }

    writeRichValue(
      editor,
      currentExternalValue,
      tokenMapRef.current,
      tokenTooltipId,
      immutable
    );
    editorSnapshotRef.current = null;
    editorContentRevisionRef.current += 1;
    initializedRef.current = true;
    internalSignatureRef.current = externalSignature;
    internalPlainTextRef.current = currentExternalValue.plainText;
    lastAcceptedValueRef.current = currentExternalValue;
    editor.dataset.empty = String(currentExternalValue.plainText.length === 0);
    triggerRangeRef.current = null;
    suppressedKeyUpRef.current = null;
    dismissedMenuSignatureRef.current = null;
    setActiveMenu(null);
    setActiveTokenId(null);
    setTokenTooltip(CLOSED_TOKEN_TOOLTIP);
  }, [
    currentExternalValue,
    dismissedMenuSignatureRef,
    editorContentRevisionRef,
    editorRef,
    editorRevision,
    editorSnapshotRef,
    externalSignature,
    immutable,
    internalPlainTextRef,
    internalSignatureRef,
    lastAcceptedValueRef,
    richValue,
    setActiveMenu,
    setActiveTokenId,
    setTokenTooltip,
    suppressedKeyUpRef,
    tokenMapRef,
    tokenTooltipId,
    triggerRangeRef,
    value,
  ]);

  useLayoutEffect(() => {
    const editor = editorRef.current;
    if (!editor) return;
    editor.querySelectorAll<HTMLElement>("[data-ai-input-token]").forEach((token) => {
      const isActive = token.dataset.aiInputToken === activeTokenId;
      token.dataset.active = String(isActive);
      token.setAttribute("aria-pressed", String(isActive));
      if (token instanceof HTMLButtonElement) token.disabled = immutable;
    });
  }, [activeTokenId, editorRef, externalSignature, immutable]);

  useLayoutEffect(() => {
    if (!immutable) return;
    triggerRangeRef.current = null;
    suppressedKeyUpRef.current = null;
    dismissedMenuSignatureRef.current = null;
    setActiveMenu(null);
    setActiveTokenId(null);
    setTokenTooltip(CLOSED_TOKEN_TOOLTIP);
  }, [
    dismissedMenuSignatureRef,
    immutable,
    setActiveMenu,
    setActiveTokenId,
    setTokenTooltip,
    suppressedKeyUpRef,
    triggerRangeRef,
  ]);

  return currentExternalValue;
}
