import { expect, it } from "vitest";
import { documentHead } from "../AttachmentPreviewCard";

const bytes = (text: string) => new TextEncoder().encode(text);

it("shows the top of a document's page in its card: no front matter, no pictures, whole lines only", () => {
  const text =
    '---\ntitle: Draft\n---\n# Plan\n\n![Chart](chart.png)\n\n<p align="center"><img src="wide.png" alt="Wide" width="380"></p>\n\nBody.\nA line cut sho';
  expect(documentHead(bytes(text), false)).toBe("# Plan\n\n\n\n\n\nBody.");
  expect(documentHead(bytes("# Plan\n\nBody."), true)).toBe("# Plan\n\nBody.");
});
