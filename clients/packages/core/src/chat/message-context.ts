// The messages around one message of a conversation (`chat.messageContext`): a reply that quotes a message the
// transcript has not loaded yet reads them, so the window can show that message in place. Read once for each call, as
// a window shows them.
//
// Bounds: one read per call; the server bounds the page.
import type { CoreError } from "@comma/core-kernel";
import { Effect } from "effect";
import { z } from "zod";
import { route } from "../api.ts";
import {
  commaConversationKindSchema,
  commaPageSchema,
  salixMessageSchema,
} from "../comma/api-schemas.ts";
import type { Ctx } from "../ctx.ts";
import {
  normalizeServerMessages,
  type ChatMessage,
} from "./model/conversationChannel.ts";
import { transcriptMessages } from "./model/taskActivity.ts";

const id = z.string().min(1).max(256);

export const messageContextInputSchema = z.object({
  groupId: id,
  conversationId: id,
  messageId: id,
  conversationKind: commaConversationKindSchema,
});

export function readMessageContext(
  ctx: Ctx,
  input: z.output<typeof messageContextInputSchema>
): Effect.Effect<ChatMessage[], CoreError> {
  return Effect.gen(function* () {
    const account = yield* ctx.session.account();
    const page = yield* ctx.api.request(
      account,
      "GET",
      route`/v1/comma/groups/${input.groupId}/conversations/${input.conversationId}/messages/${input.messageId}/context`,
      commaPageSchema(salixMessageSchema)
    );
    return transcriptMessages(
      normalizeServerMessages(
        page.data,
        [],
        input.conversationKind,
        input.conversationId
      )
    );
  });
}
