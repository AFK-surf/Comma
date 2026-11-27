import { describe, expect, test } from "bun:test";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import {
  buildBlindedCftReviewPayload,
  renderCftBlindReviewHtml,
} from "./blind-review-html";
import {
  buildCftTriageDatasetFromSnapshot,
  diversifyCftDatasetItems,
  redactCftText,
} from "./build-cft-triage-dataset";
import {
  CftTriageObservationSchema,
  classifyCftShadowFlip,
  type CftTriageObservation,
} from "./contracts";
import {
  CftTriageEvalItemSchema,
  extractCftDiversityKeys,
  normalizeTemplateSkeleton,
  type CftScenarioPayload,
  type CftTriageEvalItem,
} from "./dataset";
import {
  cftParticipationEvaluator,
  cftShadowAggregator,
  cftShadowDiffEvaluator,
  cftTriageAggregator,
  deterministicCftAIsCandidate,
  formatCftScenarioForJudge,
  parseCftBlindJudgeOutput,
  resolveTwoPassCftWinner,
  runCftPositionDebiasedJudge,
  scoreCftBranchExpectation,
} from "./evaluation";
import { loadRecordedCftObservations } from "./runner";

function makeObs(
  overrides: Partial<CftTriageObservation> & { itemId: string }
): CftTriageObservation {
  return CftTriageObservationSchema.parse({
    layer: "worker_participation",
    communicationKind: "silence",
    silenceReason: "no_useful_addition",
    delegationCount: 0,
    delegationTasks: [],
    contextCandidates: [],
    validationPassed: true,
    promptBytes: 4200,
    llmCalls: 1,
    latencyMs: 950,
    ...overrides,
  });
}

function makeWorkerPayload(
  itemId: string,
  text: string,
  extra?: Partial<
    Extract<CftScenarioPayload, { layer: "worker_participation" }>["worker"]
  >
): CftScenarioPayload {
  return {
    layer: "worker_participation",
    worker: {
      itemId,
      channelId: "C_ENG",
      threadTs: "1795600000.000100",
      targetRoute: "none",
      isRecheck: false,
      recheckContextRefs: [],
      messages: [
        {
          messageTs: "1795600000.000100",
          actorKind: "human",
          text,
          sourceRef: `slack://T1/C_ENG/1795600000.000100/1795600000.000100`,
        },
      ],
      contextSources: [],
      workspaceFindings: [],
      ...extra,
    },
  };
}

describe("cft-triage contracts and flip classification", () => {
  test("rejects malformed observation payload at Zod boundary", () => {
    expect(() =>
      CftTriageObservationSchema.parse({
        itemId: "x1",
        layer: "worker_participation",
        communicationKind: "invalid_kind",
        promptBytes: 100,
        llmCalls: 1,
        latencyMs: 50,
      })
    ).toThrow();
  });

  test("classifies shadow flips across silence, intervention, delegation, and follow-up", () => {
    const silent = makeObs({ itemId: "i1", communicationKind: "silence" });
    const replied = makeObs({
      itemId: "i1",
      communicationKind: "reply",
      silenceReason: undefined,
      replyText: "PR #5727 merged.",
    });
    const reacted = makeObs({
      itemId: "i1",
      communicationKind: "reaction",
      silenceReason: undefined,
      reactionEmoji: "eyes",
    });
    const delegated = makeObs({
      itemId: "i1",
      layer: "native_evaluator",
      communicationKind: "silence",
      silenceReason: "insufficient_evidence",
      delegationCount: 1,
      delegationTasks: ["Check GCP alert status"],
    });
    const silentWithFollowUp = makeObs({
      itemId: "i1",
      communicationKind: "silence",
      contextCandidates: [
        {
          kind: "follow_up",
          subject: "Alert check",
          value: "Recheck alert in 1h",
          confidence: "explicit",
          followUpBasis: "agent_owned",
          recheckAfterHours: 1,
        },
      ],
    });

    expect(classifyCftShadowFlip(silent, silent)).toBe("both_silent_no_delegation");
    expect(classifyCftShadowFlip(silent, replied)).toBe("newly_intervened");
    expect(classifyCftShadowFlip(replied, silent)).toBe("newly_silenced");
    expect(classifyCftShadowFlip(delegated, silent)).toBe("newly_silenced");
    expect(classifyCftShadowFlip(replied, reacted)).toBe("communication_changed");
    expect(classifyCftShadowFlip(silentWithFollowUp, silent)).toBe("follow_up_changed");
    expect(
      classifyCftShadowFlip(
        delegated,
        makeObs({
          itemId: "i1",
          layer: "native_evaluator",
          communicationKind: "silence",
          silenceReason: "insufficient_evidence",
          delegationCount: 2,
          delegationTasks: ["a", "b"],
        })
      )
    ).toBe("delegation_changed");
    expect(classifyCftShadowFlip(replied, replied)).toBe("same_action_copy_diff");
  });
});

