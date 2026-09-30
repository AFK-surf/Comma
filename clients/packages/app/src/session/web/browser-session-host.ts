import type {
  WebSessionCoordinationStorage,
  WebSessionHostPorts,
} from "./coordination-ports";

export function createBrowserSessionHostPorts(
  storage: WebSessionCoordinationStorage
): WebSessionHostPorts {
  const locks =
    "locks" in navigator && navigator.locks
      ? {
          request<T>(name: string, signal: AbortSignal, work: () => Promise<T>) {
            return navigator.locks.request(
              name,
              { mode: "exclusive", signal },
              async (lock) => {
                if (!lock) {
                  throw new Error("The Web Session coordination lock was denied.");
                }
                return work();
              }
            );
          },
        }
      : undefined;

  return {
    broadcast: {
      open(name) {
        const channel = new BroadcastChannel(name);
        return {
          close() {
            channel.close();
          },
          publish(hint) {
            // oxlint-disable-next-line unicorn/require-post-message-target-origin -- BroadcastChannel.postMessage has no targetOrigin parameter.
            channel.postMessage(hint);
          },
          subscribe(listener) {
            const onMessage = (event: MessageEvent<unknown>) => {
              listener(event.data);
            };
            channel.addEventListener("message", onMessage);
            return () => {
              channel.removeEventListener("message", onMessage);
            };
          },
        };
      },
    },
    documentOrigin: location.origin,
    fetch: globalThis.fetch.bind(globalThis),
    locks,
    now: () => Date.now(),
    randomId: secureRandomId,
    schedule(callback, delayMs) {
      return window.setTimeout(callback, delayMs);
    },
    storage,
    unschedule(handle) {
      window.clearTimeout(handle);
    },
  };
}

function secureRandomId() {
  if (globalThis.crypto.randomUUID) {
    return globalThis.crypto.randomUUID();
  }

  const bytes = globalThis.crypto.getRandomValues(new Uint8Array(16));
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}
