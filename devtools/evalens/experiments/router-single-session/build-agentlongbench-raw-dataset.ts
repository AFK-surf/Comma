import { mkdir } from "node:fs/promises";
import path from "node:path";

import { RouterSingleSessionItem } from "./dataset";
import { loadAgentLongBenchItems } from "./importers";
import { ensureAgentLongBenchSource } from "./source-data";

const evalensRoot = path.resolve(import.meta.dir, "../..");
const { benchmarkRoot } = await ensureAgentLongBenchSource({
  root: process.env.AGENTLONGBENCH_DATA_ROOT ?? "/tmp/comma-agentlongbench-official",
  download: process.env.EVALENS_DATASET_DOWNLOAD !== "false",
});
const tiers = [
  { tokenLength: "32k", datasetName: "agentlongbench-32k-raw-v1" },
  { tokenLength: "256k", datasetName: "agentlongbench-256k-raw-v1" },
  { tokenLength: "1M", datasetName: "agentlongbench-1m-raw-v1" },
] as const;

type BuiltItem = {
  id: string;
  input: {
    currentHistory: unknown[];
    priorHistory: unknown[];
    probe: unknown;
    officialEpisodes?: {
      current: unknown;
      prior: unknown;
    };
  };
  metadata: { tokenLength?: string };
};

const outputs = [];
for (const tier of tiers) {
  const items = (
    (await loadAgentLongBenchItems({
      benchmarkRoot,
      tokenLength: tier.tokenLength,
    })) as unknown[]
  )
    .map((item: unknown) => RouterSingleSessionItem.parse(item) as BuiltItem)
    .sort((left: BuiltItem, right: BuiltItem) => left.id.localeCompare(right.id));

  if (items.length !== 800) {
    throw new Error(
      `Expected 800 official AgentLongBench ${tier.tokenLength} items, received ${items.length}`
    );
  }
  if (items.some((item: BuiltItem) => !item.input.officialEpisodes)) {
    throw new Error(
      `Every AgentLongBench ${tier.tokenLength} item must retain both official raw episodes`
    );
  }
  if (items.some((item: BuiltItem) => item.metadata.tokenLength !== tier.tokenLength)) {
    throw new Error(
      `AgentLongBench ${tier.tokenLength} item metadata does not match its source tier`
    );
  }

  const outputDirectory = path.join(evalensRoot, "datasets", tier.datasetName);
  const outputPath = path.join(outputDirectory, "dataset.json");
  const itemArchiveDirectory = path.join(outputDirectory, "items");
  await mkdir(itemArchiveDirectory, { recursive: true });
  const manifestItems = [];
  for (const item of items) {
    const episodes = item.input.officialEpisodes;
    if (!episodes) {
      throw new Error(`AgentLongBench item ${item.id} is missing official episodes`);
    }
    const current = JSON.stringify(episodes.current);
    const prior = JSON.stringify(episodes.prior);
    await Bun.Archive.write(path.join(itemArchiveDirectory, `${item.id}.tar`), {
      "current.json": current,
      "prior.json": prior,
    });
    const { officialEpisodes: _officialEpisodes, ...input } = item.input;
    manifestItems.push({
      ...item,
      input: {
        ...input,
        currentHistory: [],
        priorHistory: [],
        officialEpisodeArchive: {
          format: "agentlongbench-official-episodes-v1",
          currentPath: "current.json",
          priorPath: "prior.json",
          currentSha256: sha256(current),
          priorSha256: sha256(prior),
        },
      },
    });
  }
  await Bun.write(
    outputPath,
    `${JSON.stringify(
      {
        name: tier.datasetName,
        description: `Complete official AgentLongBench ${tier.tokenLength} slice. Each item attachment retains its two original episode objects in source order; labels remain evaluator-only fields.`,
        items: manifestItems,
      },
      null,
      2
    )}\n`
  );
  outputs.push({ outputPath, itemCount: items.length, tokenLength: tier.tokenLength });
}

console.log(JSON.stringify({ benchmarkRoot, outputs }, null, 2));

function sha256(content: string): string {
  return new Bun.CryptoHasher("sha256").update(content).digest("hex");
}
