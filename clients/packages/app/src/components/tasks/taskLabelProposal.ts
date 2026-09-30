import type { CommaTaskLabelProposal } from "../../api";

/** New proposals contain a batch; previously saved single-label proposals remain readable. */
export function taskLabelProposalLabels(proposal: CommaTaskLabelProposal) {
  const { payload } = proposal;
  if (payload.labels) return payload.labels;
  return [
    {
      name: typeof payload["name"] === "string" ? payload["name"] : "",
      color: typeof payload["color"] === "string" ? payload["color"] : undefined,
      description:
        typeof payload["description"] === "string" ? payload["description"] : undefined,
    },
  ];
}
