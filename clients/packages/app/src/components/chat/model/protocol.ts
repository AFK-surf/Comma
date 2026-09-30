const COMMA_CONTEXT_MARKER = "[[comma-context]]";
const COMMA_PROTOCOL_MARKER = "[[comma-protocol]]";
// A private fence is fail-closed: if transport truncation drops its closing
// marker, everything from the opener to EOF remains non-display content.
const COMMA_FENCE_PATTERN = /```comma:[\s\S]*?(?:```|$)/g;
const ATTACHED_FILE_LINE_PATTERN =
  /^- (.+?) \(workspace file: (\/[A-Za-z0-9._~!$&'()*+,;=:@%/-]+)\)$/;

export const MAX_ATTACHMENT_BYTES = 10_000_000;
export const MAX_ATTACHMENTS_PER_MESSAGE = 8;
export const ATTACHMENT_IMAGE_EXTENSIONS = [".png", ".jpg", ".jpeg", ".gif", ".webp"];
/**
 * Camera formats the agent runtime cannot read as image input. A host that
 * can decode them re-encodes to JPEG before upload, so they only pass
 * attachment validation where such a transcoder is installed.
 */
export const ATTACHMENT_TRANSCODED_IMAGE_EXTENSIONS = [".heic", ".heif"];
export const ATTACHMENT_TEXT_EXTENSIONS = [
  ".md",
  ".markdown",
  ".txt",
  ".csv",
  ".tsv",
  ".json",
  ".jsonl",
  ".xml",
  ".yaml",
  ".yml",
  ".toml",
  ".html",
  ".htm",
  ".log",
];
/** Documents the runtime stores verbatim; the panel renders them as file cards. */
export const ATTACHMENT_DOCUMENT_EXTENSIONS = [
  ".pdf",
  ".doc",
  ".docx",
  ".xls",
  ".xlsx",
  ".ppt",
  ".pptx",
  ".svg",
];
export const ATTACHMENT_MEDIA_EXTENSIONS = [
  ".mp3",
  ".wav",
  ".m4a",
  ".aac",
  ".flac",
  ".ogg",
  ".mp4",
  ".mov",
  ".m4v",
  ".webm",
];
export const ATTACHMENT_EXTENSIONS = [
  ...ATTACHMENT_IMAGE_EXTENSIONS,
  ...ATTACHMENT_TEXT_EXTENSIONS,
  ...ATTACHMENT_DOCUMENT_EXTENSIONS,
  ...ATTACHMENT_MEDIA_EXTENSIONS,
];
export const ATTACHMENT_ACCEPT = ATTACHMENT_EXTENSIONS.join(",");
export const ATTACHED_FILES_HEADER = "Attached files in your workspace:";
export const ATTACHED_ONLY_TEXT = "I've attached some files:";
export const QUOTED_TEXT_HEADER = "Quoted from this conversation:";

export type AttachedWorkspaceFile = {
  name: string;
  path: string;
};

export function stripCommaProtocolMarkers(text: string) {
  return stripCommaProtocolMarkersPreservingWhitespace(text).trimEnd().trim();
}

export function stripCommaProtocolMarkersPreservingWhitespace(text: string) {
  const beforeProtocol = text.split(COMMA_PROTOCOL_MARKER)[0] ?? "";
  return beforeProtocol.replace(COMMA_FENCE_PATTERN, "");
}

export function isCommaContextMessage(text: string) {
  return text.trimStart().startsWith(COMMA_CONTEXT_MARKER);
}

export function composeMessageWithAttachments(
  text: string,
  attachments: AttachedWorkspaceFile[]
) {
  if (attachments.length === 0) {
    return text;
  }

  const body = text.trim() || ATTACHED_ONLY_TEXT;
  const lines = attachments.map(
    (attachment) => `- ${attachment.name} (workspace file: ${attachment.path})`
  );
  return `${body}\n\n${ATTACHED_FILES_HEADER}\n${lines.join("\n")}`;
}

/**
 * Quoted passages lead the message: the reader (model or human) sees what is
 * being referred to before the sentence that refers to it. Attachments keep
 * appending at the end, so the two blocks never contend for the same edge.
 *
 * Every quoted line is `>`-prefixed, so a quote that itself contains a quoted
 * line survives the round trip through `parseQuotedTextBlock`.
 */
export function composeMessageWithQuotes(text: string, quotes: readonly string[]) {
  if (quotes.length === 0) {
    return text;
  }

  const blocks = quotes.map(
    (quote) =>
      `${QUOTED_TEXT_HEADER}\n${quote
        .split("\n")
        .map((line) => (line === "" ? ">" : `> ${line}`))
        .join("\n")}`
  );
  const body = text.trim();
  const quoted = blocks.join("\n\n");
  return body ? `${quoted}\n\n${body}` : quoted;
}

export function parseQuotedTextBlock(text: string): {
  body: string;
  quotes: string[];
} {
  const quotes: string[] = [];
  let rest = text;

  while (rest.startsWith(`${QUOTED_TEXT_HEADER}\n`)) {
    const lines = rest.slice(QUOTED_TEXT_HEADER.length + 1).split("\n");
    const quoteLines: string[] = [];
    let index = 0;

    while (index < lines.length) {
      const line = lines[index]!;
      if (line === ">") {
        quoteLines.push("");
      } else if (line.startsWith("> ")) {
        quoteLines.push(line.slice(2));
      } else {
        break;
      }
      index += 1;
    }

    // A header with no quoted line is ordinary prose that happens to match.
    if (quoteLines.length === 0) break;

    quotes.push(quoteLines.join("\n"));
    if (lines[index] === "") index += 1;
    rest = lines.slice(index).join("\n");
  }

  return quotes.length > 0 ? { body: rest, quotes } : { body: text, quotes: [] };
}

export function parseAttachmentsBlock(text: string): {
  attachments: AttachedWorkspaceFile[];
  body: string;
} {
  const headerIndex = text.lastIndexOf(`\n\n${ATTACHED_FILES_HEADER}\n`);
  if (headerIndex === -1) {
    return { attachments: [], body: text };
  }

  const body = text.slice(0, headerIndex);
  const rawLines = text
    .slice(headerIndex + 2 + ATTACHED_FILES_HEADER.length + 1)
    .trimEnd()
    .split(/\n/);
  const attachments: AttachedWorkspaceFile[] = [];

  for (const line of rawLines) {
    const match = line.match(ATTACHED_FILE_LINE_PATTERN);
    if (!match) {
      return { attachments: [], body: text };
    }

    const [, name, path] = match;
    if (!name || !path) {
      return { attachments: [], body: text };
    }

    attachments.push({ name, path });
  }

  if (attachments.length === 0) {
    return { attachments: [], body: text };
  }

  return {
    attachments,
    body: body.trim() === ATTACHED_ONLY_TEXT ? "" : body,
  };
}

export function attachmentExtension(name: string) {
  const index = name.lastIndexOf(".");
  if (index === -1) {
    return "";
  }

  return name.slice(index).toLowerCase();
}

export function isImageAttachment(name: string) {
  return ATTACHMENT_IMAGE_EXTENSIONS.includes(attachmentExtension(name));
}

export function isTranscodedImageAttachment(name: string) {
  return ATTACHMENT_TRANSCODED_IMAGE_EXTENSIONS.includes(attachmentExtension(name));
}

export function isGroupImagePreviewPath(value: string) {
  return /^\/uploads\/[A-Za-z0-9_-]{22}-[A-Za-z0-9._-]+\.(?:png|jpe?g|gif|webp)$/i.test(
    value
  );
}

export function isAllowedAttachment(name: string) {
  return ATTACHMENT_EXTENSIONS.includes(attachmentExtension(name));
}
