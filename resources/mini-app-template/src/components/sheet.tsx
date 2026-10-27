import { cn } from "cn";
import { useEffect, useId, useRef, useState, type ReactNode } from "react";
import { Button } from "@/components/ui/button";

/**
 * A sheet (DESIGN.md §9): a task on top of the screen (compose, edit, confirm).
 * On compact it rises from the bottom, as on a phone; from 640px it is a
 * centered form sheet. Its bar has Cancel at the leading end and the task's
 * one action at the trailing end. Escape and a press outside it cancel.
 */
export function Sheet({
  open,
  onClose,
  title,
  confirm,
  cancelLabel = "Cancel",
  children,
}: {
  open: boolean;
  onClose: () => void;
  title: string;
  /** The task's action. A destructive one is red. */
  confirm?: {
    label: string;
    onConfirm: () => void;
    disabled?: boolean;
    destructive?: boolean;
  };
  cancelLabel?: string;
  children: ReactNode;
}) {
  const dialog = useRef<HTMLDialogElement>(null);
  const titleId = useId();
  const [closing, setClosing] = useState(false);

  useEffect(() => {
    const element = dialog.current;
    if (!element) return;
    if (open && !element.open) {
      setClosing(false);
      if (typeof element.showModal === "function") element.showModal();
      else element.setAttribute("open", "");
    } else if (!open && element.open) {
      // The sheet leaves with its own motion; without motion it closes at once.
      const still =
        typeof window.matchMedia !== "function" ||
        window.matchMedia("(prefers-reduced-motion: reduce)").matches;
      if (!still) setClosing(true);
      else if (typeof element.close === "function") element.close();
      else element.removeAttribute("open");
    }
  }, [open]);

  return (
    <dialog
      ref={dialog}
      aria-labelledby={titleId}
      data-closing={closing || undefined}
      data-slot="sheet"
      onAnimationEnd={(event) => {
        if (event.target !== event.currentTarget || !closing) return;
        setClosing(false);
        const element = dialog.current;
        if (typeof element?.close === "function") element.close();
        else element?.removeAttribute("open");
      }}
      onCancel={(event) => {
        event.preventDefault();
        onClose();
      }}
      // The backdrop is the dialog's own box outside its content.
      onClick={(event) => {
        if (event.target === event.currentTarget) onClose();
      }}
    >
      {open || closing ? (
        <div className="flex max-h-[inherit] flex-col">
          <div
            aria-hidden
            className="mx-auto mt-2 h-1 w-9 shrink-0 rounded-full bg-border sm:hidden"
          />
          <header className="relative flex h-12 shrink-0 items-center justify-between gap-2 px-2">
            <Button
              type="button"
              variant="ghost"
              className="px-2 text-primary hover:bg-transparent hover:text-primary/80"
              onClick={onClose}
            >
              {cancelLabel}
            </Button>
            <h2
              className="pointer-events-none absolute inset-x-24 truncate text-center text-headline"
              id={titleId}
            >
              {title}
            </h2>
            {confirm ? (
              <Button
                type="button"
                variant="ghost"
                className={cn(
                  "px-2 font-semibold hover:bg-transparent",
                  confirm.destructive
                    ? "text-destructive hover:text-destructive/80"
                    : "text-primary hover:text-primary/80",
                )}
                disabled={confirm.disabled}
                onClick={confirm.onConfirm}
              >
                {confirm.label}
              </Button>
            ) : null}
          </header>
          <div
            className="min-h-0 overflow-y-auto px-4 pb-6 sm:px-6"
            style={{ paddingBottom: "max(1.5rem, env(safe-area-inset-bottom))" }}
          >
            {children}
          </div>
        </div>
      ) : null}
    </dialog>
  );
}
