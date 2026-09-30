import { createFileLogger, type LoggerBindings } from "@evalens/core/logger";
import { type EvalensStore } from "@evalens/core/store/contracts";
import {
  Store,
  type ObjectNamespace,
  type ObjectNamespaceFile,
  type ObjectWriteData,
  writeObject,
} from "@evalens/store";
import { mkdirSync, writeFileSync } from "node:fs";
import { rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { createRemoteMetadataWriter } from "./metadata-writer";

const PRESIGNED_PUT_THRESHOLD_BYTES = 256 * 1024;

export type CreateRemoteStoreOptions = {
  url: string;
  access: {
    clientId: string;
    clientSecret: string;
  };
  r2: {
    accountId: string;
    bucket: string;
    accessKeyId: string;
    secretAccessKey: string;
  };
  fetch?: typeof fetch;
  createId?: () => string;
  namespace?: ObjectNamespace;
};

export function createRemoteStore(options: CreateRemoteStoreOptions): EvalensStore {
  const namespace =
    options.namespace ??
    new S3ObjectNamespace(
      new Bun.S3Client({
        endpoint: `https://${options.r2.accountId}.r2.cloudflarestorage.com`,
        bucket: options.r2.bucket,
        accessKeyId: options.r2.accessKeyId,
        secretAccessKey: options.r2.secretAccessKey,
        retry: 8,
      })
    );
  return new Store({
    namespace,
    metadataWriter: createRemoteMetadataWriter({
      url: options.url,
      access: options.access,
      fetcher: options.fetch,
    }),
    createLogger: (key, bindings) => createRemoteLogger(namespace, key, bindings),
    createId: options.createId,
  });
}

export class S3ObjectNamespace implements ObjectNamespace {
  constructor(
    readonly client: Bun.S3Client,
    private readonly fetcher: typeof fetch = fetch,
    private readonly requestTimeoutMs = 60_000
  ) {}

  file(key: string): ObjectNamespaceFile {
    return this.client.file(key);
  }

  async write(key: string, data: ObjectWriteData): Promise<void> {
    const body = await objectBody(data);
    if (objectBodySize(body) < PRESIGNED_PUT_THRESHOLD_BYTES) {
      await withDeadline(
        this.client.file(key).write(body as never),
        this.requestTimeoutMs
      );
      return;
    }
    const response = await this.fetcher(
      this.client.file(key).presign({ method: "PUT", expiresIn: 5 * 60 }),
      {
        method: "PUT",
        body,
        signal: AbortSignal.timeout(this.requestTimeoutMs),
      }
    );
    if (!response.ok) {
      throw Object.assign(
        new Error(`R2 object write failed with HTTP ${response.status}`),
        { status: response.status }
      );
    }
  }

  async *list(prefix: string): AsyncIterable<string> {
    const directoryPrefix = prefix.endsWith("/") ? prefix : `${prefix}/`;
    let continuationToken: string | undefined;
    do {
      const page = await this.client.list({
        prefix: directoryPrefix,
        continuationToken,
      });
      for (const object of page.contents ?? []) yield object.key;
      if (page.isTruncated && !page.nextContinuationToken) {
        throw new Error("truncated R2 listing did not include a continuation token");
      }
      continuationToken = page.isTruncated ? page.nextContinuationToken : undefined;
    } while (continuationToken);
  }
}

function createRemoteLogger(
  namespace: ObjectNamespace,
  key: string,
  bindings: LoggerBindings
) {
  const localPath = path.join(
    os.tmpdir(),
    "evalens",
    `${Bun.randomUUIDv7()}.log.jsonl`
  );
  mkdirSync(path.dirname(localPath), { recursive: true });
  writeFileSync(localPath, "");
  const local = createFileLogger({ logFile: localPath, bindings });
  return {
    logger: local.logger,
    flush: local.flush,
    async [Symbol.asyncDispose]() {
      try {
        await local[Symbol.asyncDispose]();
        await writeObject(namespace, key, Bun.file(localPath));
      } finally {
        await rm(localPath, { force: true });
      }
    },
  };
}

type FetchRequestBody = NonNullable<NonNullable<Parameters<typeof fetch>[1]>["body"]>;

async function objectBody(data: ObjectWriteData): Promise<FetchRequestBody> {
  if (data instanceof Bun.Archive) return data.blob();
  if (data instanceof SharedArrayBuffer) return new Uint8Array(data);
  return data as FetchRequestBody;
}

function objectBodySize(body: FetchRequestBody): number {
  if (typeof body === "string") return Buffer.byteLength(body);
  if (body instanceof Blob) return body.size;
  if (body instanceof ArrayBuffer) return body.byteLength;
  if (ArrayBuffer.isView(body)) return body.byteLength;
  return PRESIGNED_PUT_THRESHOLD_BYTES;
}

async function withDeadline<T>(promise: Promise<T>, timeoutMs: number): Promise<T> {
  let timeout: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      promise,
      new Promise<never>((_resolve, reject) => {
        timeout = setTimeout(
          () =>
            reject(
              Object.assign(new Error("R2 object write timed out"), {
                code: "Timeout",
              })
            ),
          timeoutMs
        );
      }),
    ]);
  } finally {
    if (timeout) clearTimeout(timeout);
  }
}
