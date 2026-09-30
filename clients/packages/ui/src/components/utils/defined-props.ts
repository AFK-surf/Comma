type DefinedProps<T extends Record<string, unknown>> = {
  [Key in keyof T as undefined extends T[Key] ? Key : never]?: Exclude<
    T[Key],
    undefined
  >;
} & {
  [Key in keyof T as undefined extends T[Key] ? never : Key]: T[Key];
};

export const definedProps = <T extends Record<string, unknown>>(
  props: T
): DefinedProps<T> => {
  const entries = Object.entries(props).filter(([, value]) => value !== undefined);
  return Object.fromEntries(entries) as DefinedProps<T>;
};
