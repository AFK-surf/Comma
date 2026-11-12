import { useRef } from "react";

/**
 * `value` while `enabled`; while not, the value it had when last enabled. A
 * surface kept mounted while hidden (Home under another page) holds what it
 * showed, so nothing derived from it changes until it shows again.
 */
export function useHeldWhileDisabled<T>(enabled: boolean, value: T): T {
  const held = useRef(value);
  if (enabled) held.current = value;
  return held.current;
}
