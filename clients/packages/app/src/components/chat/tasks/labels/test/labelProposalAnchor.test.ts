import { describe, expect, it } from "vitest";
import {
  groupLabelProposalsByAnchor,
  labelProposalAnchorMessageId,
} from "../labelProposalAnchor";

const messages = [
  { createdAt: 1_700_000_000_000, messageId: "msg_user", role: "user" },
  { createdAt: 1_700_000_060_000, messageId: "msg_reply_old", role: "assistant" },
  { createdAt: 1_700_000_600_000, messageId: "msg_reply_new", role: "assistant" },
];

describe("labelProposalAnchorMessageId", () => {
  it("returns the reply nearest the time the proposals were filed", () => {
    // The API accepts Unix seconds for both sides of this comparison.
    expect(labelProposalAnchorMessageId(messages, 1_700_000_061)).toBe("msg_reply_old");
    expect(labelProposalAnchorMessageId(messages, 1_700_000_599_000)).toBe(
      "msg_reply_new"
    );
  });

  it("keeps the earlier reply when two replies are equally close", () => {
    expect(
      labelProposalAnchorMessageId(
        [
          { createdAt: 1_700_000_000_000, messageId: "msg_first", role: "assistant" },
          { createdAt: 1_700_000_020_000, messageId: "msg_second", role: "assistant" },
        ],
        1_700_000_010_000
      )
    ).toBe("msg_first");
  });

  it("never anchors to a user message", () => {
    expect(labelProposalAnchorMessageId(messages, 1_700_000_001_000)).toBe(
      "msg_reply_old"
    );
  });

  it("has no anchor for a proposal filed before the oldest loaded message", () => {
    // The reply that filed it is not loaded; the oldest loaded reply is unrelated.
    expect(labelProposalAnchorMessageId(messages, 1_699_000_000_000)).toBeUndefined();
  });

  it("anchors a proposal older than a reply at the head of the loaded history to it", () => {
    // The page starts at a reply whose person's message is not loaded. The reply
    // is dated after the proposals it filed while it was written.
    expect(labelProposalAnchorMessageId(messages.slice(1), 1_700_000_050_000)).toBe(
      "msg_reply_old"
    );
    expect(
      groupLabelProposalsByAnchor(
        [{ created_at: 1_700_000_050_000, id: "prp_settled", status: "approved" }],
        messages.slice(1)
      )
    ).toMatchObject([{ messageId: "msg_reply_old" }]);
  });

  it("keeps a decision older than a reply at the head of the loaded history on the tail", () => {
    // Anchored at the head, a decision would hold every loaded turn mounted.
    expect(
      labelProposalAnchorMessageId(messages.slice(1), 1_700_000_050_000, {
        awaitsDecision: true,
      })
    ).toBeUndefined();
    expect(
      groupLabelProposalsByAnchor(
        [{ created_at: 1_700_000_050_000, id: "prp_pending", status: "pending" }],
        messages.slice(1)
      )
    ).toMatchObject([{ messageId: undefined }]);
  });

  it("has no anchor without a proposal time or a dated reply", () => {
    expect(labelProposalAnchorMessageId(messages, undefined)).toBeUndefined();
    expect(
      labelProposalAnchorMessageId(
        [{ createdAt: undefined, messageId: "msg_reply", role: "assistant" }],
        1_700_000_000_000
      )
    ).toBeUndefined();
  });
});

type Proposal = {
  created_at?: number | undefined;
  id: string;
  status: "pending" | "approved";
};

const proposal = (
  id: string,
  created_at: number,
  status: Proposal["status"] = "pending"
): Proposal => ({
  created_at,
  id,
  status,
});

describe("groupLabelProposalsByAnchor", () => {
  it("keeps each round with the reply that filed it", () => {
    const groups = groupLabelProposalsByAnchor(
      [
        proposal("prp_first", 1_700_000_060_000),
        proposal("prp_second", 1_700_000_600_000),
        proposal("prp_second_batch", 1_700_000_601_000),
      ],
      messages
    );
    expect(groups.map((group) => group.messageId)).toEqual([
      "msg_reply_old",
      "msg_reply_new",
    ]);
    expect(groups[0]?.proposals.map((item) => item.id)).toEqual(["prp_first"]);
    expect(groups[1]?.proposals.map((item) => item.id)).toEqual([
      "prp_second",
      "prp_second_batch",
    ]);
  });

  it("orders the groups by the reply in the transcript, not by filing time", () => {
    const groups = groupLabelProposalsByAnchor(
      [proposal("prp_new", 1_700_000_600_000), proposal("prp_old", 1_700_000_060_000)],
      messages
    );
    expect(groups.map((group) => group.messageId)).toEqual([
      "msg_reply_old",
      "msg_reply_new",
    ]);
  });

  it("keeps proposals with no dated reply together, last", () => {
    const groups = groupLabelProposalsByAnchor(
      [
        { id: "prp_undated", status: "approved" },
        proposal("prp_dated", 1_700_000_060_000),
      ],
      messages
    );
    expect(groups.map((group) => group.messageId)).toEqual([
      "msg_reply_old",
      undefined,
    ]);
    expect(groups[1]?.proposals.map((item) => item.id)).toEqual(["prp_undated"]);
  });

  it("keeps a decision filed before the loaded history on the tail and shows no settled one", () => {
    const groups = groupLabelProposalsByAnchor(
      [
        proposal("prp_old_pending", 1_699_000_000_000),
        proposal("prp_old_approved", 1_699_000_000_000, "approved"),
        proposal("prp_loaded_approved", 1_700_000_060_000, "approved"),
      ],
      messages
    );
    expect(groups.map((group) => group.messageId)).toEqual([
      "msg_reply_old",
      undefined,
    ]);
    expect(groups[0]?.proposals.map((item) => item.id)).toEqual([
      "prp_loaded_approved",
    ]);
    expect(groups[1]?.proposals.map((item) => item.id)).toEqual(["prp_old_pending"]);
  });
});
