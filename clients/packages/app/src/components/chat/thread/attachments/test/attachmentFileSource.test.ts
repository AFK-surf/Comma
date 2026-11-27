import { describe, expect, it } from "vitest";
import { conversationFileSource } from "../../../../../runtime-files/fileSources";
import { attachmentFileSource } from "../useAttachmentFileActions";

const thread = { groupId: "grp_1", conversationId: "cnv_1" };

describe("attachmentFileSource", () => {
  it("reads an Agent's attachment from its message even when it names a path", () => {
    const source = attachmentFileSource(
      {
        attachmentIndex: 0,
        workspacePath: "/artifacts/Release v2.1 - bundle.zip",
        fileName: "bundle.zip",
      },
      0,
      "msg_1",
      thread
    );
    expect(source && conversationFileSource(source)).toEqual({
      source: "attachment",
      group: "grp_1",
      conversation: "cnv_1",
      message: "msg_1",
      index: 0,
    });
  });

  it("reads a file the person sent from where it was uploaded", () => {
    const source = attachmentFileSource(
      { workspacePath: "/uploads/photo.png", fileName: "photo.png" },
      1,
      "msg_1",
      thread
    );
    expect(source && conversationFileSource(source)).toEqual({
      source: "group-file",
      group: "grp_1",
      path: "/uploads/photo.png",
    });
  });
});
