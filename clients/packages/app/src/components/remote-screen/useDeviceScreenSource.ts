import { useCall } from "@comma/core-client";
import { useMemo } from "react";
import type { ScreenStreamSource } from "./ScreenStreamStage";

/** Screen streams of one computer, signaled through the core. `apps` names the apps an app stream shows. */
export function useDeviceScreenSource(
  workspace: string,
  device: string,
  apps: readonly string[]
): ScreenStreamSource {
  const call = useCall();
  const appsKey = apps.join("\n");
  return useMemo<ScreenStreamSource>(
    () => ({
      iceServers: () =>
        call("devices.screenStreamIce", { workspace, device }).then(
          (answer) => answer.servers
        ),
      start: ({ iceServers, ...request }) =>
        call("devices.startScreenStream", {
          workspace,
          device,
          apps: appsKey ? appsKey.split("\n") : [],
          servers: iceServers.map((server) => ({
            urls: [server.urls].flat(),
            ...(server.username === undefined ? {} : { username: server.username }),
            ...(typeof server.credential === "string"
              ? { credential: server.credential }
              : {}),
          })),
          ...request,
        }),
      stop: (stream) => {
        void call("devices.stopScreenStream", { workspace, device, stream }).catch(
          () => undefined
        );
      },
    }),
    [appsKey, call, device, workspace]
  );
}
