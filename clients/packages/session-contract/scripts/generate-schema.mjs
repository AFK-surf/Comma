import { mkdir, readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { format, resolveConfig } from "prettier";
import { z } from "zod";
import { sessionLifecycleSnapshotSchema } from "../src/contracts.ts";

const outputUrl = new URL(
  "../generated/session-lifecycle.schema.json",
  import.meta.url
);
const outputPath = fileURLToPath(outputUrl);
const prettierConfig = (await resolveConfig(outputPath)) ?? {};
const expected = await format(
  JSON.stringify(
    z.toJSONSchema(sessionLifecycleSnapshotSchema, {
      target: "draft-7",
    })
  ),
  {
    ...prettierConfig,
    filepath: outputPath,
    parser: "json",
  }
);

if (process.argv.includes("--check")) {
  const actual = await readFile(outputPath, "utf8").catch(() => "");
  if (actual !== expected) {
    process.stderr.write(
      "session-lifecycle.schema.json is stale; run pnpm generate:schema.\n"
    );
    process.exitCode = 1;
  }
} else {
  await mkdir(new URL("../generated/", import.meta.url), { recursive: true });
  await writeFile(outputPath, expected);
}
