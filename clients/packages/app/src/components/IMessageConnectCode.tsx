import { QRCodeCanvas } from "qrcode.react";
import { Button } from "@comma/ui";
import { useCommaMessages } from "@comma/i18n/react";

export function IMessageConnectCode({
  handle,
  code,
  onCopy,
  onOpen,
}: {
  handle: string;
  code: string;
  onCopy: (text: string) => void;
  onOpen: (url: string) => void;
}) {
  const m = useCommaMessages();
  const command = `bridgebot connect ${code}`;
  const url = `sms:${encodeURIComponent(handle)}&body=${encodeURIComponent(command)}`;

  return (
    <div className="flex flex-wrap items-center gap-xl">
      <figure aria-label={m.settings_imessage_qr_label()} className="m-0 shrink-0">
        <QRCodeCanvas
          value={url}
          size={192}
          marginSize={4}
          level="M"
          className="rounded-lg"
        />
      </figure>
      <div className="min-w-0 flex-1 basis-48 space-y-md">
        <p className="text-sm font-medium text-primary">{m.settings_imessage_scan()}</p>
        <p className="text-sm leading-5 text-tertiary">
          {m.settings_imessage_scan_instruction()}
        </p>
        <p className="text-xs leading-5 text-quaternary">
          {m.settings_imessage_qr_expiry()}
        </p>
        <Button hierarchy="secondary-gray" size="sm" onPress={() => onOpen(url)}>
          {m.settings_imessage_open_messages()}
        </Button>
        <details className="text-xs leading-5 text-tertiary">
          <summary className="cursor-pointer">{m.settings_imessage_manual()}</summary>
          <p className="mt-md">{m.settings_imessage_manual_instruction()}</p>
          <Button
            hierarchy="secondary-gray"
            size="sm"
            className="mt-md max-w-full whitespace-normal break-all"
            onPress={() => onCopy(command)}
          >
            {command}
          </Button>
        </details>
      </div>
    </div>
  );
}
