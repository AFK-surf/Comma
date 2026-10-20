import type { CommaTaskLabelApprovalPolicy } from "@comma/core/api-schemas";

/** The Group's server-owned policy; only a saved human decision grants auto approval. */
export function isLabelProposalPolicy(
  value: unknown
): value is CommaTaskLabelApprovalPolicy {
  return value === "ask" || value === "auto";
}
