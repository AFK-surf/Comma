/// <reference lib="webworker" />
// This tab's core worker: the tabs' workers elect one (a Web Lock) to run the Comma client core; the others relay to
// it (packages/core, hosts/web.ts). The page names the worker `comma-core:<API origin>`.
import { runWebCoreWorker } from "@comma/core/web";

declare const COMMA_DEFINED_CORE_BUILD: number;

const name = (self as unknown as { name: string }).name;
runWebCoreWorker({
  apiBase: name.slice(name.indexOf(":") + 1),
  build: COMMA_DEFINED_CORE_BUILD,
});
