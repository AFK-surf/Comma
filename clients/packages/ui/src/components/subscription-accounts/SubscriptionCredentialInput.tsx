import type { ReactNode } from "react";

/** A subscription credential, from the file a provider CLI writes or pasted JSON. */
export function SubscriptionCredentialInput({
  busy,
  value,
  onChange,
  onFile,
  fileName,
  fileLabel,
  fileSource,
  jsonLabel,
}: {
  busy: boolean;
  value: string;
  onChange: (value: string) => void;
  onFile: (file: File) => void;
  fileName: string;
  fileLabel: string;
  /** Where the provider's CLI writes the file, so the reader can go find it. */
  fileSource: ReactNode;
  jsonLabel: string;
}) {
  return (
    // The two ways in are alternatives, so they stack rather than share a row.
    <div className="flex w-full min-w-0 flex-col gap-lg">
      <label className="relative block cursor-pointer rounded-lg border border-dashed border-primary bg-secondary p-3xl text-center focus-within:ring-2">
        <span className="block text-sm font-medium text-primary">
          {fileName || fileLabel}
        </span>
        <span className="mt-xs block text-xs text-tertiary">{fileSource}</span>
        <input
          type="file"
          aria-label={fileLabel}
          accept=".json,application/json"
          disabled={busy}
          className="absolute inset-0 h-full w-full cursor-pointer opacity-0"
          onChange={(event) => {
            const file = event.target.files?.[0];
            event.target.value = "";
            if (file) onFile(file);
          }}
        />
      </label>
      <label className="block text-sm text-primary">
        {jsonLabel}
        <textarea
          aria-label={jsonLabel}
          rows={4}
          spellCheck={false}
          autoComplete="off"
          disabled={busy}
          value={value}
          onChange={(event) => onChange(event.target.value)}
          className="mt-sm block w-full resize-none rounded-lg border border-primary bg-primary px-lg py-md font-mono text-xs text-primary"
        />
      </label>
    </div>
  );
}
