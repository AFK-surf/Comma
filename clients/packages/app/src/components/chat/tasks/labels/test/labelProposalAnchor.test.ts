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

type Proposal = { created_at?: number | undefined; id: string };

const proposal = (id: string, created_at: number): Proposal => ({
  created_at,
  id,
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
      [{ id: "prp_undated" }, proposal("prp_dated", 1_700_000_060_000)],
      messages
    );
    expect(groups.map((group) => group.messageId)).toEqual([
      "msg_reply_old",
      undefined,
    ]);
    expect(groups[1]?.proposals.map((item) => item.id)).toEqual(["prp_undated"]);
  });
});
