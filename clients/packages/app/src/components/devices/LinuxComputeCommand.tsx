import { useCall } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { useRef, useState } from "react";
import { DeviceInstallCommand } from "./AddComputerCommand";

/** Requests a command only after the member chooses Linux installation. */
export function LinuxComputeCommand({ workspace }: { workspace: string }) {
  const m = useCommaMessages();
  const call = useCall();
  const requestId = useRef<string | undefined>(undefined);
  const [issued, setIssued] = useState<{ command: string; expiresAt: string }>();
  const [busy, setBusy] = useState(false);
  const [failed, setFailed] = useState(false);
  const generate = () => {
    requestId.current ??= crypto.randomUUID();
    setBusy(true);
    setFailed(false);
    void call("computeNode.installCommand", {
      workspaceId: workspace,
      requestId: requestId.current,
    }).then(
      (answer) => {
        setIssued(answer);
        setBusy(false);
      },
      () => {
        setFailed(true);
        setBusy(false);
      }
    );
  };
  return (
    <div className="flex flex-col gap-sm">
      {issued ? (
        <DeviceInstallCommand
          enrollment={{
            command: issued.command,
            expiresAt: Date.parse(issued.expiresAt) / 1000,
          }}
          description={m.settings_devices_linux_description()}
        />
      ) : (
        <Button
          hierarchy="secondary-gray"
          size="sm"
          isDisabled={busy}
          onPress={generate}
        >
          {busy ? m.common_loading() : m.settings_devices_linux_install()}
        </Button>
      )}
      {failed ? (
        <p className="m-0 text-sm text-error-primary" role="alert">
          {m.settings_devices_install_failed()}
        </p>
      ) : null}
    </div>
  );
}
