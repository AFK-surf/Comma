import { mkdir, mkdtemp, rename, rm, stat } from "node:fs/promises";
import path from "node:path";

export const AGENTLONGBENCH_REVISION = "7c32c2520a777ea51e3a8dcf9d94d524523be12f";
export const AGENTLONGBENCH_URL =
  "https://huggingface.co/datasets/ign1s/AgentLongBench";
const AGENTLONGBENCH_ARCHIVE_SHA256 =
  "5414f8fc051ff0421cc7e8e09380b037ea1c4d6b0c6e8d5f94e87902aeb69d30";

export const LONGMEMEVAL_V2_REVISION = "f152293e235517d504809563c833d7190b8c713b";
export const LONGMEMEVAL_V2_URL =
  "https://huggingface.co/datasets/xiaowu0162/longmemeval-v2";
export const LONGMEMEVAL_V2_TRAJECTORIES_SHA256 =
  "363cec9a8e87aa8d9101ce4e600aadbf7031d674056ebe4f969e8424abc5f3c6";
const LONGMEMEVAL_V2_QUESTIONS_SHA256 =
  "0a3ae5ebea938c24d7800e1e0b0828e08ae1646f939a53853b2b8cdc08e292b7";
const LONGMEMEVAL_V2_SMALL_HAYSTACK_SHA256 =
  "9b5301defb23a088a5f06e45ff8d5f35e569d78305a66d492046a9fff9b46593";

const LONGMEMEVAL_V2_TRAJECTORY_COUNT = 1_870;

type SourceDownloadOptions = {
  root: string;
  download: boolean;
};

type AgentLongBenchSource = {
  root: string;
  archivePath: string;
  benchmarkRoot: string;
};

type LongMemEvalV2Source = {
  root: string;
  questionsPath: string;
  trajectoriesPath: string;
  haystackPath: string;
  trajectoryPool: string;
};

export async function ensureAgentLongBenchSource(
  options: SourceDownloadOptions
): Promise<AgentLongBenchSource> {
  const root = path.resolve(options.root);
  const archivePath = path.join(root, "benchmark.tar.gz");
  const extractedRoot = path.join(root, "extracted");
  const benchmarkRoot = path.join(extractedRoot, "benchmark");
  await mkdir(root, { recursive: true });
  await ensurePinnedFile({
    localPath: archivePath,
    remotePath: "benchmark.tar.gz",
    revision: AGENTLONGBENCH_REVISION,
    repo: "ign1s/AgentLongBench",
    expectedSha256: AGENTLONGBENCH_ARCHIVE_SHA256,
    download: options.download,
  });

  if (!(await hasAgentLongBenchTiers(benchmarkRoot))) {
    if (await pathExists(extractedRoot)) {
      throw new Error(
        `AgentLongBench extraction is incomplete: ${extractedRoot}. ` +
          "Move it aside and call the loader again."
      );
    }
    const temporaryRoot = await mkdtemp(path.join(root, ".extract-"));
    try {
      const extraction = Bun.spawn(["tar", "-xzf", archivePath, "-C", temporaryRoot], {
        stdout: "pipe",
        stderr: "pipe",
      });
      const exitCode = await extraction.exited;
      if (exitCode !== 0) {
        throw new Error(
          `AgentLongBench extraction failed with exit ${exitCode}: ${await new Response(
            extraction.stderr
          ).text()}`
        );
      }
      if (!(await hasAgentLongBenchTiers(path.join(temporaryRoot, "benchmark")))) {
        throw new Error("AgentLongBench archive does not contain the expected tiers");
      }
      await rename(temporaryRoot, extractedRoot);
    } catch (error) {
      await rm(temporaryRoot, { recursive: true, force: true });
      throw error;
    }
  }

  return { root, archivePath, benchmarkRoot };
}

