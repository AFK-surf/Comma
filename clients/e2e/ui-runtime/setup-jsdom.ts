import Module from "node:module";
import { installTestUiHost } from "../../packages/ui/src/runtime/test/testing";

// React DOM loads as a Node module here, outside Vite's aliases: point its
// `scheduler` at React's mock scheduler before it loads.
const mock = Module.createRequire(import.meta.url).resolve("scheduler/unstable_mock");
type Resolve = (request: string, ...rest: unknown[]) => string;
const resolver = Module as unknown as Record<string, Resolve>;
const resolveFilename = "_resolveFilename";
const resolve = resolver[resolveFilename]!;
resolver[resolveFilename] = function (this: unknown, request, ...rest) {
  return request === "scheduler" ? mock : resolve.call(this, request, ...rest);
};

installTestUiHost();
