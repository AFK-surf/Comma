import type { ChatAttachment } from "../../../model/conversationChannel";
import { isImageAttachment } from "../../../model/protocol";

export function textAttachmentsToPills(
  attachments: { name: string; path: string }[]
): ChatAttachment[] {
  return attachments.map((attachment) => ({
    blockType: isImageAttachment(attachment.name) ? "image" : "file",
    fileName: attachment.name,
    mimeType: undefined,
    size: undefined,
    title: undefined,
    workspacePath: attachment.path,
  }));
}

export function mergeMessageAttachments(
  canonical: ChatAttachment[],
  parsed: ChatAttachment[]
): ChatAttachment[] {
  if (parsed.length === 0) return canonical;
  if (canonical.length === 0) return parsed;

  const claimedCanonical = new Set<number>();
  let mergedCanonical: ChatAttachment[] | undefined;
  const additions = parsed.filter((candidate) => {
    const list = mergedCanonical ?? canonical;
    const canonicalIndex = list.findIndex(
      (attachment, index) =>
        !claimedCanonical.has(index) &&
        canonicalAttachmentMatchesParsed(attachment, candidate)
    );
    if (canonicalIndex < 0) return true;
    claimedCanonical.add(canonicalIndex);
    const existing = list[canonicalIndex]!;
    if (!existing.workspacePath && candidate.workspacePath) {
      if (!mergedCanonical) mergedCanonical = [...canonical];
      mergedCanonical[canonicalIndex] = {
        ...existing,
        workspacePath: candidate.workspacePath,
      };
    }
    return false;
  });
  if (!mergedCanonical && additions.length === 0) return canonical;
  return [...(mergedCanonical ?? canonical), ...additions];
}

function canonicalAttachmentMatchesParsed(
  canonical: ChatAttachment,
  parsed: ChatAttachment
) {
  // A local-file ref identifies a different attachment domain from a workspace
  // upload marker, even when the user selected two files with the same name.
  if (canonical.localFileRef) return false;
  if (canonical.workspacePath && parsed.workspacePath) {
    return canonical.workspacePath === parsed.workspacePath;
  }
  return (
    canonical.blockType === parsed.blockType &&
    canonicalAttachmentName(canonical) === canonicalAttachmentName(parsed)
  );
}

function canonicalAttachmentName(attachment: ChatAttachment) {
  return attachment.fileName ?? attachment.title;
}
