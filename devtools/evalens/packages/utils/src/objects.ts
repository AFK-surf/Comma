export function omit<O extends Record<string, unknown>, K extends keyof O>(
  object: O,
  keys: readonly K[]
): Omit<O, K> {
  return Object.fromEntries(
    Object.entries(object).filter(([key]) => !keys.includes(key as K))
  ) as Omit<O, K>;
}
