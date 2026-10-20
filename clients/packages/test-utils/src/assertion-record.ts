import { createRequire, syncBuiltinESMExports } from "node:module";
import { inspect } from "node:util";
import { chai, vi, type RunnerTestCase } from "vitest";

type Listener = (test: RunnerTestCase | undefined, event: string) => void;
const listeners = new Set<Listener>();
let restore: (() => void) | undefined;

// Record values when the matcher reads them. A later mutation of an object or
// reset of a mock must not change an earlier observation. Do not run getters,
// custom inspectors or toJSON, or truncate long strings and collections.
//
// Values are recorded whole, class instances included, up to the edges of
// the host's object graph: a DOM node is recorded by its markup and form
// values, the window and React's internals (fibers, an event's target
// instance) by a placeholder. Platform values with no fields of their own
// (URL, Headers, Blob) are recorded by what they hold.
function nodeOf(value: Node) {
  return {
    node: value instanceof Element ? value.outerHTML : value.nodeValue,
    ...(value instanceof HTMLInputElement
      ? { value: value.value, checked: value.checked }
      : value instanceof HTMLTextAreaElement
        ? { value: value.value }
        : value instanceof HTMLSelectElement
          ? { selected: Array.from(value.selectedOptions, (option) => option.value) }
          : {}),
  };
}

const snapshotNode = (node: Node) =>
  node instanceof Element ? node.tagName.toLowerCase() : node.nodeValue;

const isNode = (value: unknown): value is Node =>
  typeof Node !== "undefined" && value instanceof Node;

function primitive(value: unknown) {
  return value === null || (typeof value !== "object" && typeof value !== "function");
}

// React's internal links: each reaches the whole tree of fibers.
const reactInternal =
  /^(__react|_react|_owner$|_store$|_targetInst$|_debug|stateNode$|return$|child$|sibling$|alternate$)/;

/** The classes of the values recorded by class, counted (DETERMINISM_CLASS_STATS). */
export const recordedClasses = new Map<string, number>();

// What a platform value holds, read through its own deterministic accessors.
function platformValue(object: object): unknown {
  const named = (name: string) => {
    const type = (globalThis as Record<string, unknown>)[name];
    return typeof type === "function" && object instanceof (type as new () => object);
  };
  if (named("URL")) return { URL: (object as URL).href };
  if (named("Range")) {
    const range = object as Range;
    return {
      Range: {
        start: [snapshotNode(range.startContainer), range.startOffset],
        end: [snapshotNode(range.endContainer), range.endOffset],
        text: range.toString(),
      },
    };
  }
  if (named("AbortSignal"))
    return { AbortSignal: { aborted: (object as AbortSignal).aborted } };
  if (named("URLSearchParams")) return { URLSearchParams: String(object) };
  if (named("Headers")) return { Headers: [...(object as Headers).entries()] };
  if (named("File"))
    return {
      File: {
        name: (object as File).name,
        size: (object as File).size,
        type: (object as File).type,
      },
    };
  if (named("Blob"))
    return { Blob: { size: (object as Blob).size, type: (object as Blob).type } };
  if (named("Request"))
    return {
      Request: { method: (object as Request).method, url: (object as Request).url },
    };
  if (named("Response"))
    return {
      Response: { status: (object as Response).status, url: (object as Response).url },
    };
  const temporal = (globalThis as { Temporal?: Record<string, unknown> }).Temporal;
  if (temporal)
    for (const [name, type] of Object.entries(temporal))
      if (typeof type === "function" && object instanceof (type as new () => object))
        return { [`Temporal.${name}`]: String(object) };
  return undefined;
}

