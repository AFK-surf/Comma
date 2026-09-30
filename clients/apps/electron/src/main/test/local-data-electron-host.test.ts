import { describe, expect, it, vi } from "vitest";
import {
  LOCAL_DATA_WORKER_CONNECT_MESSAGE,
  LOCAL_DATA_WORKER_PROTOCOL_VERSION,
} from "../../shared/local-data";

const electron = vi.hoisted(() => {
  const port1 = {
    close: vi.fn(),
    off: vi.fn(),
    on: vi.fn(),
    postMessage: vi.fn(),
    start: vi.fn(),
  };
  const port2 = { close: vi.fn() };
  const child = {
    kill: vi.fn(() => true),
    off: vi.fn(),
    on: vi.fn(),
    postMessage: vi.fn(),
  };

  return {
    child,
    messageChannel: { port1, port2 },
    port1,
    port2,
    fork: vi.fn(() => child),
  };
});

vi.mock("electron", () => ({
  MessageChannelMain: vi.fn(function MessageChannelMain() {
    return electron.messageChannel;
  }),
  utilityProcess: {
    fork: electron.fork,
  },
}));

import { createElectronLocalDataWorkerHost } from "../modules/local-data/electron-utility-host";

describe("Electron local-data utility host", () => {
  it("forks the bundled worker and transfers exactly one typed RPC port", () => {
    const connection = createElectronLocalDataWorkerHost({
      modulePath: "/app/.vite/build/utility.js",
    }).connect();

    expect(electron.fork).toHaveBeenCalledWith("/app/.vite/build/utility.js", [], {
      serviceName: "Comma Local Data",
      stdio: "inherit",
    });
    expect(electron.child.postMessage).toHaveBeenCalledWith(
      {
        protocolVersion: LOCAL_DATA_WORKER_PROTOCOL_VERSION,
        type: LOCAL_DATA_WORKER_CONNECT_MESSAGE,
      },
      [electron.port2]
    );
    expect(electron.port1.start).toHaveBeenCalledOnce();

    const terminated = vi.fn();
    connection.onTerminated(terminated);
    const exitListener = electron.child.on.mock.calls.find(
      ([event]) => event === "exit"
    )?.[1] as ((code: number) => void) | undefined;
    exitListener?.(23);

    expect(connection.isTerminated()).toBe(true);
    expect(terminated).toHaveBeenCalledWith(
      expect.objectContaining({
        message: "Local data utility process exited with code 23.",
      })
    );

    connection.dispose();
    expect(electron.child.kill).toHaveBeenCalledOnce();
    expect(electron.port1.close).toHaveBeenCalledOnce();
  });
});
