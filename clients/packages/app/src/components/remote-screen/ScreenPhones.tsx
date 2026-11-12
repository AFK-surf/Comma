import { useCall, type ListedPhone, type ListedPhones } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { Dialog } from "@comma/ui/components/dialog";
import { InputField } from "@comma/ui/components/input";
import { toast } from "@comma/ui/components/toast";
import { Toggle } from "@comma/ui/components/toggle";
import { useEffect, useState } from "react";

type Change =
  | { usb: boolean }
  | { serial: string; shown: boolean; agents?: boolean }
  | { connect: string };

/** What a phone's line says of it beside its name: what to do on it, or its serial. */
function phoneLine(phone: ListedPhone, messages: ReturnType<typeof useCommaMessages>) {
  if (phone.state === "unauthorized")
    return messages.remote_screen_phone_unauthorized();
  if (phone.state === "absent") return messages.remote_screen_phone_absent();
  return phone.serial;
}

/**
 * The computer's owner chooses its phones: whether its station takes USB phones (it then contends with Android
 * Studio's adb for them), which phones show, which agents may use, and one over Wi-Fi by its address. A phone not
 * shown is listed from what adb says alone; the station asks it nothing.
 */
export function ScreenPhonesDialog({
  workspace,
  device,
  computer,
  onClose,
}: {
  workspace: string;
  device: string;
  computer: string;
  onClose(): void;
}) {
  const messages = useCommaMessages();
  const call = useCall();
  const [phones, setPhones] = useState<ListedPhones | null>(null);
  const [busy, setBusy] = useState(false);
  const [address, setAddress] = useState("");

  useEffect(() => {
    let live = true;
    void call("devices.listScreens", { workspace, device })
      .then((answer) => {
        if (live) setPhones(answer.phones ?? { usb: false, list: [] });
      })
      .catch(() => toast(messages.remote_screen_phones_failed(), { intent: "error" }));
    return () => {
      live = false;
    };
  }, [call, device, messages, workspace]);

  const change = (what: Change) => {
    setBusy(true);
    void call("devices.chooseScreenPhones", { workspace, device, change: what })
      .then((answer) => {
        setPhones({ usb: answer.usb, list: answer.list });
        if ("connect" in what) setAddress("");
      })
      .catch(() => toast(messages.remote_screen_phones_failed(), { intent: "error" }))
      .finally(() => setBusy(false));
  };

  return (
    <Dialog
      actions={[
        {
          label: messages.remote_screen_phones_done(),
          hierarchy: "primary",
          onPress: onClose,
        },
      ]}
      description={messages.remote_screen_phones_body()}
      isOpen
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
      showCloseButton
      title={messages.remote_screen_phones_title({ computer })}
    >
      <div className="flex flex-col gap-lg" data-testid="remote-screen-phones">
        <Toggle
          checked={phones?.usb ?? false}
          disabled={busy || phones === null}
          hint={messages.remote_screen_phones_usb_hint()}
          label={messages.remote_screen_phones_usb()}
          onChange={(event) => change({ usb: event.target.checked })}
          size="sm"
        />
        {phones && phones.list.length === 0 ? (
          <p className="text-sm text-tertiary">
            {messages.remote_screen_phones_none()}
          </p>
        ) : null}
        <ul className="flex flex-col gap-md">
          {(phones?.list ?? []).map((phone) => (
            <li
              className="flex flex-wrap items-center justify-between gap-md"
              data-testid="remote-screen-phone"
              key={phone.serial}
            >
              <span className="flex min-w-0 flex-col">
                <span className="truncate text-sm font-medium text-secondary">
                  {phone.model ?? phone.serial}
                </span>
                <span className="truncate text-xs text-tertiary">
                  {phoneLine(phone, messages)}
                </span>
              </span>
              <span className="flex items-center gap-lg">
                <Toggle
                  checked={phone.shown}
                  disabled={busy}
                  label={messages.remote_screen_phone_show()}
                  onChange={(event) =>
                    change({
                      serial: phone.serial,
                      shown: event.target.checked,
                      agents: false,
                    })
                  }
                  size="sm"
                />
                <Toggle
                  checked={phone.agents}
                  disabled={busy || !phone.shown}
                  label={messages.remote_screen_phone_agents()}
                  onChange={(event) =>
                    change({
                      serial: phone.serial,
                      shown: true,
                      agents: event.target.checked,
                    })
                  }
                  size="sm"
                />
              </span>
            </li>
          ))}
        </ul>
        <div className="flex flex-col gap-xs">
          <div className="flex items-end gap-md">
            <InputField
              className="w-full"
              disabled={busy}
              fieldSize="sm"
              label={messages.remote_screen_phones_wifi()}
              onChange={(event) => setAddress(event.target.value)}
              placeholder="192.168.1.20:41234"
              value={address}
              wrapperClassName="flex-1"
            />
            <Button
              hierarchy="secondary-gray"
              isDisabled={busy || address.trim() === ""}
              onPress={() => change({ connect: address.trim() })}
              size="sm"
            >
              {messages.remote_screen_phones_connect()}
            </Button>
          </div>
          <p className="text-sm text-tertiary">
            {messages.remote_screen_phones_wifi_hint()}
          </p>
        </div>
      </div>
    </Dialog>
  );
}
