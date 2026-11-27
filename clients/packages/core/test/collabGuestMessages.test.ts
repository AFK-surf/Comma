import { describe, expect, it } from "vitest";
import { normalizeGuestMessage } from "../src/hosts/collab-guest.ts";

// The messages `GET /v1/comma/public/collaborations/task` sends a guest, as the server projects them
// (`CommaWeb.CollaborationGuestEndpoints.project_guest_messages/3`): no system lines, metadata or user ids.
const projected = [
  {
    id: "msg_comma",
    seq: 7,
    role: "assistant",
    sender_name: "Comma",
    is_guest: false,
    is_self: false,
    created_at: 1_795_500_000_000,
    content: [
      { type: "text", text: "Here is the PDF. I saved it in Files too." },
      {
        type: "file",
        file_name: "anthropic-news.pdf",
        path: "/task/anthropic-news.pdf",
        size: 184_320,
        mime_type: "application/pdf",
      },
      {
        type: "mini_app",
        app_id: "app_venues",
        name: "Venue comparison",
        summary: "Compare the venues.",
        version: 3,
      },
    ],
  },
  {
    id: "msg_self",
    seq: 8,
    role: "user",
    sender_name: "Gabriel Souza",
    is_guest: true,
    is_self: true,
    content: [{ type: "text", text: "Thanks!" }],
  },
  {
    id: "msg_anon",
    seq: 9,
    role: "user",
    sender_name: null,
    is_guest: true,
    is_self: false,
    content: [{ type: "text", text: "Same here." }],
  },
];

describe("a guest's view of the server's projected messages", () => {
  it("reads Comma's reply, its file and Mini App, the guest's own line and an unnamed guest's", () => {
    const [comma, self, anonymous] = projected.map((raw, i) =>
      normalizeGuestMessage(raw, `fallback-${i}`)
    );

    expect(comma).toMatchObject({
      id: "msg_comma",
      role: "assistant",
      senderName: "Comma",
      isSelf: false,
      text: "Here is the PDF. I saved it in Files too.",
      attachments: [
        {
          fileName: "anthropic-news.pdf",
          path: "/task/anthropic-news.pdf",
          size: 184_320,
          mimeType: "application/pdf",
        },
      ],
      miniApps: [{ appId: "app_venues", name: "Venue comparison", version: 3 }],
    });
    expect(self).toMatchObject({
      role: "user",
      senderName: "Gabriel Souza",
      isGuestSender: true,
      isSelf: true,
    });
    // No name and no address: the page names them Anonymous.
    expect(anonymous).toMatchObject({
      senderName: null,
      isGuestSender: true,
      isSelf: false,
    });
  });
});
