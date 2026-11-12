import { useCall, useCore, type ListedScreen } from "@comma/core-client";
import { getNativeBridge } from "@comma/native-bridge";
import { useEffect, useMemo, useRef } from "react";
import type {
  ScreenDeviceButton,
  ScreenDeviceShape,
  ScreenStreamCapabilities,
} from "./screenDevice";
import type { ScreenStreamChrome } from "./screenCase";
import type { ScreenStreamSource } from "./ScreenStreamStage";

const BUTTONS: readonly ScreenDeviceButton[] = ["home", "lock", "volume", "rotate"];
// What a panel that says no rounded corners is drawn with, as a share of its width: an emulator's say 0
// (`rounded_corner_radius` 0dip), where the phones they stand for do not have square corners.
const DEFAULT_CORNER = 0.035;

function shapeOf(
  panel: ListedScreen["capabilities"]["panels"][number]
): ScreenDeviceShape {
  const { curves } = panel;
  // (a simulator's mask says each corner closer: the superellipse its curve is)
  if (curves)
    return {
      frame: { width: panel.width, height: panel.height },
      screen: { x: 0, y: 0, width: panel.width, height: panel.height },
      corners: [
        curves[0].reach * panel.width,
        curves[1].reach * panel.width,
        curves[2].reach * panel.width,
        curves[3].reach * panel.width,
      ],
      shapes: [curves[0].k, curves[1].k, curves[2].k, curves[3].k],
    };
  const [topLeft, topRight, bottomRight, bottomLeft] = panel.corners.some((c) => c > 0)
    ? panel.corners
    : [DEFAULT_CORNER, DEFAULT_CORNER, DEFAULT_CORNER, DEFAULT_CORNER];
  return {
    // (the body goes round the screen at one thickness: styles.css)
    frame: { width: panel.width, height: panel.height },
    screen: { x: 0, y: 0, width: panel.width, height: panel.height },
    corners: [
      topLeft * panel.width,
      topRight * panel.width,
      bottomRight * panel.width,
      bottomLeft * panel.width,
    ],
  };
}

/**
 * What the stage is told of a listed device. `chromePictures`: asks the computer for one panel's case pictures turned, for
 * a simulator whose case its Mac has.
 */
export function deviceCapabilities(
  screen: ListedScreen,
  chrome?: Omit<ScreenStreamChrome, "panels"> | undefined
): ScreenStreamCapabilities {
  const { panels, buttons, input, poses } = screen.capabilities;
  const [first, ...rest] =
    panels.length > 0
      ? panels.map(shapeOf)
      : screen.width > 0 && screen.height > 0
        ? [
            shapeOf({
              width: screen.width,
              height: screen.height,
              corners: [0, 0, 0, 0],
            }),
          ]
        : [];
  return {
    input,
    buttons: BUTTONS.filter((button) => buttons.includes(button)),
    ...(first ? { shapes: [first, ...rest] } : {}),
    ...(poses?.length ? { poses } : {}),
    ...(chrome && screen.capabilities.chrome?.length
      ? { chrome: { ...chrome, panels: screen.capabilities.chrome } }
      : {}),
  };
}

/**
 * Screen streams of one computer over the mesh, through the core. `apps` names the apps an app stream shows; `screen`:
 * one of its devices instead of its own screen.
 */
export function useDeviceScreenSource(
  workspace: string,
  device: string,
  apps: readonly string[],
  screen?: ListedScreen | undefined
): ScreenStreamSource {
  const call = useCall();
  const core = useCore();
  const appsKey = apps.join("\n");
  // This app's own computer, as its connector says it (Main's `connectorRuntime` state): a view of it carries no sound,
  // which playing here would put back on the same computer's output and capture again.
  const self = useRef(false);
  useEffect(() => {
    self.current = false;
    const bridge = getNativeBridge();
    if (bridge.platform !== "electron") return undefined;
    return bridge.connectorRuntime.state.subscribe((snapshot) => {
      self.current = snapshot.scopes.some(
        (scope) => scope.workspaceId === workspace && scope.deviceId === device
      );
    });
  }, [workspace, device]);
  return useMemo<ScreenStreamSource>(
    () => ({
      self: () => self.current,
      key: `${workspace}\n${device}\n${appsKey}${screen ? `\n${screen.id}\n${screen.instance}` : ""}`,
      ...(screen
        ? {
            capabilities: deviceCapabilities(screen, {
              key: `${workspace}\n${device}`,
              pictures: (panel, turn) =>
                call("devices.screenDeviceChrome", {
                  workspace,
                  device,
                  screen: screen.id,
                  panel,
                  turn,
                }),
            }),
          }
        : {}),
      view: {
        open: (request, onEvent, signal) =>
          core.call(
            "devices.openScreenView",
            {
              workspace,
              device,
              apps: appsKey ? appsKey.split("\n") : [],
              ...(screen ? { instance: screen.instance } : {}),
              ...request,
            },
            onEvent as (value: unknown) => void,
            signal
          ),
        send: (view, message) => {
          void call("devices.sendToScreenView", {
            view,
            ...message,
          }).catch(() => undefined);
        },
      },
    }),
    [appsKey, call, core, device, screen, workspace]
  );
}
