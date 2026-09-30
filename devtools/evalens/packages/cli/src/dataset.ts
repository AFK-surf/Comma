import { mkdir, rename, rm } from "node:fs/promises";
import path from "node:path";
import type { BunFile } from "bun";
import { c as createTar, x as extractTar } from "tar";
import { z } from "zod";

import {
  DatasetName,
  ItemId,
  type Dataset,
  type DatasetItemArchive,
  type DatasetItemSchema,
  type DatasetReference,
  type DatasetSource,
  type LoadedDatasetItem,
} from "@evalens/core";

import type { EvalensConfig, R2Config } from "./config";

const DatasetManifest = z
  .object({
    name: DatasetName,
    description: z.string().optional(),
    items: z.array(z.object({ id: ItemId }).loose()).min(1),
  })
  .strict();
const Sha256 = z.string().regex(/^[a-f0-9]{64}$/);

export function createDatasetSource(
  config: EvalensConfig,
  configDir = process.cwd()
): DatasetSource {
  const root = path.join(configDir, "datasets");
  return new ContentAddressedDatasetSource(
    root,
    "remote" in config ? createR2Client(config.remote.r2) : undefined
  );
}

export async function packDataset(
  name: string,
  configDir: string
): Promise<{ digest: string; filePath: string }> {
  const datasetName = DatasetName.parse(name);
  const sourceDir = path.join(configDir, "datasets", datasetName);
  if (!(await Bun.file(path.join(sourceDir, "dataset.json")).exists())) {
    throw new Error(`dataset manifest is missing: ${datasetName}`);
  }
  DatasetManifest.parse(await Bun.file(path.join(sourceDir, "dataset.json")).json());

  const files: string[] = [];
  const glob = new Bun.Glob("**/*");
  for await (const relativePath of glob.scan({
    cwd: sourceDir,
    onlyFiles: true,
    dot: true,
  })) {
    const archivePath = relativePath.split(path.sep).join(path.posix.sep);
    if (archivePath === "sha256" || archivePath.startsWith("sha256/")) continue;
    files.push(archivePath);
  }
  if (!files.includes("dataset.json")) {
    throw new Error(`dataset manifest is missing: ${datasetName}`);
  }

  const outputDir = path.join(sourceDir, "sha256");
  await mkdir(outputDir, { recursive: true });
  const temporaryPath = path.join(outputDir, `.pack-${Bun.randomUUIDv7()}.tar`);
  await createTar(
    {
      cwd: sourceDir,
      file: temporaryPath,
      noMtime: true,
      portable: true,
    },
    files.sort()
  );
  const digest = await sha256File(temporaryPath);
  const filePath = path.join(outputDir, `${digest}.tar`);
  if (await Bun.file(filePath).exists()) {
    await rm(temporaryPath, { force: true });
  } else {
    await rename(temporaryPath, filePath);
  }
  return { digest, filePath };
}

export async function publishDataset(
  name: string,
  digest: string,
  configDir: string,
  r2: R2Config
): Promise<{ key: string; uploaded: boolean }> {
  const datasetName = DatasetName.parse(name);
  const parsedDigest = Sha256.parse(digest);
  const sourcePath = datasetArchivePath(configDir, datasetName, parsedDigest);
  const source = Bun.file(sourcePath);
  if (!(await source.exists())) {
    throw new Error(`packed dataset does not exist: ${sourcePath}`);
  }
  const actualDigest = await sha256File(sourcePath);
  if (actualDigest !== parsedDigest) {
    throw new Error(
      `packed dataset digest mismatch: expected ${parsedDigest}, received ${actualDigest}`
    );
  }

  const key = datasetObjectKey(datasetName, parsedDigest);
  const destination = createR2Client(r2).file(key);
  if (await destination.exists()) return { key, uploaded: false };
  await Bun.write(destination, source);
  return { key, uploaded: true };
}

class ContentAddressedDatasetSource implements DatasetSource {
  constructor(
    private readonly root: string,
    private readonly remote?: Bun.S3Client
  ) {}

