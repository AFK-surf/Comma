import type { RangedFile } from "./PdfFilePreview";
import { wholeFileOf } from "./wholeFile";

/** Largest non-ZIP archive file read whole, and largest ZIP Central Directory read into memory. */
export const archivePreviewMaxBytes = 64 * 1024 * 1024;
/** Hard cap on gunzipped bytes read from a .tar.gz / .tgz stream to prevent gzip bombs. */
export const archiveMaxDecompressedBytes = 64 * 1024 * 1024;
/** Maximum entries kept in the preview tree. */
export const archiveMaxEntries = 2000;
/** Maximum bytes requested per ranged read (`files.readRange` caps at 10 MB). */
const archiveRangeChunk = 8 * 1024 * 1024;
/** Maximum size of ZIP EOCD + 64 KiB comment window at the end of a ZIP file. */
const zipTailWindowBytes = 65_557;

export interface ArchiveEntry {
  path: string;
  isDirectory: boolean;
  size: number;
  compressedSize?: number | undefined;
  modifiedAt?: number | undefined;
}

export interface ParsedArchive {
  format: "zip" | "tar" | "tar.gz" | "gz";
  entries: ArchiveEntry[];
  totalFiles: number;
  totalFolders: number;
  totalUncompressedBytes: number;
  totalCompressedBytes: number;
  truncated: boolean;
}

export interface ArchiveTreeNode {
  name: string;
  path: string;
  isDirectory: boolean;
  size: number;
  fileCount: number;
  /** When the file last changed; for a folder, its newest file's time. */
  modifiedAt?: number | undefined;
  children: ArchiveTreeNode[];
}

