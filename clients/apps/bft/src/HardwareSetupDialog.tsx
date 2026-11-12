import { Dialog } from "@comma/ui/components/dialog";
import { Dropdown } from "@comma/ui/components/dropdown";
import { InputField } from "@comma/ui/components/input";
import { useEffect, useRef, useState } from "react";
import { DialogError, writeErrorMessage } from "./dialogs";
import {
  Board,
  bluetoothAvailable,
  validPassword,
  type BoardStatus,
  type WifiNetwork,
} from "./hardwareBle";
import { messages } from "./messages";
import { useApi } from "./resource";

const t = messages.hardwareSetup;

type Step =
  | { kind: "start"; error?: string | undefined }
  | { kind: "connecting" }
  | { kind: "wifi"; error?: string | undefined }
  | { kind: "joining"; ssid: string }
  | { kind: "saving" }
  | { kind: "done"; online: boolean }
  | { kind: "failed"; message: string };

// How long the board may take to join Wi-Fi and to store its credentials
// (as in the Comma app's setup flow).
const joinTimeoutMs = 45_000;
const saveTimeoutMs = 20_000;

/**
 * Sets up a Comma hardware board for this Agent Swarm from the browser: pick
 * it over Web Bluetooth, join it to a 2.4 GHz Wi-Fi network, then store the
 * credentials the server mints for it once its Wi-Fi is up (so a wrong
 * password never leaves credentials behind). The board starts read-only; an
 * admin allows operations in the device list.
 */
