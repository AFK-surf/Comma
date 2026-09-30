import type { AiInputMenuItem, AiInputRichValue } from "../../richText";
import type { CommitEditor } from "../state/useCommitEditor";
import type { RichEditorState } from "../state/useRichEditorState";
import type { TokenTooltipState } from "../tokens/useTokenTooltip";
import type { MenuBrowse } from "../trigger-menu/useMenuBrowse";
import type { TriggerMenu } from "../trigger-menu/useTriggerMenu";
import type { RichEditMenu } from "./useRichEditMenu";

/** Everything the editor's DOM event handlers read from and act on. */
export interface EditorEventContext {
  browse: MenuBrowse;
  commitEditor: CommitEditor;
  currentExternalValue: AiInputRichValue;
  disabled: boolean;
  editMenu: RichEditMenu;
  effectiveMaxLength: number | undefined;
  immutable: boolean;
  menu: TriggerMenu;
  onEditorLayoutChange: (element: HTMLDivElement) => void;
  onSubmitRequest: () => void;
  readOnly: boolean;
  selectItem: (item: AiInputMenuItem) => void;
  state: RichEditorState;
  tooltip: TokenTooltipState;
}
