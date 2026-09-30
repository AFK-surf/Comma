import { MenuPopover } from "@comma/ui";
import { useEffect, useRef, useState, type KeyboardEvent } from "react";
import {
  Button as AriaButton,
  Dialog as AriaDialog,
  DialogTrigger,
  Input,
  TextField as AriaTextField,
} from "react-aria-components";

/**
 * Edit-in-place on the dropdown's selection-aligned popover: the text stays a
 * plain button in the layout, and editing opens a one-row popover whose input
 * ink sits exactly over that text (same trick the Dropdown uses for its checked
 * option), so nothing in the table moves or grows while a name or description
 * is being edited. Enter or leaving the editor commits, Escape reverts.
 */
export function InlineTextEditor({
  className = "",
  disabled,
  editRequest = 0,
  label,
  onCommit,
  placeholder,
  value,
}: {
  className?: string;
  disabled: boolean;
  /** Bumped by a caller (the row menu) to open the editor without a click. */
  editRequest?: number;
  label: string;
  onCommit: (next: string) => void;
  placeholder: string;
  value: string;
}) {
  const [open, setOpen] = useState(false);
  const [draft, setDraft] = useState(value);
  const [width, setWidth] = useState<number>();
  const triggerRef = useRef<HTMLButtonElement | null>(null);
  const inputRef = useRef<HTMLInputElement | null>(null);
  const cancelled = useRef(false);

  // The popover lands on device-pixel snaps of a fractionally positioned
  // trigger, and its half-pixel border rounds up, so the input text can sit up
  // to a couple of pixels off the ink it replaces. Measure the two once the
  // popover has been positioned and translate the input by the remainder —
  // a transform, so the row's layout and the sheet stay where they are.
  useEffect(() => {
    if (!open) return undefined;
    let frame = requestAnimationFrame(() => {
      frame = requestAnimationFrame(() => {
        const labelText = triggerRef.current?.querySelector(
          '[data-slot="dropdown-trigger-label"]'
        );
        const input = inputRef.current;
        if (!labelText || !input) return;
        input.style.translate = "";
        const ink = labelText.getBoundingClientRect();
        const box = input.getBoundingClientRect();
        if (ink.width === 0 || box.width === 0) return;
        const dx =
          ink.left -
          (box.left + Number.parseFloat(getComputedStyle(input).paddingLeft));
        const dy = ink.top + ink.height / 2 - (box.top + box.height / 2);
        input.style.translate = `${dx}px ${dy}px`;
      });
    });
    return () => cancelAnimationFrame(frame);
  }, [open]);
  // Each request opens the editor once. The row flips `disabled` while its
  // write is in flight, and that must not replay an already handled request.
  const handledRequest = useRef(0);

  useEffect(() => {
    if (editRequest <= handledRequest.current || disabled) return;
    handledRequest.current = editRequest;
    setDraft(value);
    cancelled.current = false;
    const cell = triggerRef.current?.closest("td");
    setWidth(cell ? cell.clientWidth : undefined);
    setOpen(true);
  }, [disabled, editRequest, value]);

  const start = () => {
    setDraft(value);
    cancelled.current = false;
    // The editor spans the cell the text lives in, not just the text's width.
    const cell = triggerRef.current?.closest("td");
    setWidth(cell ? cell.clientWidth : undefined);
    setOpen(true);
  };
  const finish = (nextOpen: boolean) => {
    if (nextOpen) {
      start();
      return;
    }
    setOpen(false);
    if (cancelled.current) return;
    const next = draft.trim();
    if (next !== value.trim()) onCommit(next);
  };
  const onKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    if (event.key === "Enter") {
      event.preventDefault();
      finish(false);
    } else if (event.key === "Escape") {
      // The popover closes on Escape by itself; only mark the edit as dropped.
      cancelled.current = true;
    }
  };

  return (
    <DialogTrigger isOpen={open} onOpenChange={finish}>
      <AriaButton
        ref={triggerRef}
        className={`comma-inline-editor-trigger ${value ? "text-primary" : "text-quaternary"} ${className}`}
        data-editing={open ? "true" : undefined}
        isDisabled={disabled}
      >
        <span data-slot="dropdown-trigger-label">{value || placeholder}</span>
      </AriaButton>
      <MenuPopover
        animation="in-place"
        className="comma-inline-editor-popover"
        selectionAlign={{ items: [{}], selectedIndex: 0, size: "sm", triggerRef }}
        {...(width ? { style: { minWidth: width } } : {})}
      >
        <AriaDialog aria-label={label} className="outline-none">
          <AriaTextField
            aria-label={label}
            className="comma-inline-editor-row"
            onChange={setDraft}
            value={draft}
          >
            <Input
              ref={inputRef}
              className="comma-inline-field-input"
              data-testid="inline-text-editor"
              onKeyDown={onKeyDown}
              placeholder={placeholder}
            />
          </AriaTextField>
        </AriaDialog>
      </MenuPopover>
    </DialogTrigger>
  );
}
