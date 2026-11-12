import type { App, Session, WebContents, WebFrameMain } from "electron";
import { miniAppRuntimeUrl } from "@comma/chat-contract/mini-app-runtime";
import { isAllowedUrl } from "./security";
import type { MainClock } from "./clock";

export type MiniAppDevice = { id: string; name: string };
export type ChooseMiniAppDevice = (
  kind: "usb" | "bluetooth",
  devices: readonly MiniAppDevice[],
  contents: WebContents
) => Promise<string | undefined>;

/**
 * Chromium enforces the frame's device policy. Electron owns the chooser and keeps selected device grants in memory.
 * No device permission handler grants blanket access. Browser device grants belong to the top-level Comma origin.
 */
export function installMiniAppDeviceChoosers({
  app,
  session,
  appOrigins,
  ownerOfFrame,
  choose,
  clock,
}: {
  app: Pick<App, "on">;
  session: Session;
  appOrigins: readonly string[];
  ownerOfFrame: (frame: WebFrameMain) => WebContents | undefined;
  choose: ChooseMiniAppDevice;
  clock: MainClock;
}) {
  const origins = new Set(appOrigins);
  const trusted = (contents: WebContents) =>
    !contents.isDestroyed() &&
    contents.session === session &&
    isAllowedUrl(contents.getURL(), origins);
  // A window may have only one device chooser at a time, including a Bluetooth scan.
  const busy = new WeakSet<WebContents>();

  session.on("select-usb-device", (event, details, callback) => {
    event.preventDefault();
    const frame = details.frame;
    const contents = frame ? ownerOfFrame(frame) : undefined;
    if (
      !frame ||
      frame.url !== miniAppRuntimeUrl ||
      !contents ||
      !trusted(contents) ||
      busy.has(contents)
    ) {
      callback();
      return;
    }
    busy.add(contents);
    let finished = false;
    const finish = (id?: string) => {
      if (finished) return;
      finished = true;
      busy.delete(contents);
      contents.removeListener("destroyed", destroyed);
      callback(id);
    };
    const destroyed = () => finish();
    contents.once("destroyed", destroyed);
    const devices = details.deviceList.map((device) => ({
      id: device.deviceId,
      name: device.productName || `${device.vendorId}:${device.productId}`,
    }));
    void choose("usb", devices, contents).then(
      (id) =>
        finish(
          trusted(contents) &&
            !frame.detached &&
            frame.url === miniAppRuntimeUrl &&
            devices.some((device) => device.id === id)
            ? id
            : undefined
        ),
      () => finish()
    );
  });

  app.on("web-contents-created", (_event, contents) => {
    if (contents.session !== session) return;
    let pending:
      | {
          finish: (id?: string) => void;
          devices: readonly MiniAppDevice[];
        }
      | undefined;
    contents.on("select-bluetooth-device", (event, devices, callback) => {
      event.preventDefault();
      if (!trusted(contents)) {
        if (pending) pending.finish();
        else callback("");
        return;
      }
      if (!pending) {
        if (busy.has(contents)) {
          callback("");
          return;
        }
        busy.add(contents);
        let cancelScan: (() => void) | undefined;
        const finish = (id?: string) => {
          if (pending !== request) return;
          pending = undefined;
          cancelScan?.();
          busy.delete(contents);
          contents.removeListener("destroyed", destroyed);
          callback(id ?? "");
        };
        const destroyed = () => finish();
        const request = {
          finish,
          devices: [] as readonly MiniAppDevice[],
        };
        pending = request;
        contents.once("destroyed", destroyed);
        // One five-second collection window per request. Later scan events update the list before the dialog opens.
        // The timer is not extended by repeated events, so an empty or busy scan still completes.
        cancelScan = clock.setTimer(5_000, () => {
          if (!trusted(contents) || request.devices.length === 0) {
            finish();
            return;
          }
          void choose("bluetooth", request.devices, contents).then(
            (id) =>
              request.finish(
                trusted(contents) && request.devices.some((device) => device.id === id)
                  ? id
                  : undefined
              ),
            () => request.finish()
          );
        });
      }
      const request = pending;
      request.devices = devices.map((device) => ({
        id: device.deviceId,
        name: device.deviceName || device.deviceId,
      }));
    });
  });
}
