import { describe, expect, it } from "vitest";
import { inlineMediaKindOf, inlineMediaTypeOf } from "../runtime-files/inlineMedia";

describe("inline media allowlist", () => {
  it.each([
    ["chart.png", "image", "image/png"],
    ["photo.jpg", "image", "image/jpeg"],
    ["photo.jpeg", "image", "image/jpeg"],
    ["loop.gif", "image", "image/gif"],
    ["render.webp", "image", "image/webp"],
    ["demo.mp4", "video", "video/mp4"],
    ["demo.m4v", "video", "video/mp4"],
    ["capture.webm", "video", "video/webm"],
  ])("admits %s as %s", (fileName, kind, mediaType) => {
    expect(inlineMediaKindOf({ fileName })).toBe(kind);
    expect(inlineMediaTypeOf({ fileName })).toBe(mediaType);
  });

  it.each([
    // Active content: can carry script or reach external resources.
    "diagram.svg",
    "page.html",
    "report.pdf",
    // No decoder in every shipped renderer, or codec not knowable from the name.
    "scan.avif",
    "camera.heic",
    "bitmap.bmp",
    "print.tiff",
    "screen.mov",
    "legacy.ogv",
    "movie.mkv",
    "clip.avi",
    // Not visual media.
    "voice.mp3",
    "bundle.zip",
    "README",
    ".png",
  ])("keeps %s a file card", (fileName) => {
    expect(inlineMediaKindOf({ fileName })).toBe("file");
  });

  it("reads the type from the name a locator-shaped or differently cased name carries", () => {
    expect(inlineMediaKindOf({ fileName: "FRAME.PNG" })).toBe("image");
    expect(inlineMediaKindOf({ fileName: "Clip.WebM" })).toBe("video");
    expect(inlineMediaKindOf({ fileName: "clip.mp4?token=abc#t=3" })).toBe("video");
    expect(inlineMediaKindOf({ fileName: "bundle.zip?name=cover.png" })).toBe("file");
  });

  it("falls back from file name to title to the workspace path's last segment", () => {
    expect(inlineMediaKindOf({ title: "cover.webp" })).toBe("image");
    expect(inlineMediaKindOf({ workspacePath: "/out/run.1/demo.webm" })).toBe("video");
    expect(inlineMediaKindOf({ fileName: "notes.txt", title: "cover.webp" })).toBe(
      "file"
    );
  });

  it("lets a declared type stand in for a missing extension", () => {
    expect(inlineMediaKindOf({ fileName: "render", mimeType: "image/png" })).toBe(
      "image"
    );
    expect(
      inlineMediaTypeOf({ fileName: "clip", mimeType: "Video/MP4; codecs=avc1" })
    ).toBe("video/mp4");
    expect(inlineMediaTypeOf({ fileName: "p.jpg", mimeType: "image/jpg" })).toBe(
      "image/jpeg"
    );
  });

  it("lets the name decide only when the sender declared no type", () => {
    expect(
      inlineMediaKindOf({ fileName: "a.png", mimeType: "application/octet-stream" })
    ).toBe("image");
    expect(inlineMediaKindOf({ fileName: "a.png", mimeType: " " })).toBe("image");
  });

  it("fails closed when the declared type and the extension disagree", () => {
    // An SVG or HTML payload renamed to pass as a raster image.
    expect(inlineMediaKindOf({ fileName: "a.png", mimeType: "image/svg+xml" })).toBe(
      "file"
    );
    expect(inlineMediaKindOf({ fileName: "a.png", mimeType: "text/html" })).toBe(
      "file"
    );
    expect(inlineMediaKindOf({ fileName: "a.svg", mimeType: "image/png" })).toBe(
      "file"
    );
    expect(inlineMediaKindOf({ fileName: "a.png", mimeType: "video/mp4" })).toBe(
      "file"
    );
  });
});
