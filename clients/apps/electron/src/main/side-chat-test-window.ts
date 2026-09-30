import type {
  SideChatTestWindowSourceFrame,
  SurfaceBounds,
} from "@comma/native-bridge";

export const sideChatTestWindowRoute = "/side-chat/test-window";

export function localizeSideChatTestWindowSourceFrame(
  sourceFrame: SideChatTestWindowSourceFrame,
  displayBounds: SurfaceBounds
): SideChatTestWindowSourceFrame {
  const width = Math.min(displayBounds.width, Math.max(1, sourceFrame.width));
  const height = Math.min(displayBounds.height, Math.max(1, sourceFrame.height));

  return {
    x: clamp(sourceFrame.x - displayBounds.x, 0, displayBounds.width - width),
    y: clamp(sourceFrame.y - displayBounds.y, 0, displayBounds.height - height),
    width,
    height,
  };
}

export function sideChatTestWindowRouteWithSource(
  sourceFrame: SideChatTestWindowSourceFrame,
  target?: { conversationId: string; groupId: string; workspaceId: string }
) {
  const search = new URLSearchParams({
    sourceHeight: formatCoordinate(sourceFrame.height),
    sourceWidth: formatCoordinate(sourceFrame.width),
    sourceX: formatCoordinate(sourceFrame.x),
    sourceY: formatCoordinate(sourceFrame.y),
    ...(target
      ? {
          conversationId: target.conversationId,
          groupId: target.groupId,
          workspaceId: target.workspaceId,
        }
      : {}),
  });
  return `${sideChatTestWindowRoute}?${search.toString()}`;
}

function formatCoordinate(value: number) {
  return String(Math.round(value * 1_000) / 1_000);
}

function clamp(value: number, minimum: number, maximum: number) {
  return Math.min(maximum, Math.max(minimum, value));
}

/** TaskWindowEntrance.tla: native show precedes document loading/first paint. */
export function presentSideChatTaskHost(
  window: {
    getNativeWindowHandle(): Buffer;
    show(): void;
    showInactive(): void;
    focus(): void;
  },
  native: { disableWindowAnimations(handle: Buffer): void },
  inactive: boolean
) {
  native.disableWindowAnimations(window.getNativeWindowHandle());
  if (inactive) window.showInactive();
  else {
    window.show();
    window.focus();
  }
}
