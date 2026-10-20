import { minifySync, type Plugin } from "vite";

// The dev server inlines each module's source map into the module itself.
// For pre-bundled dependencies and the generated message catalogs, the map is
// most of the response: the 858 KB `test` bundle went out as 4.4 MB and
// `effect` as 22 MB. Browser test jobs on the CI Macs sometimes receive such
// a large response with part of it sent twice, and the module then fails to
// parse (clients/vite/parse-failure-watch.ts). These modules are not ours, so
// the browser tests serve them without maps; our own modules keep theirs, and
// so do stack traces through them. The message catalogs also lose their
// JSDoc, which is most of the 2.2 MB `_index.js`.

/** The generated message catalogs (`#messages`), compiled by paraglide. */
const GENERATED_MESSAGES = /\/packages\/i18n\/src\/paraglide\//;

const SOURCE_MAP_COMMENT = /\n\/\/# sourceMappingURL=[^\n]*\s*$/;

/** The same code without comments, still readable: nothing renamed or folded. */
function withoutComments(id: string, code: string) {
  const { code: stripped, errors } = minifySync(id.replace(/\?.*/s, ""), code, {
    compress: false,
    mangle: false,
    codegen: { removeWhitespace: false },
  });
  return errors.length ? code : stripped;
}

/** Serves dependencies and generated message catalogs without source maps. */
export function noDependencySourceMapsPlugin(): Plugin {
  return {
    name: "comma:no-dependency-source-maps",
    apply: "serve",
    enforce: "post",
    transform(code, id) {
      const messages = GENERATED_MESSAGES.test(id);
      // Pre-bundled dependencies live in the cache directory under
      // node_modules too.
      if (!messages && !id.includes("/node_modules/")) return undefined;
      const served = code.replace(SOURCE_MAP_COMMENT, "\n");
      // An empty `mappings` tells Vite the module has no source map, so it
      // neither inlines one nor generates a fallback.
      return {
        code: messages ? withoutComments(id, served) : served,
        map: { mappings: "" },
      };
    },
  };
}
