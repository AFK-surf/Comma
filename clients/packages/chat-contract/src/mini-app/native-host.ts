/* eslint-disable unicorn/require-post-message-target-origin -- WebKit and MessagePort calls have no targetOrigin. */
/// <reference lib="dom" />
import {
  miniAppFrameSandbox,
  miniAppRuntimeCsp,
  miniAppRuntimeDocument,
} from "./runtime.ts";
import type { MiniAppInit } from "@comma/miniapp-sdk";

const fromBytes = (_key: string, value: unknown) => {
  if (!value || typeof value !== "object") return value;
  const bytes = (value as { $bytes?: unknown }).$bytes;
  return typeof bytes === "string" && Object.keys(value).length === 1
    ? Uint8Array.from(atob(bytes), (c) => c.charCodeAt(0))
    : value;
};
const toBytes = (_key: string, value: unknown) => {
  const bytes =
    value instanceof ArrayBuffer
      ? new Uint8Array(value)
      : value instanceof Uint8Array
        ? value
        : undefined;
  if (!bytes) return value;
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return { $bytes: btoa(binary) };
};

/** How the trusted host page reaches the native app. Each invoke is answered once, or rejected. */
export interface MiniAppNativeBridge {
  postMessage(value: { kind: "invoke"; wire: string }): Promise<unknown>;
}

/**
 * The phone apps' trusted host page: it starts the shared runtime in a sandboxed frame and relays the frame's calls
 * to [native]. It runs only in the main frame. App code never receives this bridge.
 */
