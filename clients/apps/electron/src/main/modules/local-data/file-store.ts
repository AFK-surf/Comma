import { existsSync, mkdirSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

export interface LocalDataReferenceReader {
  referencedBlobIds(): Promise<string[]> | string[];
}

export class FileStore {
  readonly #localData: LocalDataReferenceReader;
  readonly #rootDir: string;

  private constructor({
    localData,
    rootDir,
  }: {
    localData: LocalDataReferenceReader;
    rootDir: string;
  }) {
    this.#localData = localData;
    this.#rootDir = rootDir;
  }

  static open({
    localData,
    rootDir,
  }: {
    localData: LocalDataReferenceReader;
    rootDir: string;
  }) {
    mkdirSync(rootDir, { recursive: true });
    return new FileStore({ localData, rootDir });
  }

  blobCount() {
    return this.#blobFiles().length;
  }

  async findMissingReferencedBlobs() {
    const referencedBlobIds = await this.#localData.referencedBlobIds();
    return referencedBlobIds.filter(
      (blobId) => !existsSync(this.#blobPath(parseBlobId(blobId)))
    );
  }

  rootDir() {
    return this.#rootDir;
  }

  totalBytes() {
    return this.#blobFiles().reduce((total, blob) => total + blob.byteLength, 0);
  }

  #blobFiles() {
    if (!existsSync(this.#rootDir)) return [];

    const blobs: Array<{ blobId: string; byteLength: number; path: string }> = [];
    for (const prefix of readdirSync(this.#rootDir, { withFileTypes: true })) {
      if (!prefix.isDirectory()) continue;

      const prefixDir = join(this.#rootDir, prefix.name);
      for (const file of readdirSync(prefixDir, { withFileTypes: true })) {
        if (!file.isFile() || !isSha256Hash(file.name)) continue;

        const path = join(prefixDir, file.name);
        blobs.push({
          blobId: blobIdFromHash(file.name),
          byteLength: statSync(path).size,
          path,
        });
      }
    }

    return blobs.toSorted((left, right) => left.blobId.localeCompare(right.blobId));
  }

  #blobPath(contentHash: string) {
    return join(this.#rootDir, contentHash.slice(0, 2), contentHash);
  }
}

function blobIdFromHash(contentHash: string) {
  return `sha256:${contentHash}`;
}

function isSha256Hash(value: string) {
  return /^[a-f0-9]{64}$/.test(value);
}

function parseBlobId(blobId: string) {
  const [algorithm, contentHash] = blobId.split(":");
  if (algorithm !== "sha256" || !contentHash || !isSha256Hash(contentHash)) {
    throw new Error(`Invalid FileStore blob id: ${blobId}`);
  }

  return contentHash;
}