export async function ensureLongMemEvalV2Source(
  options: SourceDownloadOptions
): Promise<LongMemEvalV2Source> {
  const root = path.resolve(options.root);
  const questionsPath = path.join(root, "questions.jsonl");
  const trajectoriesPath = path.join(root, "trajectories-full.jsonl");
  const haystackPath = path.join(root, "lme_v2_small.json");
  const trajectoryPool = path.join(root, "trajectory-pool");
  await mkdir(root, { recursive: true });

  await Promise.all([
    ensurePinnedFile({
      localPath: questionsPath,
      remotePath: "questions.jsonl",
      revision: LONGMEMEVAL_V2_REVISION,
      repo: "xiaowu0162/longmemeval-v2",
      expectedSha256: LONGMEMEVAL_V2_QUESTIONS_SHA256,
      download: options.download,
    }),
    ensurePinnedFile({
      localPath: haystackPath,
      remotePath: "haystacks/lme_v2_small.json",
      revision: LONGMEMEVAL_V2_REVISION,
      repo: "xiaowu0162/longmemeval-v2",
      expectedSha256: LONGMEMEVAL_V2_SMALL_HAYSTACK_SHA256,
      download: options.download,
    }),
    ensurePinnedFile({
      localPath: trajectoriesPath,
      remotePath: "trajectories.jsonl",
      revision: LONGMEMEVAL_V2_REVISION,
      repo: "xiaowu0162/longmemeval-v2",
      expectedSha256: LONGMEMEVAL_V2_TRAJECTORIES_SHA256,
      download: options.download,
    }),
  ]);

  await ensureLongMemEvalTrajectoryPool({
    root,
    trajectoriesPath,
    trajectoryPool,
  });
  return {
    root,
    questionsPath,
    trajectoriesPath,
    haystackPath,
    trajectoryPool,
  };
}

async function ensurePinnedFile(input: {
  localPath: string;
  remotePath: string;
  revision: string;
  repo: string;
  expectedSha256: string;
  download: boolean;
}): Promise<void> {
  const existingDigest = await sha256FileIfPresent(input.localPath);
  if (existingDigest === input.expectedSha256) return;
  if (!input.download) {
    const detail = existingDigest
      ? `checksum ${existingDigest}`
      : "the file is missing";
    throw new Error(
      `Pinned dataset source is unavailable at ${input.localPath}: ${detail}. ` +
        "Enable download to populate the local cache."
    );
  }

  await mkdir(path.dirname(input.localPath), { recursive: true });
  const temporaryPath = `${input.localPath}.download-${Bun.randomUUIDv7()}`;
  const url =
    `https://huggingface.co/datasets/${input.repo}/resolve/` +
    `${input.revision}/${input.remotePath}?download=true`;
  try {
    // These public, immutable artifacts need no Hub authentication, pagination,
    // or repository mutation. A narrow fetch keeps the exact response bytes
    // available for the pinned checksum and avoids adding an SDK solely to read
    // one resolve URL.
    const response = await fetch(url, { redirect: "follow" });
    if (!response.ok || !response.body) {
      throw new Error(
        `Failed to download ${input.repo}/${input.remotePath}: HTTP ${response.status}`
      );
    }
    await Bun.write(temporaryPath, response);
    const digest = await sha256File(temporaryPath);
    if (digest !== input.expectedSha256) {
      throw new Error(
        `Downloaded ${input.repo}/${input.remotePath} checksum mismatch: ` +
          `expected ${input.expectedSha256}, received ${digest}`
      );
    }
    await rename(temporaryPath, input.localPath);
  } finally {
    await rm(temporaryPath, { force: true });
  }
}

async function ensureLongMemEvalTrajectoryPool(input: {
  root: string;
  trajectoriesPath: string;
  trajectoryPool: string;
}): Promise<void> {
  const manifestPath = path.join(
    input.root,
    "router-single-session-source-manifest.json"
  );
  if (await isCompleteLongMemEvalPool(input.trajectoryPool, manifestPath)) {
    return;
  }

  const temporaryPool = await mkdtemp(path.join(input.root, ".trajectory-pool-"));
  const ids = new Set<string>();
  try {
    await forEachOriginalJsonLine(input.trajectoriesPath, async (line) => {
      const values = Bun.JSONL.parse(line);
      if (values.length !== 1) {
        throw new Error("LongMemEval-V2 trajectory line must contain one JSON value");
      }
      const parsed = values[0] as { id?: unknown };
      if (typeof parsed.id !== "string" || !parsed.id) {
        throw new Error("LongMemEval-V2 trajectory has no id");
      }
      if (ids.has(parsed.id)) {
        throw new Error(`Duplicate LongMemEval-V2 trajectory id: ${parsed.id}`);
      }
      ids.add(parsed.id);
      const directory = path.join(temporaryPool, parsed.id);
      await mkdir(directory, { recursive: true });
      await Bun.write(path.join(directory, "trajectory.json"), `${line}\n`);
    });
    if (ids.size !== LONGMEMEVAL_V2_TRAJECTORY_COUNT) {
      throw new Error(
        `Expected ${LONGMEMEVAL_V2_TRAJECTORY_COUNT} LongMemEval-V2 trajectories, ` +
          `received ${ids.size}`
      );
    }
    if (await pathExists(input.trajectoryPool)) {
      throw new Error(
        `LongMemEval-V2 trajectory pool is incomplete: ${input.trajectoryPool}. ` +
          "Move it aside and call the loader again."
      );
    }
    await rename(temporaryPool, input.trajectoryPool);
    await Bun.write(
      manifestPath,
      `${JSON.stringify(
        {
          dataset: "longmemeval-v2",
          consumer: "router-single-session",
          revision: LONGMEMEVAL_V2_REVISION,
          trajectoriesSha256: LONGMEMEVAL_V2_TRAJECTORIES_SHA256,
          trajectoryCount: ids.size,
        },
        null,
        2
      )}\n`
    );
  } catch (error) {
    await rm(temporaryPool, { recursive: true, force: true });
    throw error;
  }
}

