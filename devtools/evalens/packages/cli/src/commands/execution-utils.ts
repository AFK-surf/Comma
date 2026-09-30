import path from "node:path";
import yargs from "yargs";
import { z, type JSONType } from "zod";

import {
  NoParamsSchema,
  Params,
  type AdapterNames,
  type DatasetItem,
  type EvalensStore,
  type Experiment,
  type ParamsSchema,
} from "@evalens/core";
import { createLocalStore } from "@evalens/store/local";

import type { EvalensConfig } from "../config";
import { createRemoteStore } from "../store/remote";

export type UnknownExperiment = Experiment<
  DatasetItem<unknown, unknown>,
  JSONType,
  ParamsSchema,
  ParamsSchema
>;

export async function loadExperiment(modulePath: string): Promise<UnknownExperiment> {
  const resolvePath = path.isAbsolute(modulePath)
    ? modulePath
    : path.resolve(process.cwd(), modulePath);
  const experiment = (await import(resolvePath)).default;
  if (!experiment) {
    throw new Error(
      `experiment module must export a default experiment: ${modulePath}`
    );
  }
  return experiment;
}

export function parseCliParams(args: string[]) {
  const {
    _,
    $0: _scriptName,
    ...params
  } = yargs(args)
    .parserConfiguration({
      "camel-case-expansion": false,
      "dot-notation": true,
      "parse-numbers": true,
      "boolean-negation": true,
    })
    .help(false)
    .version(false)
    .parseSync();

  return parseJsonValues(params);
}

export async function readCliParamsFile(filePath: string): Promise<unknown> {
  return Bun.file(filePath).json();
}

export function parseParams<Schema extends ParamsSchema>(
  schema: Schema | undefined,
  input: z.input<Schema> | undefined
): z.output<Schema>;
export function parseParams(
  schema: ParamsSchema | undefined,
  input: z.input<ParamsSchema> | undefined
) {
  return Params.parse((schema ?? NoParamsSchema).parse(input ?? {}));
}

export function evaluatorIdentities(
  evaluators: readonly { name: string; version: string }[]
) {
  return evaluators.map(({ name, version }) => ({ name, version }));
}

export function phaseAdapters<Names extends AdapterNames>(
  names: Names | undefined
): Names | readonly [] {
  return names ?? [];
}

export async function createStore(config: EvalensConfig): Promise<EvalensStore> {
  if ("local" in config) {
    return createLocalStore({ outputDir: config.local.outputDir });
  }
  return createRemoteStore(config.remote);
}

// Yargs parses individual scalars; comma-separated values represent flat arrays.
function parseJsonValues(value: unknown): unknown {
  if (typeof value === "string") {
    if (value.includes(",")) {
      return value.split(",").map((entry) => {
        if (entry === "true") return true;
        if (entry === "false") return false;
        if (entry === "null") return null;
        const number = Number(entry);
        return entry.length > 0 && Number.isFinite(number) ? number : entry;
      });
    }
    if (value === "null" || value.startsWith("{") || value.startsWith("[")) {
      try {
        return JSON.parse(value);
      } catch {
        return value;
      }
    }
    return value;
  }
  if (Array.isArray(value)) return value.map(parseJsonValues);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([key, entry]) => [key, parseJsonValues(entry)])
    );
  }
  return value;
}
