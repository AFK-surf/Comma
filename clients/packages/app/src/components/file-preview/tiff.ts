/** Largest TIFF read whole for browser canvas decoding. */
export const tiffPreviewMaxBytes = 32 * 1024 * 1024;
/** Maximum decoded pixel budget (same bound as PDF page canvases). */
const maxPixels = 16_777_216;

export interface DecodedTiff {
  width: number;
  height: number;
  rgba: Uint8ClampedArray;
}

const typeSizes: Record<number, number> = {
  1: 1,
  2: 1,
  3: 2,
  4: 4,
  5: 8,
  6: 1,
  7: 1,
  8: 2,
  9: 4,
  10: 8,
  11: 4,
  12: 8,
};

function readTagValues(
  view: DataView,
  littleEndian: boolean,
  type: number,
  count: number,
  valueOffsetPos: number
): number[] {
  const unit = typeSizes[type];
  if (!unit) return [];
  const totalBytes = unit * count;
  const start =
    totalBytes <= 4 ? valueOffsetPos : view.getUint32(valueOffsetPos, littleEndian);
  if (start + totalBytes > view.byteLength) return [];
  const values: number[] = [];
  for (let i = 0; i < count; i += 1) {
    const at = start + i * unit;
    if (type === 1 || type === 7) values.push(view.getUint8(at));
    else if (type === 3) values.push(view.getUint16(at, littleEndian));
    else if (type === 4) values.push(view.getUint32(at, littleEndian));
    else if (type === 6) values.push(view.getInt8(at));
    else if (type === 8) values.push(view.getInt16(at, littleEndian));
    else if (type === 9) values.push(view.getInt32(at, littleEndian));
  }
  return values;
}

function decodePackBits(src: Uint8Array, expected: number): Uint8Array {
  const out = new Uint8Array(expected);
  let i = 0;
  let o = 0;
  while (i < src.length && o < expected) {
    const header = (src[i]! << 24) >> 24;
    i += 1;
    if (header >= 0) {
      const count = header + 1;
      for (let k = 0; k < count && i < src.length && o < expected; k += 1) {
        out[o++] = src[i++]!;
      }
    } else if (header !== -128) {
      const count = 1 - header;
      const val = src[i++] ?? 0;
      for (let k = 0; k < count && o < expected; k += 1) {
        out[o++] = val;
      }
    }
  }
  return out;
}

function decodeTiffLzw(src: Uint8Array, expected: number): Uint8Array {
  const out = new Uint8Array(expected);
  let outPos = 0;
  let bitPos = 0;
  const totalBits = src.length * 8;
  const clearCode = 256;
  const eoiCode = 257;

  let codeSize = 9;
  let nextCode = 258;
  const table: Array<Uint8Array | undefined> = Array.from({ length: 4096 });
  const reset = () => {
    for (let i = 0; i < 256; i += 1) table[i] = Uint8Array.of(i);
    codeSize = 9;
    nextCode = 258;
  };
  reset();

  const readCode = (): number => {
    if (bitPos + codeSize > totalBits) return eoiCode;
    let code = 0;
    for (let b = 0; b < codeSize; b += 1) {
      const idx = bitPos + b;
      const bit = (src[idx >> 3]! >> (7 - (idx & 7))) & 1;
      code = (code << 1) | bit;
    }
    bitPos += codeSize;
    return code;
  };

  let prev: Uint8Array | undefined;
  while (outPos < expected) {
    const code = readCode();
    if (code === eoiCode) break;
    if (code === clearCode) {
      reset();
      prev = undefined;
      continue;
    }
    let entry: Uint8Array;
    if (code < nextCode && table[code]) {
      entry = table[code]!;
    } else if (code === nextCode && prev) {
      entry = new Uint8Array(prev.length + 1);
      entry.set(prev);
      entry[prev.length] = prev[0]!;
    } else {
      break;
    }
    const take = Math.min(entry.length, expected - outPos);
    out.set(entry.subarray(0, take), outPos);
    outPos += take;

    if (prev && nextCode < 4096) {
      const combined = new Uint8Array(prev.length + 1);
      combined.set(prev);
      combined[prev.length] = entry[0]!;
      table[nextCode++] = combined;
      if (nextCode === 511) codeSize = 10;
      else if (nextCode === 1023) codeSize = 11;
      else if (nextCode === 2047) codeSize = 12;
    }
    prev = entry;
  }
  return out;
}

async function inflateStrip(src: Uint8Array): Promise<Uint8Array> {
  if (typeof DecompressionStream === "undefined") {
    throw new Error("DecompressionStream unavailable");
  }
  const format =
    src.length >= 2 && (src[0]! & 0x0f) === 8 && ((src[0]! << 8) | src[1]!) % 31 === 0
      ? "deflate"
      : "deflate-raw";
  const stream = new Blob([src as Uint8Array<ArrayBuffer>])
    .stream()
    .pipeThrough(new DecompressionStream(format));
  const buffer = await new Response(stream).arrayBuffer();
  return new Uint8Array(buffer);
}

/**
 * Decodes the first image of a baseline TIFF (uncompressed, PackBits, LZW, or Deflate; Grayscale, RGB, RGBA, or
 * Palette; 8-bit or 16-bit per sample) into RGBA pixels for canvas rendering.
 */