function snapshot(value: unknown, seen = new Set<object>()): unknown {
  if (typeof value === "bigint" || typeof value === "symbol") return String(value);
  if (primitive(value)) return value;
  if (vi.isMockFunction(value))
    return {
      calls: snapshot(value.mock.calls, seen),
      results: snapshot(value.mock.results, seen),
    };
  if (typeof value === "function") return `[Function ${value.name}]`;
  const object = value as object;
  if (seen.has(object)) return "[Circular]";
  if (isNode(object)) return nodeOf(object);
  if (object === globalThis) return "[Window]";
  seen.add(object);
  try {
    if (Array.isArray(object)) return object.map((item) => snapshot(item, seen));
    if (object instanceof Map)
      return {
        Map: [...object].map(([key, item]) => [
          snapshot(key, seen),
          snapshot(item, seen),
        ]),
      };
    if (object instanceof Set)
      return { Set: [...object].map((item) => snapshot(item, seen)) };
    if (object instanceof Date) return { Date: object.getTime() };
    if (object instanceof RegExp) return { RegExp: String(object) };
    if (object instanceof Error) return { Error: object.name, message: object.message };
    if (ArrayBuffer.isView(object))
      return { [object.constructor.name]: Array.from(object as Uint8Array) };
    if (
      (typeof NodeList !== "undefined" && object instanceof NodeList) ||
      (typeof HTMLCollection !== "undefined" && object instanceof HTMLCollection)
    )
      return {
        [object.constructor.name]: Array.from(object as ArrayLike<Node>, nodeOf),
      };
    const platform = platformValue(object);
    if (platform !== undefined) return platform;
    const prototype = Object.getPrototypeOf(object) as object | null;
    const plain = prototype === null || prototype === Object.prototype;
    const fields: Record<string, unknown> = {};
    for (const [key, descriptor] of Object.entries(
      Object.getOwnPropertyDescriptors(object)
    )) {
      if (!descriptor.enumerable) continue;
      if (reactInternal.test(key)) fields[key] = "[React internals]";
      else if (!("value" in descriptor)) fields[key] = "[Getter]";
      else fields[key] = snapshot(descriptor.value, seen);
    }
    if (plain) return fields;
    const name = prototype?.constructor?.name ?? "Object";
    recordedClasses.set(name, (recordedClasses.get(name) ?? 0) + 1);
    return { [name]: fields };
  } finally {
    seen.delete(object);
  }
}

function valueOf(value: unknown): unknown {
  return snapshot(value);
}

function record(assertion: Chai.AssertionStatic, method: string, args: unknown[]) {
  const test = chai.util.flag(assertion, "vitest-test") as RunnerTestCase | undefined;
  emit(test, {
    method,
    not: chai.util.flag(assertion, "negate") === true,
    actual: valueOf(chai.util.flag(assertion, "object")),
    arguments: args.map(valueOf),
  });
}

function emit(test: RunnerTestCase | undefined, observation: object) {
  const event = inspect(observation, {
    depth: null,
    maxArrayLength: null,
    maxStringLength: null,
    customInspect: false,
    getters: false,
    colors: false,
    compact: true,
    breakLength: Infinity,
  });
  for (const listen of listeners) listen(test, event);
}

