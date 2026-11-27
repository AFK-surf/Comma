import type { ChatMessage } from "@comma/core/chat";
import { expect, it } from "vitest";
import { conversationFileSource } from "../../../runtime-files/fileSources";
import { documentVersionsIn } from "../FilePreviewPanel";
import { sentDocuments, sentPictures } from "../sentDocuments";

const message = (
  part: Pick<ChatMessage, "messageId" | "role"> & Partial<ChatMessage>
): ChatMessage =>
  ({
    attachments: [],
    createdAt: 1_720_000_000,
    source: "server",
    ...part,
  }) as ChatMessage;

const shown = {
  groupId: "grp_1",
  conversationId: "cnv_1",
  messageId: "m1",
  attachmentIndex: 1,
  fileName: "plan.md",
};

it("counts a version the person sent among a document's versions, read from the Group's uploads", () => {
  const versions = documentVersionsIn(
    [
      message({
        messageId: "m1",
        role: "assistant",
        attachments: [
          { attachmentIndex: 1, blockType: "file", fileName: "plan.md" },
        ] as ChatMessage["attachments"],
      }),
      // The person's message names the files it sent; another document of the chat is no version of this one.
      message({
        messageId: "m2",
        role: "user",
        createdAt: 1_720_000_060,
        display: {
          body: "Restored plan.md",
          quotes: [],
          files: [
            { name: "notes.md", path: "/uploads/AAAAAAAAAAAAAAAAAAAAAA-notes.md" },
            { name: "plan.md", path: "/uploads/AAAAAAAAAAAAAAAAAAAAAQ-plan.md" },
          ],
        },
      }),
    ],
    shown
  )!;
  expect(versions.map((version) => [version.author, version.at])).toEqual([
    ["agent", 1_720_000_000_000],
    ["user", 1_720_000_060_000],
  ]);
  // Comma's version is the message's attachment; the person's is the upload its message names.
  expect(versions.map((version) => conversationFileSource(version.source))).toEqual([
    {
      source: "attachment",
      group: "grp_1",
      conversation: "cnv_1",
      message: "m1",
      index: 1,
    },
    {
      source: "group-file",
      group: "grp_1",
      path: "/uploads/AAAAAAAAAAAAAAAAAAAAAQ-plan.md",
    },
  ]);
});

it("reads no document or picture a person named by its path on their computer: it is not in the Group's uploads", () => {
  const sent = message({
    messageId: "m2",
    role: "user",
    display: {
      body: "Edit these",
      quotes: [],
      files: [
        { name: "plan.md", path: "/Users/me/plan.md", local: true },
        { name: "shot.png", path: "/Users/me/shot.png", local: true },
        { name: "notes.md", path: `/uploads/${"u".repeat(22)}-notes.md` },
      ],
    },
  });
  expect(sentDocuments(sent)).toEqual([
    {
      attachmentIndex: 2,
      fileName: "notes.md",
      workspacePath: `/uploads/${"u".repeat(22)}-notes.md`,
    },
  ]);
  expect(sentPictures([sent])).toEqual(new Map());
});