export async function decodeTiff(bytes: Uint8Array): Promise<DecodedTiff> {
  if (bytes.length < 8) throw new Error("invalid tiff");
  const littleEndian = bytes[0] === 0x49 && bytes[1] === 0x49;
  const bigEndian = bytes[0] === 0x4d && bytes[1] === 0x4d;
  if (!littleEndian && !bigEndian) throw new Error("invalid tiff byte order");
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (view.getUint16(2, littleEndian) !== 42)
    throw new Error("unsupported tiff version");

  const ifdOffset = view.getUint32(4, littleEndian);
  if (ifdOffset + 2 > bytes.length) throw new Error("corrupt tiff ifd");
  const entryCount = view.getUint16(ifdOffset, littleEndian);
  const tags = new Map<number, number[]>();
  for (let i = 0; i < entryCount; i += 1) {
    const at = ifdOffset + 2 + i * 12;
    if (at + 12 > bytes.length) break;
    const tag = view.getUint16(at, littleEndian);
    const type = view.getUint16(at + 2, littleEndian);
    const count = view.getUint32(at + 4, littleEndian);
    tags.set(tag, readTagValues(view, littleEndian, type, count, at + 8));
  }

  const width = tags.get(256)?.[0] ?? 0;
  const height = tags.get(257)?.[0] ?? 0;
  if (width <= 0 || height <= 0 || width * height > maxPixels) {
    throw new Error("tiff dimensions out of bounds");
  }

  const bitsPerSample = tags.get(258) ?? [8];
  const compression = tags.get(259)?.[0] ?? 1;
  const photometric = tags.get(262)?.[0] ?? 2;
  const stripOffsets = tags.get(273) ?? [];
  const samplesPerPixel = tags.get(277)?.[0] ?? bitsPerSample.length;
  const rowsPerStrip = tags.get(278)?.[0] ?? height;
  const stripByteCounts = tags.get(279) ?? [];
  const planarConfig = tags.get(284)?.[0] ?? 1;
  const predictor = tags.get(317)?.[0] ?? 1;
  const colorMap = tags.get(320);

  if (planarConfig !== 1 || stripOffsets.length === 0) {
    throw new Error("unsupported tiff layout");
  }
  const bps = bitsPerSample[0] ?? 8;
  if (bps !== 8 && bps !== 16) throw new Error("unsupported tiff bit depth");
  const bytesPerSample = bps / 8;

  const rgba = new Uint8ClampedArray(width * height * 4);
  let currentRow = 0;

  for (let s = 0; s < stripOffsets.length && currentRow < height; s += 1) {
    const stripRows = Math.min(rowsPerStrip, height - currentRow);
    const expectedBytes = stripRows * width * samplesPerPixel * bytesPerSample;
    const offset = stripOffsets[s]!;
    const count = stripByteCounts[s] ?? expectedBytes;
    if (offset + count > bytes.length) throw new Error("corrupt tiff strip");
    const rawStrip = bytes.subarray(offset, offset + count);

    let decoded: Uint8Array;
    if (compression === 1) decoded = rawStrip;
    else if (compression === 32773) decoded = decodePackBits(rawStrip, expectedBytes);
    else if (compression === 5) decoded = decodeTiffLzw(rawStrip, expectedBytes);
    else if (compression === 8 || compression === 32946)
      decoded = await inflateStrip(rawStrip);
    else throw new Error("unsupported tiff compression");

    // Horizontal differencing predictor (tag 317 = 2).
    if (predictor === 2 && bytesPerSample === 1) {
      const copy = decoded.slice();
      const rowStride = width * samplesPerPixel;
      for (let r = 0; r < stripRows; r += 1) {
        const base = r * rowStride;
        for (let x = samplesPerPixel; x < rowStride; x += 1) {
          copy[base + x] = (copy[base + x]! + copy[base + x - samplesPerPixel]!) & 0xff;
        }
      }
      decoded = copy;
    }

    const stripView = new DataView(
      decoded.buffer,
      decoded.byteOffset,
      decoded.byteLength
    );
    const readSample = (index: number): number => {
      if (bytesPerSample === 1) return decoded[index] ?? 0;
      const byteIndex = index * 2;
      if (byteIndex + 2 > decoded.byteLength) return 0;
      return stripView.getUint16(byteIndex, littleEndian) >> 8;
    };

    for (let r = 0; r < stripRows; r += 1) {
      const y = currentRow + r;
      for (let x = 0; x < width; x += 1) {
        const srcIdx = (r * width + x) * samplesPerPixel;
        const dstIdx = (y * width + x) * 4;
        if (photometric === 0 || photometric === 1) {
          const v = readSample(srcIdx);
          const gray = photometric === 0 ? 255 - v : v;
          rgba[dstIdx] = gray;
          rgba[dstIdx + 1] = gray;
          rgba[dstIdx + 2] = gray;
          rgba[dstIdx + 3] = samplesPerPixel >= 2 ? readSample(srcIdx + 1) : 255;
        } else if (photometric === 3 && colorMap && colorMap.length >= 768) {
          const idx = readSample(srcIdx);
          rgba[dstIdx] = (colorMap[idx] ?? 0) >> 8;
          rgba[dstIdx + 1] = (colorMap[256 + idx] ?? 0) >> 8;
          rgba[dstIdx + 2] = (colorMap[512 + idx] ?? 0) >> 8;
          rgba[dstIdx + 3] = 255;
        } else if (photometric === 2) {
          rgba[dstIdx] = readSample(srcIdx);
          rgba[dstIdx + 1] = readSample(srcIdx + 1);
          rgba[dstIdx + 2] = readSample(srcIdx + 2);
          rgba[dstIdx + 3] = samplesPerPixel >= 4 ? readSample(srcIdx + 3) : 255;
        } else {
          throw new Error("unsupported tiff photometric");
        }
      }
    }
    currentRow += stripRows;
  }

  return { width, height, rgba };
}
