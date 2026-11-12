// What a paste here does to a computer's screen, and how a copy made there comes onto this device's clipboard
// (screenClipboard.ts, after still.fail's web/src/screen/Transfer.tsx and ScreenViewer.tsx's paste rule).
import { describe, expect, it, vi } from "vitest";
import { pasted, putClip, takesPaste } from "../screenClipboard";

/** A paste's data: its text, and its files. */
const data = (text: string, files: File[] = []) => ({
  files: files as unknown as FileList,
  getData: (type: string) => (type === "text/plain" ? text : ""),
});
const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47]);
const png = () => new File([PNG], "shot.png", { type: "image/png" });

describe("a paste on a computer's screen", () => {
  it("goes onto its clipboard where it carries what is pasted, else it is typed", () => {
    expect(takesPaste(data("hi"), ["text", "png"])).toBe(true);
    expect(takesPaste(data("", [png()]), ["text", "png"])).toBe(true);
    // A screen of text only takes no picture; one with no clipboard (a station before it) takes nothing.
    expect(takesPaste(data("", [png()]), ["text"])).toBe(false);
    expect(takesPaste(data("hi"), [])).toBe(false);
    expect(takesPaste(data(""), ["text", "png"])).toBe(false);
  });

  it("sets a picture before text, of the types the screen carries", async () => {
    expect(await pasted(data("caption", [png()]), ["text", "png"])).toEqual({
      type: "png",
      data: PNG,
    });
    expect(await pasted(data("caption", [png()]), ["text"])).toEqual({
      type: "text",
      text: "caption",
    });
    expect(await pasted(data("", []), ["text"])).toBeNull();
  });
});

describe("a copy made on the screen", () => {
  it("goes onto this device's clipboard as text or as a PNG picture", async () => {
    const clipboard = {
      text: vi.fn(() => Promise.resolve()),
      png: vi.fn(() => Promise.resolve()),
    };
    await putClip({ type: "text", text: "复制的" }, clipboard);
    expect(clipboard.text).toHaveBeenCalledWith("复制的");
    await putClip({ type: "png", data: PNG }, clipboard);
    const [[blob]] = clipboard.png.mock.calls as unknown as [[Blob]];
    expect(blob.type).toBe("image/png");
    expect(new Uint8Array(await blob.arrayBuffer())).toEqual(PNG);
  });

  it("fails where it may not be written, for the page to offer it", async () => {
    const refused = {
      text: () => Promise.reject(new DOMException("no focus", "NotAllowedError")),
      png: () => Promise.resolve(),
    };
    await expect(putClip({ type: "text", text: "x" }, refused)).rejects.toThrow(
      "no focus"
    );
  });
});
