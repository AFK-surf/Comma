export interface AsyncCallMessagePort {
  close(): void;
  off(event: "close", listener: () => void): unknown;
  off(event: "message", listener: (event: { data: unknown }) => void): unknown;
  on(event: "close", listener: () => void): unknown;
  on(event: "message", listener: (event: { data: unknown }) => void): unknown;
  postMessage(message: unknown): void;
  start(): void;
}

export interface LocalDataRpcChannel {
  close(): void;
  on(listener: (data: unknown) => void): () => void;
  onClose(listener: (error: LocalDataRpcClosedError) => void): () => void;
  send(data: unknown): void;
}

export class LocalDataRpcClosedError extends Error {
  constructor(message = "Local data RPC channel closed.") {
    super(message);
    this.name = "LocalDataRpcClosedError";
  }
}

export function createAsyncCallMessagePortChannel(
  port: AsyncCallMessagePort
): LocalDataRpcChannel {
  const closeListeners = new Set<(error: LocalDataRpcClosedError) => void>();
  const messageListeners = new Set<(data: unknown) => void>();
  let closed = false;

  const detach = () => {
    port.off("message", handleMessage);
    port.off("close", handleClose);
  };
  const close = (closePort: boolean) => {
    if (closed) return;
    closed = true;
    detach();
    if (closePort) port.close();
    const error = new LocalDataRpcClosedError();
    for (const listener of closeListeners) listener(error);
    closeListeners.clear();
    messageListeners.clear();
  };
  const handleClose = () => close(false);
  const handleMessage = (event: { data: unknown }) => {
    for (const listener of messageListeners) listener(event.data);
  };

  port.on("message", handleMessage);
  port.on("close", handleClose);
  port.start();

  return {
    close() {
      close(true);
    },
    on(listener) {
      if (closed) return () => {};
      messageListeners.add(listener);
      return () => {
        messageListeners.delete(listener);
      };
    },
    onClose(listener) {
      if (closed) {
        listener(new LocalDataRpcClosedError());
        return () => {};
      }
      closeListeners.add(listener);
      return () => {
        closeListeners.delete(listener);
      };
    },
    send(data) {
      if (closed) throw new LocalDataRpcClosedError();
      port.postMessage(data);
    },
  };
}