describe("cft-triage participation evaluator", () => {
  test("flags false intervention and forbidden follow-up on unaddressed alert", () => {
    const obs = makeObs({
      itemId: "alert_1",
      communicationKind: "reply",
      silenceReason: undefined,
      replyText: "Please share GCP logs access so I can check this alert.",
      contextCandidates: [
        {
          kind: "follow_up",
          subject: "GCP alert",
          value: "Recheck logs later",
          confidence: "explicit",
          followUpBasis: "agent_owned",
          recheckAfterHours: 1,
        },
      ],
    });

    const scored = scoreCftBranchExpectation(obs, {
      allowedCommunications: ["silence"],
      mustStaySilent: true,
      forbidFollowUp: true,
      requiredFacts: [],
      forbiddenClaims: ["GCP logs access"],
    });

    expect(scored.pass).toBe(0);
    expect(scored.falseIntervention).toBe(1);
    expect(scored.followUpCompliant).toBe(0);
    expect(scored.forbiddenClaimFree).toBe(0);
  });

  test("scores counterfactual_pair flip and aggregates restraint + recall", () => {
    const item: CftTriageEvalItem = CftTriageEvalItemSchema.parse({
      id: "cf_answered_after",
      input: {
        kind: "counterfactual_pair",
        mutationNote: "Teammate answers in channel_context.after",
        base: makeWorkerPayload("cf_base", "enterprise的还不能用了么？", {
          workspaceFindings: [
            { source: "slack", summary: "PR #6548 landed for Gemini Enterprise" },
          ],
        }),
        variant: makeWorkerPayload("cf_var", "enterprise的还不能用了么？", {
          channelContext: {
            before: [],
            after: [
              {
                actorKind: "human",
                text: "能用了，#6548 已经合了",
              },
            ],
          },
        }),
      },
      expected: {
        primary: {
          allowedCommunications: ["reply"],
          mustAct: true,
          requiredFacts: ["6548"],
          forbiddenClaims: [],
        },
        variant: {
          allowedCommunications: ["silence"],
          allowedSilenceReasons: ["already_handled"],
          mustStaySilent: true,
          forbidFollowUp: true,
          requiredFacts: [],
          forbiddenClaims: [],
        },
        counterfactualMustFlip: true,
      },
    });

    const evaluated = cftParticipationEvaluator.evaluate(item, {
      result: {
        revision: "8178d3524",
        model: "codex",
        observation: makeObs({
          itemId: "cf_base",
          communicationKind: "reply",
          silenceReason: undefined,
          replyText: "能用了，PR #6548 已合并支持企业版登录。",
        }),
        variantObservation: makeObs({
          itemId: "cf_var",
          communicationKind: "silence",
          silenceReason: "already_handled",
          explanation: "Teammate already answered with #6548 in channel_context.after.",
        }),
      },
      trajectories: [],
    });

    expect(evaluated.score.triagePass).toBe(1);
    expect(evaluated.score.counterfactualFlip).toBe(1);
    expect(evaluated.score.falseIntervention).toBe(0);
    expect(evaluated.score.missedHelp).toBe(0);

    const agg = cftTriageAggregator.aggregate({
      "cft-participation": [
        {
          itemId: item.id,
          score: evaluated.score,
          explanation: evaluated.explanation,
        },
      ],
    });
    expect(agg.triagePassRate).toBe(1);
    expect(agg.falseInterventionRate).toBe(0);
    expect(agg.helpRecall).toBe(1);
    expect(agg.counterfactualFlipRate).toBe(1);
  });
});

