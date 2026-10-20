import { onTestFinished } from "vitest";

// What the running test's stubs replaced, newest last.
const restores: (() => void)[] = [];

/**
 * Defines `key` on `target` (a global object, `navigator`, `CSS`, a DOM
 * prototype) for the running test, and puts back what was there when the test
 * ends, the newest stub first. Test files share processes (vitest.config.ts
 * `sharedDomFiles`), so what a test assigns there directly reaches the files
 * after it. For a function or accessor that exists, `vi.spyOn` does the same;
 * for a global, `vi.stubGlobal`.
 */
export function stubProperty(
  target: object,
  key: PropertyKey,
  descriptor: PropertyDescriptor
): void {
  const before = Reflect.getOwnPropertyDescriptor(target, key);
  Reflect.defineProperty(target, key, { configurable: true, ...descriptor });
  if (restores.length === 0)
    onTestFinished(() => {
      for (const restore of restores.splice(0).toReversed()) restore();
    });
  restores.push(() => {
    if (before) Reflect.defineProperty(target, key, before);
    else Reflect.deleteProperty(target, key);
  });
}
