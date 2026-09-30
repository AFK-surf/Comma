import {
  createContext,
  memo,
  useContext,
  useState,
  type CSSProperties,
  type ReactNode,
} from "react";
import { Dialog as RacDialog, Modal, ModalOverlay } from "react-aria-components";
import { Button } from "../Button";
import { dialogOverlay } from "../dialog/styles";
import { XIcon } from "../icons";
import { NativeSurfaceSuppressor } from "../native-surface/NativeSurfaceSuppressor";
import { OverlayPortalProvider } from "../portal";
import { useLatestCallback } from "../settings-panel/settingsIdentity";
import type { SettingsSidebarLayout } from "../settings-sidebar";
import { cx } from "../utils";
import { SettingsPage, type SettingsPageProps } from "./SettingsPage";

export interface SettingsDialogProps extends Omit<SettingsPageProps, "onLayoutChange"> {
  /** Names the dialog itself, so it is required here. */
  ariaLabel: string;
  /** Accessible name for the close control. */
  closeLabel: string;
  onClose: () => void;
  /** Overlays the modal hosts for the app, rendered inside its portal scope. */
  children?: ReactNode;
}

const overlayMotion = {
  enter: "duration-200 ease-out animate-in fade-in",
  exit: "duration-150 ease-in animate-out fade-out",
} as const;

const modalMotion = {
  enter: "duration-200 ease-out animate-in fade-in zoom-in-95 slide-in-from-top-1",
  exit: "duration-150 ease-in animate-out fade-out zoom-out-95 slide-out-to-top-1",
} as const;

const SettingsDialogBodyContext = createContext<ReactNode>(null);

/** The page and the owner's overlays, read from the dialog that owns them. */
const SettingsDialogBody = () => useContext(SettingsDialogBodyContext);
const settingsDialogBody = <SettingsDialogBody />;

/**
 * The modal around the page. React Aria's overlay and dialog hand every
 * button inside them a new context value each time they render, and a
 * context reaches past `memo`. The frame therefore renders only when its own
 * props change; the page changes with every setting and reaches it through
 * `SettingsDialogBodyContext`.
 */
const SettingsDialogFrame = memo(function SettingsDialogFrame({
  ariaLabel,
  children,
  closeLabel,
  layout,
  onClose,
}: {
  ariaLabel: string;
  children: ReactNode;
  closeLabel: string;
  layout: SettingsSidebarLayout;
  onClose: () => void;
}) {
  // An open modal hides everything outside itself from assistive tech, so the
  // menus and dropdowns raised from inside settings have to portal into the
  // modal instead of to the document body.
  const [modalElement, setModalElement] = useState<HTMLElement | null>(null);

  return (
    <ModalOverlay
      className={(state) =>
        cx(
          dialogOverlay,
          // Same weight as the command palette; the dialog scrim is meant for
          // the small dialogs raised over content, not for a full surface.
          "comma-settings-overlay bg-transparent",
          state.isEntering && overlayMotion.enter,
          state.isExiting && overlayMotion.exit
        )
      }
      isDismissable
      isOpen
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
    >
      <Modal
        className={(state) =>
          cx(
            "flex h-[750px] max-h-full w-[1180px] max-w-full outline-none [--comma-overlay-safe-top:2.75rem]",
            state.isEntering && modalMotion.enter,
            state.isExiting && modalMotion.exit
          )
        }
        ref={setModalElement}
      >
        <NativeSurfaceSuppressor />
        <RacDialog
          aria-label={ariaLabel}
          className="comma-settings-dialog relative flex size-full min-h-0 min-w-0 overflow-hidden rounded-2xl border-[0.5px] border-primary bg-popup-primary shadow-lg outline-none"
          data-slot="settings-dialog"
        >
          <OverlayPortalProvider getContainer={() => modalElement}>
            {children}
            {/* In the tab row the close control shares the row's 48px: its 40px
                box sits an xs inset from the top, on the tabs' centre line. The
                standing rail keeps it on the card's lg inset. */}
            <Button
              aria-label={closeLabel}
              className="absolute right-lg top-lg z-[1] data-[layout=tabs]:top-xs [&_.comma-icon-slot]:size-6"
              data-layout={layout}
              data-slot="settings-close"
              hierarchy="tertiary-gray"
              iconLeading={<XIcon />}
              iconOnly
              onPress={onClose}
              size="md"
              style={
                {
                  "--comma-button-hover-bg": "var(--color-sidebar-bg-item)",
                } as CSSProperties
              }
            />
          </OverlayPortalProvider>
        </RacDialog>
      </Modal>
    </ModalOverlay>
  );
});

/**
 * Settings as a centred modal over the product shell.
 *
 * Mounting the component opens it; the owner unmounts it on close. The card
 * holds the whole `SettingsPage` (its own sidebar and panel), so the surface
 * behind stays exactly where the user left it.
 */
export const SettingsDialog = ({
  className,
  children,
  closeLabel,
  onClose,
  ...pageProps
}: SettingsDialogProps) => {
  // The close control reads the page's layout from its own attribute. A :has()
  // on the dialog would restyle all of Settings whenever a node in it changes.
  const [layout, setLayout] = useState<SettingsSidebarLayout>("rail");
  const close = useLatestCallback(onClose);

  return (
    <SettingsDialogBodyContext.Provider
      value={
        <>
          <SettingsPage
            {...pageProps}
            {...(className ? { className } : {})}
            onLayoutChange={setLayout}
          />
          {children}
        </>
      }
    >
      <SettingsDialogFrame
        ariaLabel={pageProps.ariaLabel}
        closeLabel={closeLabel}
        layout={layout}
        onClose={close}
      >
        {settingsDialogBody}
      </SettingsDialogFrame>
    </SettingsDialogBodyContext.Provider>
  );
};
