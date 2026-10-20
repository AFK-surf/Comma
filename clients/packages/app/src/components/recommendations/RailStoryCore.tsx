import { CoreClient, CoreProvider } from "@comma/core-client";
import type { LinkPreview } from "@comma/core/contract";
import type { RecommendationEnvelope } from "@comma/recommendation-contract";
import { useState, type ReactNode } from "react";

/**
 * A core for stories: the rail's briefing is `envelope` (none: still loading), a hovered link's preview is
 * `previewOf(href)` (none: the generic card), and a refresh is accepted.
 */
export function RailStoryCore({
  children,
  envelope,
  previewOf,
}: {
  children: ReactNode;
  envelope?: RecommendationEnvelope | undefined;
  previewOf?: ((href: string) => LinkPreview | undefined) | undefined;
}) {
  const [client] = useState(
    () =>
      new CoreClient(
        (onMessage) => ({
          post(raw) {
            const message = raw as {
              id: number;
              call?: string;
              subscribe?: { topic: string; workspace?: string; href?: string };
            };
            const answer = (data: unknown) => queueMicrotask(() => onMessage(data));
            if (message.subscribe?.topic === "recommendations" && envelope)
              answer({
                id: message.id,
                value: {
                  workspace: message.subscribe.workspace ?? null,
                  envelope,
                  failure: null,
                  discovering: false,
                  refreshing: false,
                },
              });
            else if (message.subscribe?.topic === "linkPreview") {
              const preview = previewOf?.(message.subscribe.href ?? "");
              answer({
                id: message.id,
                value: preview ? { status: "ready", preview } : { status: "missing" },
              });
            } else if (message.call)
              answer({
                id: message.id,
                ok:
                  message.call === "recommendations.refresh"
                    ? { rateLimited: false }
                    : null,
              });
          },
          close() {},
        }),
        { schedule: () => undefined }
      )
  );
  return <CoreProvider client={client}>{children}</CoreProvider>;
}
