import {
  productInboxListInputSchema,
  productInboxSnapshotSchema,
  salixConversationSchema,
  salixPageSchema,
  salixWorkspaceSchema,
} from "@comma/native-bridge";
import {
  sessionBoundStateEnvelopeSchema,
  type SessionBoundStateEnvelope,
} from "@comma/session-contract";
import { z } from "zod";

/**
 * Comma's public Workspace and Conversation resources contain more fields than
 * ProductInbox owns. Accept additive public fields at this HTTP boundary, then
 * strip every field outside the ProductInbox allowlist before the response can
 * enter local data or the renderer projection. The runtime separately rejects
 * any response that reflects the exact bearer credential.
 */
const salixProductWorkspaceWireSchema = salixWorkspaceSchema.strip();
export const salixProductConversationWireSchema = salixConversationSchema
  .extend({
    freshness: z
      .object({
        state: z.enum(["fresh", "stale", "unknown"]),
      })
      .strip()
      .optional(),
  })
  .strip();

export const salixProductWorkspacePageSchema = salixPageSchema(
  salixProductWorkspaceWireSchema
);
export const salixProductConversationPageSchema = salixPageSchema(
  salixProductConversationWireSchema
);

export const productInboxStateEnvelopeSchema = sessionBoundStateEnvelopeSchema(
  productInboxSnapshotSchema
);
export const productInboxRefreshInputSchema = productInboxListInputSchema;
export const productInboxDemandInputSchema = productInboxListInputSchema.pick({
  session: true,
});

export type SalixProductWorkspace = z.output<typeof salixWorkspaceSchema>;
export type SalixProductConversation = z.output<typeof salixConversationSchema>;
export type SalixProductWorkspacePage = z.output<
  typeof salixProductWorkspacePageSchema
>;
export type SalixProductConversationPage = z.output<
  typeof salixProductConversationPageSchema
>;
export type ProductInboxSnapshot = z.output<typeof productInboxSnapshotSchema>;
export type ProductInboxRefreshInput = z.output<typeof productInboxRefreshInputSchema>;
export type ProductInboxDemandInput = z.output<typeof productInboxDemandInputSchema>;
export type ProductInboxStateEnvelope = SessionBoundStateEnvelope<ProductInboxSnapshot>;
