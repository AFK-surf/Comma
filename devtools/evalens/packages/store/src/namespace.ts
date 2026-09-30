import type { BunFile, S3File } from "bun";

export type ObjectNamespaceFile = BunFile | S3File;
export type ObjectWriteData =
  string | ArrayBufferView | ArrayBuffer | SharedArrayBuffer | Blob | Bun.Archive;

export interface ObjectNamespace {
  file(key: string): ObjectNamespaceFile;
  write?(key: string, data: ObjectWriteData): Promise<void>;
  list(prefix: string): AsyncIterable<string>;
}

export async function writeObject(
  namespace: ObjectNamespace,
  key: string,
  data: ObjectWriteData
): Promise<void> {
  if (namespace.write) {
    await namespace.write(key, data);
    return;
  }
  const writable = data instanceof Bun.Archive ? await data.blob() : data;
  await namespace.file(key).write(writable as never);
}