export function installMiniAppHost(native: MiniAppNativeBridge) {
  const policy = miniAppRuntimeCsp.replace(/^sandbox [^;]+; /, "");
  const meta = document.createElement("meta");
  meta.httpEquiv = "Content-Security-Policy";
  meta.content = policy.replace("frame-src 'none'", "frame-src blob:");
  document.head.append(meta);
  const frame = document.createElement("iframe");
  frame.sandbox.value = miniAppFrameSandbox;
  frame.allow =
    "camera 'none'; microphone 'none'; geolocation 'none'; clipboard-read 'none'; clipboard-write 'none'; payment 'none'";
  frame.title = "Comma app";
  frame.style.cssText = "position:fixed;inset:0;width:100%;height:100%;border:0";
  const html = miniAppRuntimeDocument()
    .replace("initial-scale=1", "initial-scale=1, viewport-fit=cover")
    .replace(
      "<head>",
      `<head><style>html{height:100%;box-sizing:border-box}body{min-height:100%;margin:0}</style><meta http-equiv="Content-Security-Policy" content="${policy.replaceAll('"', "&quot;")}">`
    );
  const url = URL.createObjectURL(new Blob([html], { type: "text/html" }));
  frame.src = url;
  let port: MessagePort | undefined;
  let closed = false;
  let total = 0;
  let current: { path: string; mime: string; chunks: Uint8Array[] } | undefined;
  const files: { path: string; mime: string; data: ArrayBuffer }[] = [];
  const pending = new Set<number>();
  let ready: (() => void) | undefined;
  let started: (() => void) | undefined;
  let failed: ((error: Error) => void) | undefined;
  const settled = new Promise<void>((resolve, reject) => {
    started = resolve;
    failed = reject;
  });
  // A rejection can arrive before the native app calls finish().
  void settled.catch(() => {});
  let timer: ReturnType<typeof setTimeout>;
  const loaded = new Promise<void>((resolve, reject) => {
    ready = () => {
      clearTimeout(timer);
      resolve();
    };
    timer = setTimeout(() => reject(Error("The app runtime did not start.")), 10_000);
  });
  void loaded.catch(() => {});
  const hello = () =>
    frame.contentWindow?.postMessage({ type: "comma-app:hello" }, "*");
  const onReady = (event: MessageEvent) => {
    if (event.source === frame.contentWindow && event.data?.type === "comma-app:ready")
      ready?.();
  };
  window.addEventListener("message", onReady);
  frame.addEventListener("load", hello, { once: true });
  document.body.append(frame);

  return {
    async start(init: MiniAppInit) {
      await loaded;
      if (closed) throw Error("The app closed.");
      window.removeEventListener("message", onReady);
      const channel = new MessageChannel();
      port = channel.port1;
      port.addEventListener("message", (event: MessageEvent) => {
        const message = event.data;
        if (message?.type === "started") {
          started?.();
          return;
        }
        if (message?.type === "error") {
          failed?.(Error(String(message.reason)));
          return;
        }
        if (
          message?.type !== "call" ||
          !Number.isSafeInteger(message.id) ||
          typeof message.op !== "string" ||
          closed
        )
          return;
        if (pending.size >= 8 || pending.has(message.id)) {
          port?.postMessage({
            type: "result",
            id: message.id,
            ok: false,
            error: { code: "rate_limited", message: "Too many pending calls." },
          });
          return;
        }
        pending.add(message.id);
        // The frame cannot select a session, Core method, grant or confirmation.
        let wire: string;
        try {
          wire = JSON.stringify({ op: message.op, args: message.args }, toBytes);
          if (wire.length > 2 * 1024 * 1024) throw Error("The call is too large.");
        } catch {
          pending.delete(message.id);
          port?.postMessage({
            type: "result",
            id: message.id,
            ok: false,
            error: { code: "invalid", message: "The call cannot be sent." },
          });
          return;
        }
        void native
          .postMessage({ kind: "invoke", wire })
          .then((reply) => {
            const answer = JSON.parse(JSON.stringify(reply), fromBytes);
            if (
              message.op === "backend.fetch" &&
              answer.value?.body instanceof Uint8Array
            )
              answer.value.body = answer.value.body.buffer;
            if (message.op === "files.pick" && Array.isArray(answer.value))
              for (const file of answer.value)
                if (file.data instanceof Uint8Array) file.data = file.data.buffer;
            if (!closed)
              port?.postMessage({ type: "result", id: message.id, ...answer });
          })
          .catch(() => {
            if (!closed)
              port?.postMessage({
                type: "result",
                id: message.id,
                ok: false,
                error: { code: "unavailable", message: "The app call failed." },
              });
          })
          .finally(() => pending.delete(message.id));
      });
      port.start();
      frame.contentWindow?.postMessage({ type: "comma-app:init", init }, "*", [
        channel.port2,
      ]);
    },
    begin(path: string, mime: string) {
      if (closed || current || files.length >= 2000)
        throw Error("Invalid bundle transfer.");
      current = { path, mime, chunks: [] };
    },
    append(encoded: string) {
      if (!current || encoded.length > 96 * 1024) throw Error("Invalid bundle chunk.");
      const bytes = Uint8Array.from(atob(encoded), (c) => c.charCodeAt(0));
      total += bytes.length;
      if (total > 25 * 1024 * 1024) throw Error("The app is larger than 25 MiB.");
      current.chunks.push(bytes);
    },
    end() {
      if (!current) throw Error("No file transfer.");
      const bytes = new Uint8Array(current.chunks.reduce((n, c) => n + c.length, 0));
      let offset = 0;
      for (const chunk of current.chunks) {
        bytes.set(chunk, offset);
        offset += chunk.length;
      }
      files.push({ path: current.path, mime: current.mime, data: bytes.buffer });
      current = undefined;
    },
    async finish() {
      if (closed || current || !port) throw Error("The app is not open.");
      port.postMessage(
        { type: "files", files },
        files.map((file) => file.data)
      );
      files.length = 0;
      await settled;
    },
    theme(theme: string, tokens: Record<string, string>) {
      if (!closed) port?.postMessage({ type: "theme", theme, tokens });
    },
    stop() {
      closed = true;
      ready?.();
      failed?.(Error("The app closed."));
      port?.postMessage({ type: "stop", reason: "closed" });
      port?.close();
      window.removeEventListener("message", onReady);
      frame.remove();
      URL.revokeObjectURL(url);
      files.length = 0;
      current = undefined;
    },
  };
}
