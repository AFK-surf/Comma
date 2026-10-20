// The recommendations API a Routine briefing reads, for
// e2e/app-shell/recommendations.chromium.test.ts: what each test's
// Playwright scenario answered with `page.route`, here the stub's, on world
// time. A test picks its scenario (`setRecommendations`) before its page opens
// and reads back what the app asked (`recommendationCalls`).
import type { IncomingMessage, ServerResponse } from "node:http";
import { chatSmokeWorkspace } from "../../../../p0/chat-stub";
import {
  customProviderSource,
  oldMockEnvelope,
  settings,
  source,
} from "./recommendations-data";

type Scenario =
  /** A refresh is refused: the next read is the canonical empty state. */
  | { name: "rejected-refresh" }
  /** A refresh starts; every read says the Routine credits are exhausted. */
  | { name: "no-credits" }
  /** The first refresh fails, the second cannot be read, the third is refused. */
  | { name: "fallback" }
  /** Reads answer the empty state; the app's queries are kept. */
  | { name: "empty" }
  /** Two workspaces; relevance and proactive messages are the settings to change. */
  | { name: "proactive" }
  /** Every read answers `envelope`. */
  | { name: "fixed"; envelope: unknown };

const json = (response: ServerResponse, body: unknown, status = 200) => {
  response.writeHead(status, { "content-type": "application/json" });
  response.end(JSON.stringify(body));
};
const read = async (request: IncomingMessage) => {
  const chunks: Buffer[] = [];
  for await (const chunk of request) chunks.push(chunk as Buffer);
  const text = Buffer.concat(chunks).toString();
  return text ? (JSON.parse(text) as Record<string, unknown>) : {};
};

/** The briefing that shows the custom provider's own logo on one card. */
export const envelopeWithCustomProviderLogo = {
  ...oldMockEnvelope,
  settings: { ...oldMockEnvelope.settings, sources: [source, customProviderSource] },
  snapshot: {
    ...oldMockEnvelope.snapshot,
    cards: oldMockEnvelope.snapshot.cards.map((card) =>
      card.id === "additional-mock-card-1"
        ? { ...card, sourceIds: [customProviderSource.connectionId] }
        : card
    ),
  },
};

export function recommendationsRoutes() {
  let scenario: Scenario = { name: "empty" };
  const calls = {
    refreshes: 0,
    reads: 0,
    readFailures: 0,
    queries: [] as string[],
    proactiveWrites: [] as { path: string; body: unknown }[],
    proactiveReads: [] as string[],
  };
  let relevanceMode = "member";
  let proactiveEnabled = true;
  const recommendations = `/v1/comma/workspaces/${chatSmokeWorkspace.id}/recommendations`;

  async function handle(request: IncomingMessage, url: URL, response: ServerResponse) {
    const method = request.method ?? "GET";
    if (scenario.name === "proactive") {
      if (url.pathname === "/v1/comma/workspaces" && method === "GET") {
        json(response, {
          data: [
            { group_id: "grp-first", id: "ws-first", name: "First workspace" },
            { group_id: "grp-active", id: "ws-active", name: "Active workspace" },
          ],
        });
        return true;
      }
      if (/^\/v1\/comma\/workspaces\/[^/]+\/recommendations/.test(url.pathname)) {
        if (method === "PATCH")
          relevanceMode = String((await read(request)).relevanceMode);
        json(response, {
          settings: { ...settings, relevanceMode },
          snapshot: null,
          state: "empty",
        });
        return true;
      }
      if (/^\/v1\/comma\/groups\/[^/]+\/proactive$/.test(url.pathname)) {
        if (method === "PUT") {
          const body = await read(request);
          calls.proactiveWrites.push({ path: url.pathname, body });
          proactiveEnabled = Boolean(body.enabled);
        } else calls.proactiveReads.push(url.pathname);
        json(response, { enabled: proactiveEnabled });
        return true;
      }
      return false;
    }
    if (!url.pathname.startsWith(recommendations)) return false;
    const refresh = method === "POST" && url.pathname.endsWith("/refresh");
    switch (scenario.name) {
      case "rejected-refresh":
        if (refresh) {
          calls.refreshes += 1;
          json(response, { error: "no_recommendation_sources" }, 409);
          return true;
        }
        if (method !== "GET") return false;
        json(
          response,
          calls.refreshes > 0
            ? {
                settings: { ...settings, sourceRevision: 2, sources: [] },
                snapshot: null,
                state: "empty",
              }
            : envelopeWithCustomProviderLogo
        );
        return true;
      case "no-credits":
        if (method === "POST") {
          calls.refreshes += 1;
          json(
            response,
            {
              envelope: { settings, snapshot: null, state: "refreshing" },
              run: {
                id: "rrn_no_credits",
                generation: 2,
                sourceRevision: settings.sourceRevision,
                status: "pending",
                trigger: "manual",
              },
            },
            202
          );
          return true;
        }
        calls.reads += 1;
        json(response, {
          settings,
          snapshot: null,
          state: "error",
          lastError: "insufficient_credits",
        });
        return true;
      case "fallback":
        if (refresh) {
          calls.refreshes += 1;
          if (calls.refreshes === 1)
            json(response, {
              envelope: { ...oldMockEnvelope, state: "stale", lastError: "failed" },
              run: {
                id: "rrn_failed",
                generation: 2,
                sourceRevision: 1,
                status: "failed",
                trigger: "manual",
              },
            });
          else if (calls.refreshes === 2)
            json(response, { error: "temporarily_unavailable" }, 503);
          else json(response, { error: "member_identity_required" }, 409);
          return true;
        }
        if (method !== "GET") return false;
        if (calls.refreshes === 2) {
          calls.readFailures += 1;
          json(response, { error: "temporarily_unavailable" }, 503);
        } else
          json(
            response,
            calls.refreshes >= 3
              ? {
                  settings,
                  state: "error",
                  snapshot: null,
                  lastError: "member_identity_required",
                }
              : oldMockEnvelope
          );
        return true;
      case "empty":
        if (method !== "GET") return false;
        calls.queries.push(url.search);
        json(response, { settings, snapshot: null, state: "empty" });
        return true;
      case "fixed":
        if (method !== "GET") return false;
        json(response, scenario.envelope);
        return true;
    }
  }

  return {
    handle,
    calls: {
      setRecommendations: (next: Scenario) => {
        scenario = next;
      },
      recommendationCalls: () => structuredClone(calls),
    },
  };
}
