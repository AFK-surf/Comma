import type { SideChatPresentation } from "@comma/chat-contract";
import {
  getNativeBridge,
  sideChatTestWindowSourceFrameSchema,
  type NativeStateBridge,
  type ProductInboxItem,
  type ProductInboxListResult,
  type SideChatShortcutBinding,
  type SideChatTestWindowSourceFrame,
} from "@comma/native-bridge";

export type {
  NativeStateBridge,
  ProductInboxItem,
  ProductInboxListResult,
  SideChatTestWindowSourceFrame,
};

/**
 * Narrow renderer adapter for the Side Chat native-capability leaves. Product
 * chat components stay bridge-agnostic; this module is the single place that
 * knows how the Electron host exposes presentation/window orchestration.
 */
export function isElectronSideChatRuntime() {
  return getNativeBridge().platform === "electron";
}

export function closeNativeSideChat() {
  return getNativeBridge().sideChat.close();
}

export function closeNativeSideChatTestWindow() {
  return getNativeBridge().sideChat.closeTestWindow();
}

export function getNativeSideChatPresentation() {
  return getNativeBridge().sideChat.presentation.get();
}

export function openNativeSideChatSettings() {
  return getNativeBridge().sideChat.openSettings();
}

export function openNativeMainWindow() {
  return getNativeBridge().windows.focus({ windowId: "win_main" });
}

export function openNativeSideChatTestWindow(
  sourceFrame: SideChatTestWindowSourceFrame,
  target?: { conversationId: string; groupId: string; workspaceId: string }
) {
  return getNativeBridge().sideChat.openTestWindow({
    sourceFrame,
    ...(target ? { target } : {}),
  });
}

export function parseNativeSideChatTestWindowSourceFrame(value: unknown) {
  return sideChatTestWindowSourceFrameSchema.parse(value);
}

export function setNativeSideChatContentSize(size: {
  height: number;
  visualHeight: number;
  width: number;
}) {
  return getNativeBridge().sideChat.setContentSize(size);
}

export function updateNativeSideChatShortcut(shortcut: SideChatShortcutBinding) {
  return getNativeBridge().sideChat.updateShortcut(shortcut);
}

export function subscribeNativeSideChatPresentation(
  listener: (presentation: SideChatPresentation) => void
) {
  return getNativeBridge().sideChat.presentation.subscribe(listener);
}
