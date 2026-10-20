import { fileURLToPath } from "node:url";
import { compile, paraglideVitePlugin } from "@inlang/paraglide-js";
import type { ConfigEnv, Plugin, UserConfig } from "vite";
import {
  ensureCompiled,
  hostCache,
  viteIsServer,
} from "../scripts/compiled-catalogs.mjs";

/** The dev server and a watching build recompile when a catalog changes. */
const watches = (config: UserConfig, { command }: ConfigEnv) =>
  command === "serve" || Boolean(config.build?.watch);

export function commaI18nVitePlugin(): Plugin[] {
  const paraglide = paraglideVitePlugin({
    project: fileURLToPath(new URL("../project.inlang", import.meta.url)),
    outdir: fileURLToPath(new URL("./paraglide", import.meta.url)),
    strategy: ["globalVariable", "baseLocale"],
    outputStructure: "locale-modules",
    emitTsDeclarations: true,
  }) as Plugin | Plugin[];
  return [
    // A build reads the catalogs once: it compiles them only when
    // src/paraglide does not hold their output yet
    // (../scripts/compiled-catalogs.mjs). Paraglide's plugin compiles on
    // every start, which each build of a CI job paid for again.
    {
      name: "comma-i18n-compiled-catalogs",
      enforce: "pre",
      apply: (config, env) => !watches(config, env),
      async buildStart() {
        const how = await ensureCompiled({
          isServer: viteIsServer,
          cache: hostCache(),
          compile,
        });
        this.info(`Message catalogs: ${how}.`);
      },
    },
    ...[paraglide].flat().map((plugin) => ({ ...plugin, apply: watches })),
  ];
}