describe("cft-triage blind pairwise judge and shadow diff", () => {
  test("two-pass swap resolves consistent winner and collapses flip-flop to tie", async () => {
    expect(resolveTwoPassCftWinner("candidate", "candidate")).toEqual({
      winner: "candidate",
      consistent: true,
    });
    expect(resolveTwoPassCftWinner("candidate", "baseline")).toEqual({
      winner: "tie",
      consistent: false,
    });

    const payload = makeWorkerPayload("w1", "[P2][PROD] alert fired");
    const baseline = makeObs({
      itemId: "w1",
      communicationKind: "reply",
      silenceReason: undefined,
      replyText: "Can someone grant me GCP Logs permissions?",
    });
    const candidate = makeObs({
      itemId: "w1",
      communicationKind: "silence",
      silenceReason: "insufficient_evidence",
      explanation:
        "No GCP Logs read access; stay silent without asking for credentials.",
    });

    const aIsCand1 = deterministicCftAIsCandidate("w1");
    let pass = 0;
    const judged = await runCftPositionDebiasedJudge({
      itemId: "w1",
      payload,
      baseline,
      candidate,
      swapPasses: true,
      async runJudge() {
        pass += 1;
        const candLetter = (pass === 1 ? aIsCand1 : !aIsCand1) ? "A" : "B";
        return {
          winner: candLetter,
          confidence: "high",
          scores: {
            restraint: candLetter,
            helpfulness: "tie",
            grounding: candLetter,
            groupTone: candLetter,
          },
          rationale: "Silent avoids noisy credential request in alert thread.",
        };
      },
    });

    expect(judged.winner).toBe("candidate");
    expect(judged.consistent).toBe(true);
    expect(judged.dimensions.restraint).toBe("candidate");
  });

  test("throws on malformed judge JSON instead of coercing", () => {
    expect(() => parseCftBlindJudgeOutput("not json at all")).toThrow();
    expect(() =>
      parseCftBlindJudgeOutput('{"winner":"A","confidence":"high"}')
    ).toThrow();
  });

  test("aggregates shadow diff and blind review HTML", () => {
    const payload = makeWorkerPayload(
      "item_diff_1",
      "感觉得搞搞 session transcript 备份"
    );
    const item = CftTriageEvalItemSchema.parse({
      id: "item_diff_1",
      input: { kind: "shadow_diff", payload, tags: ["worker", "ambient"] },
      expected: {},
    });
    const baseline = makeObs({
      itemId: "item_diff_1",
      communicationKind: "reply",
      silenceReason: undefined,
      replyText: "You should replicate to S3 and run regular restore drills.",
    });
    const candidate = makeObs({
      itemId: "item_diff_1",
      communicationKind: "silence",
      silenceReason: "no_useful_addition",
      explanation: "Unaddressed engineering musing without workspace-specific facts.",
    });

    const diffRes = cftShadowDiffEvaluator.evaluate(item, {
      result: {
        baselineRevision: "base123",
        candidateRevision: "cand456",
        model: "codex",
        baseline,
        candidate,
      },
      trajectories: [],
    });
    expect(diffRes.score.newlySilenced).toBe(1);
    expect(diffRes.score.baselineReplied).toBe(1);
    expect(diffRes.score.candidateReplied).toBe(0);

    const agg = cftShadowAggregator.aggregate({
      "cft-shadow-diff": [
        { itemId: item.id, score: diffRes.score, explanation: diffRes.explanation },
      ],
      "cft-blind-pairwise-judge": [
        {
          itemId: item.id,
          score: {
            judged: 1,
            candidateWin: 1,
            swapConsistent: 1,
            restraintWin: 1,
            helpfulnessWin: 0.5,
            groundingWin: 1,
            groupToneWin: 1,
          },
          explanation: "winner=candidate",
        },
      ],
    });
    expect(agg.newlySilencedCount).toBe(1);
    expect(agg.blindPairwiseWinRate).toBe(1);

    const html = renderCftBlindReviewHtml(
      {
        baselineRevision: "base123",
        candidateRevision: "cand456",
        model: "codex",
        totalItems: 1,
        baselineIntervened: 1,
        candidateIntervened: 0,
        baselineReplied: 1,
        candidateReplied: 0,
        candidateWins: 1,
        baselineWins: 0,
        ties: 0,
        swapConsistencyPct: 100,
      },
      [{ id: item.id, tags: ["worker"], payload, baseline, candidate }]
    );
    expect(html).toContain("CFT Group-Chat Triage");
    expect(html).toContain("item_diff_1");
    expect(html).not.toContain("undefined");
  });
});

