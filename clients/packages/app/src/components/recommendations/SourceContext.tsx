import type { RecommendationQuoteLine } from "@comma/recommendation-contract";
import { recommendationLinkHrefAttribute } from "./recommendationLinkMenu";

// A quote as the recommendation contract reads it (recommendationSourceQuote):
// one block per source line, a list item hanging off its bullet, and its links
// and Slack mentions as anchors where they may open. Everything is React text.
export function SourceContext({
  lines,
  onOpenUrl,
}: {
  lines: readonly RecommendationQuoteLine[];
  onOpenUrl: (url: string) => void;
}) {
  return (
    <>
      {lines.map((line, index) => (
        <span
          className="comma-recommendation-source-line"
          data-list-item={line.listItem ? "true" : undefined}
          key={index}
        >
          {line.runs.map((run, runIndex) => {
            if (run.kind === "text") return run.text;
            const mention = run.kind === "mention";
            const className =
              "comma-recommendation-inline comma-recommendation-inline-source comma-recommendation-context-link";
            const href = run.href;
            // An anchor, not a button: a button is one box, so a long link would
            // move to its own line and leave the words around it behind.
            return href ? (
              <a
                className={className}
                data-mention={mention || undefined}
                href={href}
                key={runIndex}
                rel="noopener noreferrer"
                target="_blank"
                title={run.title}
                {...{ [recommendationLinkHrefAttribute]: href }}
                onClick={(event) => {
                  event.preventDefault();
                  event.stopPropagation();
                  onOpenUrl(href);
                }}
              >
                {run.text}
              </a>
            ) : (
              <span
                className={className}
                data-mention={mention || undefined}
                key={runIndex}
              >
                {run.text}
              </span>
            );
          })}
        </span>
      ))}
    </>
  );
}
