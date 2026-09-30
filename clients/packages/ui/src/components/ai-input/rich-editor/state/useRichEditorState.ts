import { useId, useRef, useState } from "react";
import type {
  AiInputMenuItem,
  AiInputMenuRegistration,
  AiInputRichTokenSegment,
  AiInputRichValue,
  filterAiInputMenuGroups,
} from "../../richText";
import type { EditorReadSnapshot } from "../dom/readEditor";

export interface ActiveMenu {
  registration: AiInputMenuRegistration;
  groups: ReturnType<typeof filterAiInputMenuGroups>;
  items: AiInputMenuItem[];
  query: string;
  signature: string;
  /**
   * Caret-anchored placement relative to the positioned shell's padding box:
   * the panel's left edge follows the trigger character (clamped inside the
   * shell), its bottom edge sits above the trigger's line, and originX keeps
   * the enter/exit scale anchored on the trigger even when clamping shifts
   * the panel.
   */
  position: { bottomOffset: number; left: number; originX: number } | null;
  /** The group whose browse panel replaces the list once "View more" is chosen. */
  browseGroupId: string | null;
}

export type RichEditorState = ReturnType<typeof useRichEditorState>;

/**
 * What the editor's hooks share. While the reader types, the DOM holds the
 * draft; these refs record what was last read from it or written into it,
 * alongside the interaction state (the open menu, the selected token) that
 * any edit may reset.
 */
export function useRichEditorState(initialValue: AiInputRichValue) {
  const editorRef = useRef<HTMLDivElement | null>(null);
  const editorSnapshotRef = useRef<EditorReadSnapshot | null>(null);
  const editorContentRevisionRef = useRef(0);
  const tokenMapRef = useRef(new Map<string, AiInputRichTokenSegment>());
  const triggerRangeRef = useRef<Range | null>(null);
  const composingRef = useRef(false);
  const lastCompositionEndAtRef = useRef<number | null>(null);
  const suppressedKeyUpRef = useRef<string | null>(null);
  const dismissedMenuSignatureRef = useRef<string | null>(null);
  const internalSignatureRef = useRef("");
  const internalPlainTextRef = useRef("");
  const lastAcceptedValueRef = useRef<AiInputRichValue>(initialValue);
  const [activeMenu, setActiveMenu] = useState<ActiveMenu | null>(null);
  const [activeIndex, setActiveIndex] = useState(0);
  const [activeTokenId, setActiveTokenId] = useState<string | null>(null);
  const [editorRevision, setEditorRevision] = useState(0);
  const menuId = useId();

  return {
    activeIndex,
    activeMenu,
    activeTokenId,
    composingRef,
    dismissedMenuSignatureRef,
    editorContentRevisionRef,
    editorRef,
    editorRevision,
    editorSnapshotRef,
    internalPlainTextRef,
    internalSignatureRef,
    lastAcceptedValueRef,
    lastCompositionEndAtRef,
    menuId,
    setActiveIndex,
    setActiveMenu,
    setActiveTokenId,
    setEditorRevision,
    suppressedKeyUpRef,
    tokenMapRef,
    triggerRangeRef,
  };
}
