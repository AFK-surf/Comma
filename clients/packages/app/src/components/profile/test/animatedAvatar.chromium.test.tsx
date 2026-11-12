import { describe, expect, it } from "vitest";
import { encodeAnimatedAvatar } from "../avatarImage";

/** A 40 px GIF of three frames: red for 100 ms, blue for 200 ms, green for 300 ms. */
const movingGif =
  "R0lGODlhKAAoAPcAAAAA/wD/AP8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEA" +
  "AAAh+QQFCgD/ACwAAAAAKAAoAAAIQwAFCBxIsKDBgwgTKlzIsKHDhxAjSpxIsaLFixgzatzIsaPH" +
  "jyBDihxJsqTJkyhTqlzJsqXLlzBjypxJs6bNmzgJBgQAIfkEBRQA/wAsAAAAACgAKAAACEMAAQgc" +
  "SLCgwYMIEypcyLChw4cQI0qcSLGixYsYM2rcyLGjx48gQ4ocSbKkyZMoU6pcybKly5cwY8qcSbOm" +
  "zZs4CQYEACH5BAUeAP8ALAAAAAAoACgAAAhDAAMIHEiwoMGDCBMqXMiwocOHECNKnEixosWLGDNq" +
  "3Mixo8ePIEOKHEmypMmTKFOqXMmypcuXMGPKnEmzps2bOAkGBAA7";

const near = (actual: number[], expected: number[]) =>
  actual.every((value, index) => Math.abs(value - expected[index]!) < 24);

describe("moving avatar", () => {
  it("turns a moving GIF into a cropped animated WebP that the browser plays", async () => {
    const bytes = Uint8Array.from(atob(movingGif), (char) => char.charCodeAt(0));
    const file = new File([bytes], "dance.gif", { type: "image/gif" });

    const out = await encodeAnimatedAvatar(
      file,
      { width: 40, height: 40 },
      { x: 5, y: 5, size: 30 }
    );

    expect(out?.type).toBe("image/webp");
    expect(out?.name).toBe("dance.webp");
    const decoder = new ImageDecoder({
      data: new Uint8Array(await out!.arrayBuffer()),
      type: "image/webp",
    });
    try {
      await Promise.all([decoder.tracks.ready, decoder.completed]);
      expect(decoder.tracks.selectedTrack?.frameCount).toBe(3);
      const frames = [];
      for (let frameIndex = 0; frameIndex < 3; frameIndex++) {
        const { image } = await decoder.decode({ frameIndex });
        const canvas = new OffscreenCanvas(image.displayWidth, image.displayHeight);
        const context = canvas.getContext("2d")!;
        context.drawImage(image, 0, 0);
        const pixel = [...context.getImageData(48, 48, 1, 1).data];
        frames.push({ side: image.displayWidth, duration: image.duration, pixel });
        image.close();
      }
      expect(frames.map(({ side, duration }) => [side, duration])).toEqual([
        [96, 100_000],
        [96, 200_000],
        [96, 300_000],
      ]);
      expect(near(frames[0]!.pixel, [255, 0, 0, 255])).toBe(true);
      expect(near(frames[1]!.pixel, [0, 0, 255, 255])).toBe(true);
      expect(near(frames[2]!.pixel, [0, 255, 0, 255])).toBe(true);
    } finally {
      decoder.close();
    }
  });
});
