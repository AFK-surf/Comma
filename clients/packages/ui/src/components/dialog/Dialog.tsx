/* oxlint-disable jsx-a11y/no-noninteractive-element-interactions, jsx-a11y/prefer-tag-over-role -- React Aria requires a custom Dialog renderer to return a section; this handler implements the dialog's advertised Enter shortcut. */
import {
  useCallback,
  useContext,
  useId,
  type KeyboardEvent as ReactKeyboardEvent,
} from "react";
import {
  Dialog as RacDialog,
  DialogTrigger,
  Modal,
  ModalOverlay,
  OverlayTriggerStateContext,
  type ModalOverlayProps,
} from "react-aria-components";
import { NativeSurfaceSuppressor } from "../native-surface/NativeSurfaceSuppressor";
import { cx, definedProps, isImeKeyEvent } from "../utils";
import { resolveShortcut } from "./DialogActions";
import { DialogPanel, dialogPanelShellClass } from "./DialogPanel";
import { dialogModal, dialogOverlay, dialogShell } from "./styles";
import type { DialogPanelProps, DialogProps } from "./types";

const dialogOverlayMotion = {
  enter: "duration-200 ease-out animate-in fade-in",
  exit: "duration-150 ease-in animate-out fade-out",
} as const;

const dialogModalMotion = {
  enter: "duration-200 ease-out animate-in fade-in zoom-in-95 slide-in-from-top-1",
  exit: "duration-150 ease-in animate-out fade-out zoom-out-95 slide-out-to-top-1",
} as const;

const dialogEnterOwnerSelector = [
  "a[href]",
  "button",
  "select",
  "summary",
  "textarea",
  "[contenteditable]:not([contenteditable='false'])",
  "[role='button']",
  "[role='checkbox']",
  "[role='combobox']",
  "[role='gridcell']",
  "[role='listbox']",
  "[role='menuitem']",
  "[role='option']",
  "[role='radio']",
  "[role='slider']",
  "[role='spinbutton']",
  "[role='switch']",
  "[role='textbox']",
  "[role='treeitem']",
].join(", ");

const dialogEnterTextInputTypes = new Set([
  "email",
  "number",
  "password",
  "search",
  "tel",
  "text",
  "url",
]);

const ownsDialogEnter = (target: EventTarget | null) => {
  if (!(target instanceof Element)) return false;
  if (target.closest(dialogEnterOwnerSelector)) return true;

  const input = target.closest("input");
  return input !== null && !dialogEnterTextInputTypes.has(input.type);
};

/** Enter runs the action wearing the ↵ keycap unless the focused control owns it. */
const useDialogEnterShortcut = (
  actions: DialogPanelProps["actions"],
  close: () => void
) => {
  return useCallback(
    (event: ReactKeyboardEvent<HTMLElement>) => {
      if (event.key !== "Enter" || event.defaultPrevented) return;
      if (isImeKeyEvent(event.nativeEvent)) return;
      if (event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return;
      if (ownsDialogEnter(event.target)) return;

      const action = actions?.find(
        (candidate) => resolveShortcut(candidate) === "enter"
      );
      if (!action || action.disabled) return;

      event.preventDefault();
      if (action.onPress) action.onPress();
      else close();
    },
    [actions, close]
  );
};

const DialogSurface = ({
  className,
  panelProps,
  titleId,
  descriptionId,
}: {
  className?: string;
  panelProps: DialogPanelProps;
  titleId: string;
  descriptionId?: string;
}) => {
  const overlayState = useContext(OverlayTriggerStateContext);
  const close = useCallback(() => overlayState?.close(), [overlayState]);
  const handleEnterShortcut = useDialogEnterShortcut(panelProps.actions, close);

  return (
    <RacDialog
      {...definedProps({ "aria-describedby": descriptionId })}
      aria-labelledby={titleId}
      className={cx(dialogShell, dialogPanelShellClass, className)}
      render={(domProps) => (
        <section
          {...domProps}
          onKeyDown={(event) => {
            domProps.onKeyDown?.(event);
            handleEnterShortcut(event);
          }}
          role="dialog"
        />
      )}
    >
      {(renderProps) => (
        <DialogPanel
          {...panelProps}
          {...definedProps({ descriptionId })}
          onClose={() => renderProps.close()}
          titleId={titleId}
        />
      )}
    </RacDialog>
  );
};

const DialogOverlay = ({
  isDismissable,
  className,
  panelProps,
  overlayProps,
  titleId,
  descriptionId,
}: {
  isDismissable: boolean;
  className?: string;
  panelProps: DialogPanelProps;
  overlayProps?: Pick<ModalOverlayProps, "isOpen" | "defaultOpen" | "onOpenChange">;
  titleId: string;
  descriptionId?: string;
}) => (
  <ModalOverlay
    isDismissable={isDismissable}
    {...overlayProps}
    className={(state) =>
      cx(
        dialogOverlay,
        state.isEntering && dialogOverlayMotion.enter,
        state.isExiting && dialogOverlayMotion.exit
      )
    }
  >
    <Modal
      className={(state) =>
        cx(
          dialogModal,
          state.isEntering && dialogModalMotion.enter,
          state.isExiting && dialogModalMotion.exit
        )
      }
    >
      <NativeSurfaceSuppressor />
      <DialogSurface
        {...definedProps({ className })}
        {...definedProps({ descriptionId })}
        panelProps={panelProps}
        titleId={titleId}
      />
    </Modal>
  </ModalOverlay>
);

export const Dialog = ({
  isOpen,
  defaultOpen,
  onOpenChange,
  trigger,
  isDismissable = true,
  onClose,
  className,
  ...panelProps
}: DialogProps) => {
  const instanceId = useId();
  const titleId = `${instanceId}-title`;
  const descriptionId = panelProps.description
    ? `${instanceId}-description`
    : undefined;

  const handleOpenChange = (open: boolean) => {
    onOpenChange?.(open);
    if (!open) onClose?.();
  };

  if (trigger != null) {
    return (
      <DialogTrigger
        {...definedProps({ isOpen, defaultOpen, onOpenChange: handleOpenChange })}
      >
        {trigger}
        <DialogOverlay
          isDismissable={isDismissable}
          {...definedProps({ className })}
          {...definedProps({ descriptionId })}
          panelProps={panelProps}
          titleId={titleId}
        />
      </DialogTrigger>
    );
  }

  return (
    <DialogOverlay
      isDismissable={isDismissable}
      {...definedProps({ className })}
      {...definedProps({ descriptionId })}
      panelProps={panelProps}
      titleId={titleId}
      overlayProps={definedProps({
        isOpen,
        defaultOpen,
        onOpenChange: handleOpenChange,
      })}
    />
  );
};
