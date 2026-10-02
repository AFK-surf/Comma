import { describe, expect, it, vi } from "vitest";
import {
  createBftApi,
  triageActivitySchema,
  type BftTriageHeatmap,
  type BftTriageKnowledge,
  type BftTriageOutcome,
  type BftTriageSource,
} from "../src/api";
import {
  activityCounts,
  canSwitch,
  effectSummary,
  heatmapView,
  knowledgeCounts,
  outcomeLabel,
  outcomeTone,
  sourceNotices,
  threadGroups,
} from "../src/triageModel";

const source = (extra: Partial<BftTriageSource> = {}): BftTriageSource => ({
  connect_id: "c-1",
  bot_name: "Support Assistant",
  bot_username: "support",
  workspace_name: "Acme",
  complete: true,
  enabled: false,
  authority_valid: true,
  channel_scope_complete: true,
  channel_controls: true,
  channels: [{ id: "C1", name: "support", enabled: true }],
  ...extra,
});

const outcome = (extra: Partial<BftTriageOutcome> = {}): BftTriageOutcome => ({
  kind: "outcome",
  id: "o-1",
  obligation_id: null,
  at: 1_000,
  updated_at: 2_000,
  state: "applied",
  attempts: 1,
  source: {
    connect_id: "c-1",
    channel_id: "C1",
    thread_ts: "1700000000.000100",
    message_count: 1,
    latest_activity_at_ms: null,
    url: null,
  },
  messages: [],
  communication: {
    kind: "reply",
    reason: null,
    status: "delivered",
    text: "Done",
    emoji: null,
    explanation: null,
  },
  effect: { adapter: "slack", status: "delivered", external_writes: 1 },
  companion: null,
  evidence: {},
  context: {},
  related_context: [],
  delegations: [],
  ...extra,
});

describe("Slack sources", () => {
  it("only enables a complete, valid source with a channel; disabling is always safe", () => {
    expect(canSwitch(source())).toBe(true);
    expect(canSwitch(source({ channels: [] }))).toBe(false);
    expect(canSwitch(source({ authority_valid: false }))).toBe(false);
    expect(canSwitch(source({ complete: false, enabled: true }))).toBe(true);
  });

  it("says why channel controls are limited", () => {
    expect(sourceNotices(source())).toEqual([]);
    expect(sourceNotices(source({ complete: false, enabled: true }))[0]).toMatch(
      /still turn Triage off safely/
    );
    expect(sourceNotices(source({ channel_scope_complete: false }))[0]).toMatch(
      /could not be read completely/
    );
    expect(sourceNotices(source({ channel_controls: false }))[0]).toMatch(
      /Per-channel controls will become available/
    );
  });
});

describe("Timeline outcomes", () => {
  it("names the decision and its unsettled or failed companion reaction", () => {
    expect(outcomeLabel(outcome())).toBe("Reply delivered");
    const pending = outcome({
      companion: {
        kind: "reaction",
        emoji: "eyes",
        state: "pending",
        external_writes: 0,
      },
    });
    expect(outcomeLabel(pending)).toBe("Reply delivered · Reaction in progress");
    expect(outcomeTone(pending)).toBeUndefined();
    expect(
      outcomeLabel(outcome({ companion: { ...pending.companion!, state: "failed" } }))
    ).toBe("Reply delivered · reaction failed");
    expect(
      outcomeLabel(
        outcome({ effect: { adapter: "audit_sink", status: null, external_writes: 0 } })
      )
    ).toBe("Would reply");
  });

  it("does not count a Worker assignment as a final silence", () => {
    const assigned = outcome({
      communication: {
        ...outcome().communication,
        kind: "silence",
        reason: "worker_pending",
      },
    });
    expect(outcomeLabel(assigned)).toBe("Assigned to Worker");
    expect(activityCounts([assigned]).silence).toBe(0);
  });

  it("summarizes context and delegation effects without calling a proposal created", () => {
    const item = outcome({
      context: { candidates: 2 },
      delegations: [
        { index: 0, status: "created", task: "Check" },
        { index: 1, status: "proposed", task: "Ask" },
      ],
    });
    expect(effectSummary(item)).toBe(
      "2 context effects · 1 worker task created · 1 worker task proposed"
    );
  });

  it("groups a page by exact Slack thread and keeps unknown sources apart", () => {
    const names = new Map([["c-1/C1", "#support"]]);
    const later = outcome({ id: "o-2", at: 5_000 });
    const other = outcome({
      id: "o-3",
      source: { ...outcome().source, thread_ts: "1700000001.0" },
    });
    const unknown = (id: string) =>
      outcome({ id, source: { ...outcome().source, thread_ts: null } });
    const threads = threadGroups(
      [later, other, outcome(), unknown("u-1"), unknown("u-2")],
      names
    );
    expect(threads).toHaveLength(4);
    expect(threads[0]?.rows.map((row) => row.id)).toEqual(["o-1", "o-2"]);
    expect(threads[0]?.channel).toBe("#support");
  });

  it("drops fields outside the contract and parses unknown states leniently", () => {
    const page = triageActivitySchema.parse({
      items: [{ ...outcome(), state: "brand-new", run_id: "internal" }],
      next_cursor: null,
      intake_status: "weird",
      follow_ups: "broken",
      context: [],
    });
    expect(page.intake_status).toBe("unavailable");
    expect(page.follow_ups).toBeNull();
    expect(page.items[0]).not.toHaveProperty("run_id");
  });
});

