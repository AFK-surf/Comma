import type { FilesSaveDownloadResult } from "@comma/native-bridge";
import { describe, expect, it } from "vitest";
import { PartSaves } from "../modules/core/part-saves";

/** A streamed save that writes each chunk as it takes it, and fails once `failAt` chunks came. */
function save(failAt = Number.POSITIVE_INFINITY) {
  const written: number[][] = [];
  let removed = false;
  const stream = async ({
    chunks,
    fileName,
  }: {
    chunks: AsyncIterable<Uint8Array>;
    fileName: string;
  }): Promise<FilesSaveDownloadResult> => {
    try {
      for await (const chunk of chunks) {
        if (written.length >= failAt) throw new Error("disk full");
        written.push([...chunk]);
      }
    } catch (error) {
      removed = true;
      throw error;
    }
    return { downloadRef: `ref:${fileName}`, fileName, status: "saved" };
  };
  return { stream, written, removed: () => removed };
}

describe("files the core saves a part at a time", () => {
  it("writes each part as it comes, then puts the file in place", async () => {
    const saves = new PartSaves();
    const disk = save();
    const { id } = saves.open("clip.mp4", disk.stream);
    await saves.write(id, Uint8Array.of(1, 2));
    await saves.write(id, Uint8Array.of(3));
    expect(disk.written).toEqual([[1, 2], [3]]);
    expect(await saves.close(id, true)).toEqual({
      downloadRef: "ref:clip.mp4",
      fileName: "clip.mp4",
    });
  });

  it("leaves nothing of a save given up, and says a failed write", async () => {
    const saves = new PartSaves();
    const givenUp = save();
    const first = saves.open("a.zip", givenUp.stream);
    await saves.write(first.id, Uint8Array.of(1));
    expect(await saves.close(first.id, false)).toBeNull();
    expect(givenUp.removed()).toBe(true);

    const full = save(1);
    const second = saves.open("b.zip", full.stream);
    await saves.write(second.id, Uint8Array.of(1));
    await expect(saves.write(second.id, Uint8Array.of(2))).rejects.toThrow("disk full");
    expect(await saves.close(second.id, true)).toBeNull();
  });
});
