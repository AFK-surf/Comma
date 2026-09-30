import { resolve } from "node:path";
import { CatalogSchema } from "../shared/schema";

const catalogPath = resolve(import.meta.dir, "../data/catalog.generated.json");
const parsed = CatalogSchema.safeParse(await Bun.file(catalogPath).json());

if (!parsed.success) {
  console.error(parsed.error.issues);
  process.exit(1);
}

const ids = new Set<string>();
for (const document of parsed.data.documents) {
  if (ids.has(document.id)) {
    console.error(`duplicate document id: ${document.id}`);
    process.exit(1);
  }
  ids.add(document.id);

  const lineIds = new Set<string>();
  for (const line of document.lines) {
    if (lineIds.has(line.id)) {
      console.error(`duplicate line id in ${document.id}: ${line.id}`);
      process.exit(1);
    }
    if (line.source.lineEnd < line.source.lineStart) {
      console.error(`invalid source range for ${line.id}`);
      process.exit(1);
    }
    lineIds.add(line.id);
  }
}

console.log(
  `catalog valid: ${parsed.data.documents.length} documents, ${parsed.data.documents.reduce((sum, item) => sum + item.lines.length, 0)} lines`,
);
