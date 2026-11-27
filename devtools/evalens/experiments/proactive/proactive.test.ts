import { describe, expect, test } from "bun:test";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { buildBlindedReviewPayload, renderBlindReviewHtml } from "./blind-review-html";
import { buildShadowDatasetFromSnapshot, redactText } from "./build-shadow-dataset";
import {
  classifyShadowFlip,
  type BlindPairwiseJudgeAnswer,
  type ProactiveObservation,
} from "./contracts";
import { ProactiveEvalItemSchema, type ProactiveEvalItem } from "./dataset";
import {
  fatigueBudgetEvaluator,
  parseBlindJudgeOutput,
  proactiveShadowAggregator,
  proactiveTriageAggregator,
  resolveTwoPassWinner,
  runPositionDebiasedJudge,
  shadowDiffEvaluator,
  triageAccuracyEvaluator,
  unblindPick,
} from "./evaluation";
import { loadRecordedObservations } from "./runner";

function makeObs(overrides: Partial<ProactiveObservation> = {}): ProactiveObservation {
  return {
    itemId: "item-1",
    outcome: "quiet",
    decision: "briefing",
    promptBytes: 4200,
    llmCalls: 1,
    latencyMs: 1200,
    ...overrides,
  };
}

function makeTriageItem(overrides: Partial<ProactiveEvalItem> = {}): ProactiveEvalItem {
  return ProactiveEvalItemSchema.parse({
    id: "case-1",
    input: {
      kind: "triage",
      scenario: {
        context: {
          locale: "en",
          timezone: "Asia/Singapore",
          portraitStatements: ["Maintains HarborQL query planner"],
          home: [],
          knownMatters: [],
          poolItems: [],
        },
        items: [
          {
            itemId: "item-1",
            toolkit: "slack",
            relationship: "mentioned_you",
            title: "Can you approve the release today?",
            excerpt: "We need your sign-off before 5pm.",
            url: "https://slack.example/archives/C1/p1",
            firstSeenAt: "2026-11-25T08:00:00Z",
          },
        ],
      },
    },
    expected: {
      primary: {
        allowedOutcomes: ["routed"],
        allowedDecisions: ["interrupt", "ask"],
        mustSurface: true,
        requiredFacts: ["5pm", "release"],
        forbiddenClaims: ["already shipped"],
      },
    },
    ...overrides,
  });
}

