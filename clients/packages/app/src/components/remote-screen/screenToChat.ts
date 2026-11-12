import type { AttachmentUploadInput } from "@comma/core/chat";
import { useCommaLocale } from "@comma/i18n/react";
import { uiClock } from "@comma/ui/clock";
import { useNavigate } from "@tanstack/react-router";
import { useCallback } from "react";
import { fitImageAttachment } from "../chat/channel/fitImageAttachment";
import { useOptionalChatRegistry } from "../chat/ChatProvider";
import { useStageDraftSelection } from "../chat/composer/draftSelections";
import { resolveWorkspaceChat } from "../chat/useWorkspaceChat";
import {
  useOptionalChatSidebarActions,
  type ChatSidebarHost,
} from "../chat-sidebar/ChatSidebarContext";

/**
 * The frame a screen's `<video>` shows now, on a canvas at the size it was decoded (both of a screen's ways end in a
 * `<video>`: the mesh's decoded frames in a track). Undefined while it shows none.
 */
export function screenFrameCanvas(
  video: HTMLVideoElement | null | undefined
): HTMLCanvasElement | undefined {
  if (!video || !(video.videoWidth > 0 && video.videoHeight > 0)) return undefined;
  const canvas = video.ownerDocument.createElement("canvas");
  canvas.width = video.videoWidth;
  canvas.height = video.videoHeight;
  const context = canvas.getContext("2d");
  if (!context) return undefined;
  context.drawImage(video, 0, 0);
  return canvas;
}

/** A frame's canvas as a PNG. Undefined where it cannot be encoded. */
export function screenFramePng(canvas: HTMLCanvasElement): Promise<Blob | undefined> {
  return new Promise((resolve) =>
    canvas.toBlob((blob) => resolve(blob ?? undefined), "image/png")
  );
}

/** A selection of a screen to ask a chat about: which screen, its picture, and what the person wrote about it. */
export type ScreenToChat = {
  workspace: string;
  /** The computer's device id. */
  device: string;
  /** `display`, `android:<serial>` or `simulator:<udid>`. */
  screen: string;
  name?: string | undefined;
  /**
   * The frame, or the area of it the person selected, as it is being encoded: the chat it goes to is the one the
   * selection was made beside, whatever shows by then.
   */
  picture: Promise<Blob | undefined>;
  /** A small picture of it, for its tile in the chat's composer. */
  thumbnail?: string | undefined;
  /** What the person wrote about it. */
  note: string;
  /** Files that go with the picture (the app's recent logs), being read: none when the read fails. */
  files?: Promise<AttachmentUploadInput[]> | undefined;
};

/** The screen showed no frame to send. */
export class NoScreenFrame extends Error {
  constructor() {
    super("The screen shows no picture yet.");
    this.name = "NoScreenFrame";
  }
}

/** A sidebar host that is a conversation, not one of the shared ones Drive, Apps and the browser hang off. */
const isConversation = (host: ChatSidebarHost | undefined): host is ChatSidebarHost =>
  host !== undefined && host.groupId !== "__global__";

/** The chat's composer holds as many selections as one message takes. */
export class SelectionsFull extends Error {
  constructor() {
    super("The message takes no more selections.");
    this.name = "SelectionsFull";
  }
}

const PICTURE_TYPES = ["image/png", "image/jpeg", "image/webp"] as const;
const bytesOf = async (data: Blob) => new Uint8Array(await data.arrayBuffer());

/**
 * Puts a selection of a screen, with what the person wrote about it, into the composer of the chat the screen shows
 * beside (the side panel's conversation), or of the workspace's chat where it shows beside none, which it then
 * opens. It waits there as an attachment until the person sends the message. Undefined where there is no chat to
 * take it.
 */
export function useScreenToChat():
  | ((screen: ScreenToChat) => Promise<void>)
  | undefined {
  const registry = useOptionalChatRegistry();
  const sidebar = useOptionalChatSidebarActions();
  const stage = useStageDraftSelection();
  const locale = useCommaLocale();
  const navigate = useNavigate();
  const send = useCallback(
    async ({ workspace, picture, thumbnail, note, files, ...screen }: ScreenToChat) => {
      if (!registry || !stage) return;
      // Where it goes is fixed as it is asked, before anything is awaited: a chat opened while the frame is encoded
      // does not get it.
      const host = sidebar?.getActiveHost();
      const beside = isConversation(host);
      const home = beside ? undefined : registry.getHomeConversationTarget();
      const at = uiClock.now();
      // (a read of the logs that fails leaves none: taken up at once, while the picture is still being encoded)
      const logs = files?.catch((): AttachmentUploadInput[] => []);
      const attempt = registry.beginAttempt();
      try {
        await attempt.run(async (signal) => {
          const frame = await picture;
          if (!frame) throw new NoScreenFrame();
          const fitted = await fitImageAttachment({
            data: frame,
            name: "screen.png",
            size: frame.size,
          });
          const type =
            PICTURE_TYPES.find((one) => one === fitted.data.type) ?? "image/png";
          const attached = await Promise.all(
            ((await logs) ?? []).map(async (file) => ({
              bytes: await bytesOf(file.data),
              name: file.name,
              size: file.size,
            }))
          );
          let target = beside ? host : home;
          if (!target) {
            const resolution = await resolveWorkspaceChat({
              core: registry.core,
              locale,
              session: registry.productLease,
              signal,
              workspaceId: workspace,
            });
            if (resolution.status !== "ready") throw new Error("Chat is unavailable.");
            target = {
              conversationId: resolution.conversation.id,
              groupId: resolution.groupId,
              workspaceId: resolution.workspaceId,
            };
          }
          const staged = stage(target.conversationId, {
            note,
            picture: { bytes: await bytesOf(fitted.data), type },
            ...(thumbnail ? { thumbnail } : {}),
            about: {
              kind: "screen",
              device: screen.device,
              screen: screen.screen,
              ...(screen.name ? { name: screen.name } : {}),
              at,
              ...(attached.length > 0 ? { files: attached } : {}),
            },
          });
          if (!staged) throw new SelectionsFull();
          if (!beside) await navigate({ to: "/" });
        });
      } finally {
        attempt.release();
      }
    },
    [locale, navigate, registry, sidebar, stage]
  );
  return registry && stage ? send : undefined;
}
