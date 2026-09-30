import { z } from "zod";

import { Identifier } from "./schemas";

export interface AdapterConfigRegistry {}

export type AdapterName = Extract<keyof AdapterConfigRegistry, string>;
export type AdapterNames = readonly AdapterName[];

export type DeepReadonly<Value> = Value extends (...args: never[]) => unknown
  ? Value
  : Value extends readonly unknown[]
    ? { readonly [Key in keyof Value]: DeepReadonly<Value[Key]> }
    : Value extends object
      ? { readonly [Key in keyof Value]: DeepReadonly<Value[Key]> }
      : Value;

export type AdapterConfigFor<Names extends AdapterNames> = Pick<
  AdapterConfigRegistry,
  Names[number]
>;

export const AdapterIdentity = z
  .object({
    name: Identifier,
    version: Identifier,
  })
  .strict();
export type AdapterIdentity = z.infer<typeof AdapterIdentity>;

export const AdapterIdentities = z
  .array(AdapterIdentity)
  .refine(
    (adapters) => new Set(adapters.map(({ name }) => name)).size === adapters.length,
    "adapter names must be unique"
  );
