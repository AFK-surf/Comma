import { useRef, useState } from "react";
import { Dialog, DialogTrigger, Modal, ModalOverlay } from "react-aria-components";
import { createRoot } from "react-dom/client";
import {
  AiInput,
  Button,
  OverlayPortalProvider,
  Dropdown,
  Menu,
  MenuItem,
  MenuPopover,
  MenuTrigger,
  SubmenuTrigger,
  CopyContextMenu,
  useTextEditContextMenuState,
} from "@comma/ui";
import { InlineTextEditor } from "../../src/components/tasks/InlineTextEditor";
import { InboxActionsMenu } from "../../src/components/inbox/InboxActionsMenu";
import { initializeCommaI18n } from "@comma/i18n";
import "../../src/styles.css";
initializeCommaI18n(["en"]);
const navigationItems = Array.from({ length: 72 }, (_, index) => ({
  id: `file-${index}`,
  label: `File ${index}`,
}));
const navigationGroups = [
  { id: "recent", label: "Recent", items: navigationItems.slice(0, 36) },
  { id: "older", label: "Older", items: navigationItems.slice(36) },
];
const navigationMode = new URLSearchParams(location.search).get("navigation");
function Fixture() {
  const [modalElement, setModalElement] = useState<HTMLElement | null>(null);
  const [theme, setTheme] = useState("light");
  const [themeOpen, setThemeOpen] = useState(false);
  const ref = useRef<HTMLButtonElement>(null);
  const state = useTextEditContextMenuState({ isEnabled: true });
  return (
    <div style={{ padding: 120, display: "flex", gap: 40 }}>
      <div
        data-testid="blank-content"
        style={{ position: "fixed", left: 0, bottom: 0, width: "100%", height: 200 }}
      />
      <InlineTextEditor
        disabled={false}
        label="Fixture inline name"
        onCommit={() => {}}
        placeholder="Name"
        value="Inline name"
      />
      <InboxActionsMenu
        canDeleteAll
        canDeleteRead
        onDeleteAll={() => {}}
        onDeleteRead={() => {}}
      />
      <div style={{ position: "fixed", bottom: 80, left: 300, width: 480 }}>
        <AiInput
          menuRegistrations={[
            {
              id: "mentions",
              trigger: "@",
              label: "Motion mentions",
              maxItems: navigationMode ? 72 : 8,
              groups:
                navigationMode === "list"
                  ? navigationGroups
                  : [
                      {
                        id: "files",
                        items: [{ id: "notes", label: "Notes" }],
                        ...(navigationMode === "browse"
                          ? {
                              browse: {
                                label: "All files",
                                title: "Browse files",
                                searchPlaceholder: "Search files",
                                emptyLabel: "No files",
                                noResultsLabel: "No results",
                                groups: navigationGroups,
                              },
                            }
                          : {}),
                      },
                    ],
            },
          ]}
        />
      </div>
      <DialogTrigger>
        <Button>Open settings fixture</Button>
        <ModalOverlay>
          <Modal ref={setModalElement}>
            <Dialog aria-label="Settings focus fixture">
              <OverlayPortalProvider getContainer={() => modalElement}>
                <Button>First settings control</Button>
                <Dropdown
                  ariaLabel="Fixture theme"
                  value={theme}
                  onChange={setTheme}
                  isOpen={themeOpen}
                  onOpenChange={setThemeOpen}
                  items={[
                    { id: "light", label: "Light" },
                    { id: "dark", label: "Dark" },
                  ]}
                />
              </OverlayPortalProvider>
            </Dialog>
          </Modal>
        </ModalOverlay>
      </DialogTrigger>
      <MenuTrigger>
        <Button>Left menu</Button>
        <MenuPopover>
          <Menu aria-label="Actions">
            <MenuItem id="copy">Copy</MenuItem>
            <SubmenuTrigger>
              <MenuItem id="arrange">Arrange</MenuItem>
              <MenuPopover>
                <Menu aria-label="Arrange options">
                  <MenuItem id="date">By date</MenuItem>
                  <MenuItem id="title">By title</MenuItem>
                </Menu>
              </MenuPopover>
            </SubmenuTrigger>
          </Menu>
        </MenuPopover>
      </MenuTrigger>
      <button
        ref={ref}
        onContextMenu={(event) => {
          event.preventDefault();
          state.openAtPointer(event.currentTarget, event.clientX, event.clientY);
        }}
      >
        Right menu
      </button>
      <CopyContextMenu
        triggerRef={ref}
        isOpen={state.isOpen}
        onOpenChange={state.handleOpenChange}
        pointerOffsets={state.pointerOffsets}
        labels={{ ariaLabel: "Actions", copy: "Copy" }}
        onAction={() => {}}
      />
      <Dropdown
        ariaLabel="Next selection"
        items={[
          { id: "alpha", label: "Alpha" },
          { id: "beta", label: "Beta" },
        ]}
      />
      <Dropdown
        ariaLabel="Selection"
        items={[
          { id: "one", label: "One" },
          { id: "two", label: "Two" },
        ]}
      />
    </div>
  );
}
createRoot(document.getElementById("root")!).render(<Fixture />);
