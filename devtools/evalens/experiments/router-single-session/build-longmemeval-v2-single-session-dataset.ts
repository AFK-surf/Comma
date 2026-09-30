import { mkdir } from "node:fs/promises";
import path from "node:path";

import { RouterSingleSessionItem } from "./dataset";
import {
  ensureLongMemEvalV2Source,
  LONGMEMEVAL_V2_REVISION,
  LONGMEMEVAL_V2_TRAJECTORIES_SHA256,
  LONGMEMEVAL_V2_URL,
} from "./source-data";

const evalensRoot = path.resolve(import.meta.dir, "../..");
const datasetName = "longmemeval-v2-triple-branch-raw-v1";
const dataRoot = process.env.LONGMEMEVAL_DATA_ROOT ?? "/tmp/comma-longmemeval-v2";
const priorTrajectoryCount = 50;

type SourceQuestion = {
  id: string;
  domain: "web" | "enterprise";
  environment: string;
  question_type: string;
  question: string;
  image: string | null;
  answer: string;
  eval_function: string;
};

const source = await ensureLongMemEvalV2Source({
  root: dataRoot,
  download: process.env.EVALENS_DATASET_DOWNLOAD !== "false",
});
const sourceQuestions = Bun.JSONL.parse(
  await Bun.file(source.questionsPath).text()
) as SourceQuestion[];
const haystacks = (await Bun.file(source.haystackPath).json()) as Record<
  string,
  string[]
>;
if (sourceQuestions.length !== 451) {
  throw new Error(
    `Expected 451 LongMemEval-V2 questions, received ${sourceQuestions.length}`
  );
}

const trajectoryDomains = await loadTrajectoryDomains(source.trajectoryPool);
const pools = {
  web: [...trajectoryDomains.entries()]
    .filter(([, domain]) => domain === "web")
    .map(([id]) => id)
    .sort(),
  enterprise: [...trajectoryDomains.entries()]
    .filter(([, domain]) => domain === "enterprise")
    .map(([id]) => id)
    .sort(),
};

const excluded = sourceQuestions
  .filter((question) => question.image !== null)
  .map((question) => ({
    id: `longmemeval-v2-${question.id}`,
    sourceItemId: question.id,
    reason: "question_image_requires_unavailable_session_image_delivery",
    image: question.image,
  }));
const eligibleSourceItems = sourceQuestions.filter(
  (question) => question.image === null
);
if (eligibleSourceItems.length !== 422 || excluded.length !== 29) {
  throw new Error(
    `Expected 422 text-only and 29 image-dependent items, received ${eligibleSourceItems.length} and ${excluded.length}`
  );
}

const items = eligibleSourceItems
  .map((question) => {
    const itemId = `longmemeval-v2-${question.id}`;
    const currentTrajectoryIds = haystacks[question.id];
    if (!currentTrajectoryIds) {
      throw new Error(`Missing LongMemEval-V2 small haystack for ${question.id}`);
    }
    if (currentTrajectoryIds.length !== 100) {
      throw new Error(`${itemId} does not contain the official 100-trajectory tier`);
    }
    const currentIds = new Set(currentTrajectoryIds);
    const priorTrajectoryIds = pools[question.domain]
      .filter((id) => !currentIds.has(id))
      .slice(0, priorTrajectoryCount);
    if (priorTrajectoryIds.length !== priorTrajectoryCount) {
      throw new Error(
        `${itemId} has only ${priorTrajectoryIds.length} disjoint prior trajectories`
      );
    }
    const expected = expectedFromOfficialEvaluator(
      question.answer,
      question.eval_function
    );
    return RouterSingleSessionItem.parse({
      id: itemId,
      input: {
        currentHistory: [],
        priorHistory: [],
        rawHistory: {
          format: "longmemeval-v2-trajectory-json-v1",
          currentTrajectoryIds,
          priorTrajectoryIds,
          trajectoriesSha256: LONGMEMEVAL_V2_TRAJECTORIES_SHA256,
        },
        probe: { message: question.question },
      },
      expected,
      source: {
        dataset: "longmemeval-v2",
        revision: LONGMEMEVAL_V2_REVISION,
        itemId: question.id,
        url: LONGMEMEVAL_V2_URL,
        evaluator: question.eval_function,
        sourcePath:
          "questions.jsonl + haystacks/lme_v2_small.json + trajectories.jsonl",
      },
      metadata: {
        questionType: question.question_type,
        historyMode:
          "official ordered 100-trajectory small haystack; accumulated adds 50 deterministic disjoint same-domain trajectories",
        knowledgeMode: question.domain,
        responseMode: question.environment,
        notes:
          "Trajectory JSON is read verbatim at the adapter boundary. Prior IDs are the first 50 lexicographically sorted same-domain IDs outside the official current haystack; answers are never consulted.",
      },
      schemaVersion: 1,
      kind: "salix.router_single_session_dataset_item",
    });
  })
  .sort((left: { id: string }, right: { id: string }) =>
    left.id.localeCompare(right.id)
  );

