import { useEffect, useState } from "react";
import { useCall, useTopic } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { Dialog, type DialogAction } from "@comma/ui/components/dialog";
import { InputField } from "@comma/ui/components/input";
import { ScrollArea } from "@comma/ui/components/scroll-area";
import {
  DeviceSettingsRow,
  DeviceSetupHelp,
  DeviceSetupStatus,
  deviceSettingsButtonClassName,
} from "@comma/ui/components/settings";

/** The Add dialog's way to set up a Comma device over Bluetooth, where this app can. */
export function AddCommaDeviceOption({ onSetUp }: { onSetUp: () => void }) {
  const m = useCommaMessages();
  const { value } = useTopic({ topic: "deviceSetup" });
  if (!value?.supported) return null;
  return (
    <div className="flex flex-col gap-sm">
      <p className="m-0 text-sm text-secondary">{m.devices_add_scan_description()}</p>
      <Button hierarchy="secondary-gray" onPress={onSetUp}>
        {m.devices_add_comma()}
      </Button>
    </div>
  );
}

/** A name the core accepts for a device (its `validName`): not blank, at most 63 UTF-8 bytes trimmed. */
const validName = (name: string) =>
  name.trim().length > 0 && new TextEncoder().encode(name.trim()).length <= 63;

/** Bluetooth setup of one Comma device: it starts when shown and is cancelled when closed. */
export function AddDevice({
  workspace,
  onClose,
}: {
  workspace: string;
  onClose: () => void;
}) {
  const m = useCommaMessages();
  const call = useCall();
  const { value } = useTopic({ topic: "deviceSetup" });
  const [network, setNetwork] = useState("");
  const [password, setPassword] = useState("");
  // The name as typed, for the device it was typed for. The core trims and validates a name, so it gets
  // the name with Join instead of with each key.
  const [typed, setTyped] = useState<{ device: string; name: string } | null>(null);
  const [failed, setFailed] = useState(false);
  const state = value?.state;
  const send = (event: Parameters<typeof call<"deviceSetup.event">>[1]) =>
    void call("deviceSetup.event", event).catch(() => setFailed(true));
  const close = () => {
    send({ type: "cancel" });
    setPassword("");
    void call("devices.refresh", {}).catch(() => {});
    onClose();
  };
  useEffect(() => {
    void call("deviceSetup.start", { workspace }).catch(() => setFailed(true));
    return () => {
      void call("deviceSetup.event", { type: "cancel" }).catch(() => {});
    };
  }, [call, workspace]);
  if (!value?.supported) return null;
  const name =
    state && "name" in state
      ? state.name
      : state && "device" in state
        ? state.device.name
        : "";
  const title =
    state?.step === "pairing"
      ? m.devices_add_code_title({ name })
      : state?.step === "wifi"
        ? m.devices_add_wifi_title()
        : state?.step === "setup"
          ? m.devices_add_setup_title({ name })
          : state?.step === "done"
            ? state.online
              ? m.devices_add_done_title()
              : m.devices_add_almost_title()
            : state?.step === "failed"
              ? m.devices_add_failed_title()
              : m.devices_add_scan_title();
  const problem =
    state?.step === "failed"
      ? ({
          bluetooth: m.devices_problem_bluetooth(),
          connect_failed: m.devices_problem_connect(),
          pairing_failed: m.devices_problem_pairing(),
          disconnected: m.devices_problem_disconnected(),
          timeout: m.devices_problem_timeout(),
          rejected: m.devices_problem_rejected(),
          save_failed: m.devices_problem_save(),
          not_online: m.devices_problem_not_online(),
          connector_rejected: m.devices_problem_connector_rejected(),
          storage: m.devices_problem_storage(),
          server: m.devices_problem_server(),
        }[state.problem] ?? m.devices_problem_network())
      : "";
  const selectedNetwork =
    state?.step === "wifi"
      ? state.networks?.find((ap) => ap.ssid === network)
      : undefined;
  const typedName =
    state?.step === "wifi" && typed?.device === state.device.id ? typed.name : null;
  const actions: DialogAction[] = [
    {
      label:
        state?.step === "done" ? m.devices_add_finish() : m.settings_profile_cancel(),
      hierarchy: state?.step === "done" ? "primary" : "secondary-gray",
      onPress: close,
    },
  ];
  if (state?.step === "failed")
    actions.push({
      label: m.devices_add_try_again(),
      hierarchy: "primary",
      onPress: () => send({ type: "retry" }),
    });
  if (state?.step === "wifi")
    actions.push({
      label: m.devices_add_wifi_join(),
      hierarchy: "primary",
      disabled:
        !selectedNetwork ||
        (selectedNetwork.secure && password.length < 8) ||
        (typedName !== null && !validName(typedName)),
      onPress: () => {
        const join = { type: "join" as const, ssid: network, password };
        setPassword("");
        // The rename lands before the join that mints the device under that name.
        void (
          typedName === null
            ? Promise.resolve(null)
            : call("deviceSetup.event", { type: "rename", name: typedName })
        )
          .then(() => call("deviceSetup.event", join))
          .catch(() => setFailed(true));
      },
    });
  return (
    <Dialog
      isOpen
      title={title}
      {...(state?.step === "scanning"
        ? { description: m.devices_add_scan_description() }
        : {})}
      className="comma-device-setup"
      showCloseButton
      onOpenChange={(isOpen) => {
        if (!isOpen) close();
      }}
      actions={actions}
    >
      <ScrollArea
        className="max-h-96"
        orientation="vertical"
        scrollbarVisibility="hover"
      >
        <div className="flex flex-col gap-lg">
          {failed && <p role="alert">{m.devices_problem_network()}</p>}
          {value.bluetooth === "off" && <p>{m.devices_add_bluetooth_off()}</p>}
          {value.bluetooth === "denied" && (
            <p>{m.devices_add_bluetooth_permission()}</p>
          )}
          {state?.step === "scanning" && (
            <>
              <DeviceSetupStatus
                title={m.devices_add_scanning()}
                description={
                  state.quiet && state.devices.length === 0
                    ? m.devices_add_scan_empty()
                    : m.devices_add_scan_hint()
                }
                pending
              />
              {state.devices.length > 0 && (
                <div className="flex flex-col gap-sm">
                  <p className="comma-device-setup-list__title">
                    {m.devices_add_found()}
                  </p>
                  <div className="comma-device-setup-list">
                    {state.devices.map((device) => (
                      <DeviceSettingsRow
                        key={device.id}
                        title={device.name}
                        action={
                          <Button
                            hierarchy="secondary-gray"
                            size="sm"
                            className={deviceSettingsButtonClassName}
                            aria-label={m.devices_add_code_title({
                              name: device.name,
                            })}
                            onPress={() => send({ type: "pick", id: device.id })}
                          >
                            {m.devices_add_pair_action()}
                          </Button>
                        }
                      />
                    ))}
                  </div>
                </div>
              )}
              <DeviceSetupHelp title={m.devices_add_pairing_help()}>
                <p>{m.devices_add_scan_body()}</p>
              </DeviceSetupHelp>
            </>
          )}
          {state?.step === "pairing" && (
            <>
              <DeviceSetupStatus
                title={name}
                description={m.devices_add_connecting_body({ name })}
                pending
              />
              <p className="text-xs text-tertiary">
                {m.devices_add_code_body({ name })}
              </p>
            </>
          )}
          {state?.step === "wifi" && (
            <>
              <InputField
                label={m.devices_add_name()}
                className="w-full"
                value={typedName ?? state.name}
                onChange={(e) =>
                  setTyped({ device: state.device.id, name: e.target.value })
                }
              />
              {!selectedNetwork && (
                <p className="text-xs text-tertiary">{m.devices_add_wifi_band()}</p>
              )}
              {state.failure && (
                <p role="alert">
                  {state.failure === "wrong_password"
                    ? m.devices_add_wifi_wrong_password({ name: network })
                    : state.failure === "scan_failed"
                      ? m.devices_add_wifi_scan_failed()
                      : m.devices_add_wifi_failed({ name: network })}
                </p>
              )}
              {state.scanning && <p>{m.devices_add_wifi_scanning()}</p>}
              {selectedNetwork ? (
                <>
                  <div className="comma-device-setup-list">
                    <DeviceSettingsRow
                      title={selectedNetwork.ssid}
                      description={
                        selectedNetwork.secure
                          ? m.devices_add_wifi_secured()
                          : m.devices_add_wifi_open()
                      }
                      action={
                        <Button
                          hierarchy="secondary-gray"
                          size="sm"
                          className={deviceSettingsButtonClassName}
                          onPress={() => {
                            setNetwork("");
                            setPassword("");
                          }}
                        >
                          {m.devices_add_wifi_change()}
                        </Button>
                      }
                    />
                  </div>
                  {selectedNetwork.secure && (
                    <InputField
                      label={m.devices_add_wifi_password_description()}
                      hint={m.devices_add_wifi_password_hint()}
                      className="w-full"
                      type="password"
                      autoComplete="off"
                      // Selection replaces the picker, so move focus into its new form.
                      // oxlint-disable-next-line jsx-a11y/no-autofocus
                      autoFocus
                      value={password}
                      maxLength={64}
                      onChange={(e) => setPassword(e.target.value)}
                    />
                  )}
                </>
              ) : (
                !!state.networks?.length && (
                  <div className="comma-device-setup-list">
                    {state.networks.map((ap) => (
                      <DeviceSettingsRow
                        key={ap.ssid}
                        title={ap.ssid}
                        description={
                          ap.secure
                            ? m.devices_add_wifi_secured()
                            : m.devices_add_wifi_open()
                        }
                        action={
                          <Button
                            hierarchy="secondary-gray"
                            size="sm"
                            className={deviceSettingsButtonClassName}
                            aria-label={ap.ssid}
                            onPress={() => {
                              setNetwork(ap.ssid);
                              setPassword("");
                            }}
                          >
                            {m.devices_add_wifi_select()}
                          </Button>
                        }
                      />
                    ))}
                  </div>
                )
              )}
              {!selectedNetwork && (
                <Button
                  hierarchy="link-gray"
                  size="sm"
                  disabled={state.scanning}
                  onPress={() => send({ type: "rescan" })}
                >
                  {m.devices_add_wifi_rescan()}
                </Button>
              )}
            </>
          )}
          {state?.step === "setup" && (
            <DeviceSetupStatus
              title={
                {
                  joining: m.devices_add_setup_wifi({ name: state.ssid }),
                  minting: m.devices_add_setup_credentials(),
                  saving: m.devices_add_setup_save(),
                  online: m.devices_add_setup_online(),
                }[state.phase]
              }
              description={m.devices_add_setup_body()}
              pending
            />
          )}
          {state?.step === "done" && (
            <DeviceSetupStatus
              title={name}
              tone={state.online ? "success" : "neutral"}
              description={
                state.online
                  ? m.devices_add_done_body({ name })
                  : m.devices_add_almost_body({ name })
              }
            />
          )}
          {state?.step === "failed" && (
            <div role="alert">
              <DeviceSetupStatus title={problem} tone="warning" />
            </div>
          )}
        </div>
      </ScrollArea>
    </Dialog>
  );
}