export function HardwareSetupDialog({
  org,
  project,
  onClose,
}: {
  org: string;
  project: string;
  onClose: () => void;
}) {
  const api = useApi();
  const board = useRef<Board | null>(null);
  const [step, setStep] = useState<Step>({ kind: "start" });
  const [name, setName] = useState("");
  const [ssid, setSsid] = useState("");
  const [password, setPassword] = useState("");
  const [networks, setNetworks] = useState<WifiNetwork[] | null>(null);
  // The board's own status drives the steps after the Wi-Fi password.
  const onStatus = useRef<(status: BoardStatus) => void>(() => {});

  // Each step that waits on the board or the server is one phase. Ending it
  // (an answer, a timeout, a lost connection) starts the next phase, so a late
  // answer of an ended phase changes nothing.
  const phase = useRef(0);
  // Whether the board stored its credentials: Bluetooth closes by design then.
  const stored = useRef(false);
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const begin = () => {
    clearTimeout(timer.current);
    onStatus.current = () => {};
    phase.current += 1;
    const id = phase.current;
    /** Runs `run` only while this phase is current. */
    return <T,>(run: () => T): T | undefined =>
      phase.current === id ? run() : undefined;
  };
  const end = (next: Step) => {
    begin();
    setStep(next);
  };

  useEffect(
    () => () => {
      begin();
      board.current?.disconnect();
    },
    []
  );

  const scan = (current: Board) => {
    const live = begin();
    setNetworks(null);
    setStep({ kind: "wifi" });
    current.scan().then(
      (found) =>
        live(() => {
          setNetworks(found);
          setSsid((chosen) => chosen || (found[0]?.ssid ?? ""));
        }),
      () =>
        live(() => {
          setNetworks([]);
          setStep({ kind: "wifi", error: t.scanFailed });
        })
    );
  };

  const pick = () => {
    const live = begin();
    setStep({ kind: "connecting" });
    Board.pick().then(
      async (picked) => {
        board.current = picked;
        // A board lost before it stored its credentials must be picked again.
        picked.onDisconnect(() => {
          if (!stored.current) end({ kind: "start", error: t.connectionLost });
        });
        setName(picked.name);
        await picked.watch((status) => onStatus.current(status));
        live(() => scan(picked));
      },
      (error: unknown) =>
        live(() =>
          // Closing the browser's chooser is not an error worth showing.
          setStep({
            kind: "start",
            error:
              error instanceof DOMException && error.name === "NotFoundError"
                ? undefined
                : t.connectFailed,
          })
        )
    );
  };

  const save = (current: Board) => {
    const live = begin();
    setStep({ kind: "saving" });
    timer.current = setTimeout(
      () => end({ kind: "wifi", error: t.saveFailed }),
      saveTimeoutMs
    );
    onStatus.current = (status) => {
      if (status.state === "connector_up") {
        stored.current = true;
        end({ kind: "done", online: true });
      } else if (status.state === "saved") {
        stored.current = true;
        // The board may still report connector_up or connector_failed.
        clearTimeout(timer.current);
        setStep({ kind: "done", online: false });
      } else if (status.state === "connector_failed")
        end({ kind: "failed", message: t.connectorFailed });
      else if (status.state === "wifi_up" && status.error)
        // The board could not store what it was given (`save_failed`).
        end({ kind: "wifi", error: t.saveFailed });
    };
    api
      .provisionHardwareDevice(org, project, name.trim())
      // Credentials of an ended phase are never written; their token expires unused.
      .then((credentials) => live(() => current.saveCredentials(credentials)))
      .catch((error: unknown) =>
        live(() =>
          end({ kind: "wifi", error: writeErrorMessage(error) || t.saveFailed })
        )
      );
  };

  const join = () => {
    const current = board.current;
    if (!current) return;
    const live = begin();
    setStep({ kind: "joining", ssid });
    timer.current = setTimeout(
      () => end({ kind: "wifi", error: t.wifiFailed.timeout ?? t.wifiFailedFallback }),
      joinTimeoutMs
    );
    onStatus.current = (status) => {
      if (status.state === "wifi_up" && !status.error) save(current);
      else if (status.state === "wifi_failed")
        end({
          kind: "wifi",
          error: t.wifiFailed[status.error ?? ""] ?? t.wifiFailedFallback,
        });
    };
    current
      .joinWifi(ssid, password)
      .catch(() => live(() => end({ kind: "wifi", error: t.wifiFailedFallback })));
  };

  const network = networks?.find((candidate) => candidate.ssid === ssid);
  const nameValid =
    name.trim() !== "" && new TextEncoder().encode(name.trim()).length <= 63;
  const ready = !!network && nameValid && validPassword(network, password);
  const busy =
    step.kind === "connecting" || step.kind === "joining" || step.kind === "saving";
  const close = () => {
    if (!busy) onClose();
  };

  const primary =
    step.kind === "done" || step.kind === "failed"
      ? { label: t.finish, hierarchy: "primary" as const, onPress: onClose }
      : step.kind === "start" || step.kind === "connecting"
        ? {
            label: step.kind === "connecting" ? t.connecting : t.findBoard,
            hierarchy: "primary" as const,
            onPress: pick,
            disabled: busy || !bluetoothAvailable(),
          }
        : {
            label:
              step.kind === "joining"
                ? t.joining(step.ssid)
                : step.kind === "saving"
                  ? t.saving
                  : t.connect,
            hierarchy: "primary" as const,
            onPress: join,
            disabled: busy || !ready,
          };

  return (
    <Dialog
      actions={[
        ...(step.kind === "done" || step.kind === "failed"
          ? []
          : [
              {
                label: messages.common.cancel,
                hierarchy: "secondary-gray" as const,
                onPress: close,
                disabled: busy,
              },
            ]),
        primary,
      ]}
      description={
        step.kind === "done" || step.kind === "failed" ? undefined : t.description
      }
      isDismissable={!busy}
      isOpen
      onOpenChange={(open) => {
        if (!open) close();
      }}
      title={step.kind === "done" ? t.doneTitle : t.title}
    >
      <div className="bft-form">
        {step.kind === "start" || step.kind === "connecting" ? (
          <>
            <ol className="bft-steps">
              <li>{t.stepPower}</li>
              <li>{t.stepPairing}</li>
              <li>{t.stepCode}</li>
            </ol>
            {bluetoothAvailable() ? null : (
              <p className="bft-dialog-error" role="alert">
                {t.noBluetooth}
              </p>
            )}
            <DialogError message={step.kind === "start" ? step.error : undefined} />
          </>
        ) : step.kind === "done" ? (
          <p>{step.online ? t.doneOnline(name.trim()) : t.doneSaved(name.trim())}</p>
        ) : step.kind === "failed" ? (
          <p className="bft-dialog-error" role="alert">
            {step.message}
          </p>
        ) : (
          <>
            <InputField
              className="w-full"
              disabled={busy}
              fieldSize="sm"
              label={t.name}
              onChange={(event) => setName(event.target.value)}
              value={name}
              wrapperClassName="bft-form-field"
            />
            {networks === null ? (
              <p className="bft-quiet">{t.scanning}</p>
            ) : (
              <Dropdown
                className="bft-form-field"
                disabled={busy || !networks?.length}
                items={(networks ?? []).map((candidate) => ({
                  id: candidate.ssid,
                  label: candidate.secure
                    ? candidate.ssid
                    : t.openNetwork(candidate.ssid),
                }))}
                label={t.network}
                onChange={(chosen) => {
                  setSsid(chosen);
                  // An open network takes no password; a typed one would block Connect.
                  if (
                    networks?.find((candidate) => candidate.ssid === chosen)?.secure ===
                    false
                  )
                    setPassword("");
                }}
                size="sm"
                value={ssid}
              />
            )}
            <p className="bft-quiet">{t.onlyTwoFour}</p>
            {network?.secure === false ? null : (
              <InputField
                className="w-full"
                disabled={busy}
                fieldSize="sm"
                label={t.password}
                onChange={(event) => setPassword(event.target.value)}
                type="password"
                value={password}
                wrapperClassName="bft-form-field"
              />
            )}
            {step.kind === "wifi" && !busy ? (
              <button
                className="bft-btn bft-btn-sm"
                onClick={() => board.current && scan(board.current)}
                type="button"
              >
                {t.rescan}
              </button>
            ) : null}
            <DialogError message={step.kind === "wifi" ? step.error : undefined} />
          </>
        )}
      </div>
    </Dialog>
  );
}
