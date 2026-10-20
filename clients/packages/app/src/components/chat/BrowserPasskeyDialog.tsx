import { QRCodeCanvas } from "qrcode.react";
import type { BrowserSidebarPasskeyPrompt } from "@comma/native-bridge";
import { useCommaMessages } from "@comma/i18n/react";
import { Dialog } from "@comma/ui/components/dialog";
import { LoadingIndicator } from "@comma/ui/components/LoadingIndicator";

/**
 * The passkey dialog of a browser tab. The page asked for a passkey that a
 * phone can provide: the phone scans the QR code, then the user confirms on
 * the phone. Main owns the request; closing the dialog cancels it, and the
 * page gets the error a browser gives when the user closes its dialog.
 */
export function BrowserPasskeyDialog({
  onDismiss,
  prompt,
}: {
  onDismiss: () => void;
  prompt: BrowserSidebarPasskeyPrompt;
}) {
  const m = useCommaMessages();
  const failed = prompt.phase === "failed";
  const title = failed
    ? m.browser_passkey_failed_title()
    : prompt.kind === "create"
      ? m.browser_passkey_create_title()
      : m.browser_passkey_sign_in_title();
  const description =
    prompt.phase === "scan"
      ? prompt.kind === "create"
        ? m.browser_passkey_scan_create({ site: prompt.site })
        : m.browser_passkey_scan_sign_in({ site: prompt.site })
      : prompt.phase === "connecting"
        ? m.browser_passkey_connecting()
        : prompt.phase === "phone"
          ? m.browser_passkey_phone()
          : m.browser_passkey_failed();
  const bluetooth =
    prompt.phase !== "scan"
      ? undefined
      : prompt.bluetooth === "off"
        ? m.browser_passkey_bluetooth_off()
        : prompt.bluetooth === "denied"
          ? m.browser_passkey_bluetooth_denied()
          : prompt.bluetooth === "unsupported"
            ? m.browser_passkey_bluetooth_unsupported()
            : undefined;

  return (
    <Dialog
      isOpen
      isDismissable
      onOpenChange={(open) => {
        if (!open) onDismiss();
      }}
      title={title}
      description={description}
      actions={[
        {
          label: failed ? m.browser_passkey_close() : m.settings_profile_cancel(),
          hierarchy: "secondary-gray",
          onPress: onDismiss,
        },
      ]}
    >
      {prompt.phase === "scan" && prompt.qr ? (
        <div className="flex flex-col items-center gap-3">
          <figure aria-label={m.browser_passkey_qr_label()} className="m-0">
            <QRCodeCanvas
              className="rounded-lg"
              level="M"
              marginSize={4}
              size={208}
              value={prompt.qr}
            />
          </figure>
          {bluetooth ? (
            <p className="text-center text-sm text-warning-primary" role="alert">
              {bluetooth}
            </p>
          ) : null}
          {prompt.securityKey ? (
            <p className="text-center text-sm text-tertiary">
              {m.browser_passkey_security_key()}
            </p>
          ) : null}
        </div>
      ) : null}
      {prompt.phase === "connecting" || prompt.phase === "phone" ? (
        <div className="flex justify-center py-4">
          <LoadingIndicator label={description} />
        </div>
      ) : null}
    </Dialog>
  );
}
