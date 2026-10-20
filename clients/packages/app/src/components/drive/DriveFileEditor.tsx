import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { ScrollArea } from "@comma/ui/components/scroll-area";
import { useState } from "react";
import { DriveFileName } from "./DriveFileName";

/**
 * A text file opened for editing in the preview sidebar: the whole text in
 * one field, saved as a whole. The preview's own toolbar row, with Cancel and
 * Save in place of the file actions.
 */
export function DriveFileEditor({
  fileName,
  initialText,
  onCancel,
  onSave,
  panelId,
}: {
  fileName: string;
  initialText: string;
  onCancel: () => void;
  /** Resolves once saved; a rejection keeps the editor open with the text. */
  onSave: (text: string) => Promise<void>;
  panelId: string;
}) {
  const messages = useCommaMessages();
  const [text, setText] = useState(initialText);
  const [saving, setSaving] = useState(false);
  const save = () => {
    setSaving(true);
    void onSave(text)
      .catch(() => undefined)
      .finally(() => setSaving(false));
  };
  return (
    <section
      className="flex min-h-0 min-w-0 flex-1 flex-col"
      data-testid="drive-file-editor"
      id={panelId}
      role="tabpanel"
    >
      <div className="flex min-h-11 shrink-0 items-center justify-between gap-md border-b-[0.5px] border-primary py-xs pr-2.5 pl-xl">
        <h2 className="m-0 flex min-w-0 flex-1 text-sm font-medium text-primary">
          <DriveFileName className="min-w-0 flex-1" name={fileName} />
        </h2>
        <div className="flex shrink-0 items-center gap-xs">
          <Button
            hierarchy="tertiary-gray"
            isDisabled={saving}
            onPress={onCancel}
            size="xs"
          >
            {messages.drive_editor_cancel()}
          </Button>
          <Button
            data-testid="drive-file-editor-save"
            isDisabled={saving || text === initialText}
            onPress={save}
            size="xs"
          >
            {messages.drive_editor_save()}
          </Button>
        </div>
      </div>
      <ScrollArea
        className="min-h-0 flex-1"
        contentClassName="flex min-h-full flex-col"
        edgeEffect="none"
        viewportClassName="h-full"
      >
        <textarea
          aria-label={messages.drive_editor_text({ fileName })}
          className="field-sizing-content block min-h-full w-full flex-1 resize-none border-0 bg-transparent p-xl font-mono text-sm text-primary outline-none"
          data-testid="drive-file-editor-text"
          disabled={saving}
          onChange={(event) => setText(event.target.value)}
          spellCheck={false}
          value={text}
        />
      </ScrollArea>
    </section>
  );
}
