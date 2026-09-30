export const sortCx = <
  T extends Record<
    string,
    string | number | Record<string, string | number | Record<string, string | number>>
  >,
>(
  classes: T
): T => classes;
