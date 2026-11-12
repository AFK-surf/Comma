/* eslint-disable unicorn/require-post-message-target-origin -- MessagePort and the opaque-origin frame have no target origin. */
import { cardIconDefaults } from "./cardIconDefaults.ts";
import { dynamicUiCsp, dynamicUiDocument } from "./runtime.ts";

/** The runtime messages a phone app may act on; the frame's other messages stay in the page. */
const NATIVE_TYPES = new Set([
  "request",
  "open-link",
  "save",
  "card-state",
  "error",
  "ready",
]);
/** The largest message, as UTF-8 JSON, that reaches the app. */
export const DYNAMIC_UI_WIRE_MAX_BYTES = 40_000;

/**
 * What of one runtime message goes to the app: its JSON text, or nothing for a type the app does not take or a
 * message over [DYNAMIC_UI_WIRE_MAX_BYTES].
 */
export function nativeWire(message: unknown): string | undefined {
  if (!message || typeof message !== "object") return undefined;
  const type = (message as { type?: unknown }).type;
  if (typeof type !== "string" || !NATIVE_TYPES.has(type)) return undefined;
  const wire = JSON.stringify(message);
  return new TextEncoder().encode(wire).length <= DYNAMIC_UI_WIRE_MAX_BYTES
    ? wire
    : undefined;
}

/**
 * The phone host page's frame: the shared runtime document in a sandboxed frame with an opaque origin. Generated UI
 * only receives a MessagePort bound to that frame; [native] gets the runtime messages [nativeWire] lets through.
 */
export function installDynamicUiHost(native: (wire: string) => void) {
  const frame = document.createElement("iframe");
  frame.sandbox.value = "allow-scripts";
  frame.allow =
    "camera 'none'; microphone 'none'; geolocation 'none'; clipboard-read 'none'; clipboard-write 'none'";
  frame.style.cssText = "border:0;width:100%;height:100%;position:absolute;inset:0";
  frame.title = "Interactive content";
  const doc = dynamicUiDocument().replace(
    "<head>",
    `<head><meta http-equiv="Content-Security-Policy" content="${dynamicUiCsp.replaceAll('"', "&quot;")}">`
  );
  const url = URL.createObjectURL(new Blob([doc], { type: "text/html" }));
  frame.src = url;
  let port: MessagePort | undefined;
  let stopped = false;
  let resolveReady: () => void;
  let rejectReady: (error: Error) => void;
  const ready = new Promise<void>((resolve, reject) => {
    resolveReady = resolve;
    rejectReady = reject;
  });
  void ready.catch(() => {});
  const timer = setTimeout(
    () => rejectReady(Error("Interactive content did not start.")),
    10_000
  );
  const listener = (event: MessageEvent) => {
    if (event.source === frame.contentWindow && event.data?.type === "comma-ui:ready") {
      clearTimeout(timer);
      resolveReady();
    }
  };
  window.addEventListener("message", listener);
  frame.addEventListener("load", () =>
    frame.contentWindow?.postMessage({ type: "comma-ui:hello" }, "*")
  );
  document.body.append(frame);
  return {
    async start(init: Record<string, unknown>) {
      await ready;
      if (stopped) return;
      window.removeEventListener("message", listener);
      const channel = new MessageChannel();
      port = channel.port1;
      port.addEventListener("message", (event: MessageEvent) => {
        const message = event.data;
        if (stopped || !message || typeof message !== "object") return;
        if (message.type === "height" && Number.isFinite(message.value)) {
          const height = Math.min(12000, Math.max(60, message.value));
          frame.style.height = `${height}px`;
          document.body.style.height = `${height}px`;
        }
        // The app keeps no logo catalog: every brand a card asks for settles
        // with none, so its tile shows the name's initial.
        if (message.type === "brand-icons" && Array.isArray(message.names))
          port?.postMessage({
            type: "brand-icons",
            icons: Object.fromEntries(
              message.names
                .filter((name: unknown) => typeof name === "string")
                .slice(0, 32)
                .map((name: string) => [name, ""])
            ),
          });
        const wire = nativeWire(message);
        if (wire !== undefined) native(wire);
      });
      port.start();
      // The app has no icon registry either: the templates and <comma-icon>
      // draw the glyphs this page carries, under any the app does pass.
      const passed = init.icons && typeof init.icons === "object" ? init.icons : {};
      frame.contentWindow?.postMessage(
        { ...init, icons: { ...cardIconDefaults, ...passed }, type: "comma-ui:init" },
        "*",
        [channel.port2]
      );
    },
    stop() {
      stopped = true;
      clearTimeout(timer);
      window.removeEventListener("message", listener);
      port?.postMessage({ type: "stop" });
      port?.close();
      frame.remove();
      URL.revokeObjectURL(url);
    },
  };
}

export type DynamicUiHost = ReturnType<typeof installDynamicUiHost>;
