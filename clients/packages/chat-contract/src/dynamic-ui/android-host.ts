/// <reference lib="dom" />
import { installDynamicUiHost, type DynamicUiHost } from "./native-host.ts";

/** What the Android app sends on its port, as JSON text. */
type FromNative = { kind: "start"; init?: unknown } | { kind: "stop" };

/** The part of a MessagePort the page uses. */
interface Port {
  postMessage(message: string): void;
  addEventListener(type: "message", listener: (event: { data: unknown }) => void): void;
  start(): void;
  close(): void;
}

/** The part of the host page's window the page listens on. */
interface PageWindow {
  addEventListener(type: "message", listener: (event: MessageEvent) => void): void;
  removeEventListener(type: "message", listener: (event: MessageEvent) => void): void;
}

/**
 * The Android host page. Android's WebView has no isolated script world, so the app hands this main frame one
 * MessagePort with `postWebMessage`, aimed at the host page's own origin. A message the app posts has no source
 * window; one from a frame has. The sandboxed runtime frame has an opaque origin and is created only after the port
 * arrived and the app said start, so it can neither receive nor replace the port. The page sends the app only the
 * runtime messages the shared host lets through.
 */
export function connect(
  page: PageWindow = window,
  install: (native: (wire: string) => void) => DynamicUiHost = installDynamicUiHost
) {
  let port: Port | undefined;
  let host: DynamicUiHost | undefined;
  let stopped = false;
  const send = (message: unknown) => port?.postMessage(JSON.stringify(message));

  const start = (init: unknown) => {
    if (host || stopped) return;
    if (!init || typeof init !== "object" || Array.isArray(init)) {
      send({ kind: "failed", reason: "Interactive content did not start." });
      return;
    }
    host = install((wire) => {
      if (!stopped) send({ kind: "event", wire });
    });
    host.start(init as Record<string, unknown>).then(
      () => {
        if (!stopped) send({ kind: "started" });
      },
      (error: unknown) => {
        if (!stopped)
          send({
            kind: "failed",
            reason: error instanceof Error ? error.message : String(error),
          });
      }
    );
  };

  const stop = () => {
    if (stopped) return;
    stopped = true;
    host?.stop();
    port?.close();
  };

  const receive = (event: { data: unknown }) => {
    if (stopped || typeof event.data !== "string") return;
    let message: FromNative;
    try {
      message = JSON.parse(event.data) as FromNative;
    } catch {
      return;
    }
    if (message?.kind === "start") start(message.init);
    else if (message?.kind === "stop") stop();
  };

  const accept = (event: MessageEvent) => {
    // Only the first port, and only from the app: a frame's message has a source window.
    if (
      port ||
      event.source !== null ||
      event.data !== "comma-native" ||
      event.ports?.length !== 1
    )
      return;
    page.removeEventListener("message", accept);
    port = event.ports[0] as unknown as Port;
    port.addEventListener("message", receive);
    port.start();
    send({ kind: "connected" });
  };
  page.addEventListener("message", accept);
}
