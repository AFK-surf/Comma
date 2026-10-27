import { useCommaMessages } from "@comma/i18n/react";
import { Dialog } from "@comma/ui/components/dialog";
import { useState } from "react";
import type { useRouterInstructions } from "./useRouterInstructions";

/**
 * Settings › General › System prompt's editor: the Router's instructions in
 * one field, saved as a whole. Reset clears them, so the Router answers as
 * by default.
 */
export function RouterInstructionsDialog({
  instructions,
  onClose,
}: {
  instructions: ReturnType<typeof useRouterInstructions>;
  onClose: () => void;
}) {
  const m = useCommaMessages();
  const held = instructions.content ?? "";
  const [text, setText] = useState(held);
  const { busy, failure } = instructions;
  const finish = (saved: boolean) => {
    if (saved) onClose();
  };
  return (
    <Dialog
      actions={[
        ...(held
          ? [
              {
                label: m.settings_system_prompt_reset(),
                hierarchy: "secondary-gray" as const,
                disabled: busy,
                shortcut: false as const,
                onPress: () => void instructions.save("").then(finish),
              },
            ]
          : []),
        {
          label: m.settings_system_prompt_cancel(),
          hierarchy: "secondary-gray",
          onPress: onClose,
        },
        {
          label: m.settings_system_prompt_save(),
          hierarchy: "primary",
          disabled: busy || !text.trim() || text === held,
          onPress: () => void instructions.save(text).then(finish),
        },
      ]}
      description={m.settings_system_prompt_dialog_description()}
      isDismissable
      isOpen
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
      title={m.settings_system_prompt()}
    >
      <textarea
        aria-label={m.settings_system_prompt()}
        className="field-sizing-content block max-h-96 min-h-40 w-full resize-none rounded-md bg-primary px-lg py-md text-sm text-primary shadow-xs ring-1 ring-primary outline-none ring-inset focus:ring-2 focus:ring-border-brand disabled:cursor-not-allowed disabled:bg-disabled disabled:opacity-60"
        disabled={busy}
        onChange={(event) => {
          setText(event.target.value);
          instructions.clearFailure();
        }}
        placeholder={m.settings_system_prompt_placeholder()}
        value={text}
      />
      {failure ? (
        <p className="text-xs text-error-primary" role="alert">
          {failure === "changed"
            ? m.settings_system_prompt_changed()
            : m.settings_system_prompt_failed()}
        </p>
      ) : null}
    </Dialog>
  );
}
