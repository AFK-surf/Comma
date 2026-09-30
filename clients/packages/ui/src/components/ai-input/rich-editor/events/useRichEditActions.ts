import { useCallback } from "react";
import type { TextEditContextMenuAction } from "../../../menu";
import type { AiInputClipboard } from "../../types";
import { selectAllEditorContents } from "../dom/caret";
import { deleteSelectedContents, insertTextAtSelection } from "../dom/editing";
import { readSelectedPlainText } from "../dom/readEditor";
import type { RichEditorState } from "../state/useRichEditorState";

export interface RichEditActionsOptions {
  captureEditSelectionAfterAction: () => void;
  clipboard: Pick<AiInputClipboard, "readText" | "writeText">;
  commitEditor: () => void;
  immutable: boolean;
  onPasteFilesFromMenu: (() => Promise<boolean>) | undefined;
  restoreEditSelection: () => boolean;
}

/**
 * Runs an edit menu action on the rich prompt's saved selection. Cut and
 * Paste edit the DOM and commit it the way typing does; Copy reads tokens
 * back as their plain text.
 */
export function useRichEditActions(
  { editorRef, tokenMapRef }: RichEditorState,
  {
    captureEditSelectionAfterAction,
    clipboard,
    commitEditor,
    immutable,
    onPasteFilesFromMenu,
    restoreEditSelection,
  }: RichEditActionsOptions
) {
  return useCallback(
    async (action: TextEditContextMenuAction) => {
      const editor = editorRef.current;
      if (!editor) return;

      editor.focus({ preventScroll: true });
      restoreEditSelection();

      if (action === "copy") {
        const text = readSelectedPlainText(editor, tokenMapRef.current);
        if (text) await clipboard.writeText(text);
        captureEditSelectionAfterAction();
        return;
      }

      if (action === "cut") {
        if (immutable) return;
        const text = readSelectedPlainText(editor, tokenMapRef.current);
        if (!text) return;
        await clipboard.writeText(text);
        deleteSelectedContents(editor);
        commitEditor();
        captureEditSelectionAfterAction();
        return;
      }

      if (action === "paste") {
        if (immutable) return;
        try {
          if (await onPasteFilesFromMenu?.()) return;
          const text = await clipboard.readText();
          insertTextAtSelection(text);
          commitEditor();
          captureEditSelectionAfterAction();
        } catch {
          captureEditSelectionAfterAction();
        }
        return;
      }

      selectAllEditorContents(editor);
      captureEditSelectionAfterAction();
    },
    [
      captureEditSelectionAfterAction,
      clipboard,
      onPasteFilesFromMenu,
      commitEditor,
      editorRef,
      immutable,
      restoreEditSelection,
      tokenMapRef,
    ]
  );
}