/** Observe actual Vitest matchers, including mocks, promises and expect.extend. */
export function observeAssertions(listen: Listener): () => void {
  const stop = () => {
    listeners.delete(listen);
    if (listeners.size === 0) {
      restore?.();
      restore = undefined;
    }
  };
  listeners.add(listen);
  if (listeners.size > 1) return stop;
  const prototype = chai.Assertion.prototype;
  const originals = new Map<string, PropertyDescriptor>();
  const wrapped = new WeakSet<object>();
  const wrap = (name: string) => {
    if (name === "constructor" || name === "withTest") return;
    const descriptor = Object.getOwnPropertyDescriptor(prototype, name);
    const original = descriptor?.value;
    if (typeof original !== "function" || wrapped.has(original)) return;
    const observer = function (this: Chai.AssertionStatic, ...args: unknown[]) {
      record(this, name, args);
      return Reflect.apply(original, this, args);
    };
    // Keep Chai's length guard and Vitest's non-enumerable matcher markers.
    for (const key of Reflect.ownKeys(original)) {
      if (Object.getOwnPropertyDescriptor(observer, key)?.configurable === false)
        continue;
      Object.defineProperty(
        observer,
        key,
        Object.getOwnPropertyDescriptor(original, key)!
      );
    }
    wrapped.add(observer);
    originals.set(name, descriptor!);
    Object.defineProperty(prototype, name, { ...descriptor, value: observer });
  };
  for (const name of Object.getOwnPropertyNames(prototype)) wrap(name);
  // Chai emits this after an extension installs a method. Custom matchers and
  // jest-dom can load after this setup file, or inside a test.
  const events = (chai.util as typeof chai.util & { events: EventTarget }).events;
  const added = (event: Event) => wrap((event as Event & { name: string }).name);
  events.addEventListener("addMethod", added);
  const restoreNodeAssert = observeNodeAssert();
  restore = () => {
    events.removeEventListener("addMethod", added);
    for (const [name, descriptor] of originals)
      Object.defineProperty(prototype, name, descriptor);
    restoreNodeAssert();
  };
  return stop;
}

const require = createRequire(import.meta.url);

// `node:assert` and `node:assert/strict`: each check is an observation of the
// values it was given. A bare `assert(value)` call is the module itself and
// stays unobserved; `assert.ok(value)` is observed.
function observeNodeAssert() {
  const originals: [Record<string, unknown>, string, unknown][] = [];
  for (const id of ["node:assert", "node:assert/strict"]) {
    const module = require(id) as Record<string, unknown>;
    for (const [name, check] of Object.entries(module)) {
      if (typeof check !== "function" || /^[A-Z]/.test(name) || name === "strict")
        continue;
      originals.push([module, name, check]);
      module[name] = function (this: unknown, ...args: unknown[]) {
        emit(undefined, { assert: name, arguments: args.map(valueOf) });
        return Reflect.apply(check, this, args);
      };
    }
  }
  syncBuiltinESMExports();
  return () => {
    for (const [module, name, check] of originals) module[name] = check;
    syncBuiltinESMExports();
  };
}

type Queried = Element | Element[] | null | undefined;

const isQuery = (name: string) => /^(get|query|find)(All)?By/.test(name);

// What a testing-library query found: each element's role, accessible name
// and text. A test that asserts only by querying (`getBy*` throws when nothing
// matches) observes these.
function describeFound(found: Queried, accessibleName: (element: Element) => string) {
  const one = (element: Element) => ({
    role: element.getAttribute("role") ?? element.tagName.toLowerCase(),
    name: accessibleName(element),
    text: element.textContent,
  });
  if (found === null || found === undefined) return found;
  return Array.isArray(found) ? found.map(one) : one(found);
}

/** Tells the listeners an observation that is not a matcher's (a query's). */
export function emitObservation(event: string) {
  for (const listen of listeners) listen(undefined, event);
}

/**
 * A copy of testing-library's bound queries (`screen`, what `within` and
 * `render` return) whose queries (`getBy*`, `queryBy*`, `findBy*` and their
 * `All` forms) each report what they found as an observation.
 */
export function observedQueries<T extends object>(
  bound: T,
  accessibleName: (element: Element) => string
): T {
  const copy = { ...bound } as Record<string, unknown>;
  for (const [name, query] of Object.entries(copy)) {
    if (!isQuery(name) || typeof query !== "function") continue;
    copy[name] = (...args: unknown[]) => {
      const report = (found: unknown) =>
        emitObservation(
          inspect(
            {
              query: name,
              arguments: args,
              found: describeFound(found as Queried, accessibleName),
            },
            { depth: null, colors: false, compact: true, breakLength: Infinity }
          )
        );
      const result = (query as (...a: unknown[]) => unknown)(...args);
      if (result instanceof Promise)
        return result.then((found) => {
          report(found);
          return found;
        });
      report(result);
      return result;
    };
  }
  return copy as T;
}
