import { mkdir } from "node:fs/promises";
import path from "node:path";

import { createFileLogger } from "@evalens/core/logger";
import { IndexService } from "../metadata/index-service";
import { type MetadataWriter, NoopMetadataWriter } from "../metadata/contracts";
import { Store, type WarningSink } from "../store";
import { LocalObjectNamespace } from "./object-namespace";
import { SqliteMetadataWriter } from "./sqlite-metadata-writer";

export async function createLocalStore(options: {
  outputDir: string;
  warn?: WarningSink;
}): Promise<Store> {
  const namespace = new LocalObjectNamespace(options.outputDir);
  const metadataDir = path.join(options.outputDir, ".evalens");
  await mkdir(metadataDir, { recursive: true });
  const metadataWriter = SqliteMetadataWriter.open(
    path.join(metadataDir, "index.sqlite")
  );
  try {
    const indexService = new IndexService(namespace, metadataWriter);
    if (metadataWriter.getIndexState() !== "ready") await indexService.bootstrap();
    else await indexService.repairMarkedScopes({ type: "all" });
  } catch (error) {
    metadataWriter.database.close();
    throw error;
  }
  return createLocalStoreWithMetadata(namespace, metadataWriter, options.warn, () =>
    metadataWriter.database.close()
  );
}

export function createUnindexedLocalStore(options: {
  outputDir: string;
  warn?: WarningSink;
}): Store {
  const namespace = new LocalObjectNamespace(options.outputDir);
  return createLocalStoreWithMetadata(
    namespace,
    new NoopMetadataWriter(),
    options.warn
  );
}

function createLocalStoreWithMetadata(
  namespace: LocalObjectNamespace,
  metadataWriter: MetadataWriter,
  warn?: WarningSink,
  dispose?: () => void | Promise<void>
): Store {
  return new Store({
    namespace,
    metadataWriter,
    createLogger: (key, bindings) =>
      createFileLogger({ logFile: namespace.resolve(key), bindings }),
    warn,
    dispose,
  });
}
