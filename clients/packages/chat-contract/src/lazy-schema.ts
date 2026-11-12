// A schema made when it is first used, not when its module loads. Zod makes a schema and every schema it is chained
// from at once; the client core defines hundreds and uses few of them to start, so making them all as it loads is most
// of its start (on the phones' Hermes: 84 ms of CPU and 13.5 MB kept, against 21 ms and 3.4 MB made on first use).
//
// The value stands for the schema in every way a caller has (its methods, its fields, `instanceof`, its place inside
// another schema): each is the made schema's own. Its identity is not, and zod keeps `.meta()` and `.describe()` in a
// registry by the schema itself: a made schema's entry there is given to its stand-in too, so a schema that carries
// them is found by either.
import { z } from "zod";

/**
 * Told of each check through a schema (`parse`, `safeParse` and their kinds) while set: a test's core counts them.
 * `made` counts the schemas made so far; `trace`, while set, keeps where each was made from.
 */
export const schemaChecks: {
  watch: ((schema: object) => void) | null;
  made: number;
  trace: string[] | null;
} = { watch: null, made: 0, trace: null };

const CHECKS = new Set([
  "parse",
  "safeParse",
  "parseAsync",
  "safeParseAsync",
  "decode",
  "safeDecode",
]);

type Registry = { _map: WeakMap<object, unknown> };

/** `make()`'s schema, made the first time anything reads it. */
export function lazySchema<T extends object>(make: () => T): T {
  let made: T | undefined;
  const schema = (): T => {
    if (made === undefined) {
      made = make();
      schemaChecks.made++;
      schemaChecks.trace?.push(new Error("made here").stack ?? "");
      // The entry by its id stays the made schema's (an id is once in the registry); the stand-in is found by itself.
      const meta = z.globalRegistry.get(made as never);
      // oxlint-disable-next-line no-underscore-dangle -- zod's own map by schema: `add` would claim the id again.
      if (meta) (z.globalRegistry as unknown as Registry)._map.set(proxy, meta);
    }
    return made;
  };
  const stand = {} as T;
  const proxy: T = new Proxy(stand, {
    get: (_, key) => {
      const value = Reflect.get(schema(), key) as unknown;
      const watch = schemaChecks.watch;
      if (
        !watch ||
        typeof key !== "string" ||
        !CHECKS.has(key) ||
        typeof value !== "function"
      )
        return value;
      return (...args: unknown[]) => {
        watch(stand);
        return (value as (...a: unknown[]) => unknown)(...args);
      };
    },
    set: (_, key, value) => Reflect.set(schema(), key, value),
    has: (_, key) => Reflect.has(schema(), key),
    ownKeys: () => Reflect.ownKeys(schema()),
    getOwnPropertyDescriptor: (_, key) => {
      const descriptor = Reflect.getOwnPropertyDescriptor(schema(), key);
      // The stand-in has none of its own: a field it reports must be one it could have.
      return descriptor && { ...descriptor, configurable: true };
    },
    defineProperty: (_, key, descriptor) =>
      Reflect.defineProperty(schema(), key, descriptor),
    deleteProperty: (_, key) => Reflect.deleteProperty(schema(), key),
    getPrototypeOf: () => Reflect.getPrototypeOf(schema()),
  });
  return proxy;
}