describe("heatmap", () => {
  const hour = 3_600_000;
  const cell = (
    channel: string,
    offset: number,
    counts: Partial<BftTriageHeatmap["cells"][number]>
  ) => ({
    connect_id: "c-1",
    channel_id: channel,
    at_ms: offset * hour,
    reply: 0,
    reaction: 0,
    silence: 0,
    total: 0,
    ...counts,
  });
  const heatmap: BftTriageHeatmap = {
    since_ms: 0,
    truncated: false,
    cells: [
      cell("C1", 0, { silence: 3, total: 3 }),
      cell("C1", 1, { reply: 1, total: 1 }),
      cell("C-OTHER", 30, { silence: 1, total: 1 }),
      cell("C1", 165, { silence: 2, total: 2 }),
    ],
  };
  const names = new Map([["c-1/C1", "#support"]]);

  it("opens on the last day when it has activity, and only counts that window", () => {
    const view = heatmapView(heatmap, names, null, false);
    expect(view?.range).toBe("24h");
    expect(view?.rows.map((row) => [row.label, row.total, row.silentPercent])).toEqual([
      ["#support", 2, 100],
    ]);
  });

  it("groups 7 days into 6-hour cells; channels outside the Agent cannot filter", () => {
    const view = heatmapView(heatmap, names, "7d", false);
    const support = view?.rows.find((row) => row.channel === "C1");
    expect([support?.total, support?.replied, support?.silentPercent]).toEqual([
      6, 1, 83,
    ]);
    expect(support?.cells[0]).toMatchObject({
      start: 0,
      end: 6 * hour,
      total: 4,
      acted: true,
    });
    expect(view?.rows.find((row) => row.channel === "C-OTHER")?.filterable).toBe(false);
  });
});

describe("Knowledge counts", () => {
  it("counts a member once, with sourced subjects, decisions and retained context", () => {
    const knowledge = {
      status: "ok",
      assertions: [
        {
          id: "a1",
          kind: "decision",
          content: "Ship",
          observed_at: null,
          source: { type: "slack_receipt", ref: "s3://r" },
          subjects: [
            { kind: "person", id: "u1", name: "Maya" },
            { kind: "project", id: "p1", name: "Bridge" },
          ],
          uses: [],
        },
      ],
      members: [{ id: "u1", name: "Maya", role: "admin", source_ref: null }],
      retained: [
        {
          id: "r1",
          kind: "decision",
          name: "Owner",
          content: "Dana",
          confidence: null,
          source_count: 1,
          updated_at_ms: null,
        },
        {
          id: "r2",
          kind: "context",
          name: "Hours",
          content: "P1",
          confidence: null,
          source_count: 1,
          updated_at_ms: null,
        },
      ],
      usage: "available",
      usage_complete: true,
      retained_status: "available",
      incomplete: false,
      imported: { status: "off", grounding: false, items: [] },
    } satisfies BftTriageKnowledge;
    expect(knowledgeCounts(knowledge)).toEqual({
      person: 1,
      project: 1,
      decision: 2,
      context: 1,
    });
  });
});

describe("Slack triage API", () => {
  it("reveals message text with the Timeline page, CSRF token and agent", async () => {
    const fetch = vi.fn<typeof globalThis.fetch>(
      async () =>
        new Response(
          JSON.stringify({
            ok: true,
            data: {
              messages: {
                r1: { speaker: "Dana", parts: [{ kind: "text", text: "Hi" }] },
              },
            },
          }),
          { status: 200 }
        )
    );
    const api = createBftApi({ fetch, csrfToken: () => "token" });
    const nav = { kind: "all", channel: "C1", before: null, cursor: "c2" };
    const messages = await api.revealTriageText("acme", "agt", ["r1"], nav);
    expect(messages.r1?.parts).toEqual([{ kind: "text", text: "Hi", url: null }]);
    const [url, init] = fetch.mock.calls[0] ?? [];
    expect(url).toBe("/dashboard/api/v1/orgs/acme/triage/reveal");
    expect(init?.method).toBe("POST");
    expect(init?.headers).toMatchObject({ "x-csrf-token": "token" });
    expect(JSON.parse(String(init?.body))).toEqual({
      agent: "agt",
      refs: ["r1"],
      activity: nav,
    });
  });
});
