import { describe, expect, it } from "vitest";
import { officeThumbnail } from "../filePictures";

type Entry = { name: string; data: Uint8Array; deflated?: Uint8Array };

/** A ZIP archive of `entries`, as an office app writes one: local entries, the directory, the end record. */
function zip(entries: Entry[]) {
  const encoder = new TextEncoder();
  const parts: Uint8Array[] = [];
  const directory: Uint8Array[] = [];
  let offset = 0;
  for (const entry of entries) {
    const name = encoder.encode(entry.name);
    const body = entry.deflated ?? entry.data;
    const local = new Uint8Array(30 + name.length + 4);
    const localView = new DataView(local.buffer);
    localView.setUint32(0, 0x04034b50, true);
    localView.setUint16(8, entry.deflated ? 8 : 0, true);
    localView.setUint32(18, body.length, true);
    localView.setUint32(22, entry.data.length, true);
    localView.setUint16(26, name.length, true);
    // An extra field only the local header has.
    localView.setUint16(28, 4, true);
    local.set(name, 30);
    const central = new Uint8Array(46 + name.length);
    const centralView = new DataView(central.buffer);
    centralView.setUint32(0, 0x02014b50, true);
    centralView.setUint16(10, entry.deflated ? 8 : 0, true);
    centralView.setUint32(20, body.length, true);
    centralView.setUint32(24, entry.data.length, true);
    centralView.setUint16(28, name.length, true);
    centralView.setUint32(42, offset, true);
    central.set(name, 46);
    parts.push(local, body);
    directory.push(central);
    offset += local.length + body.length;
  }
  const size = directory.reduce((sum, part) => sum + part.length, 0);
  const end = new Uint8Array(22);
  const endView = new DataView(end.buffer);
  endView.setUint32(0, 0x06054b50, true);
  endView.setUint16(10, entries.length, true);
  endView.setUint32(12, size, true);
  endView.setUint32(16, offset, true);
  return new Blob([...parts, ...directory, end] as BlobPart[]);
}

/** The archive read in spans, with each span asked for. */
function ranged(archive: Blob) {
  const reads: [number, number][] = [];
  return {
    reads,
    read: async (offset: number, length: number) => {
      reads.push([offset, length]);
      return {
        bytes: new Uint8Array(
          await archive.slice(offset, offset + length).arrayBuffer()
        ),
        size: archive.size,
      };
    },
  };
}

const bytes = (text: string) => new TextEncoder().encode(text);
const deflate = async (data: Uint8Array) =>
  new Uint8Array(
    await new Response(
      new Blob([data as BlobPart])
        .stream()
        .pipeThrough(new CompressionStream("deflate-raw"))
    ).arrayBuffer()
  );

describe("an office file's own thumbnail", () => {
  it("is read from a deck of any size as its directory and that one entry", async () => {
    const slides = new Uint8Array(300_000).fill(7);
    const file = ranged(
      zip([
        { name: "ppt/slides/slide1.xml", data: slides },
        { name: "docProps/thumbnail.jpeg", data: bytes("JPEG bytes") },
        { name: "ppt/media/image1.png", data: slides },
      ])
    );
    const picture = await officeThumbnail(file);
    expect(picture?.type).toBe("image/jpeg");
    expect(await picture?.text()).toBe("JPEG bytes");
    // The slides themselves are never read.
    expect(file.reads.reduce((sum, [, length]) => sum + length, 0)).toBeLessThan(
      70_000
    );
  });

  it("unpacks a deflated thumbnail", async () => {
    const data = bytes("PNG bytes ".repeat(200));
    const picture = await officeThumbnail(
      ranged(
        zip([{ name: "QuickLook/Thumbnail.png", data, deflated: await deflate(data) }])
      )
    );
    expect(picture?.type).toBe("image/png");
    expect(await picture?.text()).toBe("PNG bytes ".repeat(200));
  });

  it("is none for a deck saved without one, and for a file that is no archive", async () => {
    expect(
      await officeThumbnail(
        ranged(zip([{ name: "ppt/slides/slide1.xml", data: bytes("<slide/>") }]))
      )
    ).toBeUndefined();
    expect(
      await officeThumbnail(ranged(new Blob(["%PDF-1.7 not a zip"])))
    ).toBeUndefined();
  });
});