  async load<Schema extends DatasetItemSchema>(
    reference: DatasetReference<Schema>
  ): Promise<Dataset<LoadedDatasetItem<Schema>>> {
    const name = DatasetName.parse(reference.name);
    const digest = Sha256.parse(reference.digest);
    const archivePath = path.join(this.root, name, "sha256", `${digest}.tar`);
    if (!(await Bun.file(archivePath).exists())) {
      await this.download(name, digest, archivePath);
    }
    const actualDigest = await sha256File(archivePath);
    if (actualDigest !== digest) {
      throw new Error(
        `dataset digest mismatch for ${name}: expected ${digest}, received ${actualDigest}`
      );
    }

    const extractedDir = path.join(this.root, name, "sha256", digest);
    await this.ensureExtracted(archivePath, extractedDir, digest);

    const manifest = DatasetManifest.parse(
      await Bun.file(path.join(extractedDir, "dataset.json")).json()
    );
    if (manifest.name !== name) {
      throw new Error(`dataset manifest name ${manifest.name} does not match ${name}`);
    }
    const items: LoadedDatasetItem<Schema>[] = [];
    for (const value of manifest.items) {
      const item = reference.itemSchema.parse(value);
      const archiveFile = Bun.file(path.join(extractedDir, "items", `${item.id}.tar`));
      items.push({
        ...item,
        archive: (await archiveFile.exists())
          ? new FileDatasetItemArchive(archiveFile)
          : undefined,
      });
    }
    return {
      name,
      description: manifest.description,
      digest,
      items,
    };
  }

  private async download(name: string, digest: string, destination: string) {
    if (!this.remote) {
      throw new Error(`dataset is not available locally: ${name}@${digest}`);
    }
    const source = this.remote.file(datasetObjectKey(name, digest));
    if (!(await source.exists())) {
      throw new Error(`dataset is not available in R2: ${name}@${digest}`);
    }
    await mkdir(path.dirname(destination), { recursive: true });
    const temporaryPath = `${destination}.download-${Bun.randomUUIDv7()}`;
    try {
      await Bun.write(temporaryPath, source);
      const actualDigest = await sha256File(temporaryPath);
      if (actualDigest !== digest) {
        throw new Error(
          `downloaded dataset digest mismatch: expected ${digest}, received ${actualDigest}`
        );
      }
      await rename(temporaryPath, destination);
    } finally {
      await rm(temporaryPath, { force: true });
    }
  }

  private async ensureExtracted(
    archivePath: string,
    extractedDir: string,
    digest: string
  ): Promise<void> {
    const completeMarker = path.join(extractedDir, ".complete");
    if (await Bun.file(completeMarker).exists()) return;

    const lockDirectory = `${extractedDir}.lock`;
    try {
      await mkdir(lockDirectory);
    } catch (error) {
      if (!(error instanceof Error && "code" in error && error.code === "EEXIST")) {
        throw error;
      }
      if (await Bun.file(completeMarker).exists()) return;
      throw new Error(
        `dataset cache is locked: ${lockDirectory}; if no dataset load is running, remove this lock directory manually`
      );
    }

    const temporaryDir = `${extractedDir}.extract-${Bun.randomUUIDv7()}`;
    try {
      if (await Bun.file(completeMarker).exists()) return;
      await mkdir(temporaryDir, { recursive: true });
      await extractTar({ file: archivePath, cwd: temporaryDir });
      DatasetManifest.parse(
        await Bun.file(path.join(temporaryDir, "dataset.json")).json()
      );
      await Bun.write(path.join(temporaryDir, ".complete"), digest);
      await rm(extractedDir, { recursive: true, force: true });
      await rename(temporaryDir, extractedDir);
    } finally {
      await rm(temporaryDir, { recursive: true, force: true });
      await rm(lockDirectory, { recursive: true, force: true });
    }
  }
}

class FileDatasetItemArchive implements DatasetItemArchive {
  constructor(private readonly file: BunFile) {}

  blob(): Promise<Blob> {
    return Promise.resolve(this.file);
  }

  bytes(): Promise<Uint8Array<ArrayBuffer>> {
    return this.file.bytes();
  }

  async extract(
    ...args: Parameters<DatasetItemArchive["extract"]>
  ): ReturnType<DatasetItemArchive["extract"]> {
    return (await this.open()).extract(...args);
  }

  async files(
    ...args: Parameters<DatasetItemArchive["files"]>
  ): ReturnType<DatasetItemArchive["files"]> {
    return (await this.open()).files(...args);
  }

  private async open(): Promise<Bun.Archive> {
    return new Bun.Archive(await this.file.bytes());
  }
}

function createR2Client(config: R2Config): Bun.S3Client {
  return new Bun.S3Client({
    endpoint: `https://${config.accountId}.r2.cloudflarestorage.com`,
    bucket: config.bucket,
    accessKeyId: config.accessKeyId,
    secretAccessKey: config.secretAccessKey,
  });
}

function datasetArchivePath(configDir: string, name: string, digest: string): string {
  return path.join(configDir, "datasets", name, "sha256", `${digest}.tar`);
}

function datasetObjectKey(name: string, digest: string): string {
  return path.posix.join("datasets", name, "sha256", `${digest}.tar`);
}

async function sha256File(filePath: string): Promise<string> {
  const hasher = new Bun.CryptoHasher("sha256");
  for await (const chunk of Bun.file(filePath).stream()) hasher.update(chunk);
  return hasher.digest("hex");
}
