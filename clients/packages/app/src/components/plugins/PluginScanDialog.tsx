import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { Dialog } from "@comma/ui/components/dialog";
import { toast } from "@comma/ui/components/toast";
import { QRCodeSVG } from "qrcode.react";
import {
  nativePlatformClipboard,
  openNativePlatformExternalUrl,
} from "../../nativePlatformActions";

/**
 * The code of an install by a scan (Lark, Feishu): the member scans it with
 * the app on their phone, or opens the link (here, or copied to where they
 * are signed in to it), and confirms the bot app it makes for them. Step `member` follows in the same dialog: the member's
 * own sign-in with that app, which Comma reads and edits as them with. The client core
 * asks the server until each is done; cancelling stops it.
 */
export function PluginScanDialog({
  name,
  url,
  step,
  onCancel,
}: {
  name: string;
  url: string;
  step?: "member" | undefined;
  onCancel(): void;
}) {
  const messages = useCommaMessages();
  return (
    <Dialog
      isOpen
      isDismissable
      onOpenChange={(open) => {
        if (!open) onCancel();
      }}
      title={
        step === "member"
          ? messages.plugins_scan_member_title({ name })
          : messages.plugins_scan_title({ name })
      }
      description={
        step === "member"
          ? messages.plugins_scan_member_description({ name })
          : messages.plugins_scan_description({ name })
      }
      actions={[
        {
          // The plugin is installed already: leaving the sign-in only leaves it for later.
          label:
            step === "member"
              ? messages.plugins_scan_member_later()
              : messages.plugins_personal_source_cancel(),
          hierarchy: "secondary-gray",
          onPress: onCancel,
        },
      ]}
    >
      <div className="flex w-full flex-col items-center gap-lg">
        <figure
          aria-label={messages.plugins_scan_code({ name })}
          className="m-0 rounded-md bg-white"
        >
          <QRCodeSVG aria-hidden marginSize={2} size={320} value={url} />
        </figure>
        <div className="flex flex-wrap items-center justify-center gap-md">
          <Button
            hierarchy="secondary-color"
            size="sm"
            onPress={() => void openNativePlatformExternalUrl(url)}
          >
            {messages.plugins_scan_open({ name })}
          </Button>
          <Button
            hierarchy="secondary-gray"
            size="sm"
            onPress={() =>
              void nativePlatformClipboard.writeText(url).then(
                () => toast.success(messages.plugins_scan_link_copied()),
                () => toast.error(messages.copy_failed_title())
              )
            }
          >
            {messages.chat_copy_link()}
          </Button>
        </div>
        <output className="m-0 text-sm text-secondary">
          {messages.plugins_scan_waiting({ name })}
        </output>
      </div>
    </Dialog>
  );
}