describe("snapshot dataset builder and recorded loader", () => {
  test("redacts PII/tokens and builds both worker and native items", () => {
    expect(
      redactCftText("Ping <@U09ABCDEF1> or alice@example.com with xoxb-12345-secret")
    ).toBe("Ping <@U_REDACTED> or [redacted-email] with [redacted-token]");

    const dataset = buildCftTriageDatasetFromSnapshot(
      {
        exported_at: "2026-11-26T04:50:00Z",
        worker_items: [
          {
            id: "worker_01TEST",
            run_id: "01TEST",
            bucket: "ord_reply",
            inserted_at: "2026-11-26T04:00:00Z",
            channel_id: "C12345",
            thread_ts: "1795600000.000100",
            is_ordinary_worker: true,
            is_recheck: false,
            source_messages: [
              {
                message_ts: "1795600000.000100",
                actor_kind: "human",
                actor_id: "U09ABCDEF1",
                text: "Email alice@example.com about <@U09ABCDEF1>",
                source_ref: "slack://T1/C12345/1795600000.000100/1795600000.000100",
              },
            ],
            context_sources: [],
            worker_notes: [],
          },
        ],
        native_items: [
          {
            id: "native_01NAT",
            run_id: "01NAT",
            bucket: "recheck_delegated",
            inserted_at: "2026-11-26T04:05:00Z",
            source_mode: "scheduled_recheck",
            target_route: "none",
            model_input: {
              snapshot: {
                slack_context: {
                  channel_id: "C99999",
                  decision_target: { message_ref: "message://run/m001" },
                  messages: [
                    {
                      message_ref: "message://run/m001",
                      actor_kind: "agent",
                      text: "Recheck alert for bob@example.com — no GCP Logs access.",
                    },
                  ],
                },
              },
            },
          },
        ],
      },
      { name: "cft-test-v1", redact: true }
    );

    expect(dataset.items.length).toBe(2);
    const workerItem = dataset.items[0];
    expect(workerItem?.input.kind).toBe("shadow_diff");
    if (
      workerItem?.input.kind === "shadow_diff" &&
      workerItem.input.payload.layer === "worker_participation"
    ) {
      expect(workerItem.input.payload.worker.messages[0]?.text).toContain(
        "[redacted-email]"
      );
      expect(workerItem.input.payload.worker.channelId).toBe("C_REDACTED");
    } else {
      throw new Error("expected worker_participation item");
    }

    const nativeItem = dataset.items[1];
    if (
      nativeItem?.input.kind === "shadow_diff" &&
      nativeItem.input.payload.layer === "native_evaluator"
    ) {
      expect(nativeItem.input.payload.native.lane).toBe("scheduled_recheck");
      expect(nativeItem.input.payload.native.targetSummary).toContain(
        "[redacted-email]"
      );
    } else {
      throw new Error("expected native_evaluator item");
    }
  });

  test("loads recorded observations file cleanly", async () => {
    const dir = await mkdtemp(path.join(os.tmpdir(), "evalens-cft-test-"));
    try {
      const file = path.join(dir, "recorded.json");
      await writeFile(
        file,
        JSON.stringify({
          revision: "8178d3524",
          model: "codex",
          observations: [makeObs({ itemId: "rec_1" })],
        }),
        "utf8"
      );
      const map = await loadRecordedCftObservations(file);
      expect(map.get("rec_1")?.communicationKind).toBe("silence");
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  test("deduplicates repetitive alert templates, repeated threads, run_ids, and noisy channels", () => {
    const skelA = normalizeTemplateSkeleton(
      "*<https://console.cloud.google.com/monitoring/alerts/0.offrdffajjm3|Alert>* station_task_stalled for <@U09ABC123>"
    );
    const skelB = normalizeTemplateSkeleton(
      "*<https://console.cloud.google.com/monitoring/alerts/0.ofe3eon8pm41|Alert>* station_task_stalled for <@U09XYZ789>"
    );
    expect(skelA).toBe(skelB);

    const pAlert1 = makeWorkerPayload(
      "worker_01RUNA",
      "*<https://console.cloud.google.com/monitoring/alerts/0.offrdffajjm3|Alert>* station_task_stalled",
      { channelId: "C_ALERTS", threadTs: "1795600001.000100" }
    );
    const pAlert2 = makeWorkerPayload(
      "worker_01RUNB",
      "*<https://console.cloud.google.com/monitoring/alerts/0.ofe3eon8pm41|Alert>* station_task_stalled",
      { channelId: "C_ALERTS", threadTs: "1795600002.000100" }
    );
    const pSameThread = makeWorkerPayload(
      "worker_01RUNC",
      "Follow-up message in the exact same thread",
      { channelId: "C_ALERTS", threadTs: "1795600001.000100" }
    );
    const pSameRunNative: CftScenarioPayload = {
      layer: "native_evaluator",
      native: {
        itemId: "native_01RUNA",
        lane: "scheduled_recheck",
        sourceMode: "scheduled_recheck",
        targetRoute: "none",
        channelId: "C_ALERTS",
        targetSummary: "Recheck alert 0.offrdffajjm3",
        threadPreview: [],
        modelInput: {},
      },
    };
    const pOtherChannel = makeWorkerPayload("worker_01RUND", "How do we enable SSO?", {
      channelId: "C_GENERAL",
      threadTs: "1795600003.000100",
    });

    expect(extractCftDiversityKeys(pAlert1).templateKey).toBe(
      extractCftDiversityKeys(pAlert2).templateKey
    );
    expect(extractCftDiversityKeys(pAlert1).runKey).toBe(
      extractCftDiversityKeys(pSameRunNative).runKey
    );

    const replied = (id: string) =>
      makeObs({
        itemId: id,
        communicationKind: "reply",
        silenceReason: undefined,
        replyText: "Replied",
      });
    const silent = (id: string) =>
      makeObs({ itemId: id, communicationKind: "silence" });

    const pairs = [
      {
        id: "worker_01runa",
        tags: ["worker"],
        payload: pAlert1,
        baseline: replied("worker_01RUNA"),
        candidate: silent("worker_01RUNA"),
      },
      {
        id: "worker_01runb",
        tags: ["worker"],
        payload: pAlert2,
        baseline: replied("worker_01RUNB"),
        candidate: silent("worker_01RUNB"),
      },
      {
        id: "worker_01runc",
        tags: ["worker"],
        payload: pSameThread,
        baseline: replied("worker_01RUNC"),
        candidate: silent("worker_01RUNC"),
      },
      {
        id: "native_01runa",
        tags: ["native"],
        payload: pSameRunNative,
        baseline: replied("native_01RUNA"),
        candidate: silent("native_01RUNA"),
      },
      {
        id: "worker_01rund",
        tags: ["worker"],
        payload: pOtherChannel,
        baseline: replied("worker_01RUND"),
        candidate: silent("worker_01RUND"),
      },
    ];

    const diverse = buildBlindedCftReviewPayload(pairs, { deduplicate: true });
    expect(diverse.length).toBe(2);
    expect(diverse[0]?.id).toBe("worker_01runa");
    expect(diverse[0]?.collapsedCount).toBe(3);
    expect(diverse[1]?.id).toBe("worker_01rund");
    expect(diverse[1]?.collapsedCount).toBe(0);

    const raw = buildBlindedCftReviewPayload(pairs, { deduplicate: false });
    expect(raw.length).toBe(5);

    const dsItems = pairs.map((p) =>
      CftTriageEvalItemSchema.parse({
        id: p.id,
        input: { kind: "shadow_diff", payload: p.payload, tags: p.tags },
        expected: {},
      })
    );
    expect(diversifyCftDatasetItems(dsItems).length).toBe(2);
  });

  test("omits opaque blank context_sources and keeps blind review pre-reveal spoiler-free", () => {
    const payload = makeWorkerPayload("worker_blank_ctx", "他们的 ditto 不做了吗", {
      contextSources: [
        {
          sourceRef: "triage-context://opaque-1",
          kind: "retained_project_fact",
          subject: "",
          value: "",
        },
        {
          sourceRef: "triage-context://readable-1",
          kind: "project_fact",
          subject: "Ditto status",
          value: "Internal dogfood builds active",
        },
      ],
    });
    const formatted = formatCftScenarioForJudge(payload);
    expect(formatted).not.toContain("[retained_project_fact]");
    expect(formatted).toContain("Ditto status: Internal dogfood builds active");

    const opaqueOnly = makeWorkerPayload("worker_opaque_only", "hello", {
      contextSources: [
        {
          sourceRef: "triage-context://opaque-2",
          kind: "retained_project_fact",
          subject: "",
          value: "",
        },
      ],
    });
    expect(formatCftScenarioForJudge(opaqueOnly)).not.toContain(
      "Retained project context"
    );

    const html = renderCftBlindReviewHtml(
      {
        baselineRevision: "base",
        candidateRevision: "cand",
        model: "codex",
        totalItems: 1,
        baselineIntervened: 1,
        candidateIntervened: 0,
        baselineReplied: 1,
        candidateReplied: 0,
        candidateWins: 1,
        baselineWins: 0,
        ties: 0,
        swapConsistencyPct: 100,
      },
      [
        {
          id: "worker_blank_ctx",
          tags: ["worker", "ord_reply", "ambient"],
          payload,
          baseline: makeObs({
            itemId: "worker_blank_ctx",
            communicationKind: "reply",
            silenceReason: undefined,
            replyText: "Replied",
          }),
          candidate: makeObs({
            itemId: "worker_blank_ctx",
            communicationKind: "silence",
          }),
        },
      ]
    );
    expect(html).toContain("选择理由（可选，针对胜出项）：");
    expect(html).toContain("该闭嘴时闭嘴");
    expect(html).toContain("后台自查 ×");
    expect(html).toContain("不会私信同事或在群里发消息");
    expect(html).toContain("后台自查任务（派给内部 AI Task Agent，不私信任何人）：");
    expect(html).not.toContain("DELEGATE ×");
    expect(html).not.toContain("esc(it.flipType) + '</span>'");
  });
});
