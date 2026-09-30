import { useCallback, useMemo, useState } from "react";
import { inlineMediaTypeOf } from "../../../../runtime-files/inlineMedia";
import type { ChatAttachment } from "../../model/conversationChannel";
import type { ThreadFileSource } from "../threadContexts";

export function useInlineVideos(
  attachments: ChatAttachment[],
  inlineMediaSection: boolean,
  sourceContext: ThreadFileSource | undefined
) {
  // Videos that settled without a playable stream, for the life of the message.
  const [failedVideoPositions, setFailedVideoPositions] = useState<ReadonlySet<number>>(
    () => new Set()
  );
  const inlineVideos = useMemo(
    () =>
      attachments.flatMap((attachment, position) => {
        if (
          !inlineMediaSection ||
          !sourceContext ||
          attachment.blockType !== "file" ||
          attachment.attachmentIndex === undefined ||
          failedVideoPositions.has(position)
        ) {
          return [];
        }
        const mediaType = inlineMediaTypeOf(attachment);
        return mediaType === "video/mp4" || mediaType === "video/webm"
          ? [{ mediaType, position }]
          : [];
      }),
    [attachments, failedVideoPositions, inlineMediaSection, sourceContext]
  );
  const handleVideoUnavailable = useCallback((position: number) => {
    setFailedVideoPositions((current) =>
      current.has(position) ? current : new Set(current).add(position)
    );
  }, []);
  return { handleVideoUnavailable, inlineVideos };
}
