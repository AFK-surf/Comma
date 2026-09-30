import { parse } from "@babel/parser";
import MagicString from "magic-string";
import { relative, resolve } from "node:path";
import type { Plugin, ResolvedConfig } from "vite";
import { layoutInspectorSourceAttribute } from "./source-location.ts";

export type LayoutInspectorSourcePluginOptions = {
  enabled?: boolean;
  include?: (absoluteFile: string) => boolean;
  root?: string;
};

type JsxOpeningElement = {
  attributes: Array<{
    name?: {
      name?: string;
      type?: string;
    };
    type?: string;
  }>;
  loc?: {
    start: {
      column: number;
      line: number;
    };
  } | null;
  name: {
    end?: number | null;
    name?: string;
    type?: string;
  };
  type: "JSXOpeningElement";
};

export function layoutInspectorSourcePlugin(
  options: LayoutInspectorSourcePluginOptions = {}
): Plugin {
  let enabled = options.enabled;
  let sourceRoot = options.root ? resolve(options.root) : undefined;

  return {
    name: "comma-layout-inspector-source",
    enforce: "pre",
    configResolved(config: ResolvedConfig) {
      enabled ??= config.mode !== "production";
      sourceRoot ??= config.root;
    },
    transform(code, id) {
      if (enabled === false) return null;
      const absoluteFile = cleanModuleId(id);
      if (
        !absoluteFile ||
        !/\.[cm]?[jt]sx$/.test(absoluteFile) ||
        absoluteFile.includes("/node_modules/") ||
        (options.include && !options.include(absoluteFile))
      ) {
        return null;
      }

      const root = sourceRoot ?? process.cwd();
      const sourceFile = normalizePath(relative(root, absoluteFile));
      const ast = parse(code, {
        plugins: ["typescript", "jsx", "decorators-legacy"],
        sourceFilename: sourceFile,
        sourceType: "module",
      });
      const output = new MagicString(code);
      let insertionCount = 0;

      walkAst(ast, (element) => {
        const { name } = element;
        if (
          name.type !== "JSXIdentifier" ||
          !name.name ||
          !isNativeElementName(name.name) ||
          typeof name.end !== "number" ||
          hasSourceAttribute(element)
        ) {
          return;
        }

        const start = element.loc?.start;
        if (!start) return;
        output.appendLeft(
          name.end,
          ` ${layoutInspectorSourceAttribute}=${JSON.stringify(
            `${sourceFile}:${start.line}:${start.column + 1}`
          )}`
        );
        insertionCount += 1;
      });

      if (insertionCount === 0) return null;
      return {
        code: output.toString(),
        map: output
          .generateMap({
            hires: "boundary",
            includeContent: true,
            source: sourceFile,
          })
          .toString(),
      };
    },
  };
}

function walkAst(value: unknown, visit: (element: JsxOpeningElement) => void): void {
  if (Array.isArray(value)) {
    for (const child of value) walkAst(child, visit);
    return;
  }
  if (!value || typeof value !== "object") return;

  const node = value as Record<string, unknown>;
  if (node.type === "JSXOpeningElement") {
    visit(node as JsxOpeningElement);
  }
  for (const [key, child] of Object.entries(node)) {
    if (
      key === "comments" ||
      key === "end" ||
      key === "errors" ||
      key === "extra" ||
      key === "loc" ||
      key === "start" ||
      key === "tokens"
    ) {
      continue;
    }
    walkAst(child, visit);
  }
}

function hasSourceAttribute(element: JsxOpeningElement) {
  return element.attributes.some(
    (attribute) =>
      attribute.type === "JSXAttribute" &&
      attribute.name?.type === "JSXIdentifier" &&
      attribute.name.name === layoutInspectorSourceAttribute
  );
}

function cleanModuleId(id: string) {
  if (!id || id.startsWith("\0")) return undefined;
  const queryIndex = id.indexOf("?");
  return queryIndex === -1 ? id : id.slice(0, queryIndex);
}

function isNativeElementName(name: string) {
  return /^[a-z]/.test(name);
}

function normalizePath(path: string) {
  return path.replaceAll("\\", "/");
}
