import { isValidElement, useCallback, useInsertionEffect, useRef } from "react";

/*
 * A settings registry is rebuilt on every render of its owner, so nothing in
 * it keeps its identity: a Notch switch re-rendered every row and every
 * category of the page, twice. These helpers let a row or the sidebar tell
 * that its data renders the same and skip the render.
 */

type Path = readonly (string | number)[];

const isPlainObject = (value: object) => {
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
};

/**
 * Whether two registry values render the same. Callbacks in registry data
 * always match, because rows call the latest one (`withLatestCallbacks`).
 * Inside an element, props belong to that element's component, which keeps
 * the callbacks it rendered with, so they match only by identity. A value
 * that refers back to itself counts as changed, which only costs a render.
 */
export function sameSettingsValue(left: unknown, right: unknown): boolean {
  const open = new Set<object>();
  const same = (value: unknown, other: unknown, inElement: boolean): boolean => {
    if (Object.is(value, other)) return true;
    if (typeof value === "function" || typeof other === "function") {
      return !inElement && typeof value === "function" && typeof other === "function";
    }
    if (typeof value !== "object" || typeof other !== "object" || !value || !other) {
      return false;
    }
    if (open.has(value)) return false;
    open.add(value);
    try {
      if (isValidElement(value) || isValidElement(other)) {
        return (
          isValidElement(value) &&
          isValidElement(other) &&
          value.type === other.type &&
          value.key === other.key &&
          same(value.props, other.props, true)
        );
      }
      if (Array.isArray(value) || Array.isArray(other)) {
        return (
          Array.isArray(value) &&
          Array.isArray(other) &&
          value.length === other.length &&
          value.every((entry, index) => same(entry, other[index], inElement))
        );
      }
      if (!isPlainObject(value) || !isPlainObject(other)) return false;
      const valueRecord = value as Record<string, unknown>;
      const otherRecord = other as Record<string, unknown>;
      const keys = Object.keys(valueRecord);
      return (
        keys.length === Object.keys(otherRecord).length &&
        keys.every(
          (key) =>
            Object.hasOwn(otherRecord, key) &&
            same(valueRecord[key], otherRecord[key], inElement)
        )
      );
    } finally {
      open.delete(value);
    }
  };
  return same(left, right, false);
}

const valueAt = (value: unknown, path: Path) =>
  path.reduce<unknown>(
    (current, key) =>
      current && typeof current === "object"
        ? (current as Record<string | number, unknown>)[key]
        : undefined,
    value
  );

/**
 * A copy of `value` whose callbacks call the callback at the same place in
 * `latest()` when they run. A row that skipped renders therefore still acts
 * on its owner's current state. Elements stay as they are.
 */
export function withLatestCallbacks<T>(value: T, latest: () => unknown): T {
  const bind = (current: unknown, path: Path): unknown => {
    if (typeof current === "function") {
      return (...args: unknown[]) => {
        const callback = valueAt(latest(), path);
        return typeof callback === "function" ? callback(...args) : undefined;
      };
    }
    if (!current || typeof current !== "object" || isValidElement(current)) {
      return current;
    }
    if (Array.isArray(current)) {
      return current.map((entry, index) => bind(entry, [...path, index]));
    }
    if (!isPlainObject(current)) return current;
    return Object.fromEntries(
      Object.entries(current).map(([key, entry]) => [key, bind(entry, [...path, key])])
    );
  };
  return bind(value, []) as T;
}

/**
 * A callback with a stable identity that calls the latest `callback`. The
 * latest is stored before any layout effect runs, so an effect or an event
 * after the commit never reaches a stale one.
 */
export function useLatestCallback<Args extends unknown[], Result>(
  callback: (...args: Args) => Result
) {
  const latest = useRef(callback);
  useInsertionEffect(() => {
    latest.current = callback;
  });
  return useCallback((...args: Args) => latest.current(...args), []);
}
