import { getNativeBridge } from "@comma/native-bridge";
import { useMemo, useState } from "react";
import { openNativePlatformExternalUrl } from "../../nativePlatformActions";
import { ChatConsumerBoundary } from "../chat/ChatProvider";
import { useConversation } from "../chat/conversation/useConversation";
import { useHasTrafficLights, WindowButtons } from "../WindowBar";
import type { ConversationFileSource } from "../../runtime-files/fileSources";
import { FilePreviewLoading } from "../file-preview/FilePreviewLoading";
import { documentWindowVersion, type DocumentWindowTarget } from "./documentWindow";
import { documentVersionsIn, FilePreviewPanel } from "./FilePreviewPanel";
import { sentPictures } from "./sentDocuments";

/**
 * A document as the whole of its own window ("Open in window"): the page, its versions and what changed between
 * them, without Comma's rail, window bar or chat. The strip over it is the window's title bar: the window is dragged
 * by it, macOS paints the traffic lights into its start and Windows draws its buttons at its end. The reader edits
 * the page here as in the chat's panel: the edits are saved on the device, and the chat's next message carries them.
 * Asking Comma for a change, and putting a picture in, stay with the chat's own panel, where the composer is.
 */
export function DocumentWindowRoute({ target }: { target: DocumentWindowTarget }) {
  return (
    <ChatConsumerBoundary>
      <DocumentWindow target={target} />
    </ChatConsumerBoundary>
  );
}

function DocumentWindow({ target }: { target: DocumentWindowTarget }) {
  const bridge = getNativeBridge();
  const hasWindowButtons = bridge.platform === "electron" && bridge.os === "windows";
  const hasTrafficLights = useHasTrafficLights();
  const conversation = useConversation(
    target.workspaceId,
    target.groupId,
    target.conversationId
  );
  const messages = conversation.state.messages;
  const versions = useMemo(
    () => documentVersionsIn(messages, target),
    [messages, target]
  );
  // The version shown: the document's newest, or one the reader chose from the document's name, until another
  // version arrives (`documentWindowVersion`).
  const [chosen, setChosen] = useState<{
    version: ConversationFileSource;
    among: number;
  }>();
  // The pictures the document names are files the conversation's people sent with it.
  const pictures = useMemo(() => sentPictures(messages), [messages]);
  const sources = useMemo(() => (versions ?? []).map((one) => one.source), [versions]);
  const source = documentWindowVersion(sources, chosen);
  return (
    <main
      className="flex h-screen min-h-0 w-full min-w-0 flex-col bg-main-panel-bg text-primary"
      data-os={bridge.os}
      data-platform={bridge.platform}
      data-testid="document-window-route"
    >
      <div className="comma-window-titlebar-region flex h-8 shrink-0 items-center justify-end">
        {hasTrafficLights ? (
          <div aria-hidden="true" className="mr-auto h-8 w-13 shrink-0" />
        ) : null}
        {hasWindowButtons ? <WindowButtons /> : null}
      </div>
      {source ? (
        <FilePreviewPanel
          onOpenBrowser={(url) => void openNativePlatformExternalUrl(url)}
          onSelectVersion={(version) => setChosen({ version, among: sources.length })}
          alone
          editConversationId={target.conversationId}
          panelId="document-window-panel"
          pictures={pictures}
          source={source}
          versions={versions}
        />
      ) : (
        // The conversation's messages are on their way: the document is among them.
        <FilePreviewLoading />
      )}
    </main>
  );
}
