import { AsyncCall } from "async-call-rpc";
import {
  createAsyncCallMessagePortChannel,
  type AsyncCallMessagePort,
} from "../shared/async-call-message-port";
import {
  LOCAL_DATA_WORKER_CONNECT_MESSAGE,
  LOCAL_DATA_WORKER_PROTOCOL_VERSION,
  assertLocalDataJsonValue,
  assertLocalDataWriteRequest,
  isLocalDataWorkerGeneration,
  type LocalDataOpenInput,
  type LocalDataWorkerApi,
  type LocalDataWorkerConnectMessage,
  type LocalDataWriteRequest,
} from "../shared/local-data";
import { LocalDataService } from "./local-data-service";

export class LocalDataWorkerService implements LocalDataWorkerApi {
  readonly #onClosed: () => void;
  #closed = false;
  #localData: LocalDataService | undefined;
  #workerGeneration: number | undefined;

  constructor(onClosed: () => void = () => {}) {
    this.#onClosed = onClosed;
  }

  open({ databasePath, workerGeneration }: LocalDataOpenInput) {
    if (this.#closed) {
      throw new Error("Local data worker is closed.");
    }
    if (this.#localData) {
      throw new Error("Local data worker is already open.");
    }
    if (!isLocalDataWorkerGeneration(workerGeneration)) {
      throw new Error("Local data workerGeneration must be a positive safe integer.");
    }

    this.#localData = LocalDataService.open({ databasePath });
    this.#workerGeneration = workerGeneration;
    return {
      schemaVersion: this.#localData.schemaVersion(),
      workerGeneration,
    };
  }

  applyProductInboxSync(request: LocalDataWriteRequest) {
    assertLocalDataWriteRequest(request);
    const workerGeneration = this.#requireWorkerGeneration();
    if (request.workerGeneration !== workerGeneration) {
      throw new Error("Local data write targets a stale workerGeneration.");
    }

    this.#requireLocalData().applyProductInboxSync(request.input);
    return {
      operationId: request.operationId,
      session: structuredClone(request.input.session),
      workerGeneration,
    };
  }

  close() {
    if (this.#closed) return;
    this.#closed = true;
    this.#localData?.close();
    this.#localData = undefined;
    this.#workerGeneration = undefined;
    this.#onClosed();
  }

  listProductInboxItems(
    input: Parameters<LocalDataWorkerApi["listProductInboxItems"]>[0]
  ) {
    return this.#requireLocalData().listProductInboxItems(input);
  }

  listProductWorkspaces(
    input: Parameters<LocalDataWorkerApi["listProductWorkspaces"]>[0]
  ) {
    return this.#requireLocalData()
      .listProductWorkspaces(input)
      .map((workspace) => ({
        ...workspace,
        raw: jsonValue(workspace.raw),
      }));
  }

  referencedBlobIds() {
    return this.#requireLocalData().referencedBlobIds();
  }

  schemaVersion() {
    return this.#requireLocalData().schemaVersion();
  }

  #requireLocalData() {
    if (!this.#localData) {
      throw new Error("Local data worker is not open.");
    }
    return this.#localData;
  }

  #requireWorkerGeneration() {
    if (this.#workerGeneration === undefined) {
      throw new Error("Local data worker is not open.");
    }
    return this.#workerGeneration;
  }
}

export interface LocalDataUtilityParentPort {
  once(
    event: "message",
    listener: (event: { data: unknown; ports: AsyncCallMessagePort[] }) => void
  ): unknown;
}

export function startLocalDataUtilityWorker({
  exit = (code: number) => process.exit(code),
  parentPort = process.parentPort as LocalDataUtilityParentPort | undefined,
  scheduleExit = (callback: () => void) => setImmediate(callback),
}: {
  exit?: ((code: number) => void) | undefined;
  parentPort?: LocalDataUtilityParentPort | undefined;
  scheduleExit?: ((callback: () => void) => unknown) | undefined;
} = {}): void {
  if (!parentPort) {
    throw new Error("Local data worker requires an Electron utility parent port.");
  }

  parentPort.once("message", (event) => {
    if (!isLocalDataWorkerConnectMessage(event.data) || event.ports.length !== 1) {
      throw new Error("Local data worker received an invalid connect handshake.");
    }

    let exitScheduled = false;
    const scheduleWorkerExit = () => {
      if (exitScheduled) return;
      exitScheduled = true;
      scheduleExit(() => exit(0));
    };
    const service = new LocalDataWorkerService(scheduleWorkerExit);
    const channel = createAsyncCallMessagePortChannel(event.ports[0]!);
    const forceController = new AbortController();
    channel.onClose((error) => {
      forceController.abort(error);
      service.close();
    });

    AsyncCall<Record<string, never>>(service, {
      channel,
      forceSignal: forceController.signal,
      log: false,
      name: "local-data-utility",
      strict: true,
      thenable: false,
    });
  });
}

export function isLocalDataWorkerConnectMessage(
  value: unknown
): value is LocalDataWorkerConnectMessage {
  if (!value || typeof value !== "object") return false;

  const message = value as Partial<LocalDataWorkerConnectMessage>;
  return (
    message.type === LOCAL_DATA_WORKER_CONNECT_MESSAGE &&
    message.protocolVersion === LOCAL_DATA_WORKER_PROTOCOL_VERSION
  );
}

function jsonValue(value: unknown) {
  assertLocalDataJsonValue(value);
  return value;
}
