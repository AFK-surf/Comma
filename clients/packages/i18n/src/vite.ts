import { fileURLToPath } from "node:url";
import { paraglideVitePlugin } from "@inlang/paraglide-js";

export function commaI18nVitePlugin() {
  return paraglideVitePlugin({
    project: fileURLToPath(new URL("../project.inlang", import.meta.url)),
    outdir: fileURLToPath(new URL("./paraglide", import.meta.url)),
    strategy: ["globalVariable", "baseLocale"],
    outputStructure: "message-modules",
    emitTsDeclarations: true,
  });
}