describe("proactive evalens boundary schemas", () => {
  test("rejects malformed dataset items instead of coercing", () => {
    expect(() =>
      ProactiveEvalItemSchema.parse({
        id: "bad-case",
        input: { kind: "triage", scenario: { context: {}, items: [] } },
        expected: {},
      })
    ).toThrow();
  });

  test("rejects malformed blind judge JSON", () => {
    expect(() => parseBlindJudgeOutput("not json at all")).toThrow();
    expect(() =>
      parseBlindJudgeOutput(JSON.stringify({ winner: "C", rationale: "bad" }))
    ).toThrow();
  });

  test("loads valid recorded shadow observations and rejects corrupt payloads", async () => {
    const dir = await mkdtemp(path.join(os.tmpdir(), "proactive-recorded-"));
    const file = path.join(dir, "valid.json");
    const badFile = path.join(dir, "invalid.json");
    await writeFile(
      file,
      JSON.stringify({
        revision: "abc123",
        results: [
          {
            item: { item_id: "evt-1" },
            result: {
              outcome: "routed",
              decision: "signal",
              message: "Build ready",
              research: {
                local: [{ title: "x" }],
                queries: [{ source: "pool", query: "build" }],
              },
              prompt_bytes: 5100,
              llm_calls: 2,
              latency_ms: 980,
            },
          },
        ],
      }),
      "utf8"
    );
    await writeFile(
      badFile,
      JSON.stringify({
        results: [{ item: { item_id: "evt-1" }, result: { outcome: "bogus" } }],
      }),
      "utf8"
    );

    try {
      const loaded = await loadRecordedObservations(file);
      const obs = loaded.get("evt-1");
      expect(obs?.decision).toBe("signal");
      expect(obs?.research?.localMatches).toBe(1);
      expect(obs?.research?.queries).toHaveLength(1);
      await expect(loadRecordedObservations(badFile)).rejects.toThrow();
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
});

describe("proactive triage, counterfactual, and fatigue evaluators", () => {
  test("flags false interrupts and scores factual grounding", () => {
    const quietItem = makeTriageItem({
      id: "noise-1",
      expected: {
        primary: {
          allowedOutcomes: ["quiet"],
          allowedDecisions: ["briefing", "resolved"],
          mustNotInterrupt: true,
          requiredFacts: [],
          forbiddenClaims: [],
        },
      },
    });

    const badRes = triageAccuracyEvaluator.evaluate(quietItem, {
      result: {
        revision: "cand",
        model: "codex",
        observations: [
          makeObs({ outcome: "routed", decision: "interrupt", message: "Urgent!" }),
        ],
      },
      trajectories: [],
    });
    expect(badRes.score.falseInterrupt).toBe(1);
    expect(badRes.score.restraintScore).toBe(0);
    expect(badRes.score.triagePass).toBe(0);

    const goodItem = makeTriageItem();
    const goodRes = triageAccuracyEvaluator.evaluate(goodItem, {
      result: {
        revision: "cand",
        model: "codex",
        observations: [
          makeObs({
            outcome: "routed",
            decision: "interrupt",
            message: "Release approval needed before 5pm.",
          }),
        ],
      },
      trajectories: [],
    });
    expect(goodRes.score.triagePass).toBe(1);
    expect(goodRes.score.factGrounding).toBe(1);
    expect(goodRes.score.forbiddenClaimFree).toBe(1);
  });

  test("requires counterfactual pairs to flip decisions cleanly", () => {
    const baseScenario = makeTriageItem().input;
    if (baseScenario.kind !== "triage") throw new Error("unexpected");
    const cfItem = ProactiveEvalItemSchema.parse({
      id: "cf-1",
      input: {
        kind: "counterfactual_pair",
        base: baseScenario.scenario,
        variant: {
          ...baseScenario.scenario,
          context: {
            ...baseScenario.scenario.context,
            portraitStatements: ["No longer works on HarborQL"],
          },
        },
        mutationNote: "Owner exclusion removes responsibility",
      },
      expected: {
        primary: { allowedOutcomes: ["routed"], allowedDecisions: ["interrupt"] },
        variant: {
          allowedOutcomes: ["quiet"],
          allowedDecisions: ["briefing"],
          mustNotInterrupt: true,
        },
        counterfactualMustFlip: true,
      },
    });

    const passRes = triageAccuracyEvaluator.evaluate(cfItem, {
      result: {
        revision: "cand",
        model: "codex",
        observations: [makeObs({ outcome: "routed", decision: "interrupt" })],
        variantObservations: [makeObs({ outcome: "quiet", decision: "briefing" })],
      },
      trajectories: [],
    });
    expect(passRes.score.counterfactualFlip).toBe(1);
    expect(passRes.score.triagePass).toBe(1);

    const agg = proactiveTriageAggregator.aggregate({
      "triage-accuracy": [{ itemId: "cf-1", ...passRes }],
      "fatigue-budget": [
        {
          itemId: "cf-1",
          ...fatigueBudgetEvaluator.evaluate(cfItem, {
            result: {
              revision: "cand",
              model: "codex",
              observations: [makeObs({ outcome: "routed", decision: "interrupt" })],
            },
            trajectories: [],
          }),
        },
      ],
    });
    expect(agg.triagePassRate).toBe(1);
    expect(agg.counterfactualFlipRate).toBe(1);
  });

  test("enforces multi-day stream interrupt and duplicate budgets", () => {
    const streamItem = ProactiveEvalItemSchema.parse({
      id: "stream-48h",
      input: {
        kind: "day_stream",
        windowHours: 48,
        scenario: {
          context: { locale: "en", timezone: "UTC", portraitStatements: [] },
          items: [
            {
              itemId: "s1",
              toolkit: "slack",
              relationship: "mentioned_you",
              title: "Deploy blocked",
              url: "https://slack.example/1",
              firstSeenAt: "2026-11-24T09:00:00Z",
            },
            {
              itemId: "s2",
              toolkit: "slack",
              relationship: "mentioned_you",
              title: "Deploy blocked",
              url: "https://slack.example/2",
              firstSeenAt: "2026-11-24T10:00:00Z",
            },
          ],
        },
      },
      expected: {
        maxDailyInterrupts: 1,
        maxDuplicateAlerts: 0,
      },
    });

    const evalRes = fatigueBudgetEvaluator.evaluate(streamItem, {
      result: {
        revision: "cand",
        model: "codex",
        observations: [
          makeObs({ itemId: "s1", outcome: "routed", decision: "interrupt" }),
          makeObs({ itemId: "s2", outcome: "routed", decision: "interrupt" }),
        ],
      },
      trajectories: [],
    });
    expect(evalRes.score.dailyInterrupts).toBe(1);
    expect(evalRes.score.duplicateAlerts).toBe(1);
    expect(evalRes.score.fatiguePass).toBe(0);
  });
});

describe("shadow diff, position-debiased blind A/B judge, and HTML review", () => {
  test("classifies shadow flips accurately", () => {
    expect(classifyShadowFlip(makeObs(), makeObs())).toBe("both_quiet");
    expect(
      classifyShadowFlip(makeObs(), makeObs({ outcome: "routed", decision: "signal" }))
    ).toBe("newly_surfaced");
    expect(
      classifyShadowFlip(
        makeObs({ outcome: "routed", decision: "interrupt" }),
        makeObs()
      )
    ).toBe("newly_silenced");
    expect(
      classifyShadowFlip(
        makeObs({ outcome: "routed", decision: "interrupt" }),
        makeObs({ outcome: "routed", decision: "signal" })
      )
    ).toBe("tier_changed");
  });

  test("unblinds two-pass swapped blind judge and flags position bias as tie", async () => {
    expect(unblindPick("A", true)).toBe("candidate");
    expect(unblindPick("A", false)).toBe("baseline");
    expect(resolveTwoPassWinner("candidate", "candidate")).toEqual({
      winner: "candidate",
      consistent: true,
    });
    expect(resolveTwoPassWinner("candidate", "baseline")).toEqual({
      winner: "tie",
      consistent: false,
    });

    const src = makeTriageItem().input;
    if (src.kind !== "triage") throw new Error("unexpected");
    const sourceItem = src.scenario.items[0]!;

    // Judge that always prefers whichever system delivered the richer message
    const contentJudge = async (task: string): Promise<BlindPairwiseJudgeAnswer> => {
      const aPart = task.split("SYSTEM A:")[1]?.split("SYSTEM B:")[0] ?? "";
      const pick = aPart.includes("PR #42") ? "A" : "B";
      return {
        winner: pick,
        confidence: "high",
        scores: {
          restraint: "tie",
          insightValue: pick,
          grounding: pick,
          actionability: pick,
        },
        rationale: "Includes linked PR context.",
      };
    };

    const result = await runPositionDebiasedJudge({
      itemId: "item-1",
      sourceItem,
      portraitSummary: "Maintains HarborQL",
      baseline: makeObs({ outcome: "quiet", decision: "briefing" }),
      candidate: makeObs({
        outcome: "routed",
        decision: "signal",
        message: "PR #42 merged for HarborQL.",
      }),
      swapPasses: true,
      runJudge: contentJudge,
    });

    expect(result.winner).toBe("candidate");
    expect(result.consistent).toBe(true);
    expect(result.dimensions.insightValue).toBe("candidate");

    // Position-biased judge that always picks "A" collapses to inconsistent tie
    const biasedResult = await runPositionDebiasedJudge({
      itemId: "item-1",
      sourceItem,
      portraitSummary: "",
      baseline: makeObs(),
      candidate: makeObs({ outcome: "routed", decision: "signal", message: "hi" }),
      swapPasses: true,
      runJudge: async () => ({
        winner: "A",
        confidence: "low",
        scores: {
          restraint: "A",
          insightValue: "A",
          grounding: "A",
          actionability: "A",
        },
        rationale: "Always A",
      }),
    });
    expect(biasedResult.winner).toBe("tie");
    expect(biasedResult.consistent).toBe(false);
  });

  test("aggregates shadow scorecard and renders safe blind review HTML", () => {
    const item = makeTriageItem();
    const diffOut = shadowDiffEvaluator.evaluate(item, {
      result: {
        baselineRevision: "base",
        candidateRevision: "cand",
        model: "codex",
        baseline: makeObs({ promptBytes: 4000 }),
        candidate: makeObs({
          outcome: "routed",
          decision: "signal",
          message: "Ready </script><script>alert(1)</script>",
          promptBytes: 4800,
        }),
      },
      trajectories: [],
    });

    const scorecard = proactiveShadowAggregator.aggregate({
      "shadow-diff": [{ itemId: "case-1", ...diffOut }],
      "blind-pairwise-judge": [
        {
          itemId: "case-1",
          score: {
            judged: 1,
            candidateWin: 1,
            swapConsistent: 1,
            restraintWin: 0.5,
            insightWin: 1,
            groundingWin: 1,
            actionabilityWin: 1,
          },
          explanation: "winner=candidate",
        },
      ],
    });
    expect(scorecard.newlySurfacedCount).toBe(1);
    expect(scorecard.blindPairwiseWinRateExclTies).toBe(1);
    expect(scorecard.avgPromptBytesDelta).toBe(800);

    const src = item.input;
    if (src.kind !== "triage") throw new Error("unexpected");
    const cards = buildBlindedReviewPayload([
      {
        id: "case-1",
        sourceItem: src.scenario.items[0]!,
        baseline: makeObs(),
        candidate: makeObs({
          outcome: "routed",
          decision: "signal",
          message: "Ready </script><script>alert(1)</script>",
        }),
      },
    ]);
    expect(cards).toHaveLength(1);

    const html = renderBlindReviewHtml(
      {
        baselineRevision: "base",
        candidateRevision: "cand",
        model: "codex",
        totalItems: 1,
        baselineRouted: 0,
        candidateRouted: 1,
        candidateWins: 1,
        baselineWins: 0,
        ties: 0,
        swapConsistencyPct: 100,
      },
      [
        {
          id: "case-1",
          sourceItem: src.scenario.items[0]!,
          baseline: makeObs(),
          candidate: makeObs({
            outcome: "routed",
            decision: "signal",
            message: "Ready </script><script>alert(1)</script>",
          }),
        },
      ]
    );
    expect(html).not.toContain("</script><script>");
    expect(html).toContain("<\\/script>");
  });

  test("builds temporally isolated and optionally redacted Evalens datasets from Staging snapshots", () => {
    expect(redactText("Reach alice@example.com with code 965514")).toBe(
      "Reach [redacted-email] with code [redacted-code]"
    );

    const dataset = buildShadowDatasetFromSnapshot(
      {
        exported_at: "2026-11-25T15:00:00Z",
        profile: { locale: "en", timezone: "Asia/Singapore" },
        portrait_statements: [{ text: "Owner email alice@example.com" }],
        home: [
          {
            from: "user",
            text: "Earlier note",
            created_at: Date.parse("2026-11-25T07:00:00Z"),
          },
          {
            from: "user",
            text: "Future note",
            created_at: Date.parse("2026-11-25T12:00:00Z"),
          },
        ],
        known_matters: [],
        selected_items: [
          {
            id: "evt-100",
            toolkit: "gmail",
            relationship: "awaiting_your_reply",
            title: "Code 965514 for alice@example.com",
            excerpt: "Expires soon",
            url: "https://mail.example/100",
            first_seen_at: "2026-11-25T09:00:00Z",
          },
        ],
        pool_items: [
          {
            id: "pool-past",
            toolkit: "slack",
            relationship: "mentioned_you",
            title: "Past thread",
            excerpt: "Prior context",
            url: "https://slack.example/past",
            first_seen_at: "2026-11-25T08:00:00Z",
          },
          {
            id: "pool-future",
            toolkit: "slack",
            relationship: "mentioned_you",
            title: "Future thread",
            excerpt: "Should be excluded",
            url: "https://slack.example/future",
            first_seen_at: "2026-11-25T11:00:00Z",
          },
        ],
      },
      { name: "proactive-test-v1", redact: true }
    );

    expect(dataset.items).toHaveLength(1);
    const first = dataset.items[0]!;
    if (first.input.kind !== "shadow_diff") throw new Error("unexpected kind");
    expect(first.input.scenario.items[0]?.title).toBe(
      "Code [redacted-code] for [redacted-email]"
    );
    expect(first.input.scenario.context.home.map((m) => m.text)).toEqual([
      "Earlier note",
    ]);
    expect(first.input.scenario.context.poolItems.map((p) => p.itemId)).toEqual([
      "pool-past",
    ]);
  });
});
