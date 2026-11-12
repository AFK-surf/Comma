/* eslint-disable unicorn/require-post-message-target-origin -- WebKit's message handler has no target origin. */
import { installDynamicUiHost } from "./native-host.ts";

/** Fixed host in WKContentWorld; generated UI only receives a bound MessagePort in an opaque-origin frame. */
export function install() {
  const native = (
    globalThis as unknown as {
      webkit: { messageHandlers: { dynamicUI: { postMessage(value: unknown): void } } };
    }
  ).webkit.messageHandlers.dynamicUI;
  return installDynamicUiHost((wire) => native.postMessage(wire));
}
