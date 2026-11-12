import { MAX_ATTACHMENT_BYTES } from "@comma/core/chat";
import { afterEach, describe, expect, it, vi } from "vitest";
import { fitImageAttachment } from "../fitImageAttachment";

type Encode = { height: number; quality?: number; type: string; width: number };

/** A window's canvas, whose encoded size is `size` of what it was asked to encode. */
function stubCanvas(
  source: { height: number; width: number },
  size: (encode: Encode) => number,
  alpha = 255
) {
  const encodes: Encode[] = [];
  const close = vi.fn();
  vi.stubGlobal(
    "createImageBitmap",
    vi.fn(async () => ({ ...source, close }))
  );
  vi.stubGlobal(
    "OffscreenCanvas",
    class {
      constructor(
        readonly width: number,
        readonly height: number
      ) {}
      getContext() {
        return {
          drawImage: () => undefined,
          getImageData: () => ({ data: new Uint8ClampedArray([0, 0, 0, alpha]) }),
        };
      }
      async convertToBlob({ quality, type }: { quality?: number; type: string }) {
        const encode = { height: this.height, type, width: this.width };
        encodes.push(quality === undefined ? encode : { ...encode, quality });
        return { size: size(encodes.at(-1)!), type } as Blob;
      }
    }
  );
  vi.stubGlobal(
    "File",
    class {
      constructor(
        readonly parts: unknown[],
        readonly name: string,
        readonly options: unknown
      ) {}
    }
  );
  return { close, encodes };
}

const input = (name: string, size: number) => ({ data: new Blob(), name, size });
const fitting = 1_000_000;
const tooBig = MAX_ATTACHMENT_BYTES + 1;

describe("fitImageAttachment", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("leaves an image that fits as it is", async () => {
    const { close, encodes } = stubCanvas({ height: 1000, width: 1000 }, () => fitting);
    const file = input("shot.png", MAX_ATTACHMENT_BYTES);
    await expect(fitImageAttachment(file)).resolves.toBe(file);
    expect(encodes).toEqual([]);
    expect(close).toHaveBeenCalled();
  });

  it("does not read a file that is no image, or a GIF", async () => {
    const { encodes } = stubCanvas({ height: 1, width: 1 }, () => fitting);
    for (const file of [input("big.pdf", tooBig), input("big.gif", tooBig)]) {
      await expect(fitImageAttachment(file)).resolves.toBe(file);
    }
    expect(createImageBitmap).not.toHaveBeenCalled();
    expect(encodes).toEqual([]);
  });

  it("keeps a PNG when that fits", async () => {
    const { encodes } = stubCanvas({ height: 2000, width: 3000 }, () => fitting);
    await expect(fitImageAttachment(input("shot.png", tooBig))).resolves.toMatchObject({
      name: "shot.png",
      size: fitting,
    });
    expect(encodes).toEqual([{ height: 2000, type: "image/png", width: 3000 }]);
  });

  it("makes an opaque PNG that does not fit a JPEG", async () => {
    const { encodes } = stubCanvas({ height: 2000, width: 3000 }, ({ type }) =>
      type === "image/png" ? tooBig : fitting
    );
    await expect(fitImageAttachment(input("shot.png", tooBig))).resolves.toMatchObject({
      name: "shot.jpg",
      size: fitting,
    });
    expect(encodes.at(-1)).toEqual({
      height: 2000,
      quality: 0.85,
      type: "image/jpeg",
      width: 3000,
    });
  });

  it("makes a transparent PNG that does not fit a WebP", async () => {
    stubCanvas(
      { height: 2000, width: 3000 },
      ({ type }) => (type === "image/png" ? tooBig : fitting),
      128
    );
    await expect(fitImageAttachment(input("logo.png", tooBig))).resolves.toMatchObject({
      name: "logo.webp",
    });
  });

  it("shrinks a small file over the server's dimensions, and the lossy steps until it fits", async () => {
    const { encodes } = stubCanvas({ height: 4000, width: 8192 }, ({ width }) =>
      width > 2048 ? tooBig : fitting
    );
    const fitted = await fitImageAttachment(input("wide.jpg", fitting));
    expect(fitted).toMatchObject({ name: "wide.jpg", size: fitting });
    expect(encodes.map(({ width }) => width)).toEqual([4096, 3072, 2048]);
    expect(encodes[0]?.height).toBe(2000);
  });

  it("leaves as it is an image it cannot shrink enough or cannot decode", async () => {
    stubCanvas({ height: 2000, width: 3000 }, () => tooBig);
    const big = input("noise.png", tooBig);
    await expect(fitImageAttachment(big)).resolves.toBe(big);

    vi.stubGlobal(
      "createImageBitmap",
      vi.fn(async () => {
        throw new Error("Undecodable");
      })
    );
    await expect(fitImageAttachment(big)).resolves.toBe(big);
  });
});
