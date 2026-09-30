import type { RefObject } from "react";
import { useCommaMessages } from "@comma/i18n/react";
import {
  TextEditContextMenu,
  type TextEditContextMenuAction,
  type TextEditContextMenuDisabledActions,
  type useTextEditContextMenuState,
} from "../menu";

/** The Cut, Copy, Paste, and Select All menu either prompt opens in place of the native one. */
export const AiInputEditMenu = ({
  disabledActions,
  menu,
  onAction,
  triggerRef,
}: {
  disabledActions: TextEditContextMenuDisabledActions;
  menu: ReturnType<typeof useTextEditContextMenuState>;
  onAction: (action: TextEditContextMenuAction) => Promise<void>;
  triggerRef: RefObject<Element | null>;
}) => {
  const messages = useCommaMessages();

  return (
    <TextEditContextMenu
      disabledActions={disabledActions}
      isOpen={menu.isOpen}
      labels={{
        ariaLabel: messages.ui_ai_edit_menu(),
        cut: messages.common_cut(),
        copy: messages.common_copy(),
        paste: messages.common_paste(),
        selectAll: messages.common_select_all(),
      }}
      onAction={(action) => {
        void onAction(action);
      }}
      onOpenChange={menu.handleOpenChange}
      pointerOffsets={menu.pointerOffsets}
      triggerRef={triggerRef}
    />
  );
};