function normalizeEntryPath(raw: string): string {
  return raw
    .replaceAll("\\", "/")
    .replace(/^\/+/u, "")
    .replace(/^\.\//u, "")
    .replace(/\/+$/u, "");
}

function decodeDosDateTime(dosDate: number, dosTime: number): number | undefined {
  if (dosDate === 0 && dosTime === 0) return undefined;
  const year = ((dosDate >> 9) & 0x7f) + 1980;
  const month = ((dosDate >> 5) & 0x0f) - 1;
  const day = dosDate & 0x1f;
  const hours = (dosTime >> 11) & 0x1f;
  const minutes = (dosTime >> 5) & 0x3f;
  const seconds = (dosTime & 0x1f) * 2;
  if (month < 0 || month > 11 || day < 1 || day > 31) return undefined;
  return Date.UTC(year, month, day, hours, minutes, seconds);
}

/**
 * Records every folder an entry stands for: the folder itself, and each folder on its path. An archive need not list
 * a folder that only holds files (most ZIPs do not), so this is the count the tree shows.
 */
function addFolderPaths(folders: Set<string>, path: string, isDirectory: boolean) {
  let end = isDirectory ? path.length : path.lastIndexOf("/");
  while (end > 0) {
    const folder = path.slice(0, end);
    if (folders.has(folder)) return;
    folders.add(folder);
    end = folder.lastIndexOf("/");
  }
}

const crc32Table = (() => {
  const table = new Uint32Array(256);
  for (let i = 0; i < 256; i += 1) {
    let c = i;
    for (let k = 0; k < 8; k += 1) {
      c = (c & 1) !== 0 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    }
    table[i] = c >>> 0;
  }
  return table;
})();

function crc32(bytes: Uint8Array): number {
  let crc = 0xffffffff;
  for (let i = 0; i < bytes.length; i += 1) {
    crc = crc32Table[(crc ^ bytes[i]!) & 0xff]! ^ (crc >>> 8);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function decodeZipEntryName(
  nameBytes: Uint8Array,
  generalPurposeFlag: number,
  unicodeExtraPath: string | undefined,
  utf8: TextDecoder,
  utf8Fatal: TextDecoder
): string {
  // General Purpose Bit 11 (EFS): filename is guaranteed UTF-8.
  if ((generalPurposeFlag & 0x0800) !== 0) {
    return utf8.decode(nameBytes);
  }
  // Info-ZIP Unicode Path Extra Field (0x7075) overrides legacy code-page names.
  if (unicodeExtraPath !== undefined) {
    return unicodeExtraPath;
  }
  let allAscii = true;
  for (let i = 0; i < nameBytes.length; i += 1) {
    if (nameBytes[i]! >= 0x80) {
      allAscii = false;
      break;
    }
  }
  if (allAscii) return utf8.decode(nameBytes);
  // Some Unix tools emit UTF-8 without setting bit 11; try strict UTF-8 first,
  // then fall back to GB18030 for Windows Chinese (CP936/GBK) archives.
  try {
    return utf8Fatal.decode(nameBytes);
  } catch {
    try {
      return new TextDecoder("gb18030").decode(nameBytes);
    } catch {
      return utf8.decode(nameBytes);
    }
  }
}

/** Finds the ZIP End of Central Directory (EOCD) offset inside a tail buffer. */
function findEocdOffset(tail: Uint8Array): number {
  if (tail.length < 22) return -1;
  const view = new DataView(tail.buffer, tail.byteOffset, tail.byteLength);
  const stop = Math.max(0, tail.length - zipTailWindowBytes);
  let fallback = -1;
  for (let pos = tail.length - 22; pos >= stop; pos -= 1) {
    if (view.getUint32(pos, true) !== 0x06054b50) continue;
    const commentLen = view.getUint16(pos + 20, true);
    if (pos + 22 + commentLen === tail.length) return pos;
    if (fallback === -1) fallback = pos;
  }
  return fallback;
}

/** Parses entries from a standalone ZIP Central Directory byte buffer. */
function parseZipCentralDirectory(
  cdBytes: Uint8Array,
  entryCount: number,
  maxEntries = archiveMaxEntries
): ParsedArchive {
  const view = new DataView(cdBytes.buffer, cdBytes.byteOffset, cdBytes.byteLength);
  const utf8 = new TextDecoder("utf-8");
  const utf8Fatal = new TextDecoder("utf-8", { fatal: true });
  const entries: ArchiveEntry[] = [];
  let totalFiles = 0;
  const folders = new Set<string>();
  let totalUncompressedBytes = 0;
  let totalCompressedBytes = 0;
  let truncated = false;
  let at = 0;
  const cdEnd = cdBytes.length;

  for (let i = 0; i < entryCount && at + 46 <= cdEnd; i += 1) {
    if (view.getUint32(at, true) !== 0x02014b50) break;
    const flags = view.getUint16(at + 8, true);
    const dosTime = view.getUint16(at + 12, true);
    const dosDate = view.getUint16(at + 14, true);
    let compSize = view.getUint32(at + 20, true);
    let uncompSize = view.getUint32(at + 24, true);
    const nameLen = view.getUint16(at + 28, true);
    const extraLen = view.getUint16(at + 30, true);
    const commentLen = view.getUint16(at + 32, true);
    const nextAt = at + 46 + nameLen + extraLen + commentLen;
    if (nextAt > cdEnd) break;

    const nameBytes = cdBytes.subarray(at + 46, at + 46 + nameLen);
    let unicodeExtraPath: string | undefined;

    // Inspect extra fields for ZIP64 sizes (0x0001) and Info-ZIP Unicode Path (0x7075).
    if (extraLen >= 4) {
      let ex = at + 46 + nameLen;
      const exEnd = ex + extraLen;
      while (ex + 4 <= exEnd) {
        const headerId = view.getUint16(ex, true);
        const dataSize = view.getUint16(ex + 2, true);
        if (ex + 4 + dataSize > exEnd) break;
        if (
          headerId === 0x0001 &&
          (uncompSize === 0xffffffff || compSize === 0xffffffff)
        ) {
          let pos = ex + 4;
          if (uncompSize === 0xffffffff && pos + 8 <= ex + 4 + dataSize) {
            uncompSize = Number(view.getBigUint64(pos, true));
            pos += 8;
          }
          if (compSize === 0xffffffff && pos + 8 <= ex + 4 + dataSize) {
            compSize = Number(view.getBigUint64(pos, true));
          }
        } else if (headerId === 0x7075 && dataSize > 5 && cdBytes[ex + 4] === 1) {
          const expectedCrc = view.getUint32(ex + 5, true);
          if (expectedCrc === crc32(nameBytes)) {
            unicodeExtraPath = utf8.decode(cdBytes.subarray(ex + 9, ex + 4 + dataSize));
          }
        }
        ex += 4 + dataSize;
      }
    }

    const rawName = decodeZipEntryName(
      nameBytes,
      flags,
      unicodeExtraPath,
      utf8,
      utf8Fatal
    );
    at = nextAt;
    const isDirectory = rawName.endsWith("/");
    const cleanPath = normalizeEntryPath(rawName);
    if (!cleanPath) continue;

    addFolderPaths(folders, cleanPath, isDirectory);
    if (!isDirectory) {
      totalFiles += 1;
      totalUncompressedBytes += uncompSize;
      totalCompressedBytes += compSize;
    }

    if (entries.length < maxEntries) {
      entries.push({
        path: cleanPath,
        isDirectory,
        size: uncompSize,
        compressedSize: compSize,
        modifiedAt: decodeDosDateTime(dosDate, dosTime),
      });
    } else {
      truncated = true;
    }
  }

  return {
    format: "zip",
    entries,
    totalFiles,
    totalFolders: folders.size,
    totalUncompressedBytes,
    totalCompressedBytes,
    truncated,
  };
}

/** Reads ZIP Central Directory headers without decompressing any file payload (immune to ZIP bombs). */
export function parseZipDirectory(
  bytes: Uint8Array,
  maxEntries = archiveMaxEntries
): ParsedArchive {
  if (bytes.length < 22) throw new Error("invalid zip");
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const eocd = findEocdOffset(bytes);
  if (eocd < 0) throw new Error("missing zip central directory");

  let entryCount = view.getUint16(eocd + 10, true);
  let cdSize = view.getUint32(eocd + 12, true);
  let cdOffset = view.getUint32(eocd + 16, true);

  // Check for ZIP64 End of Central Directory locator right before EOCD.
  if (
    (entryCount === 0xffff || cdSize === 0xffffffff || cdOffset === 0xffffffff) &&
    eocd >= 20 &&
    view.getUint32(eocd - 20, true) === 0x07064b50
  ) {
    const zip64EocdOffset = Number(view.getBigUint64(eocd - 12, true));
    if (
      zip64EocdOffset >= 0 &&
      zip64EocdOffset + 56 <= eocd &&
      view.getUint32(zip64EocdOffset, true) === 0x06064b50
    ) {
      entryCount = Number(view.getBigUint64(zip64EocdOffset + 32, true));
      cdSize = Number(view.getBigUint64(zip64EocdOffset + 40, true));
      cdOffset = Number(view.getBigUint64(zip64EocdOffset + 48, true));
    }
  }

  if (cdOffset < 0 || cdSize < 0 || cdOffset + cdSize > bytes.length) {
    throw new Error("corrupt zip central directory");
  }
  if (cdSize > archivePreviewMaxBytes) throw new Error("archive too large");

  return parseZipCentralDirectory(
    bytes.subarray(cdOffset, cdOffset + cdSize),
    entryCount,
    maxEntries
  );
}

type ArchiveSource = { blob?: Blob | undefined; ranged?: RangedFile | undefined };

async function readArchiveSpan(
  source: ArchiveSource,
  offset: number,
  length: number,
  signal: AbortSignal
): Promise<Uint8Array> {
  if (length <= 0) return new Uint8Array(0);
  if (source.ranged) {
    const out = new Uint8Array(length);
    let filled = 0;
    while (filled < length) {
      const part = await source.ranged.read(
        offset + filled,
        Math.min(archiveRangeChunk, length - filled),
        signal
      );
      if (part.bytes.length === 0) break;
      const take = Math.min(part.bytes.length, length - filled);
      out.set(part.bytes.subarray(0, take), filled);
      filled += take;
    }
    return filled < length ? out.subarray(0, filled) : out;
  }
  if (!source.blob) throw new Error("no file source");
  return new Uint8Array(await source.blob.slice(offset, offset + length).arrayBuffer());
}

/**
 * Reads only the tail EOCD and Central Directory ranges of a ZIP file so large archives
 * (> 64 MB) list their contents without transferring or buffering file payloads.
 */
async function readZipDirectoryRanged(
  source: ArchiveSource,
  totalSize: number,
  signal: AbortSignal,
  maxEntries = archiveMaxEntries
): Promise<ParsedArchive> {
  if (totalSize < 22) throw new Error("invalid zip");
  const tailLen = Math.min(totalSize, zipTailWindowBytes);
  const tailOffset = totalSize - tailLen;
  const tail = await readArchiveSpan(source, tailOffset, tailLen, signal);
  if (signal.aborted) throw new DOMException("Aborted", "AbortError");
  const eocd = findEocdOffset(tail);
  if (eocd < 0) throw new Error("missing zip central directory");

  const tailView = new DataView(tail.buffer, tail.byteOffset, tail.byteLength);
  let entryCount = tailView.getUint16(eocd + 10, true);
  let cdSize = tailView.getUint32(eocd + 12, true);
  let cdOffset = tailView.getUint32(eocd + 16, true);

  const eocdAbs = tailOffset + eocd;
  if (
    (entryCount === 0xffff || cdSize === 0xffffffff || cdOffset === 0xffffffff) &&
    eocdAbs >= 20
  ) {
    const locator =
      eocd >= 20
        ? tail.subarray(eocd - 20, eocd)
        : await readArchiveSpan(source, eocdAbs - 20, 20, signal);
    if (signal.aborted) throw new DOMException("Aborted", "AbortError");
    if (locator.length === 20) {
      const locView = new DataView(locator.buffer, locator.byteOffset, 20);
      if (locView.getUint32(0, true) === 0x07064b50) {
        const zip64EocdOffset = Number(locView.getBigUint64(8, true));
        if (zip64EocdOffset >= 0 && zip64EocdOffset + 56 <= eocdAbs) {
          const z64 =
            zip64EocdOffset >= tailOffset &&
            zip64EocdOffset + 56 <= tailOffset + tail.length
              ? tail.subarray(
                  zip64EocdOffset - tailOffset,
                  zip64EocdOffset - tailOffset + 56
                )
              : await readArchiveSpan(source, zip64EocdOffset, 56, signal);
          if (signal.aborted) throw new DOMException("Aborted", "AbortError");
          if (z64.length === 56) {
            const z64View = new DataView(z64.buffer, z64.byteOffset, 56);
            if (z64View.getUint32(0, true) === 0x06064b50) {
              entryCount = Number(z64View.getBigUint64(32, true));
              cdSize = Number(z64View.getBigUint64(40, true));
              cdOffset = Number(z64View.getBigUint64(48, true));
            }
          }
        }
      }
    }
  }

  if (cdOffset < 0 || cdSize < 0 || cdOffset + cdSize > totalSize) {
    throw new Error("corrupt zip central directory");
  }
  if (cdSize > archivePreviewMaxBytes) throw new Error("archive too large");

  const cdBytes =
    cdSize === 0
      ? new Uint8Array(0)
      : cdOffset >= tailOffset && cdOffset + cdSize <= tailOffset + tail.length
        ? tail.subarray(cdOffset - tailOffset, cdOffset - tailOffset + cdSize)
        : await readArchiveSpan(source, cdOffset, cdSize, signal);
  if (signal.aborted) throw new DOMException("Aborted", "AbortError");
  if (cdBytes.length < cdSize) throw new Error("corrupt zip central directory");
  return parseZipCentralDirectory(cdBytes, entryCount, maxEntries);
}

/**
 * Inspects an archive from either a Blob or a RangedFile. ZIP files read only their tail EOCD
 * and Central Directory (working even for archives > 64 MB); TAR/GZIP archives read bounded bytes.
 */
export async function readArchiveDirectory(
  source: ArchiveSource,
  fileName: string,
  mimeType: string | undefined,
  signal: AbortSignal,
  maxEntries = archiveMaxEntries
): Promise<ParsedArchive> {
  const lower = fileName.split("/").at(-1)?.toLowerCase() ?? "";
  const media = (mimeType ?? "").split(";")[0]?.trim().toLowerCase() ?? "";
  let totalSize: number;
  let head: Uint8Array;
  if (source.ranged) {
    const first = await source.ranged.read(0, 4, signal);
    if (signal.aborted) throw new DOMException("Aborted", "AbortError");
    totalSize = first.size;
    head = first.bytes;
  } else if (source.blob) {
    totalSize = source.blob.size;
    head = new Uint8Array(await source.blob.slice(0, 4).arrayBuffer());
    if (signal.aborted) throw new DOMException("Aborted", "AbortError");
  } else {
    throw new Error("no file source");
  }

  const isZipMagic =
    head.length >= 4 &&
    head[0] === 0x50 &&
    head[1] === 0x4b &&
    (head[2] === 0x03 || head[2] === 0x05);
  if (lower.endsWith(".zip") || media === "application/zip" || isZipMagic) {
    return readZipDirectoryRanged(source, totalSize, signal, maxEntries);
  }

  const read = await wholeFileOf(source, signal, archivePreviewMaxBytes);
  if (signal.aborted) throw new DOMException("Aborted", "AbortError");
  if ("error" in read) {
    throw new Error(read.error === "too_large" ? "archive too large" : "failed");
  }
  return parseArchive(read.bytes, fileName, mimeType ?? "", signal);
}

function readCString(bytes: Uint8Array, start: number, length: number): string {
  let end = start;
  const max = Math.min(bytes.length, start + length);
  while (end < max && bytes[end] !== 0) end += 1;
  return new TextDecoder("utf-8").decode(bytes.subarray(start, end));
}

function readTarOctal(bytes: Uint8Array, start: number, length: number): number {
  const first = bytes[start];
  // GNU base-256 extension for large files.
  if (first !== undefined && (first & 0x80) !== 0) {
    let val = first & 0x7f;
    for (let i = 1; i < length; i += 1) {
      val = val * 256 + (bytes[start + i] ?? 0);
    }
    return val;
  }
  const str = readCString(bytes, start, length).trim();
  if (!str) return 0;
  const parsed = Number.parseInt(str, 8);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : 0;
}

function parsePaxPath(bytes: Uint8Array): string | undefined {
  const text = new TextDecoder("utf-8").decode(bytes);
  let pos = 0;
  while (pos < text.length) {
    const space = text.indexOf(" ", pos);
    if (space === -1) break;
    const len = Number.parseInt(text.slice(pos, space), 10);
    if (!Number.isFinite(len) || len <= 0) break;
    const record = text.slice(space + 1, pos + len).replace(/\n$/u, "");
    if (record.startsWith("path=")) return record.slice(5);
    pos += len;
  }
  return undefined;
}

/** Walks 512-byte USTAR/PAX/GNU TAR headers without copying file payloads. */
export function parseTarDirectory(
  bytes: Uint8Array,
  format: "tar" | "tar.gz" = "tar",
  compressedBytes?: number,
  maxEntries = archiveMaxEntries
): ParsedArchive {
  const entries: ArchiveEntry[] = [];
  let totalFiles = 0;
  const folders = new Set<string>();
  let totalUncompressedBytes = 0;
  let truncated = false;
  let offset = 0;
  let nextLongName: string | undefined;
  let validHeaders = 0;

  while (offset + 512 <= bytes.length) {
    // Two consecutive zero blocks mark end-of-archive.
    let allZero = true;
    for (let i = 0; i < 512; i += 1) {
      if (bytes[offset + i] !== 0) {
        allZero = false;
        break;
      }
    }
    if (allZero) break;

    const name = readCString(bytes, offset, 100);
    const size = readTarOctal(bytes, offset + 124, 12);
    const mtime = readTarOctal(bytes, offset + 136, 12);
    const typeFlag = String.fromCharCode(bytes[offset + 156] ?? 0);
    const prefix = readCString(bytes, offset + 345, 155);
    const dataStart = offset + 512;
    const paddedSize = Math.ceil(size / 512) * 512;
    if (dataStart + size > bytes.length) break;

    validHeaders += 1;

    if (typeFlag === "L") {
      // GNU LongName for next entry.
      nextLongName = readCString(bytes, dataStart, size);
      offset = dataStart + paddedSize;
      continue;
    }
    if (typeFlag === "x") {
      // POSIX PAX extended header for next entry.
      const paxPath = parsePaxPath(bytes.subarray(dataStart, dataStart + size));
      if (paxPath) nextLongName = paxPath;
      offset = dataStart + paddedSize;
      continue;
    }
    if (typeFlag === "g") {
      offset = dataStart + paddedSize;
      continue;
    }

    const fullName = nextLongName ?? (prefix ? `${prefix}/${name}` : name);
    nextLongName = undefined;
    offset = dataStart + paddedSize;

    const isDirectory = typeFlag === "5" || fullName.endsWith("/");
    const cleanPath = normalizeEntryPath(fullName);
    if (!cleanPath) continue;

    addFolderPaths(folders, cleanPath, isDirectory);
    if (!isDirectory) {
      totalFiles += 1;
      totalUncompressedBytes += size;
    }

    if (entries.length < maxEntries) {
      entries.push({
        path: cleanPath,
        isDirectory,
        size,
        modifiedAt: mtime > 0 ? mtime * 1000 : undefined,
      });
    } else {
      truncated = true;
    }
  }

  if (validHeaders === 0) throw new Error("invalid tar");

  return {
    format,
    entries,
    totalFiles,
    totalFolders: folders.size,
    totalUncompressedBytes,
    totalCompressedBytes: compressedBytes ?? bytes.length,
    truncated,
  };
}

function readGzipHeader(bytes: Uint8Array): {
  name?: string;
  mtime?: number;
  isize: number;
} {
  if (bytes.length < 18 || bytes[0] !== 0x1f || bytes[1] !== 0x8b) {
    throw new Error("invalid gzip");
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const flg = bytes[3]!;
  const mtimeSec = view.getUint32(4, true);
  let pos = 10;
  if ((flg & 0x04) !== 0) {
    if (pos + 2 > bytes.length) throw new Error("corrupt gzip");
    pos += 2 + view.getUint16(pos, true);
  }
  let name: string | undefined;
  if ((flg & 0x08) !== 0) {
    const start = pos;
    while (pos < bytes.length && bytes[pos] !== 0) pos += 1;
    name = new TextDecoder("utf-8").decode(bytes.subarray(start, pos));
  }
  const isize = view.getUint32(bytes.length - 4, true);
  return {
    ...(name ? { name } : {}),
    ...(mtimeSec > 0 ? { mtime: mtimeSec * 1000 } : {}),
    isize,
  };
}

/** Streams a GZIP payload through DecompressionStream with a strict output byte cap. */
async function gunzipBounded(
  bytes: Uint8Array,
  maxBytes: number,
  signal?: AbortSignal
): Promise<Uint8Array> {
  if (typeof DecompressionStream === "undefined") {
    throw new Error("DecompressionStream unavailable");
  }
  const stream = new Blob([bytes as Uint8Array<ArrayBuffer>])
    .stream()
    .pipeThrough(new DecompressionStream("gzip"));
  const reader = stream.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    for (;;) {
      if (signal?.aborted) throw new DOMException("Aborted", "AbortError");
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maxBytes) {
        await reader.cancel();
        throw new Error("archive too large");
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const out = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return out;
}

/** Parses `.zip`, `.tar`, `.tar.gz`, `.tgz`, or `.gz` bytes into a bounded directory listing. */
export async function parseArchive(
  bytes: Uint8Array,
  fileName: string,
  mimeType = "",
  signal?: AbortSignal
): Promise<ParsedArchive> {
  const lower = fileName.split("/").at(-1)?.toLowerCase() ?? "";
  const media = mimeType.split(";")[0]?.trim().toLowerCase() ?? "";
  const isZipMagic =
    bytes.length >= 4 &&
    bytes[0] === 0x50 &&
    bytes[1] === 0x4b &&
    (bytes[2] === 0x03 || bytes[2] === 0x05);
  const isGzipMagic = bytes.length >= 2 && bytes[0] === 0x1f && bytes[1] === 0x8b;

  if (lower.endsWith(".zip") || media === "application/zip" || isZipMagic) {
    return parseZipDirectory(bytes);
  }
  if (lower.endsWith(".tar.gz") || lower.endsWith(".tgz")) {
    const tarBytes = await gunzipBounded(bytes, archiveMaxDecompressedBytes, signal);
    return parseTarDirectory(tarBytes, "tar.gz", bytes.length);
  }
  if (
    lower.endsWith(".gz") ||
    media === "application/gzip" ||
    media === "application/x-gzip" ||
    isGzipMagic
  ) {
    const header = readGzipHeader(bytes);
    const innerName = header.name || lower.replace(/\.gz$/u, "") || "file";
    if (innerName.toLowerCase().endsWith(".tar")) {
      const tarBytes = await gunzipBounded(bytes, archiveMaxDecompressedBytes, signal);
      return parseTarDirectory(tarBytes, "tar.gz", bytes.length);
    }
    return {
      format: "gz",
      entries: [
        {
          path: normalizeEntryPath(innerName),
          isDirectory: false,
          size: header.isize,
          compressedSize: bytes.length,
          modifiedAt: header.mtime,
        },
      ],
      totalFiles: 1,
      totalFolders: 0,
      totalUncompressedBytes: header.isize,
      totalCompressedBytes: bytes.length,
      truncated: false,
    };
  }
  return parseTarDirectory(bytes, "tar");
}

function aggregateAndSortArchiveTree(nodes: ArchiveTreeNode[]): {
  size: number;
  files: number;
  modifiedAt: number | undefined;
} {
  let totalSize = 0;
  let totalFiles = 0;
  let latest: number | undefined;
  for (const node of nodes) {
    if (node.isDirectory) {
      const sub = aggregateAndSortArchiveTree(node.children);
      node.size = sub.size;
      node.fileCount = sub.files;
      node.modifiedAt = sub.modifiedAt ?? node.modifiedAt;
      totalSize += sub.size;
      totalFiles += sub.files;
    } else {
      totalSize += node.size;
      totalFiles += 1;
    }
    if (
      node.modifiedAt !== undefined &&
      (latest === undefined || node.modifiedAt > latest)
    )
      latest = node.modifiedAt;
  }
  nodes.sort(
    (a, b) =>
      Number(b.isDirectory) - Number(a.isDirectory) ||
      a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: "base" })
  );
  return { size: totalSize, files: totalFiles, modifiedAt: latest };
}

/** Builds a sorted folder-first tree with aggregated directory sizes and file counts. */
export function buildArchiveTree(entries: readonly ArchiveEntry[]): ArchiveTreeNode[] {
  const root: ArchiveTreeNode[] = [];
  const byPath = new Map<string, ArchiveTreeNode>();

  const ensureFolder = (segments: string[], upTo: number): ArchiveTreeNode => {
    const path = segments.slice(0, upTo + 1).join("/");
    const existing = byPath.get(path);
    if (existing) return existing;
    const node: ArchiveTreeNode = {
      name: segments[upTo]!,
      path,
      isDirectory: true,
      size: 0,
      fileCount: 0,
      children: [],
    };
    byPath.set(path, node);
    if (upTo === 0) {
      root.push(node);
    } else {
      ensureFolder(segments, upTo - 1).children.push(node);
    }
    return node;
  };

  for (const entry of entries) {
    const segments = entry.path.split("/").filter(Boolean);
    if (segments.length === 0) continue;
    if (entry.isDirectory) {
      const folder = ensureFolder(segments, segments.length - 1);
      folder.modifiedAt ??= entry.modifiedAt;
      continue;
    }
    const path = segments.join("/");
    if (byPath.has(path)) continue;
    const fileNode: ArchiveTreeNode = {
      name: segments.at(-1)!,
      path,
      isDirectory: false,
      size: entry.size,
      fileCount: 1,
      modifiedAt: entry.modifiedAt,
      children: [],
    };
    byPath.set(path, fileNode);
    if (segments.length === 1) {
      root.push(fileNode);
    } else {
      const parent = ensureFolder(segments, segments.length - 2);
      parent.children.push(fileNode);
    }
  }

  aggregateAndSortArchiveTree(root);
  return root;
}

/** Every folder's path in the tree, outermost first. */
export function archiveFolderPaths(
  nodes: readonly ArchiveTreeNode[],
  out: string[] = []
): string[] {
  for (const node of nodes) {
    if (!node.isDirectory) continue;
    out.push(node.path);
    archiveFolderPaths(node.children, out);
  }
  return out;
}

/** Rows a tree shows open from the start; a larger one opens only down to its first real level. */
const archiveOpenRowLimit = 200;

/**
 * The folders a freshly opened tree starts collapsed. A small archive opens fully. A larger one opens its wrapper
 * folders (a lone top folder, and a lone folder inside that, as most archives of one project have) and the level
 * under them, and keeps everything deeper closed.
 */
export function initiallyCollapsedArchiveFolders(
  tree: readonly ArchiveTreeNode[]
): Set<string> {
  let rows = 0;
  const count = (nodes: readonly ArchiveTreeNode[]) => {
    for (const node of nodes) {
      rows += 1;
      if (rows > archiveOpenRowLimit) return;
      count(node.children);
    }
  };
  count(tree);
  if (rows <= archiveOpenRowLimit) return new Set();

  let level = tree;
  while (level.length === 1 && level[0]!.isDirectory) level = level[0]!.children;
  const collapsed = new Set<string>();
  for (const node of level) {
    if (!node.isDirectory) continue;
    archiveFolderPaths([node]).forEach((path) => collapsed.add(path));
  }
  return collapsed;
}

export interface ArchiveTreeRow {
  node: ArchiveTreeNode;
  /** 0 for a top-level entry. */
  depth: number;
  /** The folder that holds it, or undefined at the top. */
  parentPath: string | undefined;
}

/** The rows the tree shows, in order: every entry whose folders are all open. */
export function visibleArchiveRows(
  nodes: readonly ArchiveTreeNode[],
  collapsed: ReadonlySet<string>,
  depth = 0,
  parentPath: string | undefined = undefined,
  out: ArchiveTreeRow[] = []
): ArchiveTreeRow[] {
  for (const node of nodes) {
    out.push({ node, depth, parentPath });
    if (node.isDirectory && !collapsed.has(node.path))
      visibleArchiveRows(node.children, collapsed, depth + 1, node.path, out);
  }
  return out;
}
