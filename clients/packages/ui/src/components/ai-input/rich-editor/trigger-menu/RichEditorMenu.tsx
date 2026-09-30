import { useCommaMessages } from "@comma/i18n/react";
import { AiInputMenuPanel } from "../../menu/AiInputMenuPanel";
import type { AiInputMenuItem } from "../../richText";
import { AI_INPUT_MENU_WIDTH_PX } from "../../styles";
import type { RichEditorState } from "../state/useRichEditorState";
import type { MenuBrowse } from "./useMenuBrowse";
import type { TriggerMenu } from "./useTriggerMenu";

/** The open trigger menu's panel, or the one still fading out after it closed. */
export const RichEditorMenu = ({
  browse: { closeBrowse, handleBrowseBlur },
  immutable,
  menu: { closingMenu, menuOptionId, menuPanelRef },
  selectItem,
  state: { activeIndex, activeMenu, menuId, setActiveIndex },
}: {
  browse: MenuBrowse;
  immutable: boolean;
  menu: TriggerMenu;
  selectItem: (item: AiInputMenuItem) => void;
  state: RichEditorState;
}) => {
  const messages = useCommaMessages();
  const renderedMenu = activeMenu ?? closingMenu;
  if (!renderedMenu || immutable) return null;
  const position = renderedMenu.position;
  const browseGroup = renderedMenu.browseGroupId
    ? renderedMenu.registration.groups.find(
        (group) => group.id === renderedMenu.browseGroupId && group.browse
      )
    : undefined;
  return (
    <AiInputMenuPanel
      activeIndex={activeIndex}
      browse={
        browseGroup
          ? {
              backLabel: messages.ui_ai_menu_back(),
              group: browseGroup,
              initialQuery: renderedMenu.query,
              onBack: closeBrowse,
              onBlur: handleBrowseBlur,
            }
          : undefined
      }
      groups={renderedMenu.groups}
      items={renderedMenu.items}
      label={renderedMenu.registration.label}
      menuId={menuId}
      noResultsLabel={messages.ui_ai_menu_no_results()}
      onHoverItem={setActiveIndex}
      onSelectItem={selectItem}
      optionId={menuOptionId}
      panelRef={menuPanelRef}
      resetKey={renderedMenu.signature}
      searchingLabel={messages.ui_ai_menu_searching()}
      state={activeMenu ? "open" : "closed"}
      style={{
        width: AI_INPUT_MENU_WIDTH_PX,
        ...(position
          ? {
              bottom: `calc(${position.bottomOffset}px + var(--spacing-sm))`,
              left: position.left,
              transformOrigin: `${position.originX}px 100%`,
            }
          : {
              bottom: "calc(100% + var(--spacing-sm))",
              left: 0,
              transformOrigin: "left bottom",
            }),
      }}
    />
  );
};
