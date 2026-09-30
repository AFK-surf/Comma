/**
 * Which attachments a message may paint in place instead of as a file card.
 *
 * The lists are closed on purpose. An entry must decode in every renderer Comma
 * ships (Electron's Chromium and current browsers) and must be inert bytes: a
 * format that can carry script or fetch external resources (SVG, HTML, PDF)
 * stays a file card and opens through the preview panel's isolated surfaces.
 */
export type InlineMediaKind = "image" | "video" | "file";

export type InlineMediaType =
  | "image/png"
  | "image/jpeg"
  | "image/gif"
  | "image/webp"
  | "video/mp4"
  | "video/webm";

export type InlineMediaSubject = {
  fileName?: string | undefined;
  mimeType?: string | undefined;
  title?: string | undefined;
  workspacePath?: string | undefined;
};

const INLINE_MEDIA_TYPE_BY_EXTENSION: Readonly<Record<string, InlineMediaType>> = {
  png: "image/png",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  gif: "image/gif",
  webp: "image/webp",
  mp4: "video/mp4",
  m4v: "video/mp4",
  webm: "video/webm",
};

// Declared types that mean the same bytes as a canonical entry above.
const INLINE_MEDIA_TYPE_ALIASES: Readonly<Record<string, InlineMediaType>> = {
  "image/jpg": "image/jpeg",
  "video/x-m4v": "video/mp4",
};

// A sender that does not know the type says so with one of these; the file
// name then decides. Any other declared type is a claim and is held to it.
const UNDECLARED_MEDIA_TYPES = new Set(["", "application/octet-stream"]);

export const INLINE_IMAGE_EXTENSIONS = extensionsOf("image");
export const INLINE_VIDEO_EXTENSIONS = extensionsOf("video");

function extensionsOf(kind: "image" | "video") {
  return Object.entries(INLINE_MEDIA_TYPE_BY_EXTENSION).flatMap(
    ([extension, mediaType]) => (mediaType.startsWith(`${kind}/`) ? [extension] : [])
  );
}

function inlineMediaName(subject: InlineMediaSubject) {
  const name =
    subject.fileName ?? subject.title ?? subject.workspacePath?.split("/").at(-1) ?? "";
  // A locator-shaped name keeps its type in the path, not the query.
  return name.split(/[?#]/)[0]!.trim();
}

function extensionMediaType(name: string): InlineMediaType | undefined {
  const index = name.lastIndexOf(".");
  if (index <= 0) return undefined;
  const extension = name.slice(index + 1).toLowerCase();
  return Object.hasOwn(INLINE_MEDIA_TYPE_BY_EXTENSION, extension)
    ? INLINE_MEDIA_TYPE_BY_EXTENSION[extension]
    : undefined;
}

function hasExtension(name: string) {
  return name.lastIndexOf(".") > 0;
}

function declaredMediaType(mimeType: string | undefined) {
  return mimeType?.split(";")[0]?.trim().toLowerCase() ?? "";
}

/**
 * The media type to decode the attachment as, or `undefined` for a file card.
 * A declared type and a file extension must agree when both are present, so a
 * mislabeled attachment fails closed instead of reaching a decoder.
 */
export function inlineMediaTypeOf(
  subject: InlineMediaSubject
): InlineMediaType | undefined {
  const name = inlineMediaName(subject);
  const byExtension = extensionMediaType(name);
  const declared = declaredMediaType(subject.mimeType);
  if (UNDECLARED_MEDIA_TYPES.has(declared)) return byExtension;
  const byDeclaration = Object.hasOwn(INLINE_MEDIA_TYPE_ALIASES, declared)
    ? INLINE_MEDIA_TYPE_ALIASES[declared]
    : Object.values(INLINE_MEDIA_TYPE_BY_EXTENSION).find((type) => type === declared);
  if (!byDeclaration) return undefined;
  if (!hasExtension(name)) return byDeclaration;
  return byExtension === byDeclaration ? byDeclaration : undefined;
}

export function inlineMediaKindOf(subject: InlineMediaSubject): InlineMediaKind {
  const mediaType = inlineMediaTypeOf(subject);
  if (!mediaType) return "file";
  return mediaType.startsWith("image/") ? "image" : "video";
}