const outputDirectory = path.join(evalensRoot, "datasets", datasetName);
await mkdir(outputDirectory, { recursive: true });
const outputPath = path.join(outputDirectory, "dataset.json");
const constructionPath = path.join(outputDirectory, "construction.json");
const eligibilityPath = path.join(outputDirectory, "eligibility.json");
await Bun.write(
  outputPath,
  `${JSON.stringify(
    {
      name: datasetName,
      description:
        "All 422 text-only LongMemEval-V2 questions adapted to isolated Fresh, Accumulated, and Compacted session branches. The official ordered small haystack is current history; accumulated and compacted prepend the same 50 deterministic disjoint same-domain raw trajectories. The 29 image-dependent questions are inventoried separately because the controlled session-injection boundary cannot deliver their question image identically to both adapters.",
      items,
    },
    null,
    2
  )}\n`
);
await Bun.write(
  constructionPath,
  `${JSON.stringify(
    {
      schemaVersion: 1,
      sourceDataset: "longmemeval-v2",
      sourceRevision: LONGMEMEVAL_V2_REVISION,
      sourceTrajectorySha256: LONGMEMEVAL_V2_TRAJECTORIES_SHA256,
      sourceItemCount: sourceQuestions.length,
      itemCount: items.length,
      excludedItemCount: excluded.length,
      currentTrajectoryCount: 100,
      priorTrajectoryCount,
      priorSelection:
        "same domain; exclude official current ids; lexical trajectory id order; first N",
      transformation:
        "reference-only dataset manifest; complete trajectory JSON is read verbatim when the adapter materializes branch history",
      answerDrivenSelection: false,
      truncation: false,
      summarization: false,
      rewriting: false,
    },
    null,
    2
  )}\n`
);
await Bun.write(
  eligibilityPath,
  `${JSON.stringify(
    {
      schemaVersion: 1,
      sourceDataset: "longmemeval-v2",
      sourceItemCount: sourceQuestions.length,
      eligibleItemCount: items.length,
      excludedItemCount: excluded.length,
      eligibilityRule:
        "Text-only question. Full raw trajectory JSON can be injected identically into Salix and Codex sessions; no equivalent controlled question-image injection exists in the current adapters.",
      excluded,
    },
    null,
    2
  )}\n`
);
console.log(
  JSON.stringify(
    {
      outputPath,
      constructionPath,
      eligibilityPath,
      sourceItemCount: sourceQuestions.length,
      itemCount: items.length,
      excludedItemCount: excluded.length,
      currentTrajectoryCount: 100,
      priorTrajectoryCount,
      availableTrajectoryCounts: {
        web: pools.web.length,
        enterprise: pools.enterprise.length,
      },
    },
    null,
    2
  )
);

function expectedFromOfficialEvaluator(answer: string, evaluator: string) {
  const evaluatorName = evaluator.split("|", 1)[0]?.trim();
  if (
    evaluatorName === "norm_phrase_set_match" ||
    evaluatorName === "norm_phrase_set_match_ordered"
  ) {
    const claims = answer
      .split(/[,;]/gu)
      .map((claim) => claim.trim())
      .filter(Boolean);
    if (claims.length === 0) throw new Error("Phrase evaluator has no claims");
    return {
      match:
        evaluatorName === "norm_phrase_set_match_ordered"
          ? "phrase_set_ordered"
          : "phrase_set",
      answer,
      requiredClaims: claims,
      forbiddenClaims: [],
    };
  }
  if (evaluatorName === "mc_choice_match") {
    return {
      match: "mc_choice",
      answer,
      requiredClaims: [answer],
      forbiddenClaims: [],
    };
  }
  if (evaluatorName === "mc_choice_set_match") {
    return {
      match: "mc_choice_set",
      answer,
      requiredClaims: [answer],
      forbiddenClaims: [],
    };
  }
  if (evaluatorName === "llm_abstention_checker") {
    return {
      match: "llm_abstention",
      answer,
      requiredClaims: [answer],
      forbiddenClaims: [],
    };
  }
  if (evaluatorName === "llm_gotchas_checker") {
    return {
      match: "llm_gotchas",
      answer,
      requiredClaims: [answer],
      forbiddenClaims: [],
    };
  }
  throw new Error(`Unsupported LongMemEval-V2 evaluator: ${evaluator}`);
}

async function loadTrajectoryDomains(
  poolRoot: string
): Promise<Map<string, "web" | "enterprise">> {
  const result = new Map<string, "web" | "enterprise">();
  const glob = new Bun.Glob("*/trajectory.json");
  for await (const relativePath of glob.scan({ cwd: poolRoot, onlyFiles: true })) {
    const id = relativePath.split("/")[0];
    if (!id) continue;
    const prefix = await Bun.file(path.join(poolRoot, relativePath))
      .slice(0, 4096)
      .text();
    const domain = prefix.match(/"domain":"(web|enterprise)"/u)?.[1];
    if (domain !== "web" && domain !== "enterprise") {
      throw new Error(`Cannot read domain from trajectory ${id}`);
    }
    result.set(id, domain);
  }
  if (result.size !== 1870) {
    throw new Error(`Expected 1870 trajectory files, received ${result.size}`);
  }
  return result;
}
