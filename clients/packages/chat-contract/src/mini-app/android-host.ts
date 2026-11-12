/// <reference lib="dom" />
import { installMiniAppHost } from "./native-host.ts";
import type { MiniAppInit } from "@comma/miniapp-sdk";

type Host = ReturnType<typeof installMiniAppHost>;

/** What the Android app sends on its port. */
type FromNative =
  | { kind: "command"; id: number; op: string; args?: Record<string, unknown> }
  | { kind: "reply"; id: number; answer?: unknown; error?: string };

/**
 * The Android host page. Android's WebView has no isolated script world, so the app hands this main frame one
 * MessagePort with `postWebMessage`, aimed at the host page's own origin. The sandboxed app frame has an opaque origin
 * and is created only after the port arrives, so it can neither receive nor replace the port.
 */
export function connect() {
  let port: MessagePort | undefined;
  let host: Host | undefined;
  let next = 1;
  const replies = new Map<
    number,
    { resolve(value: unknown): void; reject(error: Error): void }
  >();
  const send = (message: unknown) => port?.postMessage(JSON.stringify(message));

  const run = async (op: string, args: Record<string, unknown>) => {
    if (op === "install") {
      if (host) throw Error("The app host is already installed.");
      host = installMiniAppHost({
        postMessage: ({ wire }) =>
          new Promise((resolve, reject) => {
            if (replies.size >= 8) {
              reject(Error("Too many pending calls."));
              return;
            }
            const id = next++;
            replies.set(id, { resolve, reject });
            send({ kind: "invoke", id, wire });
          }),
      });
      return;
    }
    if (!host) throw Error("The app host is not installed.");
    switch (op) {
      case "start":
        return host.start(args.init as MiniAppInit);
      case "begin":
        return host.begin(String(args.path), String(args.mime));
      case "append":
        return host.append(String(args.encoded));
      case "end":
        return host.end();
      case "finish":
        return host.finish();
      case "theme":
        return host.theme(String(args.theme), args.tokens as Record<string, string>);
      case "stop":
        for (const reply of replies.values()) reply.reject(Error("The app closed."));
        replies.clear();
        return host.stop();
      default:
        throw Error("Unknown host command.");
    }
  };

  const receive = (event: MessageEvent) => {
    let message: FromNative;
    try {
      message = JSON.parse(String(event.data)) as FromNative;
    } catch {
      return;
    }
    if (!Number.isSafeInteger(message.id)) return;
    if (message.kind === "reply") {
      const reply = replies.get(message.id);
      replies.delete(message.id);
      if (message.error === undefined) reply?.resolve(message.answer);
      else reply?.reject(Error(message.error));
      return;
    }
    if (message.kind !== "command") return;
    const { id, op } = message;
    Promise.resolve()
      .then(() => run(op, message.args ?? {}))
      .then(
        () => send({ kind: "done", id }),
        (error: unknown) =>
          send({
            kind: "done",
            id,
            error: error instanceof Error ? error.message : String(error),
          })
      );
  };

  const accept = (event: MessageEvent) => {
    // A message the app posts to the page has no source window. Only the first port is taken.
    if (
      port ||
      event.source !== null ||
      event.data !== "comma-native" ||
      event.ports.length !== 1
    )
      return;
    window.removeEventListener("message", accept);
    port = event.ports[0]!;
    port.addEventListener("message", receive);
    port.start();
    send({ kind: "connected" });
  };
  window.addEventListener("message", accept);
}
