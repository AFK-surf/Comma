// A conversation read ahead of its opening (the Tasks page prepares the ones it shows): its last 24 messages, read once
// for each call (`chat.prepare`), as a window shows them. The window keeps what it was answered for the conversation's
// first frame; the conversation itself is read again once it opens. A conversation whose last messages are all
// private delivery records answers nothing: they cannot say its transcript is empty.
//
// Bounds: one read per call, at most 24 messages; the caller bounds how many it asks for at a time.
import type { CoreError } from "@comma/core-kernel";
import { Effect } from "effect";
import { z } from "zod";
import { route } from "../api.ts";
import {
  commaConversationSchema,
  type CommaConversation,
} from "../comma/api-schemas.ts";
import type { Ctx } from "../ctx.ts";
import {
  normalizeServerMessages,
  type ChatMessage,
} from "./model/conversationChannel.ts";
import { transcriptMessages } from "./model/taskActivity.ts";

const MESSAGE_LIMIT = 24;
const id = z.string().min(1).max(256);

export const prepareInputSchema = z.object({ groupId: id, conversationId: id });

/** A conversation's canonical fields (without its messages) and its last messages, as a window shows them. */
export type PreparedConversation = {
  conversation: CommaConversation;
  messages: ChatMessage[];
};

export function readPreparedConversation(
  ctx: Ctx,
  input: z.output<typeof prepareInputSchema>
): Effect.Effect<PreparedConversation | null, CoreError> {
  return Effect.gen(function* () {
    const account = yield* ctx.session.account();
    const conversation = yield* ctx.api.request(
      account,
      "GET",
      `${route`/v1/comma/groups/${input.groupId}/conversations/${input.conversationId}`}?message_limit=${MESSAGE_LIMIT}`,
      commaConversationSchema
    );
    const raw = conversation.messages ?? [];
    const messages = transcriptMessages(
      normalizeServerMessages(raw, [], conversation.kind, conversation.id)
    );
    if (messages.length === 0 && (conversation.message_count ?? raw.length) > 0)
      return null;
    return { conversation: { ...conversation, messages: [] }, messages };
  });
}
