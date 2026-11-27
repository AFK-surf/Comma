// A file's picture for a preview card: the first page of a PDF, drawn by pdf.js, and the picture an office file
// carries of its own first page (PowerPoint, Word, Excel, Keynote, Pages, Numbers and OpenDocument files are ZIP
// archives, and the app that saved one may have put a thumbnail in it). A file with neither has no picture.
//
// The ZIP reading here is by hand. The archive is read in spans (`RangedFile`): its directory at the end, then the
// one entry wanted, so a deck of any size costs a few small reads. The ZIP libraries read the whole archive into
// memory first, which a card in a chat must not do for a 200 MB deck. Only what a thumbnail needs is read: stored
// and deflated entries, no ZIP64, no encryption.
//
// Bounds: a ZIP's directory is read up to 1 MiB and a thumbnail up to 4 MiB; a PDF's first page is drawn once at up
// to 960 px wide.
import { openPdfDocument, type RangedFile } from "./PdfFilePreview";

const tailBytes = 65_557;
const maxDirectoryBytes = 1024 * 1024;
const maxThumbnailBytes = 4 * 1024 * 1024;
const localHeaderBytes = 30;

/** Where the apps that save office files put the picture of the first page, and its type. */
const thumbnails: [name: RegExp, type: string][] = [
  [/^docprops\/thumbnail\.jpe?g$/u, "image/jpeg"],
  [/^docprops\/thumbnail\.png$/u, "image/png"],
  [/^quicklook\/thumbnail\.jpe?g$/u, "image/jpeg"],
  [/^quicklook\/thumbnail\.png$/u, "image/png"],
  [/^preview\.jpe?g$/u, "image/jpeg"],
  [/^thumbnails\/thumbnail\.png$/u, "image/png"],
];

const view = (bytes: Uint8Array) =>
  new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);

/** The picture an office file (a ZIP archive) carries of its first page, if it carries one this page can show. */
export async function officeThumbnail(
  file: RangedFile,
  signal?: AbortSignal
): Promise<Blob | undefined> {
  const head = await file.read(0, 4, signal);
  const { size } = head;
  if (head.bytes.length < 4 || view(head.bytes).getUint32(0, true) !== 0x04034b50)
    return undefined;

  // The end record is in the file's last bytes, after the directory it points to.
  const tailStart = Math.max(0, size - tailBytes);
  const tail = (await file.read(tailStart, size - tailStart, signal)).bytes;
  const tailView = view(tail);
  let end = tail.length - 22;
  while (end >= 0 && tailView.getUint32(end, true) !== 0x06054b50) end -= 1;
  if (end < 0) return undefined;
  const directorySize = tailView.getUint32(end + 12, true);
  const directoryStart = tailView.getUint32(end + 16, true);
  // A ZIP64 archive keeps both elsewhere.
  if (
    directorySize > maxDirectoryBytes ||
    directoryStart === 0xffffffff ||
    directoryStart + directorySize > size
  )
    return undefined;
  const directory =
    directoryStart >= tailStart
      ? tail.subarray(
          directoryStart - tailStart,
          directoryStart - tailStart + directorySize
        )
      : (await file.read(directoryStart, directorySize, signal)).bytes;

  const entries = view(directory);
  const names = new TextDecoder();
  for (let at = 0; at + 46 <= directory.length; ) {
    if (entries.getUint32(at, true) !== 0x02014b50) return undefined;
    const nameLength = entries.getUint16(at + 28, true);
    const next =
      at +
      46 +
      nameLength +
      entries.getUint16(at + 30, true) +
      entries.getUint16(at + 32, true);
    const name = names.decode(directory.subarray(at + 46, at + 46 + nameLength));
    const type = thumbnails.find(([pattern]) => pattern.test(name.toLowerCase()))?.[1];
    if (type) {
      const encrypted = (entries.getUint16(at + 8, true) & 1) === 1;
      const method = entries.getUint16(at + 10, true);
      const packed = entries.getUint32(at + 20, true);
      const offset = entries.getUint32(at + 42, true);
      if (encrypted || (method !== 0 && method !== 8) || packed > maxThumbnailBytes)
        return undefined;
      // The entry's own header says where its bytes start: its name and extra field may differ from the directory's.
      const header = (await file.read(offset, localHeaderBytes, signal)).bytes;
      if (header.length < localHeaderBytes) return undefined;
      const start =
        offset +
        localHeaderBytes +
        view(header).getUint16(26, true) +
        view(header).getUint16(28, true);
      const data = (await file.read(start, packed, signal)).bytes;
      if (data.length < packed) return undefined;
      const stored = new Blob([data as Uint8Array<ArrayBuffer>], { type });
      return method === 0
        ? stored
        : new Blob(
            [
              await new Response(
                stored.stream().pipeThrough(new DecompressionStream("deflate-raw"))
              ).arrayBuffer(),
            ],
            { type }
          );
    }
    at = next;
  }
  return undefined;
}

const pdfPictureWidth = 960;

/** The first page of a PDF as a picture, read in spans: only what that page needs. */
export async function pdfFirstPage(
  file: RangedFile,
  ownerDocument: Document
): Promise<Blob | undefined> {
  let failed = false;
  const opened = openPdfDocument(
    { ranged: file },
    {
      onReadFailed: () => {
        failed = true;
      },
      shareWorker: true,
    }
  );
  try {
    const page = await (await opened.document).getPage(1);
    const natural = page.getViewport({ scale: 1 });
    const viewport = page.getViewport({ scale: pdfPictureWidth / natural.width });
    const canvas = ownerDocument.createElement("canvas");
    canvas.width = Math.round(viewport.width);
    canvas.height = Math.round(viewport.height);
    await page.render({ canvas, viewport }).promise;
    if (failed) return undefined;
    return await new Promise<Blob | undefined>((resolve) =>
      canvas.toBlob((blob) => resolve(blob ?? undefined), "image/png")
    );
  } finally {
    opened.close();
  }
}
