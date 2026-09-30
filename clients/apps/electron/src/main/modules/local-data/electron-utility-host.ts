import { MessageChannelMain, utilityProcess } from "electron";
import { AsyncCall } from "async-call-rpc";
import {
  LOCAL_DATA_WORKER_CONNECT_MESSAGE,
  LOCAL_DATA_WORKER_PROTOCOL_VERSION,
  type LocalDataWorkerApi,
} from "../../../shared/local-data";
import { createAsyncCallMessagePortChannel } from "../../../shared/async-call-message-port";
import {
  LocalDataUtilityRepository,
  type LocalDataUtilityRepositoryOptions,
  type LocalDataWorkerConnection,
  type LocalDataWorkerHost,
} from "./repository";
import { resolveLocalDataUtilityModulePath } from "./worker-path";

export function createElectronLocalDataWorkerHost({
  modulePath = resolveLocalDataUtilityModulePath(),
}: {
  modulePath?: string | undefined;
} = {}): LocalDataWorkerHost {
  return {
    connect() {
      const child = utilityProcess.fork(modulePath, [], {
        serviceName: "Comma Local Data",
        stdio: "inherit",
      });
      const messageChannel = new MessageChannelMain();
      const rpcChannel = createAsyncCallMessagePortChannel(messageChannel.port1);
      const forceController = new AbortController();
      const terminatedListeners = new Set<(error: Error) => void>();
      let disposed = false;
      let removeChannelCloseListener = noop;
      let terminated = false;

      const remote = AsyncCall<LocalDataWorkerApi>(
        {},
        {
          channel: rpcChannel,
          forceSignal: forceController.signal,
          log: false,
          name: "local-data-main",
          strict: true,
          thenable: false,
        }
      );

      const cleanup = () => {
        child.off("exit", handleExit);
        removeChannelCloseListener();
      };
      const markTerminated = (error: Error) => {
        if (terminated) return;
        terminated = true;
        cleanup();
        forceController.abort(error);
        rpcChannel.close();
        for (const listener of terminatedListeners) {
          listener(error);
        }
        terminatedListeners.clear();
      };
      const handleExit = (code: number) => {
        markTerminated(
          new Error(`Local data utility process exited with code ${code}.`)
        );
      };
      removeChannelCloseListener = rpcChannel.onClose((error) => {
        markTerminated(error);
      });

      child.on("exit", handleExit);
      try {
        child.postMessage(
          {
            protocolVersion: LOCAL_DATA_WORKER_PROTOCOL_VERSION,
            type: LOCAL_DATA_WORKER_CONNECT_MESSAGE,
          },
          [messageChannel.port2]
        );
      } catch (error) {
        markTerminated(toError(error));
        child.kill();
        throw error;
      }

      return {
        remote,
        dispose() {
          if (disposed) return;
          disposed = true;
          cleanup();
          terminated = true;
          forceController.abort(new Error("Local data utility connection disposed."));
          rpcChannel.close();
          terminatedListeners.clear();
          child.kill();
        },
        isTerminated() {
          return terminated;
        },
        onTerminated(listener) {
          if (terminated) {
            listener(new Error("Local data utility connection terminated."));
            return () => {};
          }
          terminatedListeners.add(listener);
          return () => {
            terminatedListeners.delete(listener);
          };
        },
      } satisfies LocalDataWorkerConnection;
    },
  };
}

export async function openElectronLocalDataRepository({
  databasePath,
  modulePath,
  ...options
}: Omit<LocalDataUtilityRepositoryOptions, "databasePath" | "host"> & {
  databasePath: string;
  modulePath?: string | undefined;
}) {
  return LocalDataUtilityRepository.open({
    ...options,
    databasePath,
    host: createElectronLocalDataWorkerHost({ modulePath }),
  });
}

function noop() {}

function toError(error: unknown): Error {
  return error instanceof Error ? error : new Error(String(error));
}
