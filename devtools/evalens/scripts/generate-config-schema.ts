import path from "node:path";
import { format, resolveConfig } from "prettier";
import { z } from "zod";

import { EvalensConfigSchema } from "../packages/cli/src/config";

const outputPath = path.join(import.meta.dirname, "..", "evalens.config.schema.json");
const prettierConfig = await resolveConfig(outputPath);

await Bun.write(
  outputPath,
  await format(JSON.stringify(z.toJSONSchema(EvalensConfigSchema)), {
    ...prettierConfig,
    filepath: outputPath,
  })
);
