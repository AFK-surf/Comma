const mimeTypeLabels: Record<string, string> = {
  "application/epub+zip": "EPUB",
  "application/json": "JSON",
  "application/msword": "DOC",
  "application/pdf": "PDF",
  "application/rtf": "RTF",
  "application/vnd.ms-excel": "XLS",
  "application/vnd.ms-powerpoint": "PPT",
  "application/vnd.openxmlformats-officedocument.presentationml.presentation": "PPTX",
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "XLSX",
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "DOCX",
  "application/zip": "ZIP",
  "audio/mpeg": "MP3",
  "image/jpeg": "JPG",
  "image/svg+xml": "SVG",
  "text/csv": "CSV",
  "text/plain": "TXT",
  "video/mp4": "MP4",
};

export const mimeTypeLabel = (mimeType: string | undefined) => {
  const normalized = mimeType?.split(";")[0]?.trim().toLowerCase();
  if (!normalized) return undefined;
  const known = mimeTypeLabels[normalized];
  if (known) return known;
  const subtype = normalized.split("/")[1];
  return subtype
    ? subtype.replace(/^x-/, "").split(/[.+-]/).at(-1)!.toUpperCase()
    : undefined;
};

export const fileNameExtension = (fileName: string) => {
  const cleanFileName = fileName.split(/[?#]/)[0] ?? fileName;
  const extension = cleanFileName.includes(".")
    ? cleanFileName.split(".").at(-1)?.trim()
    : undefined;
  return extension ? extension.toUpperCase() : undefined;
};

/** The candidate icon types, most specific first: the extension names the file, the MIME type backs it up. */
export const fileTypeCandidates = ({
  fileName,
  mimeType,
}: {
  fileName: string;
  mimeType?: string | undefined;
}) =>
  [fileNameExtension(fileName), mimeTypeLabel(mimeType)]
    .filter((type): type is string => type !== undefined)
    .map((type) => type.toLowerCase());
