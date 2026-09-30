import { mkdirSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const previewDirectory = join(scriptDirectory, "..", ".preview");

for (const outputName of ["site", "png"]) {
  const outputDirectory = join(previewDirectory, outputName);
  rmSync(outputDirectory, { recursive: true, force: true });
  mkdirSync(outputDirectory, { recursive: true });
}

console.log("已清理并重建本地架构预览输出目录。");
