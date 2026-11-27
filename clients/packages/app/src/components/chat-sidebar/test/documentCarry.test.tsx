import type { ChatMessage } from "@comma/core/chat";
import { expect, it } from "vitest";
import { conversationFileSourceKey } from "../../../runtime-files/fileSources";
import { documentVersionsToCarry, stagedDocumentPictures } from "../documentCarry";
import { savedDocumentEdits } from "../savedDocumentEdits";

const message = (
  part: Pick<ChatMessage, "messageId" | "role"> & Partial<ChatMessage>
): ChatMessage =>
  ({
    attachments: [],
    createdAt: 1_720_000_000,
    source: "server",
    ...part,
  }) as ChatMessage;
const sends = (messageId: string, fileName = "plan.md") =>
  message({
    messageId,
    role: "assistant",
    attachments: [
      { attachmentIndex: 1, blockType: "file", fileName },
    ] as ChatMessage["attachments"],
  });
const versionOf = (conversationId: string, messageId: string) =>
  conversationFileSourceKey({
    groupId: "grp_1",
    conversationId,
    messageId,
    attachmentIndex: 1,
    fileName: "plan.md",
  });
const carried = (conversationId: string, messages: ChatMessage[]) =>
  documentVersionsToCarry(conversationId, messages).map(({ about }) =>
    about.kind === "document-version"
      ? {
          reference: about.reference,
          name: about.fileName,
          text: new TextDecoder().decode(about.file.bytes),
          images: (about.images ?? []).map((image) => image.name),
        }
      : about.kind
  );

it("carries a person's saved edits of a document's newest version, with the pictures they put in", () => {
  const first = versionOf("cnv_carry", "m1");
  savedDocumentEdits.set(first, "# Plan\n\n![chart](chart.png)\n\nMine.\n");
  stagedDocumentPictures.set(
    "cnv_carry\nplan.md",
    new Map([
      ["chart.png", { file: new File([], "chart.png"), bytes: new Uint8Array([1, 2]) }],
      // Its bytes are not read yet: it waits for a later message.
      ["late.png", { file: new File([], "late.png") }],
    ])
  );
  expect(carried("cnv_carry", [sends("m1")])).toEqual([
    {
      reference: first,
      name: "plan.md",
      text: "# Plan\n\n![chart](chart.png)\n\nMine.\n",
      images: ["chart.png"],
    },
  ]);
  // Another conversation's message carries nothing of it.
  expect(carried("cnv_other", [sends("m1")])).toEqual([]);

  // A message carried them: the next one does not.
  savedDocumentEdits.markSent(first);
  expect(carried("cnv_carry", [sends("m1")])).toEqual([]);
  savedDocumentEdits.delete(first);
  stagedDocumentPictures.delete("cnv_carry\nplan.md");
});

it("leaves edits of an earlier version with that version once the document has a newer one", () => {
  const first = versionOf("cnv_stale", "m1");
  savedDocumentEdits.set(first, "# Plan\n\nMine, of the first version.\n");
  expect(carried("cnv_stale", [sends("m1")])).toHaveLength(1);

  // Comma sends a new version: the edits of the first would go over it, so no message carries them.
  expect(carried("cnv_stale", [sends("m1"), sends("m2")])).toEqual([]);
  // They are still saved, with the version they are of.
  expect(savedDocumentEdits.get(first)).toBe("# Plan\n\nMine, of the first version.\n");

  // The person edits the newest version: that is what goes.
  const second = versionOf("cnv_stale", "m2");
  savedDocumentEdits.set(second, "# Plan\n\nMine, of the second.\n");
  expect(carried("cnv_stale", [sends("m1"), sends("m2")])).toEqual([
    {
      reference: second,
      name: "plan.md",
      text: "# Plan\n\nMine, of the second.\n",
      images: [],
    },
  ]);

  // Discarded: nothing goes.
  savedDocumentEdits.delete(second);
  expect(carried("cnv_stale", [sends("m1"), sends("m2")])).toEqual([]);
  savedDocumentEdits.delete(first);
});
