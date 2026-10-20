import { useCall } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { CopyIcon } from "@comma/ui/components/icons";
import { toast } from "@comma/ui/components/toast";
import { useEffect, useState } from "react";
import { copyTextToClipboard } from "../chat/thread/inline/linkActions";

/**
 * The one-time command that installs a station on another computer and adds it to `workspace` as the viewer's, read
 * when it is shown, with a copy button.
 */
export function AddComputerCommand({ workspace }: { workspace: string }) {
  const m = useCommaMessages();
  const call = useCall();
  const [enrollment, setEnrollment] = useState<{
    command: string;
    expiresAt: number;
  } | null>(null);
  const [failed, setFailed] = useState(false);
  useEffect(() => {
    let live = true;
    setEnrollment(null);
    setFailed(false);
    call("devices.enroll", { workspace }).then(
      (answer) => live && setEnrollment(answer),
      () => live && setFailed(true)
    );
    return () => {
      live = false;
    };
  }, [call, workspace]);
  const copy = () =>
    enrollment &&
    void copyTextToClipboard(enrollment.command).then(
      () => toast.success(m.common_copied(), { id: "copy-feedback" }),
      () => toast.error(m.settings_devices_install_failed())
    );
  if (failed)
    return (
      <p className="m-0 text-sm text-error-primary" role="alert">
        {m.settings_devices_install_failed()}
      </p>
    );
  if (!enrollment)
    return <p className="m-0 text-sm text-tertiary">{m.common_loading()}</p>;
  const expires = new Date(enrollment.expiresAt * 1000).toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
  });
  return (
    <div className="flex flex-col gap-sm">
      <p className="m-0 text-sm text-secondary">
        {m.settings_devices_install_description()}
      </p>
      <div className="flex items-start gap-sm rounded-md border-[0.5px] border-primary bg-popup-secondary p-md">
        <code
          className="min-w-0 flex-1 break-all font-mono text-xs leading-5 text-primary"
          data-testid="device-install-command"
        >
          {enrollment.command}
        </code>
        <Button
          aria-label={m.common_copy()}
          hierarchy="secondary-gray"
          iconLeading={<CopyIcon />}
          onPress={copy}
          size="xs"
        >
          {m.common_copy()}
        </Button>
      </div>
      <p className="m-0 text-xs text-tertiary">
        {m.settings_devices_install_expires({ time: expires })}
      </p>
    </div>
  );
}