async function isCompleteLongMemEvalPool(
  trajectoryPool: string,
  manifestPath: string
): Promise<boolean> {
  if (!(await directoryExists(trajectoryPool))) return false;
  const manifestFile = Bun.file(manifestPath);
  if (await manifestFile.exists()) {
    const manifest = (await manifestFile.json()) as Record<string, unknown>;
    if (
      manifest.revision === LONGMEMEVAL_V2_REVISION &&
      manifest.trajectoriesSha256 === LONGMEMEVAL_V2_TRAJECTORIES_SHA256 &&
      manifest.trajectoryCount === LONGMEMEVAL_V2_TRAJECTORY_COUNT
    ) {
      return true;
    }
  }

  const legacyManifest = Bun.file(
    path.join(path.dirname(trajectoryPool), "evalens-raw-source-manifest.json")
  );
  if (!(await legacyManifest.exists())) return false;
  const legacy = (await legacyManifest.json()) as Record<string, unknown>;
  if (
    legacy.revision !== LONGMEMEVAL_V2_REVISION ||
    legacy.trajectoriesSha256 !== LONGMEMEVAL_V2_TRAJECTORIES_SHA256 ||
    legacy.trajectoryCount !== LONGMEMEVAL_V2_TRAJECTORY_COUNT
  ) {
    return false;
  }
  await Bun.write(
    manifestPath,
    `${JSON.stringify(
      {
        dataset: "longmemeval-v2",
        consumer: "router-single-session",
        revision: LONGMEMEVAL_V2_REVISION,
        trajectoriesSha256: LONGMEMEVAL_V2_TRAJECTORIES_SHA256,
        trajectoryCount: LONGMEMEVAL_V2_TRAJECTORY_COUNT,
        adoptedFromLegacyManifest: true,
      },
      null,
      2
    )}\n`
  );
  return true;
}

async function hasAgentLongBenchTiers(benchmarkRoot: string): Promise<boolean> {
  return (
    (await directoryExists(path.join(benchmarkRoot, "ki-c", "32k"))) &&
    (await directoryExists(path.join(benchmarkRoot, "ki-c", "256k"))) &&
    (await directoryExists(path.join(benchmarkRoot, "ki-c", "1M"))) &&
    (await directoryExists(path.join(benchmarkRoot, "kf-v", "32k"))) &&
    (await directoryExists(path.join(benchmarkRoot, "kf-v", "256k"))) &&
    (await directoryExists(path.join(benchmarkRoot, "kf-v", "1M")))
  );
}

async function directoryExists(directoryPath: string): Promise<boolean> {
  try {
    return (await stat(directoryPath)).isDirectory();
  } catch {
    return false;
  }
}

async function pathExists(filePath: string): Promise<boolean> {
  try {
    await stat(filePath);
    return true;
  } catch {
    return false;
  }
}

async function sha256FileIfPresent(filePath: string): Promise<string | undefined> {
  const file = Bun.file(filePath);
  return (await file.exists()) ? sha256File(filePath) : undefined;
}

async function sha256File(filePath: string): Promise<string> {
  const hasher = new Bun.CryptoHasher("sha256");
  for await (const chunk of Bun.file(filePath).stream()) {
    hasher.update(chunk);
  }
  return hasher.digest("hex");
}

async function forEachOriginalJsonLine(
  filePath: string,
  callback: (line: string) => Promise<void>
): Promise<void> {
  // The callback validates each line with Bun.JSONL, while this framing loop
  // retains the source bytes. Re-serializing parsed objects would make the local
  // trajectory pool differ from the official corpus for no experimental reason.
  const decoder = new TextDecoder();
  let pending = "";
  for await (const chunk of Bun.file(filePath).stream()) {
    pending += decoder.decode(chunk, { stream: true });
    let newline = pending.indexOf("\n");
    while (newline >= 0) {
      const line = pending.slice(0, newline);
      pending = pending.slice(newline + 1);
      if (line.trim()) await callback(line);
      newline = pending.indexOf("\n");
    }
  }
  pending += decoder.decode();
  if (pending.trim()) await callback(pending);
}
